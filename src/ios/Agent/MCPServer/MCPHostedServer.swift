//
//  MCPHostedServer.swift
//  MinisApp
//
//  [T-mcp-host] A Model Context Protocol server hosted INSIDE Minis, so an
//  external AI client (Claude Desktop, Cursor, another agent) can use this
//  device's Shell Container and read its state over HTTP.
//
//  This is the opposite direction from MCPStore: MCPStore is the app acting as
//  an MCP CLIENT for third-party servers. This file makes the app an MCP
//  SERVER (Streamable HTTP transport):
//
//      POST /mcp   JSON-RPC 2.0 request  → application/json response
//      GET  /mcp   event stream          → 405 (this server is request/response)
//      GET  /health                      → plain status text
//
//  Tools exposed: shell_execute, file_read, file_write, list_dir, app_info.
//  Everything runs in the SAME iSH/Alpine container the agent uses, so the
//  paths and the environment are identical.
//
//  Auth: a Bearer token generated on first enable (32 chars, Keychain). The
//  listener binds 127.0.0.1 by default; "Allow LAN" switches it to 0.0.0.0.
//

import Foundation
import Network
import Security

// MARK: - Host

@MainActor
final class MCPHostedServer: ObservableObject {
    static let shared = MCPHostedServer()

    enum State: Equatable {
        case disabled
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var isEnabled: Bool
    @Published private(set) var port: Int
    @Published private(set) var allowLAN: Bool
    @Published private(set) var token: String
    @Published private(set) var lanAddress: String?
    @Published private(set) var requestCount: Int = 0

    private var server: MCPHTTPServer?
    private let logger = AppLogger(category: "MCPHost")

    private static let enabledKey = "mcpHost.enabled"
    private static let portKey = "mcpHost.port"
    private static let lanKey = "mcpHost.allowLAN"
    static let defaultPort = 8099

    private init() {
        let defaults = UserDefaults.standard
        // Enabled out of the box: the point of the feature is that an external
        // AI can reach it. Bound to localhost until "Allow LAN" is turned on.
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let stored = defaults.integer(forKey: Self.portKey)
        port = stored >= 1024 ? stored : Self.defaultPort
        allowLAN = defaults.object(forKey: Self.lanKey) as? Bool ?? false
        token = MCPHostToken.load() ?? {
            let generated = MCPHostToken.generate()
            MCPHostToken.save(generated)
            return generated
        }()
        state = .disabled
    }

    // MARK: Settings

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func setPort(_ value: Int) {
        guard (1024...65535).contains(value), value != port else { return }
        port = value
        UserDefaults.standard.set(value, forKey: Self.portKey)
        if isEnabled { restart() }
    }

    func setAllowLAN(_ enabled: Bool) {
        guard enabled != allowLAN else { return }
        allowLAN = enabled
        UserDefaults.standard.set(enabled, forKey: Self.lanKey)
        if isEnabled { restart() }
    }

    func regenerateToken() -> String {
        let generated = MCPHostToken.generate()
        MCPHostToken.save(generated)
        token = generated
        if isEnabled { restart() }
        return generated
    }

    /// URL an MCP client connects to. Always localhost for on-device use; the
    /// LAN address is offered separately when enabled.
    var localURL: String { "http://127.0.0.1:\(port)/mcp" }
    var lanURL: String? { lanAddress.map { "http://\($0):\(port)/mcp" } }

    // MARK: Lifecycle

    func startIfEnabled() {
        guard isEnabled else { state = .disabled; return }
        start()
    }

    func start() {
        guard isEnabled else { return }
        if case .running = state { return }
        state = .starting
        let listenerHost = allowLAN ? "0.0.0.0" : "127.0.0.1"
        let host = MCPHTTPServer.Host(port: UInt16(port), address: listenerHost, token: token, toolBox: MCPToolBox())
        let server = MCPHTTPServer(host: host) { [weak self] count in
            Task { @MainActor in self?.requestCount = count }
        }
        self.server = server
        do {
            try server.start()
            state = .running
            lanAddress = SSHServerManager.currentWiFiAddress()
            logger.info("[T-mcp-host] listening on \(listenerHost):\(port)")
        } catch {
            state = .failed(error.localizedDescription)
            logger.error("[T-mcp-host] start failed: \(error.localizedDescription)")
        }
    }

    func restart() {
        stop(keepEnabled: true)
        start()
    }

    func stop(keepEnabled: Bool = false) {
        server?.stop()
        server = nil
        state = keepEnabled ? .starting : .disabled
    }
}

// MARK: - HTTP transport

final class MCPHTTPServer: @unchecked Sendable {
    struct Host: Sendable {
        let port: UInt16
        let address: String
        let token: String
        let toolBox: MCPToolBox
    }

    private let host: Host
    private let onRequest: @Sendable (Int) -> Void
    private let queue = DispatchQueue(label: "minis.mcp.host", qos: .userInitiated)
    private var listener: NWListener?
    private var requestCount = 0
    private let sessionId = UUID().uuidString

    init(host: Host, onRequest: @escaping @Sendable (Int) -> Void) {
        self.host = host
        self.onRequest = onRequest
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: host.port)!
        // "Off" must actually restrict the socket, not just the documentation:
        // pin the local endpoint to loopback. "Allow LAN" listens on every
        // interface (NWListener's default).
        if host.address == "127.0.0.1" {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        }
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                AppLogger(category: "MCPHost").error("[T-mcp-host] listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let error {
                connection.cancel()
                _ = error
                return
            }
            // Headers complete?
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 128 * 1024 || isComplete {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: buffer)
                }
                return
            }
            let headerData = buffer[..<headerEnd.lowerBound]
            let headerText = String(data: headerData, encoding: .utf8) ?? ""
            let contentLength = Self.contentLength(in: headerText)
            let bodyStart = headerEnd.upperBound
            let available = buffer.count - bodyStart
            if available < contentLength {
                if isComplete { connection.cancel(); return }
                self.read(connection, buffer: buffer)
                return
            }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            self.requestCount += 1
            self.onRequest(self.requestCount)
            let response = self.respond(headers: headerText, body: body)
            self.write(response, to: connection)
        }
    }

    private static func contentLength(in headerText: String) -> Int {
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func write(_ data: Data, to connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Request handling

    private func respond(headers: String, body: Data) -> Data {
        let requestLine = headers.split(separator: "\r\n").first.map(String.init) ?? ""
        let fields = requestLine.split(separator: " ")
        let method = fields.first.map(String.init)?.uppercased() ?? ""
        let path = fields.count > 1 ? String(fields[1]) : "/"

        if method == "GET", path.hasPrefix("/health") {
            return Self.httpResponse(status: 200, contentType: "text/plain; charset=utf-8",
                                     body: Data("minis mcp server: ok\n".utf8))
        }

        // Auth. /health is deliberately open so a client can check the port.
        guard authorized(headers: headers) else {
            return Self.jsonRPCError(status: 401, code: -32001, message: "Unauthorized: send Authorization: Bearer <token>")
        }

        guard path.hasPrefix("/mcp") else {
            return Self.httpResponse(status: 404, contentType: "text/plain",
                                     body: Data("Not found\n".utf8))
        }

        switch method {
        case "DELETE":
            return Self.httpResponse(status: 200, contentType: "application/json", body: Data("{}".utf8))
        case "GET":
            // Streamable HTTP allows a GET event stream. This server is a
            // plain request/response endpoint; tell the client so instead of
            // holding a connection open forever.
            return Self.httpResponse(status: 405, contentType: "application/json",
                                     body: Data(#"{"error":"This MCP server only supports POST /mcp"}"#.utf8),
                                     extraHeaders: ["Allow": "POST, DELETE"])
        case "POST":
            return handleJSONRPC(body: body)
        default:
            return Self.httpResponse(status: 405, contentType: "text/plain", body: Data("Method not allowed\n".utf8))
        }
    }

    private func authorized(headers: String) -> Bool {
        guard !host.token.isEmpty else { return true }
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "authorization" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("bearer ") else { continue }
            let presented = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            return MCPHostToken.constantTimeEquals(presented, host.token)
        }
        return false
    }

    private func handleJSONRPC(body: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return Self.jsonRPCError(status: 400, code: -32700, message: "Parse error")
        }
        if let batch = object as? [[String: Any]] {
            var responses: [[String: Any]] = []
            for message in batch {
                if let response = handleSingle(message) { responses.append(response) }
            }
            if responses.isEmpty {
                return Self.httpResponse(status: 202, contentType: "application/json", body: Data())
            }
            let data = (try? JSONSerialization.data(withJSONObject: responses)) ?? Data("[]".utf8)
            return Self.httpResponse(status: 200, contentType: "application/json", body: data)
        }
        guard let message = object as? [String: Any] else {
            return Self.jsonRPCError(status: 400, code: -32600, message: "Invalid Request")
        }
        if let response = handleSingle(message) {
            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
            return Self.httpResponse(status: 200, contentType: "application/json", body: data,
                                     extraHeaders: ["Mcp-Session-Id": sessionId])
        }
        // Notification: no JSON-RPC response body.
        return Self.httpResponse(status: 202, contentType: "application/json", body: Data(),
                                 extraHeaders: ["Mcp-Session-Id": sessionId])
    }

    /// Returns nil for notifications (no id).
    private func handleSingle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        func result(_ value: Any) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
        }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": text]]
        }

        if method.hasPrefix("notifications/") { return nil }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested ?? "2025-06-18"
            return result([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "minis-mcp-host", "version": Self.appVersion],
                "instructions": "Tools run inside the Minis Shell Container (Alpine Linux on this device). Paths are Linux paths inside that container, e.g. /root/notes.md or /var/minis/workspace/.",
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": MCPToolBox.toolDefinitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let outcome = host.toolBox.call(name: name, arguments: arguments)
            var payload: [String: Any] = [
                "content": [["type": "text", "text": outcome.text]],
            ]
            if !outcome.success { payload["isError"] = true }
            return result(payload)
        case "resources/list":
            return result(["resources": []])
        case "prompts/list":
            return result(["prompts": []])
        default:
            return error(-32601, "Method not found: \(method)")
        }
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    // MARK: HTTP helpers

    private static func jsonRPCError(status: Int, code: Int, message: String) -> Data {
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(),
                                      "error": ["code": code, "message": message]]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return httpResponse(status: status, contentType: "application/json", body: data)
    }

    private static func httpResponse(status: Int, contentType: String, body: Data,
                                     extraHeaders: [String: String] = [:]) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        for (key, value) in extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: - Tools

struct MCPToolOutcome {
    var text: String
    var success: Bool
}

/// Executes the MCP tools against the same container the agent uses. Stateless
/// and callable from the server's queue: every operation goes through the
/// guest shell, so path handling, bind mounts and permissions match exactly
/// what the on-device agent sees.
struct MCPToolBox: Sendable {
    static var toolDefinitions: [[String: Any]] { [
        [
            "name": "shell_execute",
            "description": "Execute a shell command in the Minis Shell Container (Alpine Linux on the user's device). Returns combined stdout and stderr and the exit code. Each call is a fresh /bin/sh process; the working directory is /root.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "Shell command to run."],
                    "timeout_seconds": ["type": "integer", "description": "Timeout in seconds (default 120, max 900).",
                                        "minimum": 1, "maximum": 900],
                    "working_directory": ["type": "string", "description": "Absolute directory to run in (default /root)."],
                ],
                "required": ["command"],
            ],
        ],
        [
            "name": "file_read",
            "description": "Read a text file from the container's filesystem. Linux absolute path. Returns up to max_bytes, with truncation noted.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute Linux path, e.g. /root/notes.md."],
                    "max_bytes": ["type": "integer", "description": "Maximum bytes to return (default 100000, max 1000000).",
                                  "minimum": 1, "maximum": 1_000_000],
                ],
                "required": ["path"],
            ],
        ],
        [
            "name": "file_write",
            "description": "Write text to a file in the container, creating parent directories when create_dirs is true. Content is transferred as base64 internally, so arbitrary UTF-8 is preserved exactly.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute Linux path."],
                    "content": ["type": "string", "description": "Text to write."],
                    "append": ["type": "boolean", "description": "Append instead of overwrite (default false)."],
                    "create_dirs": ["type": "boolean", "description": "Create parent directories (default false)."],
                ],
                "required": ["path", "content"],
            ],
        ],
        [
            "name": "list_dir",
            "description": "List a directory inside the container (ls -la).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute directory path (default /root)."],
                ],
            ],
        ],
        [
            "name": "app_info",
            "description": "Report the state of the host app: Minis version, whether the Linux container is installed and booted, SSH server status, installed plugin and MCP client counts.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
    ] }

    func call(name: String, arguments: [String: Any]) -> MCPToolOutcome {
        switch name {
        case "shell_execute": return shellExecute(arguments)
        case "file_read": return fileRead(arguments)
        case "file_write": return fileWrite(arguments)
        case "list_dir": return listDir(arguments)
        case "app_info": return appInfo()
        default:
            return MCPToolOutcome(text: "Unknown tool: \(name)", success: false)
        }
    }

    // MARK: Implementations

    private func shellExecute(_ args: [String: Any]) -> MCPToolOutcome {
        guard let command = args["command"] as? String, !command.isEmpty else {
            return MCPToolOutcome(text: "Missing required argument: command", success: false)
        }
        guard ISHKernel.shared.isBooted else {
            return MCPToolOutcome(text: "The Shell Container is not booted. Open the Minis terminal once.", success: false)
        }
        let timeout = min(max((args["timeout_seconds"] as? Int) ?? 120, 1), 900)
        let cwd = (args["working_directory"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/root"
        let script = "cd \(MCPToolBox.quote(cwd)) 2>/dev/null || cd /root\n\(command)\nprintf '\\n[exit %d]' $?"
        let result = ISHShellExecutor.executeCommandSync(script, timeout: TimeInterval(timeout), lineCallback: nil)
        var text = result.output
        if !result.errorOutput.isEmpty {
            text += (text.isEmpty ? "" : "\n") + result.errorOutput
        }
        if result.error == .timeout {
            text = "Error: command timed out after \(timeout)s.\n" + text
        }
        return MCPToolOutcome(text: MCPToolBox.truncate(text.isEmpty ? "(no output)" : text),
                              success: result.exitCode == 0 && result.error != .timeout)
    }

    private func fileRead(_ args: [String: Any]) -> MCPToolOutcome {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return MCPToolOutcome(text: "Missing required argument: path", success: false)
        }
        let maxBytes = min(max((args["max_bytes"] as? Int) ?? 100_000, 1), 1_000_000)
        let script = "if [ ! -f \(MCPToolBox.quote(path)) ]; then echo 'Error: not a file: \(path.replacingOccurrences(of: "'", with: ""))' >&2; exit 2; fi\nhead -c \(maxBytes) -- \(MCPToolBox.quote(path))"
        return runGuest(script, timeout: 30)
    }

    private func fileWrite(_ args: [String: Any]) -> MCPToolOutcome {
        guard let path = args["path"] as? String, !path.isEmpty,
              let content = args["content"] as? String else {
            return MCPToolOutcome(text: "Missing required argument: path or content", success: false)
        }
        let append = (args["append"] as? Bool) ?? false
        let createDirs = (args["create_dirs"] as? Bool) ?? false
        let base64 = Data(content.utf8).base64EncodedString()
        let redirect = append ? ">>" : ">"
        var script = ""
        if createDirs {
            script += "mkdir -p -- \(MCPToolBox.quote((path as NSString).deletingLastPathComponent)) 2>/dev/null || true\n"
        }
        script += "printf '%s' \(MCPToolBox.quote(base64)) | base64 -d \(redirect) \(MCPToolBox.quote(path)) && wc -c < \(MCPToolBox.quote(path))"
        let outcome = runGuest(script, timeout: 60)
        if outcome.success {
            return MCPToolOutcome(text: "Wrote \(content.utf8.count) bytes to \(path)\n" + outcome.text, success: true)
        }
        return outcome
    }

    private func listDir(_ args: [String: Any]) -> MCPToolOutcome {
        let path = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "/root"
        return runGuest("ls -la -- \(MCPToolBox.quote(path))", timeout: 30)
    }

    private func appInfo() -> MCPToolOutcome {
        let defaults = UserDefaults.standard
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let rootfs = RootfsManager.shared.isInstalled ? "installed" : "not installed"
        let kernel = ISHKernel.shared.isBooted ? "booted" : "not booted"
        let sshEnabled = defaults.object(forKey: "ssh.server.enabled") as? Bool ?? true
        let sshPort = defaults.integer(forKey: "ssh.server.port")
        let plugins = (try? FileManager.default.contentsOfDirectory(
            at: AIChatViewModel.minisPluginsPersistentDir, includingPropertiesForKeys: nil))?.count ?? 0
        let text = """
        Minis \(version) (\(build))
        Shell Container: \(rootfs), \(kernel)
        SSH server: \(sshEnabled ? "enabled on port \(sshPort == 0 ? 2222 : sshPort)" : "disabled")
        Plugins installed: \(plugins)
        Device: \(SSHServerManager.currentWiFiAddress() ?? "no Wi-Fi address")
        """
        return MCPToolOutcome(text: text, success: true)
    }

    private func runGuest(_ script: String, timeout: TimeInterval) -> MCPToolOutcome {
        guard ISHKernel.shared.isBooted else {
            return MCPToolOutcome(text: "The Shell Container is not booted. Open the Minis terminal once.", success: false)
        }
        let result = ISHShellExecutor.executeCommandSync(script, timeout: timeout, lineCallback: nil)
        var text = result.output
        if !result.errorOutput.isEmpty {
            text += (text.isEmpty ? "" : "\n") + result.errorOutput
        }
        if result.error == .timeout {
            text = "Error: timed out.\n" + text
        }
        return MCPToolOutcome(text: MCPToolBox.truncate(text.isEmpty ? "(no output)" : text),
                              success: result.exitCode == 0 && result.error != .timeout)
    }

    static func truncate(_ text: String) -> String {
        let limit = 120_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… [truncated]"
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Token

enum MCPHostToken {
    private static let service = "app.openminis.mcphost"
    private static let account = "bearer-token"

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    static func load() -> String? {
        var query = query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String) {
        let base = query()
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(base as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = base
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func generate() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }

    /// Compare without an early exit on the first differing byte.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
