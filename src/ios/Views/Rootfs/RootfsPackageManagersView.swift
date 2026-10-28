//
//  RootfsPackageManagersView.swift
//  MinisApp
//
//  [T-mirrors-more-package-managers] Rootfs Management → Package Managers.
//
//  Shows which language package managers exist in the Shell Container and
//  installs the missing ones with apk. Each row links to its registry mirror
//  setting (MirrorSpeedTestView), so "install the manager" and "point it at a
//  fast registry" live together.
//

import SwiftUI

@MainActor
final class PackageManagersViewModel: ObservableObject {
    struct Status: Equatable {
        var checking = true
        var installed = false
        /// First line of `<manager> --version`, trimmed.
        var version: String?
        var error: String?
    }

    /// Managers offered here: the language ecosystems the rootfs is used with
    /// beyond APK itself. `.alpine` has no row of its own — APK is the
    /// installer.
    static let categories: [MirrorCategory] = [.pip, .pipx, .npm, .cargo, .go, .gem, .composer]

    @Published private(set) var statuses: [MirrorCategory: Status] = [:]
    @Published private(set) var isRefreshing = false
    @Published var installing: MirrorCategory?
    @Published var message: String?
    @Published var messageIsError = false

    private var refreshGeneration = 0

    init() {
        for category in Self.categories { statuses[category] = Status() }
    }

    /// Probe every manager in one guest call. Safe to call on every appear.
    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        for category in Self.categories {
            statuses[category] = Status(checking: true, installed: statuses[category]?.installed ?? false)
        }

        guard ISHKernel.shared.isBooted else {
            isRefreshing = false
            for category in Self.categories {
                statuses[category] = Status(checking: false, installed: false, version: nil,
                                           error: AppLocalized("Shell Container is not running"))
            }
            return
        }

        Task.detached(priority: .userInitiated) {
            let script = Self.probeScript
            let result = ISHShellExecutor.executeCommandSync(script, timeout: 30, lineCallback: nil)
            let parsed = Self.parseProbe(result.output)
            await MainActor.run {
                guard generation == self.refreshGeneration else { return }
                self.isRefreshing = false
                for category in Self.categories {
                    self.statuses[category] = parsed[category]
                        ?? Status(checking: false, installed: false, version: nil, error: nil)
                }
            }
        }
    }

    /// Install a manager's Alpine packages, then re-probe it.
    func install(_ category: MirrorCategory) {
        guard installing == nil else { return }
        let packages = category.alpinePackages
        guard !packages.isEmpty else { return }
        guard ISHKernel.shared.isBooted else {
            message = AppLocalized("The Shell Container is not running yet. Open the terminal once, then try again.")
            messageIsError = true
            return
        }
        installing = category
        message = nil
        messageIsError = false
        let command = "apk add --no-cache \(packages.joined(separator: " ")) 2>&1"

        Task.detached(priority: .userInitiated) {
            let result = ISHShellExecutor.executeCommandSync(command, timeout: 900, lineCallback: nil)
            let tail = result.output
                .split(separator: "\n")
                .suffix(3)
                .joined(separator: "\n")
            let exit = result.exitCode
            await MainActor.run {
                self.installing = nil
                if exit == 0 {
                    self.message = AppLocalized("Installed \(packages.joined(separator: " ")).")
                    self.messageIsError = false
                } else {
                    self.message = AppLocalized("apk add \(packages.joined(separator: " ")) failed: \(tail)")
                    self.messageIsError = true
                }
                self.refresh()
            }
        }
    }

    // MARK: - Probe

    private static let probeScript: String = {
        // One round trip: every line is "<manager>\t<version or MISSING>".
        let specs: [(command: String, args: String)] = [
            ("pip3", "--version"),
            ("pipx", "--version"),
            ("npm", "--version"),
            ("cargo", "--version"),
            ("go", "version"),
            ("gem", "--version"),
            ("composer", "--version --no-interaction"),
        ]
        var script = "export PATH=\"$PATH:/usr/local/bin:/usr/bin\"\n"
        for spec in specs {
            script += "if command -v \(spec.command) >/dev/null 2>&1; then printf '%s\\t' \(spec.command); \(spec.command) \(spec.args) 2>/dev/null | head -n 1; else printf '%s\\tMISSING\\n' \(spec.command); fi\n"
        }
        return script
    }()

    nonisolated static func parseProbe(_ output: String) -> [MirrorCategory: Status] {
        let byCommand = Dictionary(uniqueKeysWithValues: [
            ("pip3", MirrorCategory.pip),
            ("pipx", MirrorCategory.pipx),
            ("npm", MirrorCategory.npm),
            ("cargo", MirrorCategory.cargo),
            ("go", MirrorCategory.go),
            ("gem", MirrorCategory.gem),
            ("composer", MirrorCategory.composer),
        ])
        var result: [MirrorCategory: Status] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let command = String(line[..<tab])
            let rest = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
            guard let category = byCommand[command] else { continue }
            if rest == "MISSING" || rest.isEmpty {
                result[category] = Status(checking: false, installed: false, version: nil, error: nil)
            } else {
                result[category] = Status(checking: false, installed: true, version: rest, error: nil)
            }
        }
        return result
    }
}

// MARK: - Section

struct PackageManagersSection: View {
    @ObservedObject private var model: PackageManagersViewModel
    @State private var pendingInstall: MirrorCategory?

    init(model: PackageManagersViewModel) {
        self.model = model
    }

    var body: some View {
        Section {
            ForEach(PackageManagersViewModel.categories) { category in
                row(category)
            }
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(model.messageIsError ? .red : .green)
            }
        } header: {
            Text(AppLocalized("Package Managers"))
        } footer: {
            Text(AppLocalized("Language package managers available inside the Shell Container. Install the missing ones, then open one to pick a faster registry mirror."))
        }
        .confirmationDialog(
            pendingInstall.map { AppLocalized("Install \($0.displayName)?") } ?? "",
            isPresented: Binding(get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }),
            titleVisibility: .visible,
            presenting: pendingInstall
        ) { category in
            Button(AppLocalized("Install \(category.alpinePackages.joined(separator: " "))")) {
                model.install(category)
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: { category in
            Text(AppLocalized("Runs “apk add --no-cache \(category.alpinePackages.joined(separator: " "))” in the Shell Container."))
        }
        .task { model.refresh() }
    }

    @ViewBuilder
    private func row(_ category: MirrorCategory) -> some View {
        let status = model.statuses[category] ?? .init()
        HStack(spacing: 10) {
            Image(systemName: category.systemImage)
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(category.iconColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                if status.checking {
                    Text(AppLocalized("Checking…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if status.installed {
                    Text(verbatim: status.version ?? AppLocalized("Installed"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(status.error ?? AppLocalized("Not installed"))
                        .font(.caption)
                        .foregroundStyle(status.error == nil ? Color.secondary : Color.orange)
                }
            }

            Spacer()

            if model.installing == category {
                ProgressView().controlSize(.small)
            } else {
                if !status.installed && !status.checking && status.error == nil {
                    Button(AppLocalized("Install")) {
                        pendingInstall = category
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                // The mirror row stays reachable even when the manager is
                // missing: the config file can be prepared before the first
                // install.
                NavigationLink {
                    MirrorCategoryDetailView(category: category)
                } label: {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .accessibilityLabel(AppLocalized("Mirror for \(category.displayName)"))
            }
        }
    }
}
