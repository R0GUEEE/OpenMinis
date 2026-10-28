//
//  MCPHostSettingsView.swift
//  MinisApp
//
//  [T-mcp-host] Settings → MCP Server: the app as an MCP server.
//

import SwiftUI
import UIKit

struct MCPHostSettingsView: View {
    @ObservedObject private var server = MCPHostedServer.shared

    @State private var portText = ""
    @State private var revealToken = false
    @State private var notice: String?
    @State private var showNotice = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { server.isEnabled }, set: { server.setEnabled($0) })) {
                    Label {
                        Text(AppLocalized("MCP Server"))
                    } icon: {
                        Image(systemName: "server.rack")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .frame(width: 21, height: 21)
                            .background(.teal, in: Circle())
                    }
                }

                if server.isEnabled {
                    HStack {
                        Text(AppLocalized("Status"))
                        Spacer()
                        switch server.state {
                        case .running:
                            Text(AppLocalized("Running")).foregroundStyle(.green)
                        case .starting:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(AppLocalized("Starting…")).foregroundStyle(.secondary)
                            }
                        case .failed(let message):
                            Text(message).font(.caption).foregroundStyle(.red)
                        case .disabled:
                            Text(AppLocalized("Stopped")).foregroundStyle(.secondary)
                        }
                    }
                    if server.state == .running {
                        LabeledContent(AppLocalized("Endpoint")) {
                            Text(verbatim: server.localURL)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        if server.allowLAN, let lan = server.lanURL {
                            LabeledContent(AppLocalized("LAN endpoint")) {
                                Text(verbatim: lan)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        HStack {
                            Text(AppLocalized("Requests served"))
                            Spacer()
                            Text(verbatim: "\(server.requestCount)").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(AppLocalized("Hosted MCP Server"))
            } footer: {
                Text(AppLocalized("Exposes the Shell Container and app state as MCP tools (shell_execute, file_read, file_write, list_dir, app_info) so another AI client can use this device. Runs while Minis is running; iOS suspends it in the background."))
            }

            if server.isEnabled {
                Section {
                    HStack {
                        Text(AppLocalized("Port"))
                        Spacer()
                        TextField("8099", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .font(.body.monospaced())
                    }
                    Button(AppLocalized("Apply Port")) {
                        guard let value = Int(portText), (1024...65535).contains(value) else {
                            notify(AppLocalized("Use a port between 1024 and 65535."))
                            return
                        }
                        server.setPort(value)
                        notify(AppLocalized("Port set to \(value)."))
                    }
                    Toggle(AppLocalized("Allow LAN"), isOn: Binding(
                        get: { server.allowLAN },
                        set: { server.setAllowLAN($0) }
                    ))
                } header: {
                    Text(AppLocalized("Network"))
                } footer: {
                    Text(AppLocalized("Off: only processes on this device (including the Shell Container) can connect. On: other devices on your Wi-Fi can connect using the LAN endpoint and the token. The app cannot bind a single interface, so keep the token secret."))
                }

                Section {
                    HStack {
                        Text(AppLocalized("Bearer token"))
                        Spacer()
                        Text(verbatim: revealToken ? server.token : String(repeating: "•", count: 12))
                            .font(.caption.monospaced())
                        Button {
                            revealToken.toggle()
                        } label: {
                            Image(systemName: revealToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        UIPasteboard.general.string = server.token
                        notify(AppLocalized("Token copied."))
                    } label: {
                        Label(AppLocalized("Copy Token"), systemImage: "doc.on.doc")
                    }
                    Button(AppLocalized("Generate New Token")) {
                        _ = server.regenerateToken()
                        notify(AppLocalized("New token generated. Existing clients must be updated."))
                    }
                } header: {
                    Text(AppLocalized("Authentication"))
                } footer: {
                    Text(AppLocalized("Every request except /health must carry “Authorization: Bearer <token>”."))
                }

                Section {
                    NavigationLink {
                        MCPHostClientConfigView()
                    } label: {
                        Label(AppLocalized("Client Configuration"), systemImage: "doc.plaintext")
                    }
                    NavigationLink {
                        MCPHostToolsView()
                    } label: {
                        LabeledContent(AppLocalized("Tools")) {
                            Text(AppLocalized("5 available"))
                        }
                    }
                } header: {
                    Text(AppLocalized("Connect a Client"))
                }
            }
        }
        .navigationTitle(AppLocalized("MCP Server"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            portText = String(server.port)
            server.startIfEnabled()
        }
        .alert(AppLocalized("MCP Server"), isPresented: $showNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            if let notice { Text(notice) }
        }
    }

    private func notify(_ text: String) {
        notice = text
        showNotice = true
    }
}

// MARK: - Client config

struct MCPHostClientConfigView: View {
    @ObservedObject private var server = MCPHostedServer.shared

    private var snippet: String {
        let url = server.allowLAN ? (server.lanURL ?? server.localURL) : server.localURL
        return """
        {
          "mcpServers": {
            "minis-device": {
              "type": "http",
              "url": "\(url)",
              "headers": {
                "Authorization": "Bearer \(server.token)"
              }
            }
          }
        }
        """
    }

    private var curlSnippet: String {
        let url = server.allowLAN ? (server.lanURL ?? server.localURL) : server.localURL
        return """
        curl -s \(url) \\
          -H 'Authorization: Bearer \(server.token)' \\
          -H 'Content-Type: application/json' \\
          -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
        """
    }

    var body: some View {
        List {
            Section {
                Text(snippet)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = snippet
                } label: {
                    Label(AppLocalized("Copy JSON"), systemImage: "doc.on.doc")
                }
            } header: {
                Text(AppLocalized("Claude Desktop / Cursor"))
            } footer: {
                Text(AppLocalized("Add this to the client's MCP configuration. The clients that speak Streamable HTTP accept the url form; for older clients use an mcp-remote bridge."))
            }

            Section {
                Text(curlSnippet)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = curlSnippet
                } label: {
                    Label(AppLocalized("Copy cURL"), systemImage: "doc.on.doc")
                }
            } header: {
                Text(AppLocalized("Test from a computer"))
            } footer: {
                Text(AppLocalized("A tools/list response means the endpoint and token are working. Run it on the same device for the localhost endpoint, or from another device with Allow LAN on."))
            }
        }
        .navigationTitle(AppLocalized("Client Configuration"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Tools

struct MCPHostToolsView: View {
    private let rows: [(String, String)] = [
        ("shell_execute", "Run a shell command in the Shell Container and return stdout/stderr with the exit code."),
        ("file_read", "Read a text file by Linux absolute path."),
        ("file_write", "Write or append text to a file in the container."),
        ("list_dir", "List a directory with ls -la."),
        ("app_info", "Report Minis version, container state, SSH state and plugin count."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(rows, id: \.0) { name, description in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: name)
                            .font(.subheadline.weight(.semibold).monospaced())
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text(AppLocalized("Tools run with the same permissions as the on-device agent: root inside the container. Anyone holding the token has that access."))
            }
        }
        .navigationTitle(AppLocalized("MCP Tools"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
