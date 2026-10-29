//
//  SSHServerManager.swift
//  MinisApp
//
//  [T-ssh-server] Always-on SSH access to the Shell Container.
//
//  iSH implements the guest's sockets with host sockets, so an sshd started
//  inside Alpine listens on the device's own TCP port. This manager owns that
//  daemon:
//
//    • installs openssh-server once (apk), generates host keys;
//    • manages /etc/ssh/sshd_config — THE config file sshd actually reads —
//      and populates the UI from it, so a manual edit inside the container
//      is what the app shows;
//    • sets the root password (any length, including none) from the Keychain
//      and the user's authorized keys, then starts `sshd` daemonised;
//    • proves it works by reading the SSH banner off 127.0.0.1 and by finding
//      the daemon's PID inside the guest, not by trusting an exit code;
//    • keeps it alive while the app is active (a watchdog re-probes and
//      restarts), and starts it again on every foreground return.
//
//  sshd listens on 0.0.0.0, so another app on the device reaches it at
//  127.0.0.1:<port> and other devices on the network at <lan-ip>:<port>.
//
//  iOS suspends the whole process shortly after backgrounding, which stops
//  the daemon with it; the UI says so. "Always running" therefore means "as
//  long as Minis is running", which is the only guarantee an iOS app can
//  make.
//

import Foundation
import Network
import Security

@MainActor
final class SSHServerManager: ObservableObject {
    static let shared = SSHServerManager()

    enum Status: Equatable {
        case disabled
        case stopped
        case starting
        case installing
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
        var isBusy: Bool { self == .starting || self == .installing }
    }

    // MARK: - Published state (populated FROM sshd_config)

    @Published private(set) var status: Status = .disabled
    @Published private(set) var isEnabled: Bool
    /// Port from `Port` in /etc/ssh/sshd_config.
    @Published private(set) var port: Int
    /// `PasswordAuthentication` from sshd_config.
    @Published private(set) var passwordAuthentication: Bool
    /// `PermitEmptyPasswords` from sshd_config.
    @Published private(set) var allowEmptyPassword: Bool
    /// `PermitRootLogin` is not "no".
    @Published private(set) var permitRootLogin: Bool
    @Published private(set) var banner: String?
    @Published private(set) var lastError: String?
    @Published private(set) var authorizedKeys: String
    @Published private(set) var progressNote: String?
    /// Wi-Fi address shown in the UI (best effort; nil when not on a LAN).
    @Published private(set) var lanAddress: String?
    /// PID of the sshd process in the guest (proof it runs in the rootfs).
    @Published private(set) var guestPID: Int?
    /// The daemon's command line inside the guest, as `/proc/<pid>/cmdline` says.
    @Published private(set) var guestProcess: String?
    /// Contents of /etc/ssh/sshd_config as last read.
    @Published private(set) var configText: String = ""
    /// True while a refresh is reading the guest.
    @Published private(set) var isRefreshing = false

    // MARK: - Private

    private let logger = AppLogger(category: "SSHServer")
    private static let enabledKey = "ssh.server.enabled"
    private static let portKey = "ssh.server.port"
    private static let keysKey = "ssh.server.authorizedKeys"
    static let defaultPort = 2222

    /// Linux path of the config sshd reads. The UI's source of truth.
    nonisolated static let configPath = "/etc/ssh/sshd_config"
    private let pidPath = "/var/run/minis-sshd.pid"

    private var bringUpTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.enabledKey) == nil {
            isEnabled = true                     // [T-ssh-server] on by default
        } else {
            isEnabled = defaults.bool(forKey: Self.enabledKey)
        }
        let storedPort = defaults.integer(forKey: Self.portKey)
        port = storedPort > 0 ? storedPort : Self.defaultPort
        passwordAuthentication = true
        allowEmptyPassword = false
        permitRootLogin = true
        authorizedKeys = defaults.string(forKey: Self.keysKey) ?? ""
        status = isEnabled ? .stopped : .disabled
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startIfEnabled(reason: "user enabled")
        } else {
            stop()
        }
    }

    func setPort(_ newPort: Int) {
        guard (1...65535).contains(newPort), newPort != port else { return }
        port = newPort
        UserDefaults.standard.set(newPort, forKey: Self.portKey)
        applyAndRestart(reason: "port changed")
    }

    func setPasswordAuthentication(_ enabled: Bool) {
        guard enabled != passwordAuthentication else { return }
        passwordAuthentication = enabled
        applyAndRestart(reason: "password authentication changed")
    }

    func setAllowEmptyPassword(_ enabled: Bool) {
        guard enabled != allowEmptyPassword else { return }
        allowEmptyPassword = enabled
        if enabled {
            // Empty passwords are only meaningful with password auth on.
            passwordAuthentication = true
        }
        applyAndRestart(reason: "empty-password policy changed")
    }

    func setPermitRootLogin(_ enabled: Bool) {
        guard enabled != permitRootLogin else { return }
        permitRootLogin = enabled
        applyAndRestart(reason: "root login policy changed")
    }

    func setAuthorizedKeys(_ keys: String) {
        let cleaned = Self.sanitizeKeys(keys)
        authorizedKeys = cleaned
        UserDefaults.standard.set(cleaned, forKey: Self.keysKey)
        // Applied on the next start; restarting for a key edit would drop
        // sessions the user may be typing in.
    }

    /// The root password. Empty string means "no password" (PermitEmptyPasswords).
    /// Generated on first use and kept in the Keychain so a rootfs reset
    /// re-applies the same one.
    var password: String {
        if let stored = SSHPasswordKeychain.load() { return stored }
        let generated = Self.makePassword()
        SSHPasswordKeychain.save(generated)
        return generated
    }

    var hasEmptyPassword: Bool { password.isEmpty }

    func regeneratePassword() -> String {
        let generated = Self.makePassword()
        SSHPasswordKeychain.save(generated)
        allowEmptyPassword = false
        passwordAuthentication = true
        applyAndRestart(reason: "password changed")
        return generated
    }

    /// Set any password, INCLUDING the empty string (no password). No minimum
    /// length; the only rejected input is text that would corrupt the
    /// `root:password` line handed to chpasswd (newlines).
    @discardableResult
    func setPassword(_ newValue: String) -> Bool {
        guard !newValue.contains("\n"), !newValue.contains("\r") else { return false }
        SSHPasswordKeychain.save(newValue)
        // An empty password requires PermitEmptyPasswords yes; a real one
        // must turn it off or sshd would keep accepting the old empty login.
        allowEmptyPassword = newValue.isEmpty
        passwordAuthentication = true
        applyAndRestart(reason: newValue.isEmpty ? "password cleared" : "password changed")
        return true
    }

    // MARK: - Config (source of truth: /etc/ssh/sshd_config)

    /// Read /etc/ssh/sshd_config from the container and populate the published
    /// settings from it. Runs on appear and from the Refresh button; works
    /// with the kernel idle because the file is read from the fakefs data dir.
    func refreshFromConfig() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshLanAddress()
        let hostURL = RootfsManager.shared.dataPath.appendingPathComponent(String(Self.configPath.dropFirst()))

        Task { @MainActor in
            defer { self.isRefreshing = false }
            if let data = try? Data(contentsOf: hostURL),
               let text = String(data: data, encoding: .utf8) {
                self.apply(parsed: SSHDConfigFile.parse(text))
                self.configText = text
            } else {
                self.configText = ""
            }
            self.refreshRuntimeStatus()
        }
    }

    /// Re-read the daemon state: guest PID, process line, banner.
    func refreshRuntimeStatus() {
        guard ISHKernel.shared.isBooted, isEnabled else {
            guestPID = nil
            guestProcess = nil
            return
        }
        let pidPath = self.pidPath
        let port = self.port
        Task.detached(priority: .utility) {
            let probe = Self.guestStatus(pidPath: pidPath)
            let banner = await Self.probeBanner(port: UInt16(port), timeout: 2)
            await MainActor.run {
                self.guestPID = probe.pid
                self.guestProcess = probe.process
                if let banner {
                    self.banner = banner
                    if self.status != .running && !self.status.isBusy {
                        self.status = .running
                        self.lastError = nil
                    }
                } else if !self.status.isBusy {
                    self.banner = nil
                }
            }
        }
    }

    private func apply(parsed: SSHDConfigFile) {
        if let p = parsed.port, (1...65535).contains(p) { port = p }
        if let v = parsed.passwordAuthentication { passwordAuthentication = v }
        if let v = parsed.permitEmptyPasswords { allowEmptyPassword = v }
        if let v = parsed.permitRootLogin { permitRootLogin = v }
        UserDefaults.standard.set(port, forKey: Self.portKey)
    }

    private func applyAndRestart(reason: String) {
        UserDefaults.standard.set(port, forKey: Self.portKey)
        if isEnabled {
            restart(reason: reason)
        }
    }

    // MARK: - Lifecycle

    /// [T-ssh-menu-hang] Minimum interval between probes triggered by a view
    /// APPEARING.
    ///
    /// A `Section` inside a `Form` runs `.onAppear` again every time it scrolls
    /// back into view — not once per screen. Each of those queued another guest
    /// probe (`executeCommandSync`, 10 s timeout) plus a 3 s banner check
    /// against the same container, on top of the 20 s watchdog. Scrolling the
    /// Rootfs screen up and down was therefore indistinguishable from a hang:
    /// every appearance piled more work onto one shell.
    ///
    /// Appearing is not evidence that anything changed, so it is rate-limited;
    /// the watchdog and the user's own Refresh / Restart buttons are not.
    private static let appearKickInterval: TimeInterval = 30
    private var lastAppearKick: Date?
    /// Re-entrancy guard: `verifyOrRestart` awaits, so two callers can overlap.
    private var isVerifying = false

    /// The Rootfs screen's entry point. Cheap and idempotent by design — see
    /// `appearKickInterval`.
    func kickFromAppearance(reason: String) {
        refreshFromConfig()
        guard isEnabled else {
            status = .disabled
            return
        }
        let now = Date()
        if let last = lastAppearKick, now.timeIntervalSince(last) < Self.appearKickInterval { return }
        lastAppearKick = now
        startIfEnabled(reason: reason)
    }

    /// Boot the container if needed and make sure sshd is up. Called on every
    /// foreground return and after the rootfs screen appears; cheap when the
    /// daemon already answers its banner.
    func startIfEnabled(reason: String) {
        guard isEnabled else {
            status = .disabled
            return
        }
        refreshLanAddress()
        if status.isRunning || status.isBusy {
            // Still verify in the background: the process can die without the
            // app noticing between foregrounds.
            Task { await self.verifyOrRestart(source: reason) }
            return
        }
        generation += 1
        let token = generation
        bringUpTask?.cancel()
        bringUpTask = Task { await self.bringUp(token: token, reason: reason) }
    }

    func restart(reason: String) {
        stopDaemon()
        generation += 1
        let token = generation
        bringUpTask?.cancel()
        bringUpTask = Task { await self.bringUp(token: token, reason: reason) }
    }

    func stop() {
        generation += 1
        bringUpTask?.cancel()
        watchdog?.cancel()
        stopDaemon()
        status = isEnabled ? .stopped : .disabled
        banner = nil
        guestPID = nil
        guestProcess = nil
        logger.info("[T-ssh-server] stopped by user")
    }

    /// Foreground/background bookkeeping: the watchdog only makes sense while
    /// the app is in the foreground (iOS suspends everything on background).
    func handleScenePhase(active: Bool) {
        if active {
            refreshLanAddress()
            if isEnabled && !status.isBusy {
                startIfEnabled(reason: "foreground")
                refreshFromConfig()
            }
        } else {
            watchdog?.cancel()
            watchdog = nil
        }
    }

    // MARK: - Bring-up

    private func bringUp(token: Int, reason: String) async {
        guard token == generation else { return }
        status = .starting
        lastError = nil
        progressNote = nil

        if RootfsManager.shared.didResetWhileBooted {
            fail("The Linux environment was reset. Restart the app so it can be reinstalled, then the SSH server can start.")
            return
        }

        // Snapshot every setting; the start script writes them into
        // /etc/ssh/sshd_config, which is what sshd reads.
        let settings = SSHRuntimeSettings(
            port: port,
            password: password,
            passwordAuthentication: passwordAuthentication,
            allowEmptyPassword: allowEmptyPassword,
            permitRootLogin: permitRootLogin,
            authorizedKeys: authorizedKeys,
            configPath: Self.configPath,
            pidPath: pidPath
        )

        let outcome = await Task.detached(priority: .userInitiated) { () -> SetupOutcome in
            do {
                try Self.bootKernelIfNeeded()
            } catch {
                return SetupOutcome(error: error.localizedDescription)
            }
            return Self.setUpAndStart(settings: settings) { note in
                Task { @MainActor in
                    guard token == self.generation else { return }
                    self.status = note == .installing ? .installing : .starting
                    self.progressNote = note.text
                }
            }
        }.value

        guard token == generation else { return }
        progressNote = nil

        if let error = outcome.error {
            fail(error)
            return
        }

        // Exit code 0 from sshd only means it daemonised. The banner proves
        // the port answers; the guest PID proves it is the container's sshd.
        if let banner = await Self.probeBanner(port: UInt16(settings.port), timeout: 6) {
            guestPID = outcome.guestPID
            guestProcess = outcome.process
            if !outcome.configText.isEmpty {
                configText = outcome.configText
                apply(parsed: SSHDConfigFile.parse(outcome.configText))
            }
            succeed(banner: banner, note: reason)
            return
        }

        let tail = outcome.log.split(separator: "\n").suffix(4).joined(separator: "\n")
        fail(AppLocalized("sshd started but did not answer on port \(settings.port).\n\(tail)"))
    }

    private func succeed(banner: String, note: String) {
        status = .running
        self.banner = banner
        lastError = nil
        consecutiveFailures = 0
        refreshLanAddress()
        startWatchdog()
        logger.info("[T-ssh-server] running in guest pid=\(guestPID.map(String.init) ?? "?") on :\(port) banner=\(banner) (\(note))")
    }

    private func fail(_ message: String) {
        status = .failed(message)
        lastError = message
        logger.error("[T-ssh-server] \(message)")
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.verifyOrRestart(source: "watchdog")
            }
        }
    }

    private func verifyOrRestart(source: String) async {
        guard isEnabled else { return }
        guard !status.isBusy else { return }
        // [T-ssh-menu-hang] One verification at a time: the body awaits a 3 s
        // banner probe, and without this flag a second caller (the watchdog
        // crossing an appearance kick) probes concurrently and can restart the
        // daemon on evidence that is already stale.
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        if let banner = await Self.probeBanner(port: UInt16(port), timeout: 3) {
            if status != .running {
                status = .running
                lastError = nil
                self.banner = banner
            }
            consecutiveFailures = 0
            return
        }
        guard status.isRunning || status == .stopped else { return }
        consecutiveFailures += 1
        logger.warning("[T-ssh-server] banner probe failed (\(source)) attempt \(consecutiveFailures)")
        if consecutiveFailures <= 3 {
            restart(reason: "watchdog restart")
        } else {
            fail(AppLocalized("The SSH server keeps stopping. Open the terminal once, then tap Restart."))
        }
    }

    // MARK: - Guest side

    private struct SetupOutcome {
        var error: String?
        var log: String = ""
        var guestPID: Int?
        var process: String?
        var configText: String = ""
    }

    private enum ProgressNote {
        case starting, installing
        var text: String {
            switch self {
            case .starting: return AppLocalized("Starting…")
            case .installing: return AppLocalized("Installing OpenSSH…")
            }
        }
    }

    private struct SSHRuntimeSettings: Sendable {
        var port: Int
        var password: String
        var passwordAuthentication: Bool
        var allowEmptyPassword: Bool
        var permitRootLogin: Bool
        var authorizedKeys: String
        var configPath: String
        var pidPath: String
    }

    private struct GuestStatus: Sendable {
        var pid: Int?
        var process: String?
    }

    /// True once the fakefs change tracker and the per-session path router
    /// have been installed for this process. The chat boot path installs them
    /// too; whichever boots the kernel first must do it, or sync and
    /// /var/minis routing are silently missing for the whole session.
    nonisolated(unsafe) private static var kernelHooksInstalled = false

    nonisolated private static func bootKernelIfNeeded() throws {
        guard RootfsManager.shared.isInstalled else {
            throw NSError(domain: "SSHServer", code: -20, userInfo: [
                NSLocalizedDescriptionKey: "The Shell Container is not installed yet. Install it from Rootfs Management, then the SSH server can start."
            ])
        }
        // Boot the shared kernel without auto-installing a rootfs: starting
        // the app must not download one behind the user's back.
        if !ISHKernel.shared.isBooted {
            let error = ISHKernel.shared.boot(withRootPath: RootfsManager.shared.rootfsPath.path)
            if error < 0 {
                throw NSError(domain: "SSHServer", code: Int(error), userInfo: [
                    NSLocalizedDescriptionKey: "The Shell Container failed to boot (code \(error))."
                ])
            }
        }
        if !kernelHooksInstalled {
            kernelHooksInstalled = true
            installSessionFileChangeTracker(kernel: ISHKernel.shared)
            MinisFsRouter.shared.installHook()
        }
        RootfsManager.shared.applyDefaultMountOverlay()
    }

    /// Everything that must happen inside the guest before sshd can answer.
    /// Runs off the main actor; returns a log tail for the failure path.
    nonisolated private static func setUpAndStart(
        settings: SSHRuntimeSettings,
        status: @escaping @Sendable (ProgressNote) -> Void
    ) -> SetupOutcome {
        var log = ""
        let configPath = settings.configPath
        let quotedConfig = shellQuote(configPath)

        // 1. Package. `command -v sshd` is enough: openssh-server is the only
        // package that provides it.
        let installed = ISHShellExecutor.executeCommandSync(
            "command -v sshd >/dev/null 2>&1 && /usr/sbin/sshd -V 2>&1 | head -n 1 || true",
            timeout: 15, lineCallback: nil)
        if !installed.output.contains("OpenSSH") {
            status(.installing)
            let add = ISHShellExecutor.executeCommandSync(
                "apk add --no-cache openssh-server openssh-sftp-server 2>&1",
                timeout: 900, lineCallback: nil)
            log = add.output
            if add.exitCode != 0 {
                return SetupOutcome(error: AppLocalized("Could not install OpenSSH: \(add.output.split(separator: "\n").suffix(3).joined(separator: "\n"))"), log: log)
            }
        }

        // 2. Read the EXISTING config, patch only the managed directives, so
        // edits made by hand inside the container survive a restart.
        let read = ISHShellExecutor.executeCommandSync(
            "cat \(quotedConfig) 2>/dev/null || true", timeout: 15, lineCallback: nil)
        let originalConfig = read.output
        let newConfig = SSHDConfigFile.patched(
            originalConfig,
            port: settings.port,
            passwordAuthentication: settings.passwordAuthentication,
            allowEmptyPassword: settings.allowEmptyPassword,
            permitRootLogin: settings.permitRootLogin,
            pidPath: settings.pidPath
        )

        let keyFile = "/root/.ssh/authorized_keys"
        let keySetup: String
        if settings.authorizedKeys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keySetup = "mkdir -p /root/.ssh; chmod 700 /root/.ssh; : > \(keyFile); chmod 600 \(keyFile)"
        } else {
            keySetup = "mkdir -p /root/.ssh; chmod 700 /root/.ssh; printf '%s\\n' \(shellQuote(settings.authorizedKeys)) > \(keyFile); chmod 600 \(keyFile)"
        }

        // Empty password = no password: `passwd -d root` clears the shadow
        // entry and PermitEmptyPasswords yes lets sshd accept it.
        let passwordSetup: String
        if settings.password.isEmpty {
            passwordSetup = "passwd -d root >/dev/null 2>&1 || true"
        } else {
            passwordSetup = "printf '%s\\n' \(shellQuote("root:\(settings.password)")) | chpasswd"
        }

        // Kill a daemon started from the old config path too, so an upgrade
        // from minis_sshd_config cannot leave a process holding the port.
        let script = """
        set -e
        mkdir -p /etc/ssh /run /var/run /root/.ssh /var/log
        chmod 755 /run /var/run 2>/dev/null || true
        (ssh-keygen -A >/dev/null 2>&1) || true
        printf '%s' \(shellQuote(newConfig)) > \(quotedConfig)
        chmod 600 \(quotedConfig)
        \(passwordSetup)
        \(keySetup)
        pkill -x sshd >/dev/null 2>&1 || true
        sleep 0.3
        rm -f \(shellQuote(settings.pidPath))
        /usr/sbin/sshd -f \(quotedConfig) -E /var/log/minis-sshd.log
        sleep 0.6
        if [ -f \(shellQuote(settings.pidPath)) ]; then
            pid=$(cat \(shellQuote(settings.pidPath)) 2>/dev/null || true)
            if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
                printf 'GUEST_PID=%s\\n' "$pid"
                tr '\\0' ' ' < "/proc/$pid/cmdline"
                printf '\\n'
            fi
        fi
        tail -n 5 /var/log/minis-sshd.log 2>/dev/null || true
        printf '\\n---MINIS-CONFIG---\\n'
        cat \(quotedConfig)
        """

        let start = ISHShellExecutor.executeCommandSync(script, timeout: 120, lineCallback: nil)
        log += "\n" + start.output + "\n" + start.errorOutput
        if start.exitCode != 0 {
            let tail = (start.output + "\n" + start.errorOutput).split(separator: "\n").suffix(5).joined(separator: "\n")
            return SetupOutcome(error: AppLocalized("Could not start sshd on port \(settings.port):\n\(tail)"), log: log)
        }

        // Parse the tail we asked for: GUEST_PID, the cmdline line, then the
        // config file itself after the marker.
        let lines = start.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pid: Int?
        var process: String?
        for (index, line) in lines.enumerated() where line.hasPrefix("GUEST_PID=") {
            pid = Int(line.dropFirst("GUEST_PID=".count))
            if index + 1 < lines.count { process = lines[index + 1] }
            break
        }
        let configText: String
        if let marker = start.output.range(of: "---MINIS-CONFIG---\n") {
            configText = String(start.output[marker.upperBound...])
        } else {
            configText = ""
        }

        return SetupOutcome(error: nil, log: log, guestPID: pid, process: process, configText: configText)
    }

    /// PID and command line of the sshd running inside the container.
    nonisolated private static func guestStatus(pidPath: String) -> GuestStatus {
        let script = """
        pid=$(cat \(shellQuote(pidPath)) 2>/dev/null || true)
        if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
            printf 'PID=%s\\n' "$pid"
            tr '\\0' ' ' < "/proc/$pid/cmdline"
            printf '\\n'
        fi
        """
        let result = ISHShellExecutor.executeCommandSync(script, timeout: 10, lineCallback: nil)
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.hasPrefix("PID=") else { return GuestStatus() }
        return GuestStatus(pid: Int(first.dropFirst(4)), process: lines.count > 1 ? lines[1] : nil)
    }

    private func stopDaemon() {
        guard ISHKernel.shared.isBooted else { return }
        // `pkill -x sshd` matches the daemon by exact process name. A
        // `pkill -f <pattern>` here would also match the /bin/sh -c script
        // running this very command (its command line contains the pattern)
        // and kill the shell before it reached sshd.
        _ = ISHShellExecutor.executeCommandSync(
            "pkill -x sshd >/dev/null 2>&1 || true",
            timeout: 15, lineCallback: nil)
    }

    // MARK: - Probing

    /// Read the SSH identification string. A successful TCP connect that
    /// yields "SSH-2.0-…" proves the guest daemon is answering, which an exit
    /// code never does (sshd forks into the background).
    nonisolated static func probeBanner(port: UInt16, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let queue = DispatchQueue(label: "minis.ssh.probe")
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let box = ResumeOnce(continuation: continuation, queue: queue)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
                        if let data, let text = String(data: data, encoding: .utf8),
                           text.hasPrefix("SSH-") {
                            box.finish(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else if error != nil {
                            box.finish(nil)
                        }
                        connection.cancel()
                    }
                case .failed, .cancelled:
                    box.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                box.finish(nil)
                connection.cancel()
            }
        }
    }

    /// Resume-once wrapper: NWConnection can call back on several paths and a
    /// double resume would trap.
    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<String?, Never>?
        private let queue: DispatchQueue
        init(continuation: CheckedContinuation<String?, Never>, queue: DispatchQueue) {
            self.continuation = continuation
            self.queue = queue
        }
        func finish(_ value: String?) {
            queue.async {
                guard let continuation = self.continuation else { return }
                self.continuation = nil
                continuation.resume(returning: value)
            }
        }
    }

    // MARK: - Helpers

    private func refreshLanAddress() {
        lanAddress = Self.currentWiFiAddress()
    }

    nonisolated static func currentWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer = first
        while true {
            let interface = pointer.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 is Wi-Fi on iPhone; other interfaces are tunnels/cellular.
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let value = String(cString: host)
                        if !value.isEmpty { address = value }
                    }
                }
            }
            guard let next = interface.ifa_next else { break }
            pointer = next
        }
        return address
    }

    private static func sanitizeKeys(_ raw: String) -> String {
        let allowed = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                if line.isEmpty || line.hasPrefix("#") { return true }
                return line.range(of: #"^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)[A-Za-z0-9@.-]+ [A-Za-z0-9+/=]+"#,
                                 options: .regularExpression) != nil
            }
        // Cap the file size; authorized_keys is read by sshd on every login.
        let joined = allowed.joined(separator: "\n")
        return String(joined.prefix(16_000))
    }

    private static func makePassword() -> String {
        // No ambiguous glyphs: the password is read off a phone screen and
        // typed on a computer.
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<20).map { _ in alphabet.randomElement()! })
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - sshd_config parsing/patching

/// The subset of sshd_config the UI exposes. sshd uses the FIRST value it
/// sees for a directive, so parsing takes the first occurrence too.
struct SSHDConfigFile: Equatable, Sendable {
    var port: Int?
    var passwordAuthentication: Bool?
    var permitEmptyPasswords: Bool?
    var permitRootLogin: Bool?
    var listenAddresses: [String] = []

    static func parseOptional(_ text: String) -> SSHDConfigFile? {
        text.isEmpty ? nil : parse(text)
    }

    static func parse(_ text: String) -> SSHDConfigFile {
        var result = SSHDConfigFile()
        var seen = Set<String>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard seen.insert(key).inserted else { continue }   // first wins
            switch key {
            case "port": result.port = Int(value)
            case "passwordauthentication": result.passwordAuthentication = yes(value)
            case "permitemptypasswords": result.permitEmptyPasswords = yes(value)
            case "permitrootlogin": result.permitRootLogin = (value.lowercased() != "no")
            case "listenaddress": result.listenAddresses.append(value)
            default: break
            }
        }
        return result
    }

    /// Rewrite only the directives Minis manages. A manually added option
    /// (AllowUsers, banners, ciphers…) is preserved. The managed block goes
    /// FIRST because sshd takes the first value of a directive.
    static func patched(
        _ original: String,
        port: Int,
        passwordAuthentication: Bool,
        allowEmptyPassword: Bool,
        permitRootLogin: Bool,
        pidPath: String
    ) -> String {
        var block = """
        # --- Managed by Minis SSH Access. Edits to these lines are rewritten. ---
        Port \(port)
        ListenAddress 0.0.0.0
        AddressFamily any
        PermitRootLogin \(permitRootLogin ? "yes" : "no")
        PasswordAuthentication \(passwordAuthentication ? "yes" : "no")
        PermitEmptyPasswords \(allowEmptyPassword ? "yes" : "no")
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AuthorizedKeysFile .ssh/authorized_keys
        UseDNS no
        X11Forwarding no
        AllowTcpForwarding yes
        PidFile \(pidPath)
        Subsystem sftp /usr/lib/ssh/sftp-server
        """
        if !block.hasSuffix("\n") { block += "\n" }

        let managed: Set<String> = [
            "port", "listenaddress", "addressfamily", "permitrootlogin",
            "passwordauthentication", "permitemptypasswords",
            "kbdinteractiveauthentication", "pubkeyauthentication",
            "authorizedkeysfile", "usedns", "x11forwarding",
            "allowtcpforwarding", "pidfile", "subsystem",
        ]
        var kept: [String] = []
        for raw in original.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                let key = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)?.lowercased()
                if let key, managed.contains(key) { continue }
            }
            kept.append(line)
        }
        // Collapse leading blank lines left by removed directives.
        while let first = kept.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            kept.removeFirst()
        }
        let rest = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return block + "\n" + rest + "\n"
    }

    private static func yes(_ value: String) -> Bool {
        let v = value.lowercased()
        return v == "yes" || v == "true" || v == "1" || v == "on"
    }
}

// MARK: - Keychain

private enum SSHPasswordKeychain {
    private static let service = "app.openminis.ssh"
    private static let account = "root-password"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }

    /// nil when no password has ever been stored; "" when the user chose
    /// "no password" (an empty password is a real, load-bearing value here).
    static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String) {
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
