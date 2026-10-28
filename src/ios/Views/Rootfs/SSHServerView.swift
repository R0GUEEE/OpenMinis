//
//  SSHServerView.swift
//  MinisApp
//
//  [T-ssh-server] Rootfs Management → SSH Access, plus the settings screen.
//  Settings are read back FROM /etc/ssh/sshd_config, the file sshd uses.
//

import SwiftUI
import UIKit

// MARK: - Section

struct SSHServerSection: View {
    @ObservedObject private var manager = SSHServerManager.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { manager.isEnabled },
                set: { manager.setEnabled($0) }
            )) {
                Label {
                    Text(AppLocalized("SSH Server"))
                } icon: {
                    Image(systemName: "network")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .frame(width: 21, height: 21)
                        .background(.indigo, in: Circle())
                }
            }

            if manager.isEnabled {
                statusRow

                if manager.status.isRunning {
                    if let pid = manager.guestPID {
                        LabeledContent(AppLocalized("Running in container")) {
                            Text(verbatim: "pid \(pid)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.green)
                        }
                    }
                    connectionRows
                }

                NavigationLink {
                    SSHServerSettingsView()
                } label: {
                    Text(AppLocalized("SSH Settings"))
                }

                if case .failed(let message) = manager.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text(AppLocalized("SSH Access"))
        } footer: {
            Text(AppLocalized("sshd runs inside the Alpine container and listens on 0.0.0.0. Other apps on this device reach it at 127.0.0.1; other devices on the network use the LAN address. iOS suspends it while Minis is in the background."))
        }
        .onAppear {
            manager.refreshFromConfig()
            manager.startIfEnabled(reason: "rootfs screen")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Text(AppLocalized("Status"))
            Spacer()
            switch manager.status {
            case .disabled:
                Text(AppLocalized("Off")).foregroundStyle(.secondary)
            case .stopped:
                Text(AppLocalized("Stopped")).foregroundStyle(.secondary)
            case .starting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalized("Starting…")).foregroundStyle(.secondary)
                }
            case .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalized("Installing OpenSSH…")).foregroundStyle(.secondary)
                }
            case .running:
                Text(verbatim: "\(manager.banner ?? "SSH") · :\(manager.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
            case .failed:
                Text(AppLocalized("Failed")).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var connectionRows: some View {
        let port = manager.port
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalized("Connect"))
                .font(.caption)
                .foregroundStyle(.secondary)
            copyRow("ssh -p \(port) root@127.0.0.1")
            if let address = manager.lanAddress {
                copyRow("ssh -p \(port) root@\(address)")
            } else {
                Text(AppLocalized("No Wi-Fi address yet; other devices can connect once the phone is on a network."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func copyRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = command
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(AppLocalized("Copy SSH command"))
        }
    }
}

// MARK: - Settings

struct SSHServerSettingsView: View {
    @ObservedObject private var manager = SSHServerManager.shared

    @State private var portText = ""
    @State private var newPassword = ""
    @State private var revealPassword = false
    @State private var notice: String?
    @State private var showNotice = false

    var body: some View {
        List {
            Section {
                LabeledContent(AppLocalized("Status")) {
                    switch manager.status {
                    case .running: Text(AppLocalized("Running")).foregroundStyle(.green)
                    case .failed: Text(AppLocalized("Failed")).foregroundStyle(.red)
                    case .starting, .installing: Text(AppLocalized("Starting…")).foregroundStyle(.secondary)
                    case .stopped: Text(AppLocalized("Stopped")).foregroundStyle(.secondary)
                    case .disabled: Text(AppLocalized("Off")).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(AppLocalized("Config file")) {
                    Text(verbatim: SSHServerManager.configPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let pid = manager.guestPID {
                    LabeledContent(AppLocalized("Guest PID")) {
                        Text(verbatim: "\(pid)")
                            .font(.body.monospaced())
                            .foregroundStyle(.green)
                    }
                }
                if let process = manager.guestProcess {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalized("Process in container"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: process)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let address = manager.lanAddress {
                    LabeledContent(AppLocalized("LAN address")) {
                        Text(verbatim: "\(address):\(manager.port)")
                            .font(.body.monospaced())
                    }
                }
                if let banner = manager.banner {
                    LabeledContent(AppLocalized("Version")) {
                        Text(verbatim: banner)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                }
                if let error = manager.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button {
                    manager.refreshFromConfig()
                    manager.refreshRuntimeStatus()
                } label: {
                    Label(AppLocalized("Reload from sshd_config"), systemImage: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing)
            } header: {
                Text(AppLocalized("Server"))
            } footer: {
                Text(AppLocalized("Settings on this screen are read from /etc/ssh/sshd_config. If you edit that file in the terminal, tap Reload to see it here."))
            }

            Section {
                HStack {
                    Text(AppLocalized("Port"))
                    Spacer()
                    TextField("2222", text: $portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .font(.body.monospaced())
                }
                Button(AppLocalized("Apply Port")) {
                    guard let value = Int(portText.trimmingCharacters(in: .whitespaces)),
                          (1...65535).contains(value) else {
                        notify(AppLocalized("Use a port between 1 and 65535."))
                        return
                    }
                    manager.setPort(value)
                    notify(AppLocalized("Port set to \(value)."))
                }
                Button(AppLocalized("Restart Server")) {
                    manager.restart(reason: "user restart")
                }
                .disabled(!manager.isEnabled)
            } header: {
                Text(AppLocalized("Port"))
            } footer: {
                Text(AppLocalized("Default 2222. The server listens on 0.0.0.0 so both other apps on this device and other devices on the network can connect."))
            }

            Section {
                Toggle(AppLocalized("Password Authentication"), isOn: Binding(
                    get: { manager.passwordAuthentication },
                    set: { manager.setPasswordAuthentication($0) }
                ))
                Toggle(AppLocalized("Permit Root Login"), isOn: Binding(
                    get: { manager.permitRootLogin },
                    set: { manager.setPermitRootLogin($0) }
                ))
                Toggle(AppLocalized("Allow Empty Password"), isOn: Binding(
                    get: { manager.allowEmptyPassword },
                    set: { manager.setAllowEmptyPassword($0) }
                ))
            } header: {
                Text(AppLocalized("Authentication"))
            } footer: {
                Text(AppLocalized("These map to PasswordAuthentication, PermitRootLogin and PermitEmptyPasswords in sshd_config. With an empty password and PermitEmptyPasswords on, anyone who can reach the port can log in as root — only do that on a trusted network."))
            }

            Section {
                HStack {
                    Text(AppLocalized("Root password"))
                    Spacer()
                    if manager.password.isEmpty {
                        Text(AppLocalized("None")).foregroundStyle(.orange)
                    } else {
                        Text(verbatim: revealPassword ? manager.password : String(repeating: "•", count: 12))
                            .font(.body.monospaced())
                    }
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .disabled(manager.password.isEmpty)
                    .accessibilityLabel(revealPassword ? AppLocalized("Hide password") : AppLocalized("Show password"))
                }
                Button {
                    UIPasteboard.general.string = manager.password
                    notify(AppLocalized("Password copied."))
                } label: {
                    Label(AppLocalized("Copy Password"), systemImage: "doc.on.doc")
                }
                .disabled(manager.password.isEmpty)
                Button(AppLocalized("Generate New Password")) {
                    _ = manager.regeneratePassword()
                    notify(AppLocalized("New password generated."))
                }
            } header: {
                Text(AppLocalized("Password Authentication"))
            } footer: {
                Text(AppLocalized("Stored in the iOS Keychain and re-applied to the root account every time the server starts. Empty means no password (requires Allow Empty Password)."))
            }

            Section {
                TextField(AppLocalized("New password (any length; empty = none)"), text: $newPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(AppLocalized("Set Password")) {
                    let value = newPassword
                    if manager.setPassword(value) {
                        newPassword = ""
                        if value.isEmpty {
                            notify(AppLocalized("Empty password set. Anyone who can reach the port can log in as root."))
                        } else {
                            notify(AppLocalized("Password updated (\(value.count) characters)."))
                        }
                    } else {
                        notify(AppLocalized("The password can contain any characters except line breaks."))
                    }
                }
                if manager.hasEmptyPassword {
                    Text(AppLocalized("The root account currently has NO password."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(AppLocalized("Change Password"))
            } footer: {
                Text(AppLocalized("There is no minimum length. Clearing the field and tapping Set Password removes the password and enables empty-password logins."))
            }

            Section {
                NavigationLink {
                    SSHAuthorizedKeysEditor(manager: manager)
                } label: {
                    LabeledContent(AppLocalized("Authorized Keys")) {
                        Text(manager.authorizedKeys.isEmpty
                             ? AppLocalized("None")
                             : AppLocalized("\(Self.keyCount(manager.authorizedKeys)) key(s)"))
                    }
                }
            } header: {
                Text(AppLocalized("Public Key Authentication"))
            } footer: {
                Text(AppLocalized("Paste ssh-ed25519 / ssh-rsa public keys, one per line. Password login stays available alongside them."))
            }

            Section {
                NavigationLink {
                    SSHConfigViewer()
                } label: {
                    Label(AppLocalized("View sshd_config"), systemImage: "doc.plaintext")
                }
            }

            Section {
                Button(role: .destructive) {
                    manager.stop()
                    notify(AppLocalized("SSH server stopped. Turn it back on from Rootfs Management."))
                } label: {
                    Text(AppLocalized("Stop Server"))
                }
            }
        }
        .navigationTitle(AppLocalized("SSH Server"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            portText = String(manager.port)
            manager.refreshFromConfig()
        }
        .onChange(of: manager.port) { newValue in
            portText = String(newValue)
        }
        .alert(AppLocalized("SSH Server"), isPresented: $showNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            if let notice { Text(notice) }
        }
    }

    private func notify(_ message: String) {
        notice = message
        showNotice = true
    }

    static func keyCount(_ text: String) -> Int {
        text.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }.count
    }
}

// MARK: - Config viewer

struct SSHConfigViewer: View {
    @ObservedObject private var manager = SSHServerManager.shared

    var body: some View {
        List {
            Section {
                if manager.configText.isEmpty {
                    Text(AppLocalized("No /etc/ssh/sshd_config yet. Start the server once to create it."))
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: manager.configText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text(verbatim: SSHServerManager.configPath)
            } footer: {
                Text(AppLocalized("The daemon is started with -f /etc/ssh/sshd_config. The block at the top is rewritten by Minis; any other line you add in the terminal is preserved."))
            }
            Section {
                Button {
                    manager.refreshFromConfig()
                } label: {
                    Label(AppLocalized("Reload"), systemImage: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing)
            }
        }
        .navigationTitle(AppLocalized("sshd_config"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { manager.refreshFromConfig() }
    }
}

// MARK: - Authorized keys editor

struct SSHAuthorizedKeysEditor: View {
    @ObservedObject var manager: SSHServerManager
    @State private var draft: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                TextEditor(text: $draft)
                    .font(.caption.monospaced())
                    .frame(minHeight: 220)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text(AppLocalized("authorized_keys"))
            } footer: {
                Text(AppLocalized("Lines that are not a valid public key are dropped when saving. Keys take effect the next time the server starts."))
            }

            Section {
                Button(AppLocalized("Save")) {
                    manager.setAuthorizedKeys(draft)
                    dismiss()
                }
            }
        }
        .navigationTitle(AppLocalized("Authorized Keys"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = manager.authorizedKeys }
    }
}
