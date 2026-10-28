//
//  PluginsManagementView.swift
//  MinisApp
//
//  [T-agent-plugins] Settings → Plugins. Lists installed agent plugins,
//  installs them from a .zip or a folder, and shows what each one adds.
//

import SwiftUI
import UniformTypeIdentifiers

struct PluginsManagementView: View {
    @ObservedObject private var store = PluginStore.shared

    @State private var showImportMenu = false
    @State private var importKind: ImportKind?
    @State private var importMessage: String?
    @State private var showImportMessage = false
    @State private var pendingDelete: InstalledPlugin?

    private enum ImportKind: String, Identifiable {
        case archive, folder
        var id: String { rawValue }
    }

    var body: some View {
        List {
            if store.plugins.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text(AppLocalized("No Plugins"))
                            .font(.headline)
                        Text(AppLocalized("A plugin adds tools to the AI agent. Install one from a plugin .zip or folder, or drop it into the Plugins folder in the Files app."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(AppLocalized("Import Plugin")) { showImportMenu = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                Section {
                    ForEach(store.plugins) { plugin in
                        NavigationLink {
                            PluginDetailView(pluginId: plugin.id)
                        } label: {
                            PluginRow(plugin: plugin, isOn: Binding(
                                get: { plugin.isEnabled },
                                set: { store.setEnabled($0, for: plugin.id) }
                            ))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = plugin
                            } label: {
                                Label(AppLocalized("Delete"), systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(AppLocalized("Installed Plugins"))
                } footer: {
                    Text(AppLocalized("Plugins run commands in the Shell Container with the same permissions as the agent. Only install plugins you trust."))
                }
            }
        }
        .navigationTitle(AppLocalized("Plugins"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImportMenu = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppLocalized("Add Plugin"))
            }
        }
        .confirmationDialog(AppLocalized("Add Plugin"), isPresented: $showImportMenu, titleVisibility: .visible) {
            Button(AppLocalized("Import .zip Archive")) { importKind = .archive }
            Button(AppLocalized("Import Folder")) { importKind = .folder }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("The plugin must contain a plugin.json at its root or inside one top-level folder."))
        }
        .fileImporter(isPresented: Binding(
            get: { importKind != nil },
            set: { if !$0 { importKind = nil } }
        ), allowedContentTypes: importKind == .folder ? [.folder] : [.zip, .data], allowsMultipleSelection: false) { result in
            let kind = importKind
            importKind = nil
            guard let kind else { return }
            handleImport(result, kind: kind)
        }
        .alert(AppLocalized("Plugin Import"), isPresented: $showImportMessage) {
            Button("OK", role: .cancel) {}
        } message: {
            if let importMessage { Text(importMessage) }
        }
        .confirmationDialog(
            AppLocalized("Delete “\(pendingDelete?.manifest.name ?? "")”?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { plugin in
            Button(AppLocalized("Delete"), role: .destructive) {
                do {
                    try store.remove(id: plugin.id)
                } catch {
                    importMessage = error.localizedDescription
                    showImportMessage = true
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(AppLocalized("The plugin's files are removed from the Plugins folder. Its tools disappear from the agent."))
        }
        .onAppear { store.reload() }
    }

    private func handleImport(_ result: Result<[URL], Error>, kind: ImportKind) {
        switch result {
        case .failure(let error):
            importMessage = error.localizedDescription
            showImportMessage = true
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let plugin = kind == .folder
                    ? try store.install(payloadDirectory: url)
                    : try store.install(archiveURL: url)
                importMessage = AppLocalized("Installed “\(plugin.manifest.name)” v\(plugin.manifest.version) with \(plugin.manifest.tools.count) tool(s).")
            } catch {
                importMessage = error.localizedDescription
            }
            showImportMessage = true
        }
    }
}

// MARK: - Row

private struct PluginRow: View {
    let plugin: InstalledPlugin
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: plugin.manifest.name)
                    .font(.body.weight(.medium))
                Text(verbatim: "v\(plugin.manifest.version)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if plugin.loadError == nil {
                    Toggle("", isOn: $isOn)
                        .labelsHidden()
                        .controlSize(.mini)
                }
            }
            if let error = plugin.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                if !plugin.manifest.description.isEmpty {
                    Text(plugin.manifest.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(toolSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var toolSummary: String {
        let count = plugin.manifest.tools.count
        guard count > 0 else { return AppLocalized("No tools") }
        if count == 1, let tool = plugin.manifest.tools.first {
            return AppLocalized("1 tool: \(tool.name)")
        }
        return AppLocalized("\(count) tools")
    }
}

// MARK: - Detail

struct PluginDetailView: View {
    let pluginId: String
    @ObservedObject private var store = PluginStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var showError = false

    private var plugin: InstalledPlugin? {
        store.plugins.first { $0.id == pluginId }
    }

    var body: some View {
        Group {
            if let plugin {
                content(plugin)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(AppLocalized("Plugin Not Found"))
                        .font(.headline)
                    Text(AppLocalized("It was deleted or moved out of the Plugins folder."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
        .navigationTitle(plugin?.manifest.name ?? AppLocalized("Plugin"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(AppLocalized("Error"), isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
    }

    @ViewBuilder
    private func content(_ plugin: InstalledPlugin) -> some View {
        List {
            Section {
                if let error = plugin.loadError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text(plugin.manifest.description)
                        .font(.callout)
                }
                if !plugin.manifest.author.isEmpty {
                    labeled(AppLocalized("Author"), plugin.manifest.author)
                }
                if let homepage = plugin.manifest.homepage,
                   let url = URL(string: homepage) {
                    Link(destination: url) {
                        LabeledContent(AppLocalized("Homepage")) {
                            Text(homepage).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                labeled(AppLocalized("Identifier"), plugin.manifest.id, monospaced: true)
                labeled(AppLocalized("Version"), plugin.manifest.version)
                if let minimum = plugin.manifest.minAppVersion {
                    labeled(AppLocalized("Minimum Minis"), minimum)
                }
                LabeledContent(AppLocalized("Guest folder")) {
                    Text(verbatim: plugin.linuxDirectory)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Toggle(AppLocalized("Enabled"), isOn: Binding(
                    get: { plugin.isEnabled },
                    set: { store.setEnabled($0, for: plugin.id) }
                ))
                .disabled(plugin.loadError != nil)
            }

            if !plugin.manifest.tools.isEmpty {
                Section {
                    ForEach(plugin.manifest.tools) { tool in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: tool.name)
                                .font(.subheadline.weight(.semibold).monospaced())
                            Text(tool.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: tool.command)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                            HStack(spacing: 10) {
                                if !tool.required.isEmpty {
                                    Text(AppLocalized("Required: \(tool.required.joined(separator: ", "))"))
                                }
                                Text(AppLocalized("Timeout: \(tool.timeoutSeconds)s"))
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(AppLocalized("Tools"))
                } footer: {
                    Text(AppLocalized("The agent can call these tools in any chat. Arguments arrive as JSON on $MINIS_TOOL_ARGS (and in $MINIS_TOOL_ARGS_FILE); the working directory is the plugin's folder."))
                }
            }

            Section {
                Button(role: .destructive) {
                    do {
                        try store.remove(id: plugin.id)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                } label: {
                    Label(AppLocalized("Delete Plugin"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func labeled(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(title) {
            Text(verbatim: value)
                .font(monospaced ? .caption.monospaced() : .body)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
