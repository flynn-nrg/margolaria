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
// The Graph menu (M4a) and Edit > Duplicate act on the canvas; their
// actions are GraphEventView's. View > Command Palette… (⌘K, M4f) lists
// every item of this menu bar that is enabled when it opens, so a new item
// here is in the palette too.
//
// ⌘G is shared (M4d): Graph > Group in Backdrop while the canvas has
// keyboard focus, Edit > Find Next everywhere else (the XML tab). AppKit
// lets only one item of the menu bar have a key equivalent (it clears it
// from any other item it is given to), so the key moves between the two
// items as the focus does, and each menu shows ⌘G where it applies.
//
// Introduces (SWIFT): `#selector` with a type name (`NSDocument.save(_:)`),
// `Selector(("name:"))` for actions with no Swift declaration, variadic
// parameters (`Item...`), option sets (`[.command, .shift]`);
// `NotificationCenter.addObserver(forName:object:queue:using:)` and
// `MainActor.assumeIsolated` (M4d).

import AppKit
import GraphKit

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

    /// The whole menu bar: the app menu, File, Edit, View, Graph, Window, Help.
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

        // File. NSDocumentController and NSDocument implement all of these,
        // except Export as USD… and USDZ…, MaterialXDocument's own.
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
            Item("Revert To Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator,
            // The document's materials as a USD file (M5b), and as a
            // USDZ for Quick Look and Reality Composer Pro (M5c).
            Item("Export as USD…", #selector(MaterialXDocument.exportAsUSD(_:))),
            Item("Export as USDZ…", #selector(MaterialXDocument.exportAsUSDZ(_:))))
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
                                  // On the canvas: copies the selected nodes
                                  // next to themselves (M4a).
                                  Item("Duplicate", #selector(GraphEventView.duplicateNodes(_:)), "d"),
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
                if action == .nextMatch {
                    findNextItem = item
                }
            }
        }

        // View.
        // The command palette (M4f) is the document's: it lists this menu
        // bar's commands, read when ⌘K is pressed (MaterialXDocument).
        bar.addItem(submenu: menu("View",
                                  Item("Command Palette…", #selector(MaterialXDocument.showCommandPalette(_:)), "k"),
                                  .separator,
                                  Item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
                                  .separator,
                                  Item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])))

        // Graph: canvas commands (M4a), handled by the canvas view
        // (GraphEventView) when it has keyboard focus, and greyed out
        // otherwise. "G" in capitals adds Shift. Group in Backdrop gets ⌘G
        // while the canvas has focus (see the file comment).
        //
        // The first four are the canvas's single keys (Tab, A, F, U; M4f).
        // They have no key equivalents here: AppKit looks for a menu item's
        // key equivalent before the focused view gets the key, so a plain
        // "a" would be taken from every text field. The command palette
        // shows the keys (GraphEventView.keys).
        let graphMenu: NSMenu = menu("Graph",
                                     Item("Add Node…", #selector(GraphEventView.addNode(_:))),
                                     Item("Frame All", #selector(GraphEventView.frameAll(_:))),
                                     Item("Frame Selection", #selector(GraphEventView.frameSelection(_:))),
                                     Item("Go Up One Level", #selector(GraphEventView.goUpOneLevel(_:))),
                                     .separator,
                                     Item("Group in Backdrop", #selector(GraphEventView.groupInBackdrop(_:))),
                                     .separator,
                                     Item("Collapse into Nodegraph", #selector(GraphEventView.collapseIntoNodeGraph(_:)),
                                          "g", [.command, .option]),
                                     Item("Ungroup Nodegraph", #selector(GraphEventView.ungroupNodeGraph(_:)),
                                          "G", [.command, .option]))
        backdropItem = graphMenu.items.first { $0.action == #selector(GraphEventView.groupInBackdrop(_:)) }
        bar.addItem(submenu: graphMenu)
        shareCommandG()

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

    // MARK: ⌘G (M4d)

    /// Edit > Find Next and Graph > Group in Backdrop, which share ⌘G.
    ///
    /// SWIFT: `static var` on a `@MainActor` type: shared state, only used
    /// on the main thread, which the compiler checks.
    private static var findNextItem: NSMenuItem? = nil
    private static var backdropItem: NSMenuItem? = nil
    /// The registration for window updates, kept so it lasts.
    private static var focusObserver: (any NSObjectProtocol)? = nil

    /// Gives ⌘G to the item that applies now, and again whenever a window
    /// updates: after every event, so after every change of focus too.
    ///
    /// SWIFT: The observer's closure may be called from any thread as far
    /// as the compiler knows; `queue: .main` makes it the main thread, and
    /// `MainActor.assumeIsolated` tells the compiler so (it checks, at run
    /// time, and stops the app if it isn't).
    private static func shareCommandG() {
        giveCommandG()
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil,
                                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                giveCommandG()
            }
        }
    }

    /// ⌘G to Group in Backdrop if the key window's focus is a canvas, to
    /// Find Next otherwise. Nothing changes if it already has it.
    private static func giveCommandG() {
        guard let findNextItem, let backdropItem else {
            return
        }
        let onCanvas: Bool = NSApp.keyWindow?.firstResponder is GraphEventView
        let (owner, other): (NSMenuItem, NSMenuItem) = onCanvas ? (backdropItem, findNextItem) : (findNextItem, backdropItem)
        guard owner.keyEquivalent != "g" else {
            return
        }
        // The other one's first: AppKit wouldn't give a key equivalent
        // another item has.
        other.keyEquivalent = ""
        owner.keyEquivalent = "g"
        owner.keyEquivalentModifierMask = .command
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
