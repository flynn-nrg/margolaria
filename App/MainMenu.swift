// MainMenu.swift
//
// The menu bar, built in code. Xcode's templates describe the main menu in
// a nib or storyboard, an XML file edited with Interface Builder; in code it
// can be read and reviewed like everything else.
//
// Almost every item sends its action to the *first responder*: AppKit tries
// the focused view, then its superviews, the window, the window's document,
// and finally the application, until one of them implements the action.
// That is how "Save" reaches the frontmost NSDocument without this file
// knowing anything about documents. Items whose action nobody implements are
// greyed out automatically.
//
// Introduces (SWIFT): `#selector` with a type name (`NSDocument.save(_:)`),
// `Selector(("name:"))` for actions with no Swift declaration, variadic
// parameters (`Item...`), option sets (`[.command, .shift]`).

import AppKit

/// Builds the main menu.
@MainActor
enum MainMenu {
    /// One menu item: title, action and shortcut.
    ///
    /// SWIFT: A small struct used only to make the menu tables below easy
    /// to read. `nil` for `action` makes a separator.
    struct Item {
        let title: String
        let action: Selector?
        let key: String
        let modifiers: NSEvent.ModifierFlags

        init(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            self.title = title
            self.action = action
            self.key = key
            self.modifiers = modifiers
        }

        static let separator = Item("", nil)
    }

    /// The whole menu bar: the app menu, File, Edit, View, Window, Help.
    static func make() -> NSMenu {
        let appName: String = ProcessInfo.processInfo.processName
        let bar = NSMenu()

        // The app menu (titled with the app's name in bold).
        // SWIFT: `#selector(NSApplication.hide(_:))` names an Objective-C
        // method by its Swift declaration, checked at compile time; it
        // becomes the selector `hide:`.
        let servicesMenu = NSMenu(title: "Services")
        let appMenu: NSMenu = menu(appName,
                                   Item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                                   .separator)
        appMenu.addItem(submenu: servicesMenu)
        add(to: appMenu,
            .separator,
            Item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            Item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            Item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator,
            Item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        NSApp.servicesMenu = servicesMenu
        bar.addItem(submenu: appMenu)

        // File. NSDocumentController and NSDocument implement all of these.
        let fileMenu: NSMenu = menu("File",
                                    Item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
                                    Item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        // No "Open Recent" here: NSDocumentController inserts its own after
        // "Open…" and keeps it filled. It recognises its menu by a private
        // marker, so one built here would only be a second, empty copy.
        // (AppKit also adds "Share", and retitles Save as needed.)
        add(to: fileMenu,
            .separator,
            Item("Close", #selector(NSWindow.performClose(_:)), "w"),
            Item("Save", #selector(NSDocument.save(_:)), "s"),
            Item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            Item("Rename…", #selector(NSDocument.rename(_:))),
            Item("Move To…", #selector(NSDocument.move(_:))),
            // AppKit turns this item into the "Revert To" submenu, with
            // "Browse All Versions…".
            Item("Revert To Saved", #selector(NSDocument.revertToSaved(_:))))
        bar.addItem(submenu: fileMenu)

        // Edit. Undo and redo go to the window's undo manager.
        // SWIFT: `undo:` and `redo:` have no Swift declaration to point
        // `#selector` at (AppKit implements them privately), so the selector
        // is built from its name. The double parentheses tell the compiler
        // that this unchecked form is intended.
        bar.addItem(submenu: menu("Edit",
                                  Item("Undo", Selector(("undo:")), "z"),
                                  Item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                                  .separator,
                                  Item("Cut", #selector(NSText.cut(_:)), "x"),
                                  Item("Copy", #selector(NSText.copy(_:)), "c"),
                                  Item("Paste", #selector(NSText.paste(_:)), "v"),
                                  // On the canvas: deletes the selected nodes
                                  // (GraphEventView.delete(_:)).
                                  Item("Delete", #selector(NSText.delete(_:))),
                                  Item("Select All", #selector(NSText.selectAll(_:)), "a")))
        // Find, for the XML panel. Text views handle these through one action,
        // performTextFinderAction:, told which command by the item's tag.
        if let editMenu = bar.items.last?.submenu {
            editMenu.addItem(.separator())
            let finds: [(String, String, NSTextFinder.Action)] = [
                ("Find…", "f", .showFindInterface),
                ("Find Next", "g", .nextMatch),
                ("Find Previous", "G", .previousMatch),
            ]
            for (title, key, action) in finds {
                let item = NSMenuItem(title: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
                // SWIFT: `rawValue` is the enum case's underlying Int.
                item.tag = action.rawValue
                editMenu.addItem(item)
            }
        }

        // View.
        bar.addItem(submenu: menu("View",
                                  Item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
                                  .separator,
                                  Item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])))

        // Window. Registering it as the windows menu makes AppKit list the
        // open windows at its end.
        let windowMenu: NSMenu = menu("Window",
                                      Item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                                      Item("Zoom", #selector(NSWindow.performZoom(_:))),
                                      .separator,
                                      Item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = windowMenu
        bar.addItem(submenu: windowMenu)

        // Help. Registering it adds the system's search field to it.
        let helpMenu = NSMenu(title: "Help")
        NSApp.helpMenu = helpMenu
        bar.addItem(submenu: helpMenu)

        return bar
    }

    /// A menu with the given items.
    ///
    /// SWIFT: `Item...` is a *variadic parameter*: callers pass any number of
    /// Items separated by commas, and the function sees them as an array.
    /// Like C's `...`, but typed.
    private static func menu(_ title: String, _ items: Item...) -> NSMenu {
        let menu = NSMenu(title: title)
        add(to: menu, items)
        return menu
    }

    private static func add(to menu: NSMenu, _ items: Item...) {
        add(to: menu, items)
    }

    private static func add(to menu: NSMenu, _ items: [Item]) {
        for item in items {
            guard let action = item.action else {
                menu.addItem(NSMenuItem.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: item.key)
            menuItem.keyEquivalentModifierMask = item.modifiers
            menu.addItem(menuItem)
        }
    }
}

private extension NSMenu {
    /// Adds an item that opens `submenu`, titled like it.
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
