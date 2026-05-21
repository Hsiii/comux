import AppKit

let app = NSApplication.shared
let delegate = CodexMuxAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
