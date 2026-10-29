// [set-cookies-samesite] `set_cookies` used to accept a `sameSite` field and
// throw it away ("HTTPCookie has no public SameSite property key"), so an
// export like [{…, "sameSite":"Lax"}] restored a cookie with no policy — a
// login that behaves differently on every cross-site navigation.
//
// The premise was wrong: `HTTPCookiePropertyKey.sameSitePolicy` has been public
// since iOS 13 (NSHTTPCookieSameSitePolicy), and HTTPCookie round-trips the
// value. `sameSitePolicy(_:)` is therefore EXTRACTED FROM THE SHIPPING SOURCE
// and compiled here, so this test cannot drift from the code it covers.
//
// Standalone (`swift SetCookiesSameSiteTests.swift`) because the MinisTests
// target cannot link WebKit types used by the file it reads.
//
//   A. The normaliser, compiled as shipped: every spelling real exports emit.
//   B. The wiring: applied on write, read back, reported when dropped, and
//      preserved through the cookie backup/restore path.

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

/// The braces-balanced body of `needle`, from its first `{` to its matching `}`.
func balanced(_ text: String, from needle: String) -> String? {
    guard let r = text.range(of: needle) else { return nil }
    var depth = 0
    var i = r.lowerBound
    var started = false
    while i < text.endIndex {
        let c = text[i]
        if c == "{" {
            depth += 1
            started = true
        } else if c == "}" {
            depth -= 1
            if started && depth == 0 {
                return String(text[r.lowerBound...i])
            }
        }
        i = text.index(after: i)
    }
    return nil
}

func dedent(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            let s = String(line)
            return s.hasPrefix("    ") ? String(s.dropFirst(4)) : s
        }
        .joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let manager = source("Agent/BrowserUse/BrowserUseManager.swift")
let backup = source("Agent/BrowserUse/CookieBackupStore.swift")

// MARK: - A. The normaliser, compiled as shipped

print("A. sameSite normalization (compiled from the shipping source)")

guard let enumBody = balanced(manager, from: "enum SameSiteValue: Equatable {"),
      let funcBody = balanced(manager, from: "static func sameSitePolicy(_ raw: String) -> SameSiteValue {") else {
    print("  ❌ could not locate SameSiteValue / sameSitePolicy in BrowserUseManager.swift")
    exit(1)
}

let program = #"""
import Foundation
"""# + "\n" + dedent(enumBody) + "\n\n"
    + dedent(funcBody).replacingOccurrences(of: "static func", with: "func") + "\n\n"
    + #"""
var fail = 0
func t(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { fail += 1 }
}
t("Lax (EditThisCookie spelling) → lax", sameSitePolicy("Lax") == .policy("lax"))
t("strict, any case → strict", sameSitePolicy("strict") == .policy("strict") && sameSitePolicy("STRICT") == .policy("strict"))
t("None → none", sameSitePolicy("None") == .policy("none"))
t("no_restriction (Cookie-Editor) → none", sameSitePolicy("no_restriction") == .policy("none"))
t("unspecified → left alone, not an error", sameSitePolicy("unspecified") == .unspecified)
t("empty → left alone", sameSitePolicy("  ") == .unspecified)
t("garbage → reported, never guessed at", sameSitePolicy("cross-site-ish") == .unsupported)
print("NORMALIZER failures=\(fail)")
exit(fail == 0 ? 0 : 1)
"""#

var normalizerOK = false
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("samesite-\(UUID().uuidString)")
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
    check("normalizer compiles as shipped", cc.terminationStatus == 0)
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
        normalizerOK = run.terminationStatus == 0 && out.contains("NORMALIZER failures=0")
    }
} catch {
    check("normalizer harness setup: \(error)", false)
}
check("all SameSite scenarios pass", normalizerOK)

// MARK: - B. Wiring

print("B. Wiring")

check("the policy is written through the public property key",
      manager.contains("properties[.sameSitePolicy] = policy"))
check("the value the hash read is validated, not trusted",
      manager.contains("switch Self.sameSitePolicy(raw)") && manager.contains("case .unsupported:"))
check("a policy Foundation dropped is detected by reading the cookie back",
      manager.contains("cookie.sameSitePolicy == nil") && manager.contains("sameSiteNotApplied.append(name)"))
check("an unrecognised value is reported to the caller, not silently swallowed",
      manager.contains("SameSite value not recognised, left unset")
      && manager.contains("could not be stored for"))
check("no TODO is left claiming there is no write path",
      !manager.contains("TODO [set-cookies-samesite]"))

check("the backup records the live cookie's policy",
      backup.contains("sameSite = cookie.sameSitePolicy?.rawValue"))
check("a restore writes it back",
      backup.contains("properties[.sameSitePolicy] = sameSite"))
check("backups written before the field existed still decode (optional, not required)",
      backup.contains("var sameSite: String?"))
check("the restore log says SameSite too, so a missing policy is visible",
      backup.contains("attrs.append(\"SameSite=\\(sameSite)\")"))

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
