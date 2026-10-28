# Fork additions (iOS)

This fork adds six things on top of upstream OpenMinis. All of them are iOS-first;
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
