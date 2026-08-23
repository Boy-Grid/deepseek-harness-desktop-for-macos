# DSH Desktop for macOS

Boot / stop the DeepSeek Harness Web UI and show it in a built-in WebView
window (no browser tabs). Not affiliated with DeepSeek — see
`THIRD_PARTY_NOTICES.md` in this bundle.

The title bar hosts a multi-tab bar (right side, right-to-left): add tabs
(+/Cmd-T), close (x/Cmd-W), up to 8 tabs, each tab an independent page with
its own browser storage, all against the single instance. Closing the window
leaves the Dock icon and the instance running (unidirectional Dock -> window
binding). External links open in the default browser. Quit stops the instance
the launcher started.

The shell script at `Contents/MacOS/launcher` also works as a CLI
(`status`, `start`, `stop`, `restart`, `open`, `launch`) and supports multiple
side-by-side instances via `--port` (per-port state dirs) — see `README.md`
in `Contents/Resources/` for details.

State: `~/Library/Application Support/DSH Desktop/`
(logs, recorded PID, cached dsh/node paths).
