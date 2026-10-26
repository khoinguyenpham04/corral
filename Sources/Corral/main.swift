import AppKit

// A menu bar app: no Dock icon, no main window. `--demo` shows sample data; `--open` opens the
// panel at launch.
let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
