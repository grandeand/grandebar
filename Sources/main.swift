import AppKit

ClaudeSessionEnvironment.scrubCurrentProcess()

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.run()
