# Changelog

This project follows [semantic versioning](https://semver.org/). Dates are
release dates.

## Unreleased

### Added

- **Network settings.** The bind address, the web app's Host-header trust list and
  the port are now settings (`--host`, `--trusted-host`, `--port` on the launcher).
  Loopback stays the default. Leaving it needs a confirmation that states what it
  costs — the DeepSeek Harness UI has no authentication, so anyone who can reach
  the port can drive an agent that reads and writes files and runs commands — with
  *Cancel* as the default button. The exposure is restated in the preferences
  window while it is in effect, and on stderr and in the log at every start.
  Readiness is still probed over loopback whatever is bound.
- **Check for Updates.** A menu item that compares this bundle against the latest
  GitHub release and can install it. On request only: no background polling, and a
  second confirmation before anything is downloaded. A download replaces the
  running app only if its SHA-256 matches the release's `SHA256SUMS`, the app
  inside passes Gatekeeper, and its signing Team ID equals the one already
  installed. A locally built bundle is ad-hoc signed and has no identity to
  compare against, so updating in place is refused for it outright.
  Also available as `launcher update check` and `launcher update install`.

- **npm and Node.js mirrors.** Four built-in presets (`npmjs`, `npmmirror`,
  `tencent`, `huawei`) plus custom URLs, for networks where the defaults are slow
  or blocked. `launcher mirrors` lists them; `--mirror`, `--registry` and
  `--node-mirror` select them. Applies to what the app fetches itself — the pinned
  Node.js build and the managed dsh; the mfw backend runs its own package manager
  and follows your npm configuration.

  Nothing is passed by default, so npm keeps reading your `~/.npmrc` and the proxy
  and credentials in it. Choosing a Node.js mirror is not a trust decision — the
  expected SHA-256 stays pinned in the launcher, so a mirror serving anything else
  is refused; choosing an npm registry is one, and the documentation says so.

### Fixed

- The anchor check in `tests/t-08-docs.sh` skipped same-file links entirely, and
  its slug rule reduced any Chinese heading to the empty string, so anchors in
  `README.zh.md` were never verified.

## 0.1.0 — 2026-08-24

First public release.

### The app

- A native window for the DeepSeek Harness web UI, with up to 8 tabs in the title
  bar. Each tab is an independent web view with **its own persistent storage**, so
  several sessions can be worked on side by side and each tab comes back to its
  own session after a relaunch.
- Tab names follow the page title; double-click (or the context menu) to name one
  yourself, and a typed name outranks the automatic title. Tabs can be dragged to
  reorder.
- Closing the window leaves the instance running; quitting stops it. Links that
  are not the local harness open in the default browser, and a same-origin
  `window.open` becomes a new tab.
- Preferences (⌘,): which dsh to boot, and which DSH home to use.
- Requires macOS 14 or later. Ships as a universal binary.

### Two backends

- **stock** (default) boots the `dsh` you installed.
- **mfw** boots [dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace),
  where one workspace can hold several scattered folders. This widens what an
  agent may write — sessions can write to every member folder — so it is never
  the default and never selected implicitly; the app asks once, on first run.
- A guard refuses to boot mfw against the DSH home stock dsh also uses when the
  two versions have drifted apart, because that combination can lose data in
  either direction.

### Instance management

- All lifetime logic lives in one shell script, usable on its own:
  `status`, `start`, `stop`, `restart`, `open`, `launch`.
- The app only ever stops a server it started: before signalling anything it
  checks that the process listening on the port belongs to the recorded pid's
  process tree, and falls back to a command-line sanity check when ownership
  cannot be established, which guards against pid reuse.
- State is partitioned per backend and per port, so two differently-booted
  instances never share a pid file or a log.
- Node is resolved explicitly, from the real binary's directory rather than a
  symlink's, because `pnpm` and `corepack` live next to the former and the mfw
  backend needs one of them.

### Distribution

- Signed with a Developer ID, hardened runtime, notarized by Apple and stapled,
  so the disk image opens without a Gatekeeper warning.
- Not bundled: Node.js and DeepSeek Harness are yours to install. Nothing is
  downloaded at runtime by this app.

### Known limitations

- The notarization ticket is stapled to the disk image, not to the app inside it,
  so a first launch from `/Applications` checks notarization online. Invisible
  with a network connection; a fully offline first launch may be refused once.
- The title-bar tab strip aligns itself with the page's centre column by reading
  live DOM geometry. An upstream style change breaks the alignment silently — it
  degrades to "not aligned" rather than failing.
- Upstream DSH is a dev preview, and the mfw backend pins an exact baseline of
  it. Expect to update both together.
