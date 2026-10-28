//
//  PluginStore.swift
//  MinisApp
//
//  [T-agent-plugins] Discovery, installation and enablement for agent plugins.
//
//  Plugins live in the app-group `plugins/` directory, bind-mounted into the
//  Shell Container at /var/minis/plugins, so a plugin's own scripts are
//  visible to the guest and the model's tools can run them. One directory per
//  plugin, one plugin.json per directory — see PluginManifest.swift.
//

import Foundation
import SwiftUI

/// One installed plugin as the UI and the tool layer see it.
struct InstalledPlugin: Identifiable, Equatable {
    var id: String { manifest.id }
    var manifest: PluginManifest
    /// Host directory holding plugin.json and the plugin's files.
    var directory: URL
    /// Guest path mirror of `directory` (bind-mounted).
    var linuxDirectory: String { "\(PluginStore.linuxRoot)/\(manifest.id)" }
    var isEnabled: Bool
    var installedAt: Date
    /// Set when the directory exists but could not be loaded; such a plugin is
    /// shown with the error and never exposed as a tool.
    var loadError: String?
}

@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    /// Guest directory the plugin directory is mounted at.
    nonisolated static let linuxRoot = "/var/minis/plugins"

    /// Host directory, inside the app group so the FileProvider can reach it
    /// and the shell sees the same files through the bind mount.
    nonisolated static var rootDirectory: URL {
        AIChatViewModel.minisPluginsPersistentDir
    }

    @Published private(set) var plugins: [InstalledPlugin] = []
    /// Bumped whenever the set of enabled tools changes, so a chat view can
    /// rebuild its tool list without polling.
    @Published private(set) var revision: Int = 0

    private let fm = FileManager.default
    nonisolated private static let enabledKeyPrefix = "minis.plugins.enabled."

    private init() {
        ensureRoot()
        reload()
    }

    // MARK: - Loading

    private func ensureRoot() {
        try? fm.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
    }

    /// Re-scan the plugins directory. Safe to call at any time; every state
    /// except the enablement flag is read from disk.
    func reload() {
        ensureRoot()
        var found: [InstalledPlugin] = []
        let entries = (try? fm.contentsOfDirectory(
            at: Self.rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let manifestURL = entry.appendingPathComponent("plugin.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            do {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try PluginManifest.parse(jsonData: data)
                if manifest.id != entry.lastPathComponent {
                    throw PluginManifest.ManifestError.invalidField(
                        "id", "must match the folder name “\(entry.lastPathComponent)”")
                }
                if let minimum = manifest.minAppVersion,
                   !PluginVersion.satisfies(current: Self.appVersion, minimum: minimum) {
                    throw PluginManifest.ManifestError.invalidField(
                        "minAppVersion", "this plugin needs Minis \(minimum) or later (this build is \(Self.appVersion))")
                }
                found.append(InstalledPlugin(
                    manifest: manifest,
                    directory: entry,
                    isEnabled: isEnabledOnDisk(manifest.id),
                    installedAt: created,
                    loadError: nil
                ))
            } catch {
                // Keep a broken plugin visible so the user can read the error
                // and delete it, instead of it vanishing without explanation.
                found.append(InstalledPlugin(
                    manifest: Self.placeholderManifest(id: entry.lastPathComponent, name: entry.lastPathComponent),
                    directory: entry,
                    isEnabled: false,
                    installedAt: created,
                    loadError: Self.describe(error)
                ))
            }
        }

        plugins = found.sorted {
            if ($0.loadError == nil) != ($1.loadError == nil) { return $0.loadError == nil }
            return $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
        }
        revision &+= 1
    }

    private static func placeholderManifest(id: String, name: String) -> PluginManifest {
        PluginManifest(
            schemaVersion: 1, id: id, name: name, version: "?", description: "",
            author: "", homepage: nil, minAppVersion: nil, tools: []
        )
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - Enablement

    func isEnabledOnDisk(_ id: String) -> Bool {
        UserDefaults.standard.object(forKey: Self.enabledKeyPrefix + id) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKeyPrefix + id)
        if let index = plugins.firstIndex(where: { $0.manifest.id == id }) {
            plugins[index].isEnabled = enabled && plugins[index].loadError == nil
        }
        revision &+= 1
    }

    // MARK: - Install / remove

    enum InstallError: LocalizedError {
        case pluginJSONNotFound
        case alreadyInstalled(String)
        case invalidArchive(String)

        var errorDescription: String? {
            switch self {
            case .pluginJSONNotFound:
                return "The archive does not contain a plugin.json."
            case .alreadyInstalled(let id):
                return "A plugin with id “\(id)” is already installed."
            case .invalidArchive(let detail):
                return detail
            }
        }
    }

    /// Install from a .zip: the archive must contain plugin.json either at its
    /// root or inside a single top-level folder.
    @discardableResult
    func install(archiveURL: URL, replacing: Bool = true) throws -> InstalledPlugin {
        let staging = fm.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try BackupZipExtractor.extract(archiveURL, to: staging)
        return try install(payloadDirectory: staging, replacing: replacing)
    }

    /// Install from an already-unpacked directory (used by the zip path and by
    /// tests).
    @discardableResult
    func install(payloadDirectory: URL, replacing: Bool = true) throws -> InstalledPlugin {
        let source = try locatePayload(in: payloadDirectory)
        let manifestURL = source.appendingPathComponent("plugin.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw InstallError.pluginJSONNotFound }

        let manifest = try PluginManifest.parse(jsonData: Data(contentsOf: manifestURL))
        if let minimum = manifest.minAppVersion,
           !PluginVersion.satisfies(current: Self.appVersion, minimum: minimum) {
            throw PluginManifest.ManifestError.invalidField(
                "minAppVersion", "this plugin needs Minis \(minimum) or later (this build is \(Self.appVersion))")
        }

        ensureRoot()
        let destination = Self.rootDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            guard replacing else { throw InstallError.alreadyInstalled(manifest.id) }
            // Replace as a whole so files deleted from the new version do not
            // linger from the old one.
            let retired = Self.rootDirectory.appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: destination, to: retired)
            do {
                try fm.copyItem(at: source, to: destination)
                try? fm.removeItem(at: retired)
            } catch {
                try? fm.moveItem(at: retired, to: destination)
                throw error
            }
        } else {
            try fm.copyItem(at: source, to: destination)
        }

        // Executable bits do not survive ZIP reliably; give scripts the bit
        // back when the manifest ships them as commands. Harmless otherwise.
        try? Self.markScriptsExecutable(in: destination)

        reload()
        guard let installed = plugins.first(where: { $0.manifest.id == manifest.id }) else {
            throw InstallError.invalidArchive("The plugin was copied but could not be read back.")
        }
        return installed
    }

    /// The payload is the directory that directly contains plugin.json: the
    /// archive root, or one level down when the zip wrapped everything in a
    /// folder (the common GitHub "Download ZIP" layout).
    private func locatePayload(in root: URL) throws -> URL {
        if fm.fileExists(atPath: root.appendingPathComponent("plugin.json").path) { return root }
        let children = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let dirs = children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        for dir in dirs where fm.fileExists(atPath: dir.appendingPathComponent("plugin.json").path) {
            return dir
        }
        // macOS ZIPs carry a __MACOSX sibling; ignore it and any other noise.
        let candidates = dirs.filter { !$0.lastPathComponent.hasPrefix("__MACOSX") }
        if candidates.count == 1, let only = candidates.first {
            return try locatePayload(in: only)
        }
        throw InstallError.pluginJSONNotFound
    }

    private static func markScriptsExecutable(in directory: URL) throws {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in files {
            guard ["sh", "py", "js", "rb", "pl"].contains(url.pathExtension.lowercased()) else { continue }
            try? fm.setAttributes([FileAttributeKey.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func remove(id: String) throws {
        let destination = Self.rootDirectory.appendingPathComponent(id, isDirectory: true)
        guard fm.fileExists(atPath: destination.path) else { return }
        try fm.removeItem(at: destination)
        UserDefaults.standard.removeObject(forKey: Self.enabledKeyPrefix + id)
        reload()
    }

    // MARK: - Tool exposure

    /// The plugin tools the current settings expose to the agent. Errors and
    /// disabled plugins are filtered out; duplicate names across plugins are
    /// resolved first-one-wins with a logged warning.
    nonisolated static func enabledToolSpecs() -> [(pluginId: String, pluginName: String, linuxDirectory: String, tool: PluginToolSpec)] {
        // Read the enablement flags without touching the MainActor store: this
        // runs while building a request, off the UI actor.
        let fm = FileManager.default
        let root = AIChatViewModel.minisPluginsPersistentDir
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [(String, String, String, PluginToolSpec)] = []
        var claimedNames = Set<String>()
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("plugin.json")),
                  let manifest = try? PluginManifest.parse(jsonData: data),
                  manifest.id == entry.lastPathComponent else { continue }
            let enabled = UserDefaults.standard.object(forKey: enabledKeyPrefix + manifest.id) as? Bool ?? true
            guard enabled else { continue }
            for tool in manifest.tools {
                guard claimedNames.insert(tool.name).inserted else {
                    AppLogger(category: "Plugins").warning(
                        "[T-agent-plugins] tool “\(tool.name)” from \(manifest.id) shadowed by another plugin; skipped")
                    continue
                }
                result.append((manifest.id, manifest.name, "\(linuxRoot)/\(manifest.id)", tool))
            }
        }
        return result
    }

    /// Provider-neutral definitions for the tools above.
    nonisolated static func toolDefinitions() -> [AgentToolDefinition] {
        enabledToolSpecs().map { entry in
            var params: [String: AgentToolParam] = [:]
            for (key, spec) in entry.tool.parameters {
                let type: AgentParamType
                switch spec.type {
                case "integer": type = .integer
                case "boolean": type = .boolean
                case "array": type = .array
                default: type = .string
                }
                var description = spec.description
                if spec.type == "number" {
                    description = description.isEmpty
                        ? "A number (decimal allowed)."
                        : description + " (number; decimals allowed)"
                }
                let schema: AgentSchemaNode? = spec.type == "array"
                    ? .array(description: spec.description.isEmpty ? nil : spec.description,
                             items: Self.schemaNode(for: spec.items ?? "string"))
                    : nil
                params[key] = AgentToolParam(type: type, description: description,
                                             enumValues: spec.enumValues, schema: schema)
            }
            let prefix = "Plugin “\(entry.pluginName)”: "
            return AgentToolDefinition(
                name: entry.tool.name,
                description: prefix + entry.tool.description,
                parameters: params,
                required: entry.tool.required,
                propertyOrdering: entry.tool.parameters.keys.sorted()
            )
        }
    }

    private nonisolated static func schemaNode(for type: String) -> AgentSchemaNode {
        switch type {
        case "integer": return .integer(description: nil)
        case "boolean": return .boolean(description: nil)
        default: return .string(description: nil)
        }
    }

    /// Resolve a tool name to its owning plugin and spec at call time. The
    /// name is re-resolved (not captured when the request was built) so a
    /// plugin uninstalled mid-turn cannot be executed.
    nonisolated static func resolveTool(named name: String) -> (pluginId: String, linuxDirectory: String, tool: PluginToolSpec)? {
        guard let entry = enabledToolSpecs().first(where: { $0.tool.name == name }) else { return nil }
        return (entry.pluginId, entry.linuxDirectory, entry.tool)
    }
}
