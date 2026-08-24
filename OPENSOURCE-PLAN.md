# Roadmap

What is built and what is not.

Rationale is deliberately not repeated here — [README](README.md) explains how
things work and why there are two backends, [SECURITY.md](SECURITY.md) covers the
security model, [CHANGELOG.md](CHANGELOG.md) records what changed when. This file
answers one question: where are the gaps.

**Looking for something to work on?** Go straight to
[Not built yet](#not-built-yet); items marked **[good first PR]** are
self-contained and do not require deep knowledge of the codebase.

## Built

**The app** — native window with up to 8 title-bar tabs; per-tab persistent
storage so sessions stay independent and each tab returns to its own; tab rename
with manual names outranking page titles; drag to reorder; preferences for the
backend and the DSH home; a first-run question about which backend to use; About
panel with attribution and the trademark disclaimer.

**Instance management** — one shell script owns start/stop/status/restart/open;
two backends (stock dsh, or dsh-mfw for multi-folder workspaces) with a guard
against booting mfw against a DSH home whose dsh version has drifted from mfw's
pinned baseline; state partitioned per backend and per port; node resolved from
the real binary's directory so `pnpm`/`corepack` are reachable.

**Safety** — the app only stops what it started: ownership of the listening
process is verified against the recorded pid's process tree before signalling,
with a command-line fallback that guards against pid reuse.

**Testing and CI** — 8 test files, no framework and no external dependencies;
stand-in `dsh` and `dsh-mfw` fixtures so the suite runs without either installed;
shellcheck plus project-specific lint rules; two GitHub Actions jobs (lint/test,
and build with bundle verification), both on macOS.

**Documentation** — English README with a Chinese translation, CONTRIBUTING,
SECURITY, CHANGELOG, and a short copy inside the app bundle.

**Distribution** — universal binary (Apple Silicon and Intel), Developer ID
signature with hardened runtime and secure timestamp, notarized and stapled, DMG
plus SHA256SUMS from one command; a release workflow that verifies the tag and
opens a draft.

## Not built yet

### Application

| Item | Notes |
|---|---|
| Split `LauncherAgent.swift` further | Still ~1800 lines. The point is not tidiness: pure logic has to come out of AppKit before it can be unit-tested. `main`, `Preferences` and `TabStore` are already separate. |
| Swift unit tests (XCTest) | Blocked on the split above. The shell side is well covered; the Swift side is not covered at all. |
| Uninstall command | Remove the app, its state directory and its per-tab storage. Currently a manual `rm`. **[good first PR]** |
| Log rotation | `logs/web.log` grows without bound. **[good first PR]** |
| Check for updates | A menu item that compares against the latest release. Sparkle is the obvious route but adds a dependency; a link-only version is a smaller start. |
| Member-count badge on workspace rows | Cosmetic, mfw backend only. **[good first PR]** |

### Runtime management

| Item | Notes |
|---|---|
| Managed runtime | Install Node.js and dsh on demand instead of requiring them beforehand, with a first-run wizard, offline degradation and a `launcher dsh` subcommand. The largest remaining piece. Note the disk cost: an app-managed node, plus dsh, plus mfw's own ~300 MB tree. |
| Native multi-select folder panel | dsh-mfw disables the native directory picker and uses an in-page browse UI. A native `NSOpenPanel` is the one thing this app could offer that a browser cannot — but it needs a host-side plugin and local IPC to reach the `onPicked(paths[])` contract. |

### Release and verification

| Item | Notes |
|---|---|
| Publish the first release | The v0.1.0 draft is built, notarized and uploaded; publishing waits on making the repository public. |
| Staple the ticket to the app as well | Today only the disk image carries it, so a first launch from `/Applications` verifies online. Fixing this means a second notarization round per release. |
| Verify on Intel hardware | Both slices build and the universal binary is correct, but nothing has actually run on an Intel Mac. |
| Enable private vulnerability reporting | Needs a public repository; SECURITY.md already points at it. |
| `CODE_OF_CONDUCT.md`, issue templates, Discussions | Community scaffolding. **[good first PR]** |

## Deliberately not doing

| Decision | Why |
|---|---|
| Not shipping on the App Store | Sandboxing would forbid what this app exists to do: launch an arbitrary local process and let it read and write the user's files. |
| Not bundling Node.js or dsh | Users who run a coding agent already manage their own toolchain, and bundling one would mean shipping — and securing — someone else's runtime. |
| Homebrew Cask is not a primary channel | GitHub Releases is the source of truth. A cask maintained by whoever wants one is welcome. |
| Not signing in CI | The Developer ID private key would have to live in repository secrets. That trades a much wider blast radius for saving one local command a few times a year. |
| No "launch working directory" setting | It looked like it would decide a session's default working directory. It does not: dsh resolves that from the workspace, and only headless mode seeds a session from the launch location. A knob that changes nothing, with a wrong explanation attached, is worse than no knob. The hygiene part — not handing `/` to the child process — was kept. |
