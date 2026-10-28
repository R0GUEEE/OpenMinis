//
//  SSHServerManager.swift
//  MinisApp
//
//  [T-ssh-server] Always-on SSH access to the Shell Container.
//
//  The iSH kernel implements the guest's sockets with host sockets, so an
//  sshd started inside Alpine listens on the device's own TCP port (the same
//  fact the AOJIT benchmark relies on: it starts sshd in one iSH session and
//  reaches it from another on 127.0.0.1). This manager owns that daemon:
//
//    • installs openssh-server once (apk), generates host keys;
//    • writes /etc/ssh/minis_sshd_config with the configured port (2222);
//    • sets the root password from the Keychain and the user's authorized
//      keys, then starts `sshd` daemonised;
//    • proves it works by reading the SSH banner off 127.0.0.1, not by
//      trusting an exit code;
//    • keeps it alive while the app is active (a watchdog re-probes and
//      restarts), and starts it again on every foreground return.
//
//  iOS suspends the whole process shortly after backgrounding, which stops
//  the daemon with it; the UI says so. "Always running" therefore means "as
//  long as Minis is running", which is the only guarantee an iOS app can
//  make.
//

import Foundation
import Network
import Security

@MainActor
final class SSHServerManager: ObservableObject {
    static let shared = SSHServerManager()

    enum Status: Equatable {
        case disabled
        case stopped
        case starting
        case installing
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
        var isBusy: Bool { self == .starting || self == .installing }
    }

    // MARK: - Published state

    @Published private(set) var status: Status = .disabled
    @Published private(set) var isEnabled: Bool
    @Published private(set) var port: Int
    @Published private(set) var banner: String?
    @Published private(set) var lastError: String?
    @Published private(set) var authorizedKeys: String
    @Published private(set) var progressNote: String?
    /// Wi-Fi address shown in the UI (best effort; nil when not on a LAN).
    @Published private(set) var lanAddress: String?

    // MARK: - Private

    private let logger = AppLogger(category: "SSHServer")
    private static let enabledKey = "ssh.server.enabled"
    private static let portKey = "ssh.server.port"
    private static let keysKey = "ssh.server.authorizedKeys"
    static let defaultPort = 2222

    private var bringUpTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private let configPath = "/etc/ssh/minis_sshd_config"
    private let pidPath = "/var/run/minis-sshd.pid"

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledKey) == nil {
            isEnabled = true                     // [T-ssh-server] on by default
        } else {
            isEnabled = defaults.bool(forKey: Self.enabledKey)
        }
        let storedPort = defaults.integer(forKey: Self.portKey)
        port = storedPort > 0 ? storedPort : Self.defaultPort
        authorizedKeys = defaults.string(forKey: Self.keysKey) ?? ""
        status = isEnabled ? .stopped : .disabled
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startIfEnabled(reason: "user enabled")
        } else {
            stop()
        }
    }

    func setPort(_ newPort: Int) {
        guard (1024...65535).contains(newPort), newPort != port else { return }
        port = newPort
        UserDefaults.standard.set(newPort, forKey: Self.portKey)
        if isEnabled && status.isRunning { restart(reason: "port changed") }
    }

    func setAuthorizedKeys(_ keys: String) {
        let cleaned = Self.sanitizeKeys(keys)
        authorizedKeys = cleaned
        UserDefaults.standard.set(cleaned, forKey: Self.keysKey)
        // Applied on the next start; restarting for a key edit would drop
        // sessions the user may be typing in.
    }

    /// The root password. Generated on first use and kept in the Keychain so
    /// a rootfs reset re-applies the same one.
    var password: String {
        if let stored = SSHPasswordKeychain.load(), !stored.isEmpty { return stored }
        let generated = Self.makePassword()
        SSHPasswordKeychain.save(generated)
        return generated
    }

    func regeneratePassword() -> String {
        let generated = Self.makePassword()
        SSHPasswordKeychain.save(generated)
        if isEnabled { restart(reason: "password changed") }
        return generated
    }

    func setPassword(_ newValue: String) -> Bool {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        SSHPasswordKeychain.save(trimmed)
        if isEnabled { restart(reason: "password changed") }
        return true
    }

    // MARK: - Lifecycle

    /// Boot the container if needed and make sure sshd is up. Called on every
    /// foreground return and after the rootfs screen appears; cheap when the
    /// daemon already answers its banner.
    func startIfEnabled(reason: String) {
        guard isEnabled else {
            status = .disabled
            return
        }
        refreshLanAddress()
        if status.isRunning || status.isBusy {
            // Still verify in the background: the process can die without the
            // app noticing between foregrounds.
            Task { await self.verifyOrRestart(source: reason) }
            return
        }
        generation += 1
        let token = generation
        bringUpTask?.cancel()
        bringUpTask = Task { await self.bringUp(token: token, reason: reason) }
    }

    func restart(reason: String) {
        stopDaemon()
        generation += 1
        let token = generation
        bringUpTask?.cancel()
        bringUpTask = Task { await self.bringUp(token: token, reason: reason) }
    }

    func stop() {
        generation += 1
        bringUpTask?.cancel()
        watchdog?.cancel()
        stopDaemon()
        status = isEnabled ? .stopped : .disabled
        banner = nil
        logger.info("[T-ssh-server] stopped by user")
    }

    /// Foreground/background bookkeeping: the watchdog only makes sense while
    /// the app is in the foreground (iOS suspends everything on background).
    func handleScenePhase(active: Bool) {
        if active {
            refreshLanAddress()
            if isEnabled && !status.isBusy {
                startIfEnabled(reason: "foreground")
            }
        } else {
            watchdog?.cancel()
            watchdog = nil
        }
    }

    // MARK: - Bring-up

    private func bringUp(token: Int, reason: String) async {
        guard token == generation else { return }
        status = .starting
        lastError = nil
        progressNote = nil

        if RootfsManager.shared.didResetWhileBooted {
            fail("The Linux environment was reset. Restart the app so it can be reinstalled, then the SSH server can start.")
            return
        }

        let port = self.port
        let password = self.password
        let keys = self.authorizedKeys
        let configPath = self.configPath
        let pidPath = self.pidPath

        let outcome = await Task.detached(priority: .userInitiated) { () -> SetupOutcome in
            do {
                try Self.bootKernelIfNeeded()
            } catch {
                return SetupOutcome(error: error.localizedDescription)
            }
            return Self.setUpAndStart(port: port, password: password,
                                      authorizedKeys: keys, configPath: configPath,
                                      pidPath: pidPath,
                                      status: { note in
                // Called from the detached task; hop to the main actor only
                // when the manager is still the current generation.
                Task { @MainActor in
                    guard token == self.generation else { return }
                    self.status = note == .installing ? .installing : .starting
                    self.progressNote = note.text
                }
            })
        }.value

        guard token == generation else { return }
        progressNote = nil

        if let error = outcome.error {
            fail(error)
            return
        }

        // Exit code 0 from sshd only means it daemonised; the banner is the
        // real proof that the port is listening and the guest is answering.
        if let banner = await Self.probeBanner(port: UInt16(port), timeout: 6) {
            succeed(banner: banner, note: reason)
            return
        }

        let tail = outcome.log.split(separator: "\n").suffix(4).joined(separator: "\n")
        fail(AppLocalized("sshd started but did not answer on port \(port).\n\(tail)"))
    }

    private func succeed(banner: String, note: String) {
        status = .running
        self.banner = banner
        lastError = nil
        consecutiveFailures = 0
        refreshLanAddress()
        startWatchdog()
        logger.info("[T-ssh-server] running on :\(port) banner=\(banner) (\(note))")
    }

    private func fail(_ message: String) {
        status = .failed(message)
        lastError = message
        logger.error("[T-ssh-server] \(message)")
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.verifyOrRestart(source: "watchdog")
            }
        }
    }

    private func verifyOrRestart(source: String) async {
        guard isEnabled else { return }
        guard !status.isBusy else { return }
        if let _ = await Self.probeBanner(port: UInt16(port), timeout: 3) {
            if status != .running {
                status = .running
                lastError = nil
                banner = await Self.probeBanner(port: UInt16(port), timeout: 3)
            }
            consecutiveFailures = 0
            return
        }
        guard status.isRunning || status == .stopped else { return }
        consecutiveFailures += 1
        logger.warning("[T-ssh-server] banner probe failed (\(source)) attempt \(consecutiveFailures)")
        if consecutiveFailures <= 3 {
            restart(reason: "watchdog restart")
        } else {
            fail(AppLocalized("The SSH server keeps stopping. Open the terminal once, then tap Restart."))
        }
    }

    // MARK: - Guest side

    private struct SetupOutcome {
        var error: String?
        var log: String = ""
    }

    private enum ProgressNote {
        case starting, installing
        var text: String {
            switch self {
            case .starting: return AppLocalized("Starting…")
            case .installing: return AppLocalized("Installing OpenSSH…")
            }
        }
    }

    /// True once the fakefs change tracker and the per-session path router
    /// have been installed for this process. The chat boot path installs them
    /// too; whichever boots the kernel first must do it, or sync and
    /// /var/minis routing are silently missing for the whole session.
    nonisolated(unsafe) private static var kernelHooksInstalled = false

    nonisolated private static func bootKernelIfNeeded() throws {
        guard RootfsManager.shared.isInstalled else {
            throw NSError(domain: "SSHServer", code: -20, userInfo: [
                NSLocalizedDescriptionKey: "The Shell Container is not installed yet. Install it from Rootfs Management, then the SSH server can start."
            ])
        }
        // Boot the shared kernel without auto-installing a rootfs: starting
        // the app must not download one behind the user's back.
        if !ISHKernel.shared.isBooted {
            let error = ISHKernel.shared.boot(withRootPath: RootfsManager.shared.rootfsPath.path)
            if error < 0 {
                throw NSError(domain: "SSHServer", code: Int(error), userInfo: [
                    NSLocalizedDescriptionKey: "The Shell Container failed to boot (code \(error))."
                ])
            }
        }
        if !kernelHooksInstalled {
            kernelHooksInstalled = true
            installSessionFileChangeTracker(kernel: ISHKernel.shared)
            MinisFsRouter.shared.installHook()
        }
        RootfsManager.shared.applyDefaultMountOverlay()
    }

    /// Everything that must happen inside the guest before sshd can answer.
    /// Runs off the main actor; returns a log tail for the failure path.
    nonisolated private static func setUpAndStart(
        port: Int,
        password: String,
        authorizedKeys: String,
        configPath: String,
        pidPath: String,
        status: @escaping @Sendable (ProgressNote) -> Void
    ) -> SetupOutcome {
        var log = ""

        // 1. Package. `command -v sshd` is enough: openssh-server is the only
        // package that provides it.
        let installed = ISHShellExecutor.executeCommandSync(
            "command -v sshd >/dev/null 2>&1 && /usr/sbin/sshd -V 2>&1 | head -n 1 || true",
            timeout: 15, lineCallback: nil)
        if !installed.output.contains("OpenSSH") {
            status(.installing)
            let add = ISHShellExecutor.executeCommandSync(
                "apk add --no-cache openssh-server openssh-sftp-server 2>&1",
                timeout: 900, lineCallback: nil)
            log = add.output
            if add.exitCode != 0 {
                return SetupOutcome(error: AppLocalized("Could not install OpenSSH: \(add.output.split(separator: "\n").suffix(3).joined(separator: "\n"))"), log: log)
            }
        }

        // 2. Host keys and the config, rewritten on every start so a port or
        // password change takes effect without stale state.
        let config = """
        Port \(port)
        ListenAddress 0.0.0.0
        AddressFamily any
        HostKey /etc/ssh/ssh_host_ed25519_key
        HostKey /etc/ssh/ssh_host_rsa_key
        PermitRootLogin yes
        PubkeyAuthentication yes
        PasswordAuthentication yes
        KbdInteractiveAuthentication no
        PermitEmptyPasswords no
        AuthorizedKeysFile .ssh/authorized_keys
        UseDNS no
        X11Forwarding no
        AllowTcpForwarding yes
        MaxStartups 10:30:60
        LoginGraceTime 30
        Subsystem sftp /usr/lib/ssh/sftp-server
        PidFile \(pidPath)
        """

        let keyFile = "/root/.ssh/authorized_keys"
        let keySetup: String
        if authorizedKeys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keySetup = "mkdir -p /root/.ssh; chmod 700 /root/.ssh; : > \(keyFile); chmod 600 \(keyFile)"
        } else {
            keySetup = "mkdir -p /root/.ssh; chmod 700 /root/.ssh; printf '%s\\n' \(shellQuote(authorizedKeys)) > \(keyFile); chmod 600 \(keyFile)"
        }

        let script = """
        set -e
        mkdir -p /etc/ssh /run /var/run /root/.ssh /var/log
        (ssh-keygen -A >/dev/null 2>&1) || true
        printf '%s\\n' \(shellQuote(config)) > \(configPath)
        chmod 600 \(configPath)
        printf '%s\\n' \(shellQuote("root:\(password)")) | chpasswd
        \(keySetup)
        pkill -f \(shellQuote("sshd -f \(configPath)")) >/dev/null 2>&1 || true
        sleep 0.3
        /usr/sbin/sshd -f \(configPath) -E /var/log/minis-sshd.log
        sleep 0.5
        cat /var/log/minis-sshd.log 2>/dev/null | tail -n 5 || true
        """

        let start = ISHShellExecutor.executeCommandSync(script, timeout: 120, lineCallback: nil)
        log += "\n" + start.output + "\n" + start.errorOutput
        if start.exitCode != 0 {
            let tail = (start.output + "\n" + start.errorOutput).split(separator: "\n").suffix(5).joined(separator: "\n")
            return SetupOutcome(error: AppLocalized("Could not start sshd on port \(port):\n\(tail)"), log: log)
        }
        return SetupOutcome(error: nil, log: log)
    }

    private func stopDaemon() {
        let configPath = self.configPath
        guard ISHKernel.shared.isBooted else { return }
        _ = ISHShellExecutor.executeCommandSync(
            "pkill -f \(Self.shellQuote("sshd -f \(configPath)")) >/dev/null 2>&1 || true",
            timeout: 15, lineCallback: nil)
    }

    // MARK: - Probing

    /// Read the SSH identification string. A successful TCP connect that
    /// yields "SSH-2.0-…" proves the guest daemon is answering, which an exit
    /// code never does (sshd forks into the background).
    nonisolated static func probeBanner(port: UInt16, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let queue = DispatchQueue(label: "minis.ssh.probe")
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let box = ResumeOnce(continuation: continuation, queue: queue)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
                        if let data, let text = String(data: data, encoding: .utf8),
                           text.hasPrefix("SSH-") {
                            box.finish(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else if error != nil {
                            box.finish(nil)
                        }
                        connection.cancel()
                    }
                case .failed, .cancelled:
                    box.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                box.finish(nil)
                connection.cancel()
            }
        }
    }

    /// Resume-once wrapper: NWConnection can call back on several paths and a
    /// double resume would trap.
    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<String?, Never>?
        private let queue: DispatchQueue
        init(continuation: CheckedContinuation<String?, Never>, queue: DispatchQueue) {
            self.continuation = continuation
            self.queue = queue
        }
        func finish(_ value: String?) {
            queue.async {
                guard let continuation = self.continuation else { return }
                self.continuation = nil
                continuation.resume(returning: value)
            }
        }
    }

    // MARK: - Helpers

    private func refreshLanAddress() {
        lanAddress = Self.currentWiFiAddress()
    }

    nonisolated static func currentWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer = first
        while true {
            let interface = pointer.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 is Wi-Fi on iPhone; other interfaces are tunnels/cellular.
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let value = String(cString: host)
                        if !value.isEmpty { address = value }
                    }
                }
            }
            guard let next = interface.ifa_next else { break }
            pointer = next
        }
        return address
    }

    nonisolated private static func sanitizeKeys(_ raw: String) -> String {
        let allowed = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                if line.isEmpty || line.hasPrefix("#") { return true }
                return line.range(of: #"^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)[A-Za-z0-9@.-]+ [A-Za-z0-9+/=]+"#,
                                 options: .regularExpression) != nil
            }
        // Cap the file size; authorized_keys is read by sshd on every login.
        let joined = allowed.joined(separator: "\n")
        return String(joined.prefix(16_000))
    }

    nonisolated private static func makePassword() -> String {
        // No ambiguous glyphs: the password is read off a phone screen and
        // typed on a computer.
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<20).map { _ in alphabet.randomElement()! })
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Keychain

private enum SSHPasswordKeychain {
    private static let service = "app.openminis.ssh"
    private static let account = "root-password"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func save(_ value: String) {
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
