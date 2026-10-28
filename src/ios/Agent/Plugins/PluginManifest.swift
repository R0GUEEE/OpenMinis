//
//  PluginManifest.swift
//  MinisApp
//
//  [T-agent-plugins] AI agent plugins: a plugin is a directory with a
//  plugin.json manifest that contributes TOOLS to the agent loop. A tool is a
//  command template executed in the Shell Container (iSH/Alpine) with the
//  model's arguments on stdin and in MINIS_TOOL_ARGS.
//
//  Layout (host + guest mirror the same directory):
//
//      <plugins>/<plugin-id>/
//          plugin.json          required
//          ...                  anything the commands need (scripts, assets)
//
//  plugin.json:
//
//      {
//        "schemaVersion": 1,
//        "id": "com.example.weather",
//        "name": "Weather",
//        "version": "1.0.0",
//        "description": "Forecasts for the model.",
//        "author": "Example",
//        "homepage": "https://example.com",
//        "minAppVersion": "1.15",
//        "tools": [
//          {
//            "name": "weather_forecast",
//            "description": "Return the forecast for a city.",
//            "command": "python3 forecast.py",
//            "timeoutSeconds": 60,
//            "parameters": {
//              "city": { "type": "string", "description": "City name" }
//            },
//            "required": ["city"]
//          }
//        ]
//      }
//
//  The guest path of the plugin's own directory is handed to the command as
//  MINIS_PLUGIN_DIR and is also the working directory, so `python3 forecast.py`
//  works without absolute paths.
//

import Foundation

// MARK: - Manifest

/// One parameter a plugin tool accepts. Mirrors the subset of JSON Schema the
/// app's provider-neutral tool layer can express (see AgentToolParam).
struct PluginParamSpec: Equatable, Sendable {
    /// "string" | "integer" | "number" | "boolean" | "array"
    var type: String
    var description: String
    var enumValues: [String]?
    /// Item type for `array` parameters (scalars only).
    var items: String?

    var isSupported: Bool {
        switch type {
        case "string", "integer", "number", "boolean": return true
        case "array": return (items ?? "string") != "array" && (items ?? "string") != "object"
        default: return false
        }
    }
}

/// One tool a plugin contributes to the agent.
struct PluginToolSpec: Equatable, Sendable, Identifiable {
    var name: String
    var description: String
    /// Shell command run with /bin/sh -c in the Shell Container.
    var command: String
    var timeoutSeconds: Int
    var parameters: [String: PluginParamSpec]
    var required: [String]

    var id: String { name }
}

/// A parsed plugin.json. Validation lives in `PluginManifest.parse`, so a
/// store only ever holds manifests that passed it.
struct PluginManifest: Equatable, Sendable {
    var schemaVersion: Int
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String
    var homepage: String?
    var minAppVersion: String?
    var tools: [PluginToolSpec]

    /// Names the app already uses for its own tools. A plugin may not shadow
    /// one: the agent's dispatch switch would keep calling the built-in and
    /// the plugin tool would silently never run.
    static let reservedToolNames: Set<String> = [
        "shell_execute", "file_read", "file_write", "file_edit", "browser_use",
        "read_image", "memory_write", "memory_get", "user_ask",
        "delegate_task", "delegate_agents", "sub_agent",
    ]

    static let maxTools = 64
    static let maxCommandLength = 8_000
    static let maxDescriptionLength = 1_024

    enum ManifestError: LocalizedError, Equatable {
        case notAnObject
        case missingField(String)
        case invalidField(String, String)
        case tooManyTools
        case duplicateTool(String)
        case unsupportedSchemaVersion(Int)

        var errorDescription: String? {
            switch self {
            case .notAnObject:
                return "plugin.json must contain a JSON object."
            case .missingField(let f):
                return "plugin.json is missing required field “\(f)”."
            case .invalidField(let f, let why):
                return "plugin.json field “\(f)” is invalid: \(why)"
            case .tooManyTools:
                return "A plugin may declare at most \(PluginManifest.maxTools) tools."
            case .duplicateTool(let n):
                return "Tool “\(n)” is declared more than once."
            case .unsupportedSchemaVersion(let v):
                return "Unsupported plugin schemaVersion \(v). This build understands version 1."
            }
        }
    }

    // MARK: Parsing

    /// Parse and validate the contents of plugin.json.
    static func parse(jsonData: Data) throws -> PluginManifest {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: jsonData, options: [])
        } catch {
            throw ManifestError.invalidField("plugin.json", "not valid JSON (\(error.localizedDescription))")
        }
        guard let dict = object as? [String: Any] else { throw ManifestError.notAnObject }
        return try parse(dict: dict)
    }

    static func parse(dict: [String: Any]) throws -> PluginManifest {
        let schemaVersion = int(dict, "schemaVersion", "schema_version") ?? 1
        guard schemaVersion == 1 else {
            throw ManifestError.unsupportedSchemaVersion(schemaVersion)
        }

        let id = try requiredString(dict, "id")
        guard id.range(of: #"^[a-z0-9][a-z0-9._-]{1,63}$"#, options: .regularExpression) != nil else {
            throw ManifestError.invalidField("id", "use 2–64 lowercase letters, digits, dots, dashes or underscores")
        }

        let name = try requiredString(dict, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw ManifestError.invalidField("name", "must be 1–80 characters")
        }

        let version = try requiredString(dict, "version")
        guard version.range(of: #"^\d+(\.\d+){0,3}([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else {
            throw ManifestError.invalidField("version", "expected a version like 1.2.0")
        }

        let description = string(dict, "description") ?? ""
        let author = string(dict, "author") ?? ""
        let homepage = string(dict, "homepage").flatMap { raw -> String? in
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else { return nil }
            return raw
        }
        let minAppVersion = string(dict, "minAppVersion", "min_app_version")

        guard let rawTools = dict["tools"] as? [[String: Any]] else {
            if dict["tools"] != nil {
                throw ManifestError.invalidField("tools", "must be an array of tool objects")
            }
            throw ManifestError.missingField("tools")
        }
        guard rawTools.count <= maxTools else { throw ManifestError.tooManyTools }

        var tools: [PluginToolSpec] = []
        var seen = Set<String>()
        for raw in rawTools {
            let tool = try parseTool(raw)
            guard seen.insert(tool.name).inserted else {
                throw ManifestError.duplicateTool(tool.name)
            }
            tools.append(tool)
        }

        return PluginManifest(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            version: version,
            description: description,
            author: author,
            homepage: homepage,
            minAppVersion: minAppVersion,
            tools: tools
        )
    }

    private static func parseTool(_ raw: [String: Any]) throws -> PluginToolSpec {
        let name = try requiredString(raw, "name")
        guard name.range(of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil else {
            throw ManifestError.invalidField("tools[].name", "“\(name)” must start with a letter and contain only letters, digits, “_” or “-” (max 64)")
        }
        guard !reservedToolNames.contains(name) else {
            throw ManifestError.invalidField("tools[].name", "“\(name)” is a built-in tool name")
        }

        let description = string(raw, "description") ?? ""
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManifestError.invalidField("tools[\(name)].description", "a description is required so the model knows when to call the tool")
        }

        let command = try requiredString(raw, "command").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw ManifestError.invalidField("tools[\(name)].command", "must not be empty")
        }
        guard command.count <= maxCommandLength else {
            throw ManifestError.invalidField("tools[\(name)].command", "longer than \(maxCommandLength) characters")
        }

        let timeout = int(raw, "timeoutSeconds", "timeout_seconds", "timeout") ?? 60
        guard (1...3_600).contains(timeout) else {
            throw ManifestError.invalidField("tools[\(name)].timeoutSeconds", "must be between 1 and 3600")
        }

        var params: [String: PluginParamSpec] = [:]
        if let rawParams = raw["parameters"] as? [String: Any] {
            for (key, value) in rawParams {
                guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) != nil else {
                    throw ManifestError.invalidField("tools[\(name)].parameters", "“\(key)” is not a valid parameter name")
                }
                guard let spec = value as? [String: Any] else {
                    throw ManifestError.invalidField("tools[\(name)].parameters.\(key)", "must be an object")
                }
                let type = (string(spec, "type") ?? "string").lowercased()
                let itemType = (spec["items"] as? [String: Any]).flatMap { string($0, "type") }
                let param = PluginParamSpec(
                    type: type,
                    description: string(spec, "description") ?? "",
                    enumValues: spec["enum"] as? [String],
                    items: itemType
                )
                guard param.isSupported else {
                    throw ManifestError.invalidField("tools[\(name)].parameters.\(key).type", "unsupported type “\(type)”")
                }
                params[key] = param
            }
        }

        var required: [String] = []
        if let rawRequired = raw["required"] as? [String] {
            for key in rawRequired {
                guard params[key] != nil else {
                    throw ManifestError.invalidField("tools[\(name)].required", "“\(key)” is not declared in parameters")
                }
                required.append(key)
            }
        }

        return PluginToolSpec(
            name: name,
            description: description.count > maxDescriptionLength
                ? String(description.prefix(maxDescriptionLength))
                : description,
            command: command,
            timeoutSeconds: timeout,
            parameters: params,
            required: required
        )
    }

    /// Accept camelCase and snake_case spellings. The manifest is authored by
    /// hand, so being strict about the spelling of an optional key would only
    /// produce avoidable install failures.
    private static func string(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = dict[key] as? String { return value }
        }
        return nil
    }

    private static func int(_ dict: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? NSNumber { return value.intValue }
            if let value = dict[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func requiredString(_ dict: [String: Any], _ key: String) throws -> String {
        guard let value = string(dict, key) else { throw ManifestError.missingField(key) }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManifestError.invalidField(key, "must not be empty")
        }
        return value
    }
}

// MARK: - Version comparison

/// Numeric comparison of dotted versions ("1.15" vs "1.15.2"), used for
/// `minAppVersion`. Missing components compare as 0 and a pre-release suffix
/// lowers the release, which is the only behaviour plugin authors rely on.
enum PluginVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = components(lhs)
        let r = components(rhs)
        let count = max(l.numbers.count, r.numbers.count)
        for index in 0..<count {
            let a = index < l.numbers.count ? l.numbers[index] : 0
            let b = index < r.numbers.count ? r.numbers[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        if l.isPrerelease != r.isPrerelease {
            return l.isPrerelease ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// True when `required` is satisfied by `current` (current >= required).
    static func satisfies(current: String, minimum required: String) -> Bool {
        compare(current, required) != .orderedAscending
    }

    private static func components(_ raw: String) -> (numbers: [Int], isPrerelease: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let core = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = core.first?
            .split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 } ?? []
        return (numbers, core.count > 1)
    }
}
