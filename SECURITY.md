# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use [GitHub's private vulnerability reporting](https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos/security/advisories/new)
when that page is reachable. If it is not, open a normal issue saying only that
you have found a security issue and asking how to reach the maintainer privately
— keep the details out of the public thread.

Include what you did, what happened, and the macOS and app versions.

This is a personal project maintained in spare time. Expect an acknowledgement
within about a week. If a report turns out to be about DeepSeek Harness itself
rather than this app, it belongs
[upstream](https://github.com/deepseek-ai/deepseek-harness).

Supported: the latest release, on macOS 14 and newer.

## What this app is, in security terms

It is a launcher and a window. It starts DeepSeek Harness — an AI coding agent
that reads and writes your files and runs commands — and shows its web UI in a
`WKWebView`. **The agent's own capabilities and sandbox are upstream's**; this
app does not widen them, with one explicit exception described below.

### Process lifetime: only what we started

The promise is that the app never stops a server it did not start. Three things
enforce it:

- The pid of the process the app starts is recorded in the state directory
  (`web.pid`), partitioned per backend and per port.
- Before signalling anything, the launcher checks that the process **listening on
  the port** is inside the recorded pid's process tree. If it belongs to someone
  else, `stop` refuses and says so. A `dsh web` you started in a terminal is
  safe from it.
- When ownership cannot be determined at all (no `lsof`), the launcher falls back
  to a sanity check on the recorded process's command line and refuses if it does
  not look like a `dsh` it would have started. This guards against pid reuse — a
  state directory outlives a reboot, and the number in it may by then belong to
  an unrelated process.

Termination escalates SIGTERM → wait → SIGKILL, and only ever over that tree.
`stop` waits for the tree to be gone before reporting success.

### Network

The instance listens on `127.0.0.1` only, on port 3080 by default. This app adds
no listener of its own and makes no outbound connections except the readiness
probe to that local URL. Nothing is sent anywhere by this app.

Navigation is fenced: anything not same-origin with the local instance is handed
to the default browser instead of loading in the window. Same-origin
`window.open` becomes a new tab.

### The multi-folder backend widens the agent's write surface

Choosing the `mfw` backend installs a patched dsh in which one workspace can hold
several folders, and **sessions in such a workspace can write to every member
folder**. That is a real change in what the agent may touch. Accordingly:

- it is not the default, and is never selected implicitly;
- the app asks once, on first run, and states the trade-off;
- the setting restates it whenever mfw is selected.

Details, including how the patched sandbox resolves the member set, are in the
[dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace) repository.

### Runtimes are not bundled or downloaded

The app neither ships nor fetches Node.js or dsh. It resolves what you already
installed and executes it. Nothing is downloaded at runtime by this app; the
`mfw` backend's first run does install a patched runtime, but that work is done
by `dsh-mfw` from npm, under your own account.

### Code signing

Locally built bundles are signed ad-hoc. Releases are not yet signed with a
Developer ID or notarized, so Gatekeeper will warn about an unidentified
developer on a downloaded build. Verify what you run:

```sh
codesign -dv --verbose=2 "/path/to/DSH Desktop.app"
shasum -a 256 "/path/to/downloaded.dmg"
```

Signing and notarization are planned; until then, building from source is the
way to know what you have.

### Local data

| What | Where |
|---|---|
| pid file, resolved paths, logs | `~/Library/Application Support/DSH Desktop/` (plus `mfw/`, `ports/<port>/`) |
| per-tab web storage | `~/Library/WebKit/io.github.boy-grid.dsh-desktop/WebsiteDataStore/<uuid>/` |
| settings, tab list | app preferences (`io.github.boy-grid.dsh-desktop`) |
| sessions and credentials | `$DSH_HOME`, `~/.dsh` by default — owned by dsh, not by this app |

Closing a tab deletes its web storage; storage orphaned by a crash is swept on
the next launch. The app writes no credentials of its own and reads none.

Logs record resolved paths, the backend, exit codes and the tail of a failed
start. They are not scrubbed, so a path may reveal a directory name — worth a
glance before pasting one into an issue.
