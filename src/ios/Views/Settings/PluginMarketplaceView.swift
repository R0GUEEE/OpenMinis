//
//  PluginMarketplaceView.swift
//  MinisApp
//
//  [T-plugin-marketplace] Browse and install plugins from catalogue URLs.
//
//  Three ways in, in the order they are useful:
//  1. a catalogue the user added (searchable list, one-tap install);
//  2. a GitHub repo URL, zipped from its default branch — no catalogue needed;
//  3. a direct .zip URL.
//
//  Every path goes through the same install: the archive's own plugin.json is
//  what gets parsed, so the marketplace cannot ship anything the importer would
//  have rejected.
//

import SwiftUI
import UniformTypeIdentifiers

struct PluginMarketplaceView: View {
    @ObservedObject private var market = PluginMarketplace.shared
    @ObservedObject private var store = PluginStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var showAddSource = false
    @State private var sourceDraft = ""
    @State private var showDirect = false
    @State private var directDraft = ""
    @State private var message: String?
    @State private var showMessage = false
    @State private var addSourceError: String?

    private var filtered: [PluginMarketplaceEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return market.entries }
        return market.entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(q)
                || entry.id.localizedCaseInsensitiveContains(q)
                || (entry.description?.localizedCaseInsensitiveContains(q) ?? false)
                || (entry.author?.localizedCaseInsensitiveContains(q) ?? false)
                || (entry.tags?.contains { $0.localizedCaseInsensitiveContains(q) } ?? false)
        }
    }

    private func installedPlugin(for entry: PluginMarketplaceEntry) -> InstalledPlugin? {
        store.plugins.first { $0.manifest.id == entry.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if market.sources.isEmpty {
                    emptySourcesSection
                }
                if !market.sourceErrors.isEmpty {
                    brokenSourcesSection
                }
                if !market.entries.isEmpty {
                    Section {
                        ForEach(filtered) { entry in
                            row(entry)
                        }
                        if filtered.isEmpty {
                            Text(AppLocalized("No plugin matches “\(search)”."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(AppLocalized("Plugins"))
                    } footer: {
                        Text(AppLocalized("Catalogue entries are untrusted input: the archive's own plugin.json is re-validated here, and an entry's checksum must match."))
                    }
                }
                directSection
                sourcesSection
            }
            .searchable(text: $search, prompt: Text(AppLocalized("Search plugins")))
            .refreshable { await market.refresh() }
            .navigationTitle(AppLocalized("Plugin Marketplace"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalized("Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await market.refresh() }
                    } label: {
                        if market.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(market.sources.isEmpty || market.isLoading)
                    .accessibilityLabel(Text(AppLocalized("Refresh catalogue")))
                }
            }
            .alert(AppLocalized("Marketplace"), isPresented: $showMessage) {
                Button("OK", role: .cancel) {}
            } message: {
                if let message { Text(message) }
            }
            .alert(AppLocalized("Add a catalogue"), isPresented: $showAddSource) {
                TextField("https://example.com/plugins.json", text: $sourceDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(AppLocalized("Add")) {
                    if market.addSource(sourceDraft) {
                        sourceDraft = ""
                        Task { await market.refresh() }
                    } else {
                        addSourceError = market.lastError
                    }
                }
                Button(AppLocalized("Cancel"), role: .cancel) { sourceDraft = "" }
            } message: {
                Text(addSourceError ?? AppLocalized("A JSON file listing plugins. See the Plugins documentation for the format."))
            }
            .alert(AppLocalized("Install from URL"), isPresented: $showDirect) {
                TextField("https://…/plugin.zip", text: $directDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(AppLocalized("Install")) { installDirect(directDraft) }
                Button(AppLocalized("Cancel"), role: .cancel) { directDraft = "" }
            } message: {
                Text(AppLocalized("A .zip, or a github.com/<owner>/<repo> address."))
            }
            .task {
                if market.sources.isEmpty == false, market.entries.isEmpty {
                    await market.refresh()
                }
            }
        }
    }

    // MARK: Sections

    private var emptySourcesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(AppLocalized("No catalogue yet"), systemImage: "storefront")
                    .font(.body.weight(.medium))
                Text(AppLocalized("A marketplace is just a JSON file of plugins. Add one below, or install a plugin straight from a GitHub repo or a .zip URL."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var brokenSourcesSection: some View {
        Section {
            ForEach(Array(market.sourceErrors.keys), id: \.self) { url in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: url.host ?? url.absoluteString)
                        .font(.footnote.weight(.medium))
                    Text(verbatim: market.sourceErrors[url] ?? "")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(AppLocalized("Sources that failed"))
        }
    }

    private var directSection: some View {
        Section {
            Button {
                directDraft = ""
                showDirect = true
            } label: {
                Label(AppLocalized("Install from URL…"), systemImage: "link")
            }
        } footer: {
            Text(AppLocalized("github.com/<owner>/<repo> is zipped from its main branch; a .zip URL is downloaded as-is."))
        }
    }

    private var sourcesSection: some View {
        Section {
            ForEach(market.sources, id: \.self) { url in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: url.host ?? url.absoluteString)
                            .font(.footnote.weight(.medium))
                        Text(verbatim: url.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        market.removeSource(url)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(AppLocalized("Remove source")))
                }
            }
            Button {
                sourceDraft = ""
                addSourceError = nil
                showAddSource = true
            } label: {
                Label(AppLocalized("Add Catalogue…"), systemImage: "plus")
            }
        } header: {
            Text(AppLocalized("Catalogue sources"))
        }
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ entry: PluginMarketplaceEntry) -> some View {
        let installed = installedPlugin(for: entry)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: entry.name)
                    .font(.body.weight(.medium))
                if !entry.version.isEmpty {
                    Text(verbatim: "v\(entry.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if market.installing.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else if let installed {
                    Text(installed.manifest.version == entry.version
                         ? AppLocalized("Installed")
                         : AppLocalized("Update"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(installed.manifest.version == entry.version ? Color.secondary : Color.accentColor)
                } else {
                    Button(AppLocalized("Install")) {
                        install(entry)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let d = entry.description, !d.isEmpty {
                Text(verbatim: d)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let author = entry.author, !author.isEmpty {
                    Text(verbatim: author)
                }
                if let tags = entry.tags, !tags.isEmpty {
                    Text(verbatim: tags.prefix(3).joined(separator: " · "))
                }
                Text(verbatim: entry.id)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private func install(_ entry: PluginMarketplaceEntry) {
        Task { @MainActor in
            do {
                let plugin = try await market.install(entry, into: store)
                message = AppLocalized("Installed “\(plugin.manifest.name)” v\(plugin.manifest.version) with \(plugin.manifest.tools.count) tool(s).")
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            showMessage = true
        }
    }

    private func installDirect(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var url = URL(string: trimmed) else {
            message = PluginMarketplace.MarketError.badSourceURL.errorDescription
            showMessage = true
            return
        }
        if url.host?.lowercased() == "github.com", let zipped = PluginMarketplace.githubZipURL(from: trimmed) {
            url = zipped
        }
        guard url.scheme?.lowercased() == "https" else {
            message = PluginMarketplace.MarketError.notHTTPS.errorDescription
            showMessage = true
            return
        }
        directDraft = ""
        Task { @MainActor in
            var request = URLRequest(url: url)
            request.setValue(MinisUserAgent.default, forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    // A repo whose default branch is `master` rather than `main`.
                    if let fallback = url.absoluteString.replacingOccurrences(of: "/refs/heads/main", with: "/refs/heads/master") as String?,
                       let alt = URL(string: fallback), alt != url {
                        let (retryData, retryResponse) = try await URLSession.shared.data(from: alt)
                        if let http = retryResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                            let plugin = try store.install(downloadedArchive: retryData)
                            message = AppLocalized("Installed “\(plugin.manifest.name)” v\(plugin.manifest.version) with \(plugin.manifest.tools.count) tool(s).")
                            showMessage = true
                            return
                        }
                    }
                    throw PluginMarketplace.MarketError.httpStatus(http.statusCode)
                }
                guard data.count <= PluginMarketplace.maxArchiveBytes else {
                    throw PluginMarketplace.MarketError.downloadTooLarge
                }
                let plugin = try store.install(downloadedArchive: data)
                message = AppLocalized("Installed “\(plugin.manifest.name)” v\(plugin.manifest.version) with \(plugin.manifest.tools.count) tool(s).")
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            showMessage = true
        }
    }
}
