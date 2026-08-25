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
- Node.js and DeepSeek Harness. The app **bundles neither** — the disk image is
  about a megabyte. Install them yourself:
  ```sh
  npm install -g @deepseek-ai/dsh
  ```
  Or let the app fetch a private copy when it finds none (see
  [Managed runtime](#managed-runtime) — it is opt-in, and a runtime you installed
  yourself always wins).
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

## Managed runtime

Nothing is bundled, and nothing is downloaded behind your back. When no Node.js
or dsh can be found, the app offers to fetch a copy into its own directory; you
can also drive it directly:

```sh
"$L" runtime status      # what was fetched, and which node/dsh would be used
"$L" runtime install     # fetch Node.js and dsh
"$L" runtime uninstall   # remove them; DSH data is untouched
```

**A runtime you installed yourself always wins.** The managed copy is a fallback,
never a takeover — with one exception worth knowing: the mfw backend requires
Node 22, so if your own node is older, the managed one is used for that backend
rather than failing. The minimum version is part of the search, not a check after
it, precisely so a too-old node cannot shadow one that would work.

What it costs, measured rather than estimated:

| | |
|---|---|
| Download | ~50 MB (the official Node tarball) |
| On disk after install | **~470 MB** — Node unpacks to ~100 MB, and dsh pulls in over a hundred packages |
| Time | 5–10 minutes, mostly npm |

Node's tarball is verified against a **checksum pinned in the launcher script**
before anything is unpacked. Taking the checksum from the same server as the
download would only prove the two agree; pinning it means a compromised mirror
still cannot get code past the script. A mismatch discards the download and
refuses to unpack it.

The runtime directory is created `700` and lives outside any per-port state, so
one copy serves every backend and port.

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

⌘, opens the settings below. All of them except the port restart the served
instance; the port needs the app itself restarted, because the state directory,
the window title and every tab's address are derived from it.

| Setting | Notes |
|---|---|
| **Which dsh to boot** | stock or multi-folder, with links to both projects |
| **DSH home** | where sessions and credentials live, `~/.dsh` by default; also the way out of a baseline mismatch |
| **Bind address** | `127.0.0.1` by default. See [Letting other devices in](#letting-other-devices-in) before changing it |
| **Trusted hosts** | extra authorities for the web app's Host-header fence, comma-separated |
| **Port** | `3080` by default; `DSH_LAUNCHER_PORT` takes precedence over the setting |
| **Download source** | which npm / Node.js mirror a fetched runtime comes from — see [Mirrors](#mirrors) |

Switching stops the running instance and starts the new one, then reloads every
tab. If the instance cannot be stopped, the switch is reported as failed rather
than silently doing nothing.

### Letting other devices in

Binding anywhere other than loopback is a deliberate choice with a consequence
that is easy to underestimate: **the DeepSeek Harness web UI has no
authentication.** No password, no token, nothing. Whoever can reach the port can
drive an agent that reads and writes your files, runs commands, and uses
credentials you have already signed in with.

`--trusted-host` does not change that. It extends the Host-header check the web
app uses to defend against DNS rebinding; it is not access control, and adding an
authority grants nobody anything.

So the app asks before opening the port, states that consequence, and defaults
the confirmation to *Cancel*. Readiness checks and the tabs themselves always
talk to `127.0.0.1` regardless of what was bound — `0.0.0.0` names an interface to
listen on, not an address to connect to. If you do open it up, do so only on a
network where you trust every device, and prefer an SSH tunnel or a
reverse proxy that authenticates in front of dsh.

## Mirrors

For networks where `registry.npmjs.org` and `nodejs.org` are slow or blocked. This
applies to what the app fetches itself — the pinned Node.js build and the managed
dsh — and is chosen in Preferences or with `--mirror`:

```sh
"$L" mirrors                              # list the built-in ones
"$L" --mirror npmmirror runtime install
"$L" --registry https://npm.internal.example/ runtime install
```

| Name | npm registry | Node.js |
|---|---|---|
| `npmjs` | `registry.npmjs.org` | `nodejs.org/dist` |
| `npmmirror` | `registry.npmmirror.com` | `npmmirror.com/mirrors/node` |
| `tencent` | `mirrors.cloud.tencent.com/npm` | `mirrors.cloud.tencent.com/nodejs-release` |
| `huawei` | `repo.huaweicloud.com/repository/npm` | `repo.huaweicloud.com/nodejs` |

`--registry` and `--node-mirror` set either half on its own, and override a preset
when combined with one.

**Nothing is passed by default.** npm then reads your own `~/.npmrc`, which is
where a proxy and any credentials live — forcing `registry.npmjs.org` would break
exactly the setups this option exists for. Pick `npmjs` explicitly if you want to
override an `.npmrc` rather than inherit it.

The two halves are not equally consequential, and it is worth being clear about
why:

- **A Node.js mirror is not a trust decision.** The expected SHA-256 is pinned in
  the launcher, so a mirror serving anything else is refused and nothing is
  unpacked. The mirrors above were checked to serve tarballs byte-identical to
  nodejs.org's.
- **An npm registry is one.** npm verifies integrity hashes that the registry
  itself supplies, so choosing a registry is choosing who to trust for package
  contents. Hence a short list of well-known operators rather than a long one.

The multi-folder backend is not covered by this: `dsh-mfw` runs its own package
manager to prepare its runtime, and follows your npm/pnpm configuration. Set the
registry in `~/.npmrc` (or `pnpm config set registry …`) for that path.

## Updates

**DSH Desktop → Check for Updates…** compares this bundle against the latest
GitHub release and offers to install it. Nothing happens on a schedule: one menu
action makes one API call, and downloading needs a second confirmation.

Before a download is allowed to replace the running app, three things have to
hold, in this order:

1. the image's SHA-256 matches its line in the release's `SHA256SUMS`;
2. the app inside passes `codesign --verify --strict` and Gatekeeper's `spctl
   --assess`, the same check a first launch would face;
3. the Team ID of the new signature equals the Team ID of the app being replaced.

The third is the one that matters. A checksum published alongside the image proves
only that the two agree, and a valid Developer ID proves only that *somebody*
signed it; anchoring to the identity already installed is what makes a compromised
release unable to substitute a different publisher's app. See
[SECURITY.md](SECURITY.md#updates) for the rest.

A bundle you built yourself is ad-hoc signed and so has no identity to compare
against — updating in place is refused for it rather than falling back to a weaker
check. Run `./build.sh` again, or install a release.

The replacement is a small script written outside the bundle, because a bundle
cannot overwrite itself while running. It waits for the app to exit, swaps the
directories by rename, reopens the app and removes itself; if anything fails, the
installed copy is left untouched.

The check is anonymous, so it draws on GitHub's budget of 60 API calls an hour per
IP address. Behind a shared address that can already be spent, which is reported
as a rate limit rather than as a broken network.

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
"$L" update check    # compare this bundle against the latest release
"$L" update install  # download it, verify it, and replace this bundle
"$L" mirrors         # list the built-in npm / Node.js mirrors
"$L" help
```

| Option | Environment | Default |
|---|---|---|
| `--port <n>` | `DSH_LAUNCHER_PORT` | `3080` |
| `--host <host>` | `DSH_LAUNCHER_HOST` | `127.0.0.1` (see [above](#letting-other-devices-in)) |
| `--mirror <name>` | `DSH_LAUNCHER_MIRROR` | none; see [Mirrors](#mirrors) |
| `--registry <url>` | `DSH_LAUNCHER_NPM_REGISTRY` | inherit `~/.npmrc` |
| `--node-mirror <url>` | `DSH_LAUNCHER_NODE_DIST` | `https://nodejs.org/dist` |
| `--trusted-host <authority>` | `DSH_LAUNCHER_TRUSTED_HOSTS` (newline-separated) | none; repeatable |
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
determination, backend and path resolution, the mfw guards, the whole boot path,
and the bind-address rules on both sides — the script's classifier and the app's
have to agree about what counts as loopback, so one test compiles a probe against
`Preferences.swift` and checks the shipping code rather than a copy of it. Cases
that cannot run here are listed as SKIP rather than passing quietly. `shellcheck`
runs too when installed.

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
build.sh                assemble, compile, sign, register; --release for shipping
scripts/make-dmg.sh     package, notarize, staple, checksum
tests/                  run.sh, lib/assert.sh, t-*.sh, fixtures/
.github/workflows/      CI, and the release workflow
OPENSOURCE-PLAN.md      roadmap: what is built, what is not, what is declined
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
