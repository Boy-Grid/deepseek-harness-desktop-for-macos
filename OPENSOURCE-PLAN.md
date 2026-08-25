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
backend, the DSH home, the bind address, the Host-header trust list and the port;
a first-run question about which backend to use; About panel with attribution and
the trademark disclaimer.

**Updates** — a menu item that compares this bundle against the latest GitHub
release and can install it, on request only. A download replaces the running app
only if its checksum matches the release's `SHA256SUMS`, it passes Gatekeeper, and
its signing Team ID equals the one already installed; an ad-hoc local build has no
identity to anchor to and is refused rather than downgraded to a weaker check.

**Network exposure** — the bind address is configurable, and leaving loopback is
gated behind a dialog that states the consequence (the harness UI has no
authentication) with Cancel as the default, restated in red in the preferences
window and on stderr at every start.

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

**Managed runtime** — nothing is bundled, and the disk image stays about a
megabyte. When no Node.js or dsh is found the app offers to fetch them into its
own directory (`launcher runtime install|status|uninstall`); Node's tarball is
verified against a checksum pinned in the launcher before anything is unpacked,
and a runtime the user installed themselves always takes precedence.

**Distribution** — universal binary (Apple Silicon and Intel), Developer ID
signature with hardened runtime and secure timestamp, notarized and stapled, DMG
plus SHA256SUMS from one command; a release workflow that verifies the tag and
opens a draft.

## Not built yet

### Application

| Item | Notes |
|---|---|
| Split `LauncherAgent.swift` further | Still ~1800 lines. The point is not tidiness: pure logic has to come out of AppKit before it can be unit-tested. `main`, `Preferences` and `TabStore` are already separate. |
| Swift unit tests (XCTest) | Partly worked around rather than solved: `tests/t-11-exposure.sh` compiles a probe against `Preferences.swift` and asserts the pure decisions in it, which is enough for the bind-address classifier. Everything entangled with AppKit is still uncovered and needs the split above. |
| Uninstall command | Remove the app, its state directory and its per-tab storage. Currently a manual `rm`. **[good first PR]** |
| Log rotation | `logs/web.log` grows without bound. **[good first PR]** |
| Delta or background updates | The updater downloads a whole image, on request only. Sparkle would bring appcasts and background checks, at the cost of a dependency and of replacing an identity check that is currently ten lines. Not obviously worth it. |
| Member-count badge on workspace rows | Cosmetic, mfw backend only. **[good first PR]** |

### Runtime management

| Item | Notes |
|---|---|
| Update the managed runtime in place | `runtime install` replaces Node when the pinned version changes, but there is no `runtime update` that also refreshes dsh, and no notice when a newer dsh exists. |
| Progress detail while fetching | The install shows a spinner. It knows neither how far the download has got nor which npm phase it is in, and it runs for 5–10 minutes. |
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
