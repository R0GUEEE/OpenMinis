//
//  PluginMarketplace.swift
//  MinisApp
//
//  [T-plugin-marketplace] A catalogue of installable plugins.
//
//  Design, deliberately small:
//
//  * A "source" is an https URL returning JSON. The schema is one object with a
//    `plugins` array, or a bare array, so a single GitHub raw file, a gist or a
//    static host all work — the fork has no server to run.
//  * Entries carry a `downloadURL` to a `.zip` in the same layout `Import .zip`
//    accepts, so the marketplace reuses the install path rather than inventing
//    a second one (and inherits its validation, since PluginManifest is what
//    decides whether a plugin is acceptable).
//  * No accounts, no ratings, no telemetry: fetching a catalogue is a plain GET,
//    installing is a plain GET.
//  * Anything a catalogue can lie about is re-checked locally: the manifest in
//    the downloaded archive must parse, its id must match the entry the user
//    clicked, and a `sha256` in the entry must match the bytes. A catalogue is
//    untrusted input.
//
//  The default source list is empty on purpose: pointing the app at a catalogue
//  the user did not choose would be making a policy decision for them. The UI
//  offers a GitHub "repo zip" shortcut instead, which needs no catalogue at all.
//

import Foundation
import CryptoKit

// MARK: - Catalogue model

/// One installable plugin as a catalogue describes it.
struct PluginMarketplaceEntry: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var author: String?
    var homepage: String?
    var downloadURL: URL
    /// Lower-case hex SHA-256 of the archive. Verified when present.
    var sha256: String?
    var minAppVersion: String?
    var tags: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, homepage
        case downloadURL = "download_url"
        case sha256, minAppVersion = "min_app_version", tags
    }

    /// Accepts the snake_case keys a static JSON file is likely to use as well
    /// as the camelCase ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        let rawDownload = try c.decode(String.self, forKey: .downloadURL)
        guard let url = URL(string: rawDownload), url.scheme?.lowercased() == "https" else {
            throw DecodingError.dataCorruptedError(forKey: .downloadURL, in: c,
                                                   debugDescription: "download_url must be an https URL")
        }
        downloadURL = url
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)?.lowercased()
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
    }

    init(id: String, name: String, version: String, description: String? = nil, author: String? = nil,
         homepage: String? = nil, downloadURL: URL, sha256: String? = nil, minAppVersion: String? = nil,
         tags: [String]? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.homepage = homepage
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.minAppVersion = minAppVersion
        self.tags = tags
    }
}

/// A catalogue as returned by one source URL.
struct PluginMarketplaceCatalog: Decodable {
    var plugins: [PluginMarketplaceEntry]

    enum CodingKeys: String, CodingKey { case plugins, entries }

    init(from decoder: Decoder) throws {
        // Either `{"plugins":[…]}`, `{"entries":[…]}`, or a bare array.
        if let single = try? decoder.singleValueContainer(),
           let array = try? single.decode([PluginMarketplaceEntry].self) {
            plugins = array
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try c.decodeIfPresent([PluginMarketplaceEntry].self, forKey: .plugins) {
            plugins = list
        } else if let list = try c.decodeIfPresent([PluginMarketplaceEntry].self, forKey: .entries) {
            plugins = list
        } else {
            plugins = []
        }
    }

    init(plugins: [PluginMarketplaceEntry]) { self.plugins = plugins }
}

// MARK: - Store

@MainActor
final class PluginMarketplace: ObservableObject {
    static let shared = PluginMarketplace()

    enum MarketError: LocalizedError {
        case badSourceURL
        case notHTTPS
        case httpStatus(Int)
        case emptyCatalogue(URL)
        case downloadTooLarge
        case checksumMismatch(expected: String, actual: String)
        case idMismatch(expected: String, found: String)
        case entryRequiresNewerApp(String)
        case offline(String)

        var errorDescription: String? {
            switch self {
            case .badSourceURL: return "That doesn't look like a web address."
            case .notHTTPS: return "Marketplace sources and downloads must use https."
            case .httpStatus(let code): return "The server answered HTTP \(code)."
            case .emptyCatalogue(let url): return "\(url.host ?? "The source") answered, but the catalogue had no plugins in it."
            case .downloadTooLarge: return "The plugin archive is larger than 40 MB."
            case .checksumMismatch(let e, let a):
                return "The downloaded archive does not match the catalogue's checksum (expected \(e.prefix(12))…, got \(a.prefix(12))…). Nothing was installed."
            case .idMismatch(let e, let f):
                return "That archive contains plugin “\(f)”, not “\(e)”. It may be a different version of the entry you clicked — nothing was installed."
            case .entryRequiresNewerApp(let v): return "This plugin needs Minis \(v) or later."
            case .offline(let detail): return "Couldn't reach the marketplace: \(detail)"
            }
        }
    }

    /// Refuse anything bigger than this before it is written to disk.
    static let maxArchiveBytes = 40 * 1024 * 1024

    private static let sourcesKey = "minis.plugins.marketplaceSources"

    /// User-added catalogue URLs. Persisted; the default list is empty.
    @Published private(set) var sources: [URL] = []
    @Published private(set) var entries: [PluginMarketplaceEntry] = []
    @Published private(set) var isLoading = false
    /// Per-entry import state, keyed by entry id.
    @Published private(set) var installing: Set<String> = []
    @Published private(set) var lastError: String?
    /// Catalogue URL whose fetch failed, for the "source is broken" row.
    @Published private(set) var sourceErrors: [URL: String] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private init() {
        sources = Self.loadSources()
    }

    // MARK: Sources

    private static func loadSources() -> [URL] {
        let raw = UserDefaults.standard.stringArray(forKey: Self.sourcesKey) ?? []
        return raw.compactMap { URL(string: $0) }.filter { $0.scheme?.lowercased() == "https" }
    }

    private func persistSources() {
        UserDefaults.standard.set(sources.map(\.absoluteString), forKey: Self.sourcesKey)
    }

    /// Add a catalogue URL. Rejects non-https, and a URL already present.
    @discardableResult
    func addSource(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host != nil else {
            lastError = MarketError.badSourceURL.errorDescription
            return false
        }
        guard url.scheme?.lowercased() == "https" else {
            lastError = MarketError.notHTTPS.errorDescription
            return false
        }
        guard !sources.contains(url) else { return true }
        sources.append(url)
        persistSources()
        return true
    }

    func removeSource(_ url: URL) {
        sources.removeAll { $0 == url }
        sourceErrors[url] = nil
        persistSources()
    }

    // MARK: Fetch

    /// Fetch every source and merge the catalogues. Duplicate ids: the first
    /// source wins, so the user's own list order is the priority order.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        sourceErrors = [:]
        defer { isLoading = false }

        var merged: [PluginMarketplaceEntry] = []
        var seen = Set<String>()
        for source in sources {
            do {
                let catalog = try await fetchCatalog(from: source)
                for entry in catalog.plugins where seen.insert(entry.id).inserted {
                    merged.append(entry)
                }
            } catch {
                sourceErrors[source] = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        entries = merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if merged.isEmpty, let first = sourceErrors.values.first, sourceErrors.count == sources.count {
            lastError = first
        }
    }

    private func fetchCatalog(from url: URL) async throws -> PluginMarketplaceCatalog {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MinisUserAgent.default, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MarketError.offline(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MarketError.httpStatus(http.statusCode)
        }
        let catalog = try JSONDecoder().decode(PluginMarketplaceCatalog.self, from: data)
        guard !catalog.plugins.isEmpty else { throw MarketError.emptyCatalogue(url) }
        return catalog
    }

    // MARK: Install

    /// Download, verify and install one entry. Returns the installed plugin so
    /// the UI can report what actually landed.
    @discardableResult
    func install(_ entry: PluginMarketplaceEntry, into store: PluginStore) async throws -> InstalledPlugin {
        guard !installing.contains(entry.id) else {
            throw PluginStore.InstallError.invalidArchive("Already installing “\(entry.name)”.")
        }
        installing.insert(entry.id)
        defer { installing.remove(entry.id) }

        if let minimum = entry.minAppVersion,
           !PluginVersion.satisfies(current: PluginStore.appVersion, minimum: minimum) {
            throw MarketError.entryRequiresNewerApp(minimum)
        }

        var request = URLRequest(url: entry.downloadURL)
        request.setValue(MinisUserAgent.default, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MarketError.offline(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MarketError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maxArchiveBytes else { throw MarketError.downloadTooLarge }

        // A catalogue is untrusted: check what it promised before unpacking.
        if let expected = entry.sha256 {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw MarketError.checksumMismatch(expected: expected, actual: actual)
            }
        }
        let installed = try store.install(downloadedArchive: data)
        // The archive may disagree with the row the user clicked.
        guard installed.manifest.id == entry.id else {
            try? store.remove(id: installed.manifest.id)
            throw MarketError.idMismatch(expected: entry.id, found: installed.manifest.id)
        }
        return installed
    }

    // MARK: GitHub shortcut

    /// `https://github.com/<owner>/<repo>` → the main-branch zip. Lets a repo be
    /// installed without any catalogue at all.
    static func githubZipURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        var candidate = "https://codeload.github.com/\(owner)/\(repo)/zip/refs/heads/main"
        // Older repos still use master; the caller falls back when main 404s.
        if parts.count >= 4, parts[2] == "tree" {
            candidate = "https://codeload.github.com/\(owner)/\(repo)/zip/refs/heads/\(parts[3])"
        }
        return URL(string: candidate)
    }
}
