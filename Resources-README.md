# DSH Desktop for macOS

A native window for the DeepSeek Harness web UI. This file is the copy inside the
app bundle; the full documentation lives at
<https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos>.

**Unofficial.** An independent project, not affiliated with, endorsed by, or
sponsored by DeepSeek. See `THIRD_PARTY_NOTICES.md` in this bundle for the icon's
provenance and third-party notices.

## What it does

Boots DeepSeek Harness on `127.0.0.1:3080` if nothing is serving it, and shows
the web UI in a built-in web view. Up to 8 tabs live in the title bar, each an
independent page with its own persistent storage, all served by one instance — so
several sessions can be worked on side by side, and each tab returns to its own
session after a relaunch.

Closing the window leaves the Dock icon and the instance running. Quit (⌘Q, or
right-click the Dock icon) closes the window and stops the instance the app
started — never one it did not start. Links that are not the local harness open in
the default browser.

**⌘,** opens Preferences: which dsh to boot (the stock one, or dsh-mfw for
multi-folder workspaces) and which DSH home to use. The multi-folder backend
widens what an agent may write, so it is never selected implicitly.

Requires macOS 14+, and a Node.js and DeepSeek Harness installation of your own —
this app neither bundles nor downloads a runtime.

## Command line

`Contents/MacOS/launcher` is where all instance lifetime logic lives, and it works
on its own:

    launcher status | start | stop | restart | open | launch | help

`--port <n>` runs a second instance side by side, `--backend <stock|mfw>` picks
the runtime, `launcher help` lists every option.

## Local data

State (recorded pid, resolved dsh/node paths, logs) is under
`~/Library/Application Support/DSH Desktop/`, partitioned per backend and per
port. Per-tab web storage is under
`~/Library/WebKit/io.github.boy-grid.dsh-desktop/`. Sessions and credentials
belong to dsh, in `$DSH_HOME` (`~/.dsh` by default).
