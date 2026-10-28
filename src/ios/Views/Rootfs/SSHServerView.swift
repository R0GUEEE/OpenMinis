//
//  SSHServerView.swift
//  MinisApp
//
//  [T-ssh-server] Rootfs Management → SSH Access, plus the settings screen.
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

                if manager.status.isRunning, let address = manager.lanAddress {
                    connectionRow(address: address)
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
            Text(AppLocalized("Lets you log into the Shell Container from another computer on the same network. The server runs whenever Minis is running; iOS suspends it when the app is in the background."))
        }
        .onAppear { manager.startIfEnabled(reason: "rootfs screen") }
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

    private func connectionRow(address: String) -> some View {
        let command = "ssh -p \(manager.port) root@\(address)"
        return VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalized("Connect"))
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text(AppLocalized("Password: root password in SSH Settings."))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings

struct SSHServerSettingsView: View {
    @ObservedObject private var manager = SSHServerManager.shared

    @State private var portText = ""
    @State private var keysText = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var revealPassword = false
    @State private var showNotification: String?
    @State private var isPresentedNotification = false

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
                if let address = manager.lanAddress {
                    LabeledContent(AppLocalized("Address")) {
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
            } header: {
                Text(AppLocalized("Server"))
            } footer: {
                Text(AppLocalized("The server listens on every network interface, so other devices on your Wi-Fi can reach it. iOS suspends it while Minis is backgrounded."))
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
                          (1024...65535).contains(value) else {
                        notify(AppLocalized("Use a port between 1024 and 65535."))
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
                Text(AppLocalized("Default 2222. Changing the port restarts the server and drops open sessions."))
            }

            Section {
                HStack {
                    Text(AppLocalized("Root password"))
                    Spacer()
                    Text(verbatim: revealPassword ? manager.password : String(repeating: "•", count: 16))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(revealPassword ? AppLocalized("Hide password") : AppLocalized("Show password"))
                }
                Button {
                    UIPasteboard.general.string = manager.password
                    notify(AppLocalized("Password copied."))
                } label: {
                    Label(AppLocalized("Copy Password"), systemImage: "doc.on.doc")
                }
                Button(AppLocalized("Generate New Password")) {
                    _ = manager.regeneratePassword()
                    notify(AppLocalized("New password generated. Open sessions keep working until they disconnect."))
                }
            } header: {
                Text(AppLocalized("Password Authentication"))
            } footer: {
                Text(AppLocalized("The password is stored in the iOS Keychain and re-applied to the root account every time the server starts."))
            }

            Section {
                SecureField(AppLocalized("New password (min. 8 characters)"), text: $newPassword)
                SecureField(AppLocalized("Repeat password"), text: $confirmPassword)
                Button(AppLocalized("Set Password")) {
                    guard newPassword == confirmPassword else {
                        notify(AppLocalized("The passwords do not match."))
                        return
                    }
                    if manager.setPassword(newPassword) {
                        newPassword = ""
                        confirmPassword = ""
                        notify(AppLocalized("Password updated."))
                    } else {
                        notify(AppLocalized("Use at least 8 characters."))
                    }
                }
            } header: {
                Text(AppLocalized("Change Password"))
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
        }
        .alert(AppLocalized("SSH Server"), isPresented: $isPresentedNotification) {
            Button("OK", role: .cancel) {}
        } message: {
            if let showNotification { Text(showNotification) }
        }
    }

    private func notify(_ message: String) {
        showNotification = message
        isPresentedNotification = true
    }

    static func keyCount(_ text: String) -> Int {
        text.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }.count
    }
}

// MARK: - Authorized keys editor

struct SSHAuthorizedKeysEditor: View {
    @ObservedObject var manager: SSHServerManager
    @State private var draft: String = ""
    @State private var showInvalid = false
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
                    let cleaned = draft
                    manager.setAuthorizedKeys(cleaned)
                    dismiss()
                }
            }
        }
        .navigationTitle(AppLocalized("Authorized Keys"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = manager.authorizedKeys }
    }
}
