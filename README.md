# DSH Desktop for macOS

[![CI](https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

[中文](README.zh.md)

A native macOS window for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
web UI. Double-click to boot it, work several sessions side by side in one
window, and let the app own the lifetime of the instance it started.

> **Unofficial.** An independent project, not affiliated with, endorsed by, or
> sponsored by DeepSeek. "DeepSeek" and "DeepSeek Harness" are DeepSeek's
> trademarks. The app icon is derived from the DeepSeek Harness web UI favicon;
> attribution is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Why

Running `dsh web` in a terminal and keeping it in a browser tab works, but the
tab is one of thirty, the server outlives the window in ways nobody tracks, and
several sessions at once means several tabs that all fight over the same browser
storage. This app makes the harness a normal desktop application:

- **One window, several sessions.** Up to 8 tabs in the title bar, each an
  independent web view with its own storage, all served by one instance.
- **The app owns the instance.** It starts `dsh` when needed and stops it on
  quit — and only ever stops what it started (see [SECURITY.md](SECURITY.md)).
- **Closing the window is not quitting.** The instance keeps running; reopening
  is instant. Quit from the Dock or ⌘Q takes both down.
- **Links leave.** Anything that is not the local harness opens in your default
  browser instead of navigating the window away.
- **Optional multi-folder workspaces**, via a second backend you choose
  explicitly.

## Requirements

- macOS 14 or later (the per-tab persistent stores use an API introduced there)
- Node.js, and DeepSeek Harness installed yourself — this app **neither bundles
  nor downloads a runtime**:
  ```sh
  npm install -g @deepseek-ai/dsh
  ```
- For the multi-folder backend only: Node.js 22+ and pnpm 11+ (or corepack)

## Install

Download the disk image from
[Releases](https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos/releases),
open it and drag the app to Applications. The image is signed with a Developer ID
and notarized, so it opens without a Gatekeeper warning.

Worth verifying what you downloaded:

```sh
shasum -a 256 -c SHA256SUMS
spctl --assess --type open --context context:primary-signature -v <dmg>
# expected: accepted / source=Notarized Developer ID
```

## Build from source

```sh
git clone https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos.git
cd deepseek-harness-desktop-for-macos
./build.sh --register
```

That copies the resources, compiles the agent, signs the bundle and refreshes
LaunchServices. Output is `~/Applications/DSH Desktop.app`; `--output <path>`
builds elsewhere without registering.

The deployment target comes from `LSMinimumSystemVersion` in `Info.plist`, and
the build verifies the binary's `minos` matches it. Without an explicit
`-target`, `swiftc` stamps the *build machine's* OS version into the binary, and
the app then refuses to launch on anything older than the machine it was built
on — however generous the plist looks.

A default build is ad-hoc signed, which is all a local build needs.

### Releasing

`scripts/make-dmg.sh` goes from source to a disk image that opens without a
Gatekeeper warning: a universal binary (Apple Silicon and Intel) signed with a
Developer ID, hardened runtime and a secure timestamp, notarized by Apple, and
with the ticket stapled into the image.

```sh
./scripts/make-dmg.sh                  # build --release, package, notarize, staple
./scripts/make-dmg.sh --skip-notarize  # signed image only, for a dry run
```

Notarization credentials are read from the keychain, so they never appear in a
command line or a file in the repository. Create them once:

```sh
xcrun notarytool store-credentials "dsh-desktop-notary" \
  --key <AuthKey_XXXXXXXXXX.p8> --key-id <Key ID> --issuer <Issuer ID>
```

Only an App Store Connect **Team Key** works for notarization; an Individual Key
is rejected with a 401 that does not explain why.

Signing happens on the maintainer's machine, not in CI. The Developer ID private
key would otherwise have to live in repository secrets, which trades a much wider
blast radius for saving one command a few times a year. The release workflow
verifies the tag and opens a draft; the image is uploaded to it locally.

## Two backends

| Backend | What it boots |
|---|---|
| `stock` (default) | the `dsh` you installed |
| `mfw` | [dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace), which prepares a patched runtime where **one workspace can hold several scattered folders** |

Pick one in **DSH Desktop → Preferences** (⌘,), or on the command line:

```sh
"$L" start --backend mfw     # first run prepares a ~300 MB runtime (10–30 s)
```

> ⚠️ **The multi-folder backend widens what an agent may write**: sessions in a
> workspace can write to *every* member folder, not just their own working
> directory. That is a change in security semantics, so it is never the default
> and never selected implicitly — the app asks once, on first run.

Each backend keeps its own state directory, so the two can run side by side on
different ports. They share `$DSH_HOME` by default, so sessions and credentials
are visible to both.

**Version skew guard.** dsh-mfw pins an exact dsh baseline. When that baseline
and your installed dsh have drifted apart, the launcher refuses to boot mfw
against the home that stock dsh also uses: a newer dsh may already have written
records in a shape the pinned baseline does not know, and the reverse direction
is destructive too — stock dsh drops the extra member list the first time it
rewrites a workspace record. The ways out are a separate home
(`--dsh-home <dir>`, or the setting in Preferences) or waiting for dsh-mfw to
rebase.

## Preferences

⌘, opens two settings, both of which restart the served instance:

| Setting | Notes |
|---|---|
| **Which dsh to boot** | stock or multi-folder, with links to both projects |
| **DSH home** | where sessions and credentials live, `~/.dsh` by default; also the way out of a baseline mismatch |

Switching stops the running instance and starts the new one, then reloads every
tab. If the instance cannot be stopped, the switch is reported as failed rather
than silently doing nothing.

## Tabs

New tab with `+`, ⌘T or the context menu; the newest sits next to `+` and older
ones move right. Close with the tab's ×, ⌘W or the context menu. Drag tabs to
reorder. ⌘R reloads the active tab, ⇧⌘W closes the window.

Tab names follow the page title, which the harness updates as sessions are
created and switched. Double-click a tab (or context menu → rename) to name it
yourself; a typed name outranks the automatic title and is remembered.

### Why each tab has its own persistent store

The harness web UI keeps the active session in `localStorage` under
`dsh.sessions.current` and restores it on load, and the UI has no URL routing.
With one shared store, every tab would write that one key, and new tabs — plus
every tab after a relaunch — would converge on the same session. Which is
exactly what several tabs exist to avoid.

So each tab gets its own `WKWebsiteDataStore`, identified by the tab's UUID under
`~/Library/WebKit/io.github.boy-grid.dsh-desktop/WebsiteDataStore/<uuid>/`.
Sessions stay independent, page-level settings survive a restart, and each tab
comes back to *its own* last session. Closing a tab deletes its store; storage
orphaned by a crash is swept on the next launch.

## Command line

Everything about instance lifetime lives in one shell script, which the GUI also
calls. It is useful on its own — for scripting, for a second instance, or for
diagnosing a failed launch.

```sh
L="$HOME/Applications/DSH Desktop.app/Contents/MacOS/launcher"

"$L" status     # up or down, which backend, which home, who owns the port
"$L" start      # start if needed, wait until it answers
"$L" stop       # stop the instance this launcher started
"$L" restart
"$L" open       # open the URL in the default browser
"$L" launch     # start + open
"$L" help
```

| Option | Environment | Default |
|---|---|---|
| `--port <n>` | `DSH_LAUNCHER_PORT` | `3080` |
| `--backend <stock\|mfw>` | `DSH_LAUNCHER_BACKEND` | `stock` |
| `--dsh <path>` | `DSH_LAUNCHER_DSH` | probed, then cached in the state dir |
| `--mfw <path>` | `DSH_LAUNCHER_MFW` | probed (mfw backend only) |
| `--node <path>` | `DSH_LAUNCHER_NODE` | probed, then cached |
| `--dsh-home <dir>` | `DSH_LAUNCHER_DSH_HOME` | `$DSH_HOME`, else `~/.dsh` |
| `--allow-version-skew` | `DSH_LAUNCHER_ALLOW_VERSION_SKEW=1` | off |
| `--state <dir>` | `DSH_LAUNCHER_STATE` | `~/Library/Application Support/DSH Desktop` |
| `--no-browser` | `DSH_LAUNCHER_NO_BROWSER=1` | off (affects `open`/`launch` only) |

State is partitioned per backend and per port — a non-stock backend adds a
`<backend>` level, a non-default port a `ports/<port>` one — so two
differently-booted instances never share a pid file or a log:

```sh
"$L" --port 3099 start                    # a second instance
"$L" --port 3099 stop
```

The GUI is single-instance (LaunchServices activates the running app instead of
starting a second one); the command line is not.

**Why node is resolved explicitly.** A double-clicked app gets only the system
PATH, so a node installed by nvm, volta or into `~/.local` is invisible — and
`dsh`'s shim is `#!/usr/bin/env node`, which would simply fail. The launcher
resolves node itself and runs the entry as `node <entry>`. The child's PATH is
built from node's **realpath** directory, because `pnpm` and `corepack` live next
to the real binary while a symlink farm like `~/.local/bin` usually carries only
`node`, `npm` and `npx` — get this wrong and the mfw backend cannot find a
package manager even when its runtime is already prepared.

## Safety model

The short version: the app records the pid it started, and verifies that the
process listening on the port really belongs to that pid's process tree before
signalling anything. A port held by someone else — a `dsh web` you started in a
terminal, or an unrelated process that inherited a recycled pid — is refused,
not stopped. Details and the reporting process are in [SECURITY.md](SECURITY.md).

## Tests

No test framework and no external dependencies; stand-in `dsh` and `dsh-mfw`
fixtures mean the suite runs on a machine with neither installed.

```sh
bash tests/run.sh          # everything
bash tests/run.sh t-04     # files matching "t-04"
```

The suite covers the "only stop what we started" promise, ownership
determination, backend and path resolution, the mfw guards, and the whole boot
path. Cases that cannot run here are listed as SKIP rather than
passing quietly. `shellcheck` runs too when installed.

## Troubleshooting

A failed start shows the reason in a dialog and writes it to the log. The log
directory is created before anything can fail, so there is always somewhere to
look:

```sh
cat "$HOME/Library/Application Support/DSH Desktop/logs/web.log"   # the instance
cat "$HOME/Library/Application Support/DSH Desktop/logs/agent.log" # the app
```

For a non-default port or the mfw backend, look under `mfw/` and
`ports/<port>/`; `"$L" status` prints the exact state directory it resolved.

## Repository layout

```
main.swift              entry point (top-level code has to live here)
LauncherAgent.swift     AppKit GUI: window, title-bar tab strip, web views, menus
Preferences.swift       settings model, first-run question, preferences window
TabStore.swift          per-tab persistent stores: create, remove, sweep orphans
launcher                instance lifetime: start/stop/status, backends, state dirs
Info.plist              bundle metadata; LSMinimumSystemVersion drives the build
icon.icns, make-icon.py the app icon and the script that composes it
build.sh                assemble, compile, sign, register
tests/                  run.sh, lib/assert.sh, t-*.sh, fixtures/
.github/workflows/      CI: lint, tests, build and verify the bundle
```

## Regenerating the icon

The icon is derived from the harness web UI's own favicon (attribution in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)): fetch it from a running
instance, rasterize, then compose onto a macOS-style rounded gradient tile with
`make-icon.py` (Python standard library only).

```sh
curl -s http://127.0.0.1:3080/favicon.svg -o /tmp/favicon.svg
sed 's/width="50.000000" height="50.000000"/width="1024" height="1024"/' \
    /tmp/favicon.svg > /tmp/favicon_1024.svg
sips -s format png /tmp/favicon_1024.svg --out /tmp/logo_1024.png
python3 make-icon.py /tmp/logo_1024.png /tmp/icon_final_1024.png
# then: sips to each size → iconutil -c icns icon.iconset -o icon.icns
```

## License and attribution

MIT, see [LICENSE](LICENSE). The hosted DeepSeek Harness is DeepSeek's own
MIT-licensed project. Third-party notices and the icon's provenance are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the same statements are in the
app under **DSH Desktop → About DSH Desktop**.

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
