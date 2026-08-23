//
// Entry point.
//
// Top-level statements are only allowed in a file named main.swift once the
// target has more than one source file, which is why the bootstrap lives here
// rather than at the end of LauncherAgent.swift.
//

import AppKit

let app = NSApplication.shared
let agent = Agent()
app.delegate = agent
app.run()
