// The text-editing key equivalents, for an app that shows no menu bar.
//
// Kapture is an accessory app, so it never displays a main menu, and AppKit routes ⌘X, ⌘C, ⌘V
// and ⌘A to text fields through the main menu's key equivalents. With no main menu each of them
// beeped in every field: a share token or an API key could be pasted only from the context
// menu. This menu is installed and never shown.
//
// Undo and redo are left out. The editor canvas handles ⌘Z itself in keyDown, and a menu item
// would take the key first. The other four reach a view's keyDown as before wherever nothing in
// the responder chain implements their action, because AppKit disables those items there.
import AppKit

enum EditMenu {
    static func make() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }
}
