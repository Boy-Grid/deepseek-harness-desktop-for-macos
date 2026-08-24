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

By default the instance listens on `127.0.0.1` only, on port 3080. This app adds
no listener of its own and makes no outbound connections except the readiness
probe to that local URL. Nothing is sent anywhere by this app.

Navigation is fenced: anything not same-origin with the local instance is handed
to the default browser instead of loading in the window. Same-origin
`window.open` becomes a new tab.

#### Binding somewhere reachable

The bind address is configurable (Preferences, or `--host` / `DSH_LAUNCHER_HOST`),
and it is the one setting in this app that can change **who** is able to use the
machine. It therefore comes with a plain statement rather than a hint:

> The DeepSeek Harness web UI has no authentication. No password, no token.
> Anyone who can reach the port can drive an agent that reads and writes your
> files, runs commands, and uses credentials you have already signed in with.

`--trusted-host` does not mitigate this. It extends the Host-header check that the
web app uses against DNS rebinding; it is not access control, and adding an
authority grants nobody anything. Upstream fills that list with the machine's own
LAN addresses automatically as soon as `0.0.0.0` is bound.

What this app does about it:

- loopback is the default, and is what a fresh install uses;
- changing to anything else requires confirming a dialog that states the
  consequence above, with *Cancel* as the default button;
- the preferences window keeps showing the exposure in red while it is in effect,
  so it cannot be forgotten after the dialog is dismissed;
- every `start` repeats the warning on stderr and in the log, because the choice
  outlives the moment it was made;
- readiness probes and the tabs always connect to `127.0.0.1` whatever is bound.

If you need remote access, an SSH tunnel or a reverse proxy that authenticates in
front of dsh is the safer shape. Binding to a LAN interface is appropriate only
on a network where every device is trusted.

### The multi-folder backend widens the agent's write surface

Choosing the `mfw` backend installs a patched dsh in which one workspace can hold
several folders, and **sessions in such a workspace can write to every member
folder**. That is a real change in what the agent may touch. Accordingly:

- it is not the default, and is never selected implicitly;
- the app asks once, on first run, and states the trade-off;
- the setting restates it whenever mfw is selected.

Details, including how the patched sandbox resolves the member set, are in the
[dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace) repository.

### Runtimes are not bundled, and are only fetched on request

The app ships neither Node.js nor dsh. By default it resolves what you already
installed and executes that.

It can also fetch them, but only when asked — either by accepting the offer shown
when nothing is found, or by running `launcher runtime install`. That path
downloads and then executes code, so it is worth being precise about:

- Node.js comes from `https://nodejs.org/dist` and is verified against a
  **SHA-256 checksum pinned in the launcher script** before it is unpacked. Taking
  the checksum from the same server as the download would only prove the two
  agree; pinning it means a compromised mirror — or a compromised nodejs.org —
  still cannot get code past the script. On a mismatch the download is discarded
  and nothing is unpacked. Updating the pinned Node version means updating the
  checksums with it, which `tests/t-09-runtime.sh` guards.
- dsh is installed with npm, which verifies registry integrity hashes itself.
  The install is confined to the app's own directory with `--prefix`; the global
  npm prefix and your own `node_modules` are not touched.
- The runtime directory is created with mode `700`, so nothing else running as
  another user can drop a binary into a directory this app executes from.
- `launcher runtime uninstall` removes it. Sessions and credentials live in
  `$DSH_HOME` and are not touched.

The `mfw` backend additionally installs a patched dsh runtime on first use; that
work is done by `dsh-mfw` from npm, under your own account.

### Code signing

Released disk images are signed with a Developer ID, built with the hardened
runtime and a secure timestamp, notarized by Apple, and have the notarization
ticket stapled into the image. A locally built bundle is ad-hoc signed, which is
enough to run but is not something to distribute.

Signing happens on the maintainer's machine. The Developer ID private key is not
in repository secrets and CI cannot produce a signed build, so a compromised
workflow token cannot ship anything under this identity.

Verify a download before running it:

```sh
shasum -a 256 -c SHA256SUMS
spctl --assess --type open --context context:primary-signature -v <dmg>
# expected: accepted / source=Notarized Developer ID
```

One limitation worth stating: the notarization ticket is stapled to the disk
image, not to the application inside it. Gatekeeper therefore checks the app's
notarization online the first time it runs from `/Applications`. With a network
connection this is invisible; entirely offline, a first launch may be refused
until the machine can reach Apple once.

### Local data

| What | Where |
|---|---|
| pid file, resolved paths, logs | `~/Library/Application Support/DSH Desktop/` (plus `mfw/`, `ports/<port>/`) |
| managed runtime, if fetched | `~/Library/Application Support/DSH Desktop/runtime/` (mode `700`, ~470 MB) |
| per-tab web storage | `~/Library/WebKit/io.github.boy-grid.dsh-desktop/WebsiteDataStore/<uuid>/` |
| settings, tab list | app preferences (`io.github.boy-grid.dsh-desktop`) |
| sessions and credentials | `$DSH_HOME`, `~/.dsh` by default — owned by dsh, not by this app |

Closing a tab deletes its web storage; storage orphaned by a crash is swept on
the next launch. The app writes no credentials of its own and reads none.

Logs record resolved paths, the backend, exit codes and the tail of a failed
start. They are not scrubbed, so a path may reveal a directory name — worth a
glance before pasting one into an issue.
