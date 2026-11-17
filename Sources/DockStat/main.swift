import AppKit

// DockStat entry point.
// Runs as an "accessory" app: no Dock icon of its own. The UI is a glass panel
// that attaches to the right end of the Dock.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
