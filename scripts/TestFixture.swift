import AppKit

// Disposable status item for manual end-to-end validation. No stored preferences.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "B·TEST"
item.button?.toolTip = "BStoeq geçici test simgesi"
let menu = NSMenu()
menu.addItem(withTitle: "BStoeq test simgesi çalışıyor", action: nil, keyEquivalent: "")
menu.addItem(withTitle: "Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
item.menu = menu
app.run()
