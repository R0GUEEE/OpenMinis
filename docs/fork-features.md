# Fork additions (iOS)

This fork adds eight things on top of upstream OpenMinis. All of them are iOS-first;
the Android tree is untouched.

## 1. Agent plugins  `[T-agent-plugins]`

A plugin is a folder with a `plugin.json` that contributes tools to the agent.
Plugins live in the app-group `plugins/` directory and are bind-mounted into the
Shell Container at `/var/minis/plugins`, so a plugin's scripts are available to
the command it declares.

```
<plugins>/<plugin-id>/
  plugin.json
  forecast.py
```

```json
{
  "schemaVersion": 1,
  "id": "com.example.weather",
  "name": "Weather",
  "version": "1.0.0",
  "description": "Forecasts for the model.",
  "author": "Example",
  "tools": [
    {
      "name": "weather_forecast",
      "description": "Return the forecast for a city.",
      "command": "python3 forecast.py",
      "timeoutSeconds": 60,
      "parameters": {
        "city": { "type": "string", "description": "City name" }
      },
      "required": ["city"]
    }
  ]
}
```

* Install: Settings → Plugins → **+** → pick a `.zip` or a folder. The folder name
  must equal the manifest `id`.
* Execution: `/bin/sh -c <command>` in the Shell Container, working directory =
  the plugin folder. Arguments arrive as JSON in `$MINIS_TOOL_ARGS`; the same JSON
  is also written to the file named by `$MINIS_TOOL_ARGS_FILE` and removed after
  the call. `$MINIS_PLUGIN_ID`, `$MINIS_PLUGIN_DIR` and `$MINIS_TOOL_NAME` are set.
* Validation: id, version, tool-name syntax, parameter types (string, integer,
  number, boolean, array-of-scalar), unique names, and a refusal to shadow a
  built-in tool. A broken plugin stays visible with its error so it can be deleted.
* Source: `src/ios/Agent/Plugins/`, `src/ios/Views/Settings/PluginsManagementView.swift`.

## 2. Package-manager coverage in Rootfs Management  `[T-mirrors-more-package-managers]`

* Registry mirrors now cover **pipx, cargo, go, gem and composer** in addition to
  APK, pip and npm. Each writes the file that manager actually reads:
  `~/.config/pip/pip.conf`, `~/.cargo/config.toml` (sparse source replacement),
  `~/.config/go/env` (`GOPROXY`), `~/.gemrc`, `~/.config/composer/config.json`.
* A new **Package Managers** section probes `pip3/pipx/npm/cargo/go/gem/composer`
  in one guest call, shows each version, installs missing ones with
  `apk add --no-cache …`, and links to that manager's mirror screen.
* Turning a mirror off removes a config file Minis created instead of leaving a
  stale registry behind.

## 3. AOJIT: family-served versions are “Ready”  `[T-aojit-ready-family]`

* A module installed in the image's family (a newer build than the recorded one)
  now shows **Ready** instead of **Partial**: the runtime does serve it, with the
  unchanged code coming from the image.
* The downgrade path is gone for that case. Previously the row offered
  `apk add <pkg>=<old build>`, which replaced a healthy, newer package for a
  marginal gain and could pull dependent packages back with it.
* A failed pinned install now retries unpinned, so a mirror that has dropped the
  recorded build no longer dead-ends: the current build runs through family
  matching.
* Tests: `src/ios/MinisTests/Standalone/AOJITTests.swift`.

## 4. Always-on SSH server on port 2222  `[T-ssh-server]`

Rootfs Management → **SSH Access**. The app installs `openssh-server` once,
generates host keys, and manages **`/etc/ssh/sshd_config` — the file sshd
actually reads**. The settings screen is populated from that file, so an edit
made in the terminal shows up after **Reload from sshd_config**. Minis rewrites
only the directives it owns (at the top, because sshd takes the first value)
and preserves any line you add yourself.

* On by default, port 2222, root user. **Any password length, including an
  empty password** (no password). Empty passwords set `PermitEmptyPasswords
  yes` and clear the root shadow entry; a real password switches that off.
* **Proof it runs in the rootfs**: the daemon is started with
  `-f /etc/ssh/sshd_config` from a guest shell, and the UI shows the guest PID
  and `/proc/<pid>/cmdline` as reported inside the container. Reachability is
  still proven by reading the SSH banner off `127.0.0.1:<port>`.
* **Reachable from other apps and other devices**: `ListenAddress 0.0.0.0`
  with `AddressFamily any`; the UI shows both `ssh -p <port> root@127.0.0.1`
  and the Wi-Fi address. Password auth, empty passwords and root login are
  separate toggles mirroring `PasswordAuthentication`, `PermitEmptyPasswords`
  and `PermitRootLogin`.
* The watchdog re-probes every 20 s while the app is active and restarts after
  a failure. Foreground return restarts it; iOS suspends the whole process in
  the background, which stops the daemon with it — the UI says so.
* Restart/stop use `pkill -x sshd`, not `pkill -f <config path>`: the latter
  also matched the `/bin/sh -c` running the start script (its command line
  contains the pattern) and killed the script before it could start sshd.
* Source: `src/ios/Agent/SSH/SSHServerManager.swift`,
  `src/ios/Views/Rootfs/SSHServerView.swift`.

## 5. Terminal redesign  `[T-terminal-font-size]`, `[T-terminal-alt-key]`

* Text size is a user setting (9–28 pt): **pinch to zoom** on the terminal, or the
  toolbar text-size menu (⌘+ / ⌘-). Cell metrics are recomputed and the UIKit view
  is rebuilt for the new size while the session survives.
* A sticky **Alt/Meta** key on the accessory bar sends the ESC prefix that
  readline and vim expect.
* New Home / End / PgUp / PgDn keys for shells and pagers on a touch keyboard.
* `COLORTERM=truecolor` is exported to every guest process alongside the existing
  `TERM=xterm-256color` / `LANG=C.UTF-8`.

## 6. Hosted MCP server  `[T-mcp-host]`

The app can now act as an MCP **server** (the reverse of MCP Integrations, which
configures MCP clients). Streamable HTTP:

```
POST /mcp      JSON-RPC 2.0
GET  /health   plain status
```

Tools: `shell_execute`, `file_read`, `file_write`, `list_dir`, `app_info`. They
run in the same Shell Container as the on-device agent, so paths, bind mounts and
permissions match exactly.

* On by default, port 8099, bound for on-device clients. **Allow LAN** exposes it
  to other devices; every request except `/health` needs
  `Authorization: Bearer <token>` (32 characters, Keychain, regenerable).
* Settings → MCP Server shows the endpoint, token, a ready-to-paste client JSON
  block and a cURL smoke test.
* Source: `src/ios/Agent/MCPServer/MCPHostedServer.swift`,
  `src/ios/Views/Settings/MCPHostSettingsView.swift`.

## 7. Rate limits for stock Claude / OpenAI API keys  `[T-quota-passive-api-key]`

Upstream reports quota for an *OAuth subscription* (Pro/Max, ChatGPT) but shows
nothing at all for a plain API key: `openAIPlatform` and `anthropicPlatform` were
mapped to "only reports quota alongside replies; showing it isn't supported yet".

Both vendors publish the key's throughput limits on **every** response, a 429
included, so there is nothing to query — only something to read:

* `anthropic-ratelimit-{requests,tokens,input-tokens,output-tokens}-{limit,remaining,reset}`
  (`reset` an RFC 3339 timestamp);
* `x-ratelimit-{limit,remaining,reset}-{requests,tokens}`
  (`reset` a Go duration: `1s`, `20ms`, `6m0s`).

What that gives you:

* **A row that fills itself in.** No request of Minis's own, no polling,
  foreground-only like the rest of quota. Until the first reply the section says
  "This provider reports its rate limits alongside replies. Send a message to see
  them." and offers **no refresh button**, because there is nothing to ask.
* **Rate limits stay rate limits.** Each metric is its own `.rateLimit` pool on a
  rolling minute — `Requests 980 / 1000`, `Input tokens 39 000 / 40 000` — a kind
  that never headlines the account and never draws a percentage bar. A key at
  200-of-200 requests-per-minute is not "plenty of credit".
* **A 429 reads as rate limited**, not as an exhausted balance: remaining `0`
  with a reset still in the future is the `.rateLimited` state.
* **Two instances on one key share the pools** — the subject is the hashed
  credential, exactly as for the querying vendors.
* **Nothing is guessed.** A metric without a usable `limit`/`remaining` is
  dropped, an unrecognised metric name is dropped rather than mislabelled, and a
  subscription's `anthropic-ratelimit-unified-*` / `x-codex-*` headers are never
  read as platform limits.
* Gemini API keys move to "doesn't offer a balance or quota lookup": that API
  reports neither a balance nor rate-limit headers, so the old wording overpromised.
* Plumbing: the Anthropic API-key and manual-token `URLProtocol`s tag their
  session with `X-Minis-Quota-Instance` (a random id, resolved and stripped
  before the request leaves) because Foundation hands a `URLProtocol` nothing but
  the request; the OpenAI provider reads the headers off the response it already
  holds, in `sendMessage`, `streamMessage` and `streamRaw`.
* Source: `src/ios/Providers/Quota/QuotaAdapters.swift` (`PassiveRateLimitHeaders`,
  `AnthropicPlatformQuotaAdapter`, `OpenAIPlatformQuotaAdapter`),
  `src/ios/Providers/Quota/QuotaStore.swift` (`observeResponseHeaders`),
  `src/ios/Providers/Anthropic/OAuthHTTPClient.swift`.
* Tests: `src/ios/MinisTests/Standalone/ProviderQuotaTests.swift`.

## 8. `set_cookies` keeps SameSite, and the backup restores it  `[set-cookies-samesite]`

The browser tool documented `sameSite` as "accepted but NOT applied: HTTPCookie
has no public SameSite property key honored by WKHTTPCookieStore". That premise
was wrong — `HTTPCookiePropertyKey.sameSitePolicy` (`NSHTTPCookieSameSitePolicy`)
has been public since iOS 13, and `HTTPCookie` round-trips `lax` / `strict` /
`none`. So a Playwright / EditThisCookie export restored cookies with the right
expiry, HttpOnly and Secure but no SameSite at all.

* Every spelling real exports emit is normalised: `Lax`/`lax`, `Strict`, `None`,
  Cookie-Editor's `no_restriction` (= None), and `unspecified` (no policy stated —
  not an error). Anything else is reported back to the caller instead of being
  dropped silently.
* The policy is read back off the built `HTTPCookie`; when Foundation did not keep
  it, the result says which cookies lost it instead of implying the export was
  applied verbatim.
* `CookieBackupStore` records each live cookie's policy and writes it back on
  restore, so an ITP-evicted or session-expired login comes back with the same
  cross-site behaviour it had. Backups written before the field existed still
  decode (it is optional), and the restore log names `SameSite=` so a missing
  policy is visible.
* Source: `src/ios/Agent/BrowserUse/BrowserUseManager.swift` (`sameSitePolicy(_:)`),
  `src/ios/Agent/BrowserUse/CookieBackupStore.swift`.
* Tests: `src/ios/MinisTests/Standalone/SetCookiesSameSiteTests.swift` — the
  normaliser is extracted from the shipping source and compiled, so it cannot
  drift.

## Build note: `AIChatView.body`  `[T-ios-body-typecheck]`

The 1.16 tree did not compile at all: `AIChatView.body` failed with "the compiler
is unable to type-check this expression in reasonable time" — on `body` itself,
not on one sub-expression. The ~80-modifier chain plus every closure written
inline in it exceeded the type-checker's budget. The scene-phase handler had
already been moved out; the rest now follow it:

* `.onAppear` → `handleAppear()`, `.onDisappear` → `handleDisappear()`;
* the iPad floating-keyboard `onReceive` → `handleKeyboardFrameChange(_:)`;
* the end-of-turn auto-focus `onChange(of: vm.isProcessing)` →
  `handleProcessingChanged(_:)`, whose delayed half is
  `focusComposerAfterReplyIfAppropriate()`;
* the long `+`-concatenated log messages are built with `+=`;
* `keyboardUndocked` is no longer `private`, because its only writer now lives in
  the `AIChatView+ComposerControls.swift` extension.

Behaviour is unchanged. One latent bug in that block was fixed on the way:
`AlwaysOnController.chatAppeared(key:)` takes an optional, and the in-flight
refactor assigned `vm.draftId` (optional) to a non-optional local.

## Building this fork

The normal first-build steps from `BUILDING.md` apply. On this machine the
toolchain needed one extra piece for the iSH VDSO:

```sh
brew install ninja llvm lld libarchive pkg-config go meson
export PATH="/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/llvm/bin:$PATH"
./deps/build_lame.sh && ./deps/build_ffmpeg.sh && ./deps/build_ish.sh
./deps/prepare_alpine_rootfs.sh
GOTOOLCHAIN=go1.25.5 ./deps/build_rclone_ios.sh   # Go 1.27 breaks rclone's json lib
xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
