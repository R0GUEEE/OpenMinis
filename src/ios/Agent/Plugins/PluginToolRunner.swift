//
//  PluginToolRunner.swift
//  MinisApp
//
//  [T-agent-plugins] Executes a plugin tool's command in the Shell Container.
//
//  Arguments travel to the command two ways, both without ever being spliced
//  into the shell command line (so a model-supplied value cannot inject
//  shell syntax):
//    • MINIS_TOOL_ARGS       — the raw JSON object the model sent
//    • MINIS_TOOL_ARGS_FILE  — a file in /var/minis/shared/.plugin-tmp that
//                              holds the same JSON, for scripts that prefer
//                              to read a file (removed after the call)
//  The plugin's own directory is the working directory and is exported as
//  MINIS_PLUGIN_DIR, so a manifest can say `python3 forecast.py`.
//

import Foundation

enum PluginToolRunner {
    struct Result {
        var output: String
        var success: Bool
        var timedOut: Bool

        static func failure(_ message: String) -> Result {
            Result(output: message, success: false, timedOut: false)
        }
    }

    private static let logger = AppLogger(category: "Plugins")
    private static let maxOutputCharacters = 60_000

    /// Run `tool` for `pluginId`. Never throws: every failure is returned as a
    /// `Result` the model can read and recover from.
    nonisolated static func run(
        pluginId: String,
        linuxDirectory: String,
        tool: PluginToolSpec,
        argumentsJSON: String
    ) async -> Result {
        guard ISHKernel.shared.isBooted else {
            return .failure("Error: the Shell Container is not running, so plugin “\(pluginId)” cannot run. Open the terminal once to boot it, then retry.")
        }

        let argsFileHostURL = writeArgumentsFile(argumentsJSON)
        defer { if let url = argsFileHostURL { try? FileManager.default.removeItem(at: url) } }
        let argsFileGuestPath = argsFileHostURL.map {
            "\(AIChatViewModel.minisSharedLinuxDir)/.plugin-tmp/\($0.lastPathComponent)"
        }

        var exports = [
            "MINIS_PLUGIN_ID=\(shellQuote(pluginId))",
            "MINIS_PLUGIN_DIR=\(shellQuote(linuxDirectory))",
            "MINIS_TOOL_NAME=\(shellQuote(tool.name))",
            "MINIS_TOOL_ARGS=\(shellQuote(argumentsJSON))",
        ]
        if let guestPath = argsFileGuestPath {
            exports.append("MINIS_TOOL_ARGS_FILE=\(shellQuote(guestPath))")
        }
        // `exec` so the timeout kills the command itself, not a wrapper shell
        // that would leave the real command orphaned.
        var script = "cd \(shellQuote(linuxDirectory)) 2>/dev/null || { echo \"plugin directory is missing: \(linuxDirectory.replacingOccurrences(of: "\"", with: "'"))\" >&2; exit 97; }\n"
        script += exports.joined(separator: "\n") + "\n"
        script += "exec /bin/sh -c \(shellQuote(tool.command))"

        let timeout = TimeInterval(tool.timeoutSeconds)
        let started = Date()
        let result = await Task.detached(priority: .userInitiated) {
            ISHShellExecutor.executeCommandSync(script, timeout: timeout, lineCallback: nil)
        }.value

        var output = result.output
        let stderr = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            output += (output.isEmpty ? "" : "\n") + "[stderr]\n" + stderr
        }
        if output.isEmpty { output = "(no output)" }
        if output.count > maxOutputCharacters {
            output = String(output.prefix(maxOutputCharacters))
                + "\n… [truncated: output exceeded \(maxOutputCharacters) characters]"
        }

        let timedOut = result.error == .timeout
        if timedOut {
            output = "Error: plugin tool “\(tool.name)” exceeded its \(tool.timeoutSeconds)s timeout.\n" + output
        }
        let success = result.exitCode == 0 && !timedOut
        logger.info("[T-agent-plugins] tool=\(tool.name) plugin=\(pluginId) exit=\(result.exitCode) timeout=\(timedOut) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return Result(output: output, success: success, timedOut: timedOut)
    }

    // MARK: - Helpers

    private static func writeArgumentsFile(_ json: String) -> URL? {
        let fm = FileManager.default
        let dir = AIChatViewModel.minisSharedPersistentDir.appendingPathComponent(".plugin-tmp", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("args-\(UUID().uuidString).json")
            try Data(json.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            logger.warning("[T-agent-plugins] could not stage argument file: \(error.localizedDescription)")
            return nil
        }
    }

    /// POSIX-safe single-quote wrapping.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
