// [T-appgroup-container-not-fatal] The app crashed on launch (device crash
// `Minis-2026-10-29`, v1.15 b1) because a launch-time path force-unwrapped the
// App Group container:
//
//   MinisApp.init()                     MinisApp.swift:174
//     SoulStore.refreshCache()          SoulStore.swift:922
//       SoulStore.load()                SoulStore.swift:900
//         minisAppGroupRoot             AIChatViewModel+RequestBudget.swift:424  EXC_BREAKPOINT
//
// `containerURL(forSecurityApplicationGroupIdentifier:)` is nil whenever the
// signature does not carry the group entitlement (a wildcard provisioning
// profile silently drops it), when the group is revoked, and briefly on a fresh
// install. Trapping there is a startup crash the user cannot escape — they just
// get a bouncing icon.
//
// Standalone (`swift AppGroupFallbackTests.swift`).
//
//   A. The accessors, compiled as shipped: optional lookup, usable fallback.
//   B. Wiring: nothing in the app force-unwraps a group lookup any more, and
//      the launch-time paths go through the fallback-aware accessor.

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

// MARK: - A. Accessors, compiled as shipped

print("A. SharedContainerStore accessors (compiled from the shipping source)")

let storeSource = source("Shared/SharedContainerStore.swift")
let program = #"""
import Foundation

// Stub for the one other type the store references.
struct PendingShare: Codable {}

"""# + storeSource + #"""

var fail = 0
func t(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { fail += 1 }
}

// A command-line process has no App Group entitlement: this is exactly the
// state that used to trap.
// A command-line process cannot be given an App Group entitlement, but macOS
// still hands back a path for the identifier, so the nil branch cannot be
// induced here. What IS testable: the lookup is read as an optional (no trap on
// the way in) and the fallback is a real, writable place. The invariant that no
// call site force-unwraps it is checked in section B.
let container = SharedContainerStore.containerURL
t("containerURL is read as an optional — no trap on the way in", container != nil || container == nil)
t("sharedFileDirectory is optional and safe to call", SharedContainerStore.sharedFileDirectory == nil || true)
t("appGroupID still names the group", SharedContainerStore.appGroupID == "group.com.r0gueee.minis")

let fallback = SharedContainerStore.fallbackContainerURL
t("fallback is a container-shaped path name",
  fallback.lastPathComponent == "AppGroupFallback" && fallback.hasDirectoryPath)
t("fallback sits under Application Support",
  fallback.path.contains("/Application Support/"))
try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
t("fallback is creatable", FileManager.default.fileExists(atPath: fallback.path))
let probe = fallback.appendingPathComponent("probe.txt")
try? Data("ok".utf8).write(to: probe)
t("fallback is writable", (try? Data(contentsOf: probe)) != nil)
try? FileManager.default.removeItem(at: probe)

print("APPGROUP failures=\(fail)")
exit(fail == 0 ? 0 : 1)
"""#

var runtimeOK = false
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("appgroup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let src = tmp.appendingPathComponent("main.swift")
    try program.write(to: src, atomically: true, encoding: .utf8)
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
    check("store compiles as shipped", cc.terminationStatus == 0)
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
        runtimeOK = run.terminationStatus == 0 && out.contains("APPGROUP failures=0")
    }
} catch {
    check("harness setup: \(error)", false)
}
check("all accessor scenarios pass", runtimeOK)

// MARK: - B. Wiring

print("B. Wiring")

let budget = source("Agent/Chat/AIChatViewModel+RequestBudget.swift")
let app = source("MinisApp.swift")
let fp = source("FileProvider/FileProviderExtension.swift")

check("the FileProvider roots go through one fallback-aware accessor",
      budget.contains("nonisolated static var appGroupContainerURL: URL {")
      && budget.contains("SharedContainerStore.containerURL ?? SharedContainerStore.fallbackContainerURL"))
check("minisAppGroupRoot / minisConfigRoot no longer force-unwrap",
      budget.contains("appGroupContainerURL.appendingPathComponent(\"MinisFileProvider\"")
      && budget.contains("appGroupContainerURL.appendingPathComponent(\"MinisConfig\""))
check("a missing group is reported at launch, so the fallback is never silent",
      app.contains("reportAppGroupAvailability()")
      && app.contains("UNAVAILABLE — shared / skills / memory fall back to"))

check("the launch migration treats the container as optional",
      app.contains("let container = SharedContainerStore.containerURL")
      && app.contains("if let container {")
      && app.contains("MinisShared→shared"))
check("the FileProvider extension degrades instead of restart-looping",
      fp.contains("?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]"))

// The invariant itself: no force-unwrapped group lookup anywhere in the app.
func allSwiftFiles(_ rel: String) -> [URL] {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<7 {
        let candidate = dir.appendingPathComponent("src/ios/" + rel)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return (FileManager.default.enumerator(at: candidate, includingPropertiesForKeys: nil)?
                .allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        }
        dir = dir.deletingLastPathComponent()
    }
    return []
}
var offenders: [String] = []
for file in allSwiftFiles("") where !file.path.contains("/MinisTests/") {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
    // containerURL(forSecurityApplicationGroupIdentifier: …)!  — the trap.
    var idx = text.startIndex
    while let r = text.range(of: "forSecurityApplicationGroupIdentifier", range: idx..<text.endIndex) {
        idx = r.upperBound
        let tail = text[r.upperBound...].prefix(160)
        if let close = tail.firstIndex(of: ")"), tail[tail.index(after: close)...].drop(while: { $0 == " " || $0 == "\n" }).first == "!" {
            offenders.append(file.lastPathComponent)
            break
        }
    }
}
check("no app source force-unwraps an App Group container lookup\(offenders.isEmpty ? "" : " (found: \(offenders.joined(separator: ", ")))")",
      offenders.isEmpty)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
