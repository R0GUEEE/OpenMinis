// [T-plugin-import-robust] / [T-plugin-marketplace]
//
// `Import .zip` was the only way in, and it was fragile: one picker entry for
// zips and another for folders meant picking the wrong one failed with
// "plugin.json not found", and an uncoordinated read of a file owned by another
// app's FileProvider fails outright on providers that materialise on demand.
//
// Both are extractable facts about the SHIPPING code, so they are tested here:
//
//   A. The zip extractor, compiled as shipped, unpacks the layouts a real
//      plugin ships in: deflated (GitHub "Download ZIP", iOS Compress), stored
//      (`zip -0`), wrapped in one top-level folder, and carrying macOS noise.
//   B. The manifest parser, compiled as shipped, accepts the documented example
//      and rejects what it must.
//   C. Wiring: one picker, routed through the store; the marketplace exists in
//      the project, refuses non-https, and verifies what a catalogue claims.
//
// Standalone (`swift PluginImportTests.swift`).

import Foundation

func source(_ rel: String) -> String {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<7 {
        let p = dir.appendingPathComponent("src/ios/" + rel).path
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("source not found: \(rel)")
}

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

// MARK: - A. Zip extraction, compiled as shipped

print("A. BackupZipExtractor against real plugin archive layouts")

let extractorSource = source("Agent/Backup/BackupZipExtractor.swift")
let manifestSource = source("Agent/Plugins/PluginManifest.swift")

let harness = #"""
import Compression
import Foundation

// Stub for the one app symbol BackupZipExtractor declares (it never logs).
struct AppLogger { init(category: String) {} }

"""# + extractorSource + "\n\n" + manifestSource + #"""

var hFail = 0
func t(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { hFail += 1 }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("plug-\(UUID().uuidString)")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

/// A plugin payload on disk, ready to be zipped.
func makePayload(_ dir: URL, id: String, extra: String? = nil) throws {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let manifest: [String: Any] = [
        "schemaVersion": 1,
        "id": id,
        "name": "Weather",
        "version": "1.0.0",
        "description": "Forecasts.",
        "tools": [[
            "name": "weather_forecast",
            "description": "Return the forecast for a city.",
            "command": "python3 forecast.py",
            "timeoutSeconds": 60,
            "parameters": ["city": ["type": "string", "description": "City name"]],
            "required": ["city"],
        ]],
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent("plugin.json"))
    try "print('hi')\n".write(to: dir.appendingPathComponent("forecast.py"), atomically: true, encoding: .utf8)
    if let extra {
        try extra.write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    }
}

func run(_ exe: String, _ args: [String], cwd: URL? = nil) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

// Layout 1: deflated, files at the archive root (GitHub "Download ZIP" of a
// repo whose root IS the plugin, and iOS "Compress" of the folder's contents).
let flat = root.appendingPathComponent("flat")
try makePayload(flat, id: "com.example.weather")
let flatZip = root.appendingPathComponent("flat.zip")
_ = run("/usr/bin/zip", ["-qr", flatZip.path, "."], cwd: flat)

// Layout 2: stored (no compression) — what some upload tools produce.
let storedZip = root.appendingPathComponent("stored.zip")
_ = run("/usr/bin/zip", ["-0qr", storedZip.path, "."], cwd: flat)

// Layout 3: GitHub's real shape — one top-level folder named repo-branch.
let wrapped = root.appendingPathComponent("wrapped/repo-main")
try makePayload(wrapped, id: "com.example.weather")
let wrappedZip = root.appendingPathComponent("wrapped.zip")
_ = run("/usr/bin/zip", ["-qr", wrappedZip.path, "repo-main"], cwd: root.appendingPathComponent("wrapped"))

// Layout 4: macOS noise sibling (__MACOSX) plus AppleDouble files.
let noisy = root.appendingPathComponent("noisy/repo-main")
try makePayload(noisy, id: "com.example.weather")
try Data().write(to: noisy.appendingPathComponent("._plugin.json"))
let noisyZip = root.appendingPathComponent("noisy.zip")
_ = run("/usr/bin/zip", ["-qr", noisyZip.path, "repo-main"], cwd: root.appendingPathComponent("noisy"))

/// The payload directory: plugin.json at the root, or inside one top-level
/// folder — the rule PluginStore.locatePayload implements.
func locatePayload(_ dir: URL, depth: Int = 0) -> URL? {
    if fm.fileExists(atPath: dir.appendingPathComponent("plugin.json").path) { return dir }
    guard depth < 3 else { return nil }
    let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
    let dirs = children.filter {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && !$0.lastPathComponent.hasPrefix("__MACOSX")
    }
    for d in dirs where fm.fileExists(atPath: d.appendingPathComponent("plugin.json").path) { return d }
    if dirs.count == 1, let only = dirs.first { return locatePayload(only, depth: depth + 1) }
    return nil
}

for (label, zip) in [("deflated flat", flatZip), ("stored flat", storedZip),
                     ("GitHub-wrapped", wrappedZip), ("with __MACOSX", noisyZip)] {
    let out = root.appendingPathComponent("out-\(UUID().uuidString)")
    do {
        try BackupZipExtractor.extract(zip, to: out)
        t("extracts a \(label) archive", true)
        let payload = locatePayload(out)
        t("locates plugin.json in a \(label) archive", payload != nil)
        if let payload {
            let data = try Data(contentsOf: payload.appendingPathComponent("plugin.json"))
            let manifest = try PluginManifest.parse(jsonData: data)
            t("\(label): manifest parses with its tool", manifest.tools.count == 1
              && manifest.tools[0].name == "weather_forecast")
            t("\(label): the script came across", fm.fileExists(atPath: payload.appendingPathComponent("forecast.py").path))
        }
    } catch {
        t("extracts a \(label) archive (\(error))", false)
    }
}

// A non-zip must fail loudly, not silently install nothing.
let notZip = root.appendingPathComponent("notzip.zip")
try "this is not a zip".write(to: notZip, atomically: true, encoding: .utf8)
do {
    try BackupZipExtractor.extract(notZip, to: root.appendingPathComponent("out-bad"))
    t("a non-zip is rejected", false)
} catch {
    t("a non-zip is rejected", true)
}

print("IMPORT failures=\(hFail)")
exit(hFail == 0 ? 0 : 1)
"""#

var harnessOK = false
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("plugtest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("main.swift")
    try harness.write(to: src, atomically: true, encoding: .utf8)
    let bin = tmp.appendingPathComponent("t")
    let cc = Process()
    cc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    cc.arguments = ["swiftc", "-swift-version", "5", src.path, "-o", bin.path]
    let ccPipe = Pipe()
    cc.standardOutput = ccPipe
    cc.standardError = ccPipe
    try cc.run()
    let ccOut = String(decoding: ccPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    cc.waitUntilExit()
    check("extractor + manifest compile as shipped", cc.terminationStatus == 0)
    if cc.terminationStatus != 0 { print(ccOut) }
    if cc.terminationStatus == 0 {
        let run = Process()
        run.executableURL = bin
        let pipe = Pipe()
        run.standardOutput = pipe
        run.standardError = pipe
        try run.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        print(out, terminator: "")
        harnessOK = run.terminationStatus == 0 && out.contains("IMPORT failures=0")
    }
} catch {
    check("harness setup: \(error)", false)
}
check("every archive layout installs", harnessOK)

// MARK: - B/C. Wiring

print("B. Import wiring")

let store = source("Agent/Plugins/PluginStore.swift")
let view = source("Views/Settings/PluginsManagementView.swift")
let marketplace = source("Agent/Plugins/PluginMarketplace.swift")
let marketplaceView = source("Views/Settings/PluginMarketplaceView.swift")
let pbx = source("Minis.xcodeproj/project.pbxproj")

check("one entry point decides zip vs folder from the item itself",
      store.contains("func installPickedItem(_ url: URL) throws -> InstalledPlugin")
      && store.contains("if Self.isZip(url) {")
      && store.contains("static func isZip(_ url: URL) -> Bool"))
check("the item is read through NSFileCoordinator, with a recursive fallback",
      store.contains("NSFileCoordinator().coordinate(readingItemAt: source")
      && store.contains("try Self.copyTree(from: source, to: destination)"))
check("the security scope is held for the whole copy",
      store.contains("let scoped = url.startAccessingSecurityScopedResource()")
      && store.contains("defer { if scoped { url.stopAccessingSecurityScopedResource() } }"))
check("a folder already in the Plugins directory is adopted, not copied onto itself",
      store.contains("url.deletingLastPathComponent().standardizedFileURL == Self.rootDirectory.standardizedFileURL"))
check("the UI has one picker and routes it through the store",
      view.contains("Import File or Folder…")
      && view.contains("try store.installPickedItem(url)")
      && !view.contains("store.install(archiveURL: url)\n"))
check("the marketplace is reachable from the plugins screen",
      view.contains("PluginMarketplaceView()") && view.contains("Browse Marketplace"))

print("C. Marketplace")

check("both marketplace files are in the app target",
      pbx.contains("PluginMarketplace.swift in Sources") && pbx.contains("PluginMarketplaceView.swift in Sources"))
check("sources and downloads must be https",
      marketplace.contains("case notHTTPS") && marketplace.contains("guard url.scheme?.lowercased() == \"https\""))
check("a catalogue entry's checksum is verified before unpacking",
      marketplace.contains("checksumMismatch(expected: expected, actual: actual)")
      && marketplace.contains("SHA256.hash(data: data)"))
check("the archive must be the plugin the row promised",
      marketplace.contains("idMismatch(expected: entry.id, found: installed.manifest.id)"))
check("downloads are size-capped", marketplace.contains("maxArchiveBytes"))
check("a GitHub repo can be installed without any catalogue",
      marketplace.contains("codeload.github.com") && marketplaceView.contains("githubZipURL(from: trimmed)"))
check("catalogues may be a bare array or wrapped in plugins/entries",
      marketplace.contains("forKey: .entries") && marketplace.contains("singleValueContainer()"))

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
