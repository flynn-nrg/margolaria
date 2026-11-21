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
// Every item's key comes from GraphKit's Shortcuts.swift (M7g), the one
// table of the app's shortcuts, which docs/SHORTCUTS.md lists and tests
// check for clashes.
//
// Some keys apply only on the canvas, while it has keyboard focus: its
// single keys (A, F, U…, M7g) and ⌘G, which is Graph > Group in Backdrop
// there and Edit > Find Next everywhere else (M4d). Their items have the
// key only while it applies; the menu bar gives and takes it as the focus
// moves (giveScopedKeys). A menu item's key equivalent is looked for
// before the focused view sees the key, so a plain "a" kept in the menu
// would take the letter from every text field; and AppKit lets only one
// item have a key (it clears it from any other it is given to), so ⌘G
// moves between its two items.
//
// The Scripts menu (M6d) lists the commands scripts registered
// (`@margolaria.command`), rebuilt whenever they change, so the palette
// lists them too, under "Scripts".
//
// Introduces (SWIFT): `#selector` with a type name (`NSDocument.save(_:)`),
// `Selector(("name:"))` for actions with no Swift declaration, variadic
// parameters (`Item...`), option sets (`[.command, .shift]`);
// `NotificationCenter.addObserver(forName:object:queue:using:)` and
// `MainActor.assumeIsolated` (M4d).

import AppKit
import GraphKit
import ScriptKit

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
        /// Its shortcut, from Shortcuts.swift; nil for none.
        let shortcut: Shortcut?
        /// For items that share an action, told apart by it (Find's).
        let tag: Int

        init(_ title: String, _ action: Selector?, _ shortcut: Shortcut? = nil, tag: Int = 0) {
            self.title = title
            self.action = action
            self.shortcut = shortcut
            self.tag = tag
        }

        /// The item for `shortcut`, titled as the table names it.
        init(_ shortcut: Shortcut, _ action: Selector) {
            self.init(shortcut.title, action, shortcut)
        }

        static let separator = Item("", nil)
    }

    /// The whole menu bar: the app menu, File, Edit, View, Graph, Scripts, Window,
    /// Help.
    static func make() -> NSMenu {
        let appName: String = ProcessInfo.processInfo.processName
        let bar = NSMenu()

        // The app menu (titled with the app's name in bold).
        // SWIFT: `#selector(NSApplication.hide(_:))` names an Objective-C
        // method by its Swift declaration, checked at compile time; it
        // becomes the selector `hide:`.
        let servicesMenu = NSMenu(title: "Services")
        let appMenu: NSMenu = menu(appName,
                                   Item("About \(appName)", #selector(AppDelegate.showAbout(_:))),
                                   .separator,
                                   Item("Settings…", #selector(AppDelegate.showSettings(_:)), .settings),
                                   .separator)
        appMenu.addItem(submenu: servicesMenu)
        add(to: appMenu,
            .separator,
            Item("Hide \(appName)", #selector(NSApplication.hide(_:)), .hide),
            Item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), .hideOthers),
            Item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator,
            Item("Quit \(appName)", #selector(NSApplication.terminate(_:)), .quit))
        NSApp.servicesMenu = servicesMenu
        bar.addItem(submenu: appMenu)

        // File. NSDocumentController and NSDocument implement all of these,
        // except Export as USD… and USDZ…, and Run Script…,
        // MaterialXDocument's own.
        let fileMenu: NSMenu = menu("File",
                                    Item(.new, #selector(NSDocumentController.newDocument(_:))),
                                    Item(.open, #selector(NSDocumentController.openDocument(_:))))
        // No "Open Recent" here: NSDocumentController inserts its own after
        // "Open…" and keeps it filled. It recognises its menu by a private
        // marker, so one built here would only be a second, empty copy.
        // (AppKit also adds "Share", and retitles Save as needed.)
        add(to: fileMenu,
            .separator,
            Item(.close, #selector(NSWindow.performClose(_:))),
            Item(.save, #selector(NSDocument.save(_:))),
            Item(.duplicateDocument, #selector(NSDocument.duplicate(_:))),
            Item("Rename…", #selector(NSDocument.rename(_:))),
            Item("Move To…", #selector(NSDocument.move(_:))),
            // AppKit turns this item into the "Revert To" submenu, with
            // "Browse All Versions…".
            Item("Revert To Saved", #selector(NSDocument.revertToSaved(_:))),
            .separator,
            // The document's materials as a USD file (M5b), and as a
            // USDZ for Quick Look and Reality Composer Pro (M5c).
            Item(.exportUSD, #selector(MaterialXDocument.exportAsUSD(_:))),
            Item(.exportUSDZ, #selector(MaterialXDocument.exportAsUSDZ(_:))),
            .separator,
            // A Python script run on the document, as one undo step (M6).
            Item(.runScript, #selector(MaterialXDocument.runScript(_:))))
        bar.addItem(submenu: fileMenu)

        // Edit. Undo and redo go to the window's undo manager.
        // SWIFT: `undo:` and `redo:` have no Swift declaration to point
        // `#selector` at (AppKit implements them privately), so the selector
        // is built from its name. The double parentheses tell the compiler
        // that this unchecked form is intended.
        bar.addItem(submenu: menu("Edit",
                                  Item(.undo, Selector(("undo:"))),
                                  Item(.redo, Selector(("redo:"))),
                                  .separator,
                                  Item(.cut, #selector(NSText.cut(_:))),
                                  Item(.copy, #selector(NSText.copy(_:))),
                                  Item(.paste, #selector(NSText.paste(_:))),
                                  // On the canvas: copies the selected nodes
                                  // next to themselves (M4a).
                                  Item(.duplicateNodes, #selector(GraphEventView.duplicateNodes(_:))),
                                  // On the canvas: deletes the selected nodes
                                  // (GraphEventView.delete(_:)); ⌫ only there.
                                  Item(.delete, #selector(NSText.delete(_:))),
                                  Item(.selectAll, #selector(NSText.selectAll(_:))),
                                  // Find, for the XML panel. Text views
                                  // handle these through one action,
                                  // performTextFinderAction:, told which
                                  // command by the item's tag.
                                  // SWIFT: `rawValue` is the enum case's
                                  // underlying Int.
                                  .separator,
                                  Item("Find…", #selector(NSTextView.performTextFinderAction(_:)), .find,
                                       tag: NSTextFinder.Action.showFindInterface.rawValue),
                                  Item("Find Next", #selector(NSTextView.performTextFinderAction(_:)), .findNext,
                                       tag: NSTextFinder.Action.nextMatch.rawValue),
                                  Item("Find Previous", #selector(NSTextView.performTextFinderAction(_:)), .findPrevious,
                                       tag: NSTextFinder.Action.previousMatch.rawValue)))

        // View.
        // The command palette (M4f) is the document's: it lists this menu
        // bar's commands, read when ⌘K is pressed (MaterialXDocument).
        // The main area, the bottom panel's tabs, the sidebar's tabs and the
        // right-hand panels (M7g) are the window's (MaterialXDocument),
        // checked or retitled as they are shown.
        bar.addItem(submenu: menu("View",
                                  Item(.commandPalette, #selector(MaterialXDocument.showCommandPalette(_:))),
                                  .separator,
                                  Item(.graphView, #selector(MaterialXDocument.showGraphView(_:))),
                                  Item(.splitView, #selector(MaterialXDocument.showSplitView(_:))),
                                  Item(.textView, #selector(MaterialXDocument.showTextView(_:))),
                                  .separator,
                                  Item(.xmlPanel, #selector(MaterialXDocument.showXMLPanel(_:))),
                                  Item(.issuesPanel, #selector(MaterialXDocument.showIssuesPanel(_:))),
                                  Item(.shaderPanel, #selector(MaterialXDocument.showShaderPanel(_:))),
                                  Item(.consolePanel, #selector(MaterialXDocument.showConsolePanel(_:))),
                                  .separator,
                                  Item(.documentSidebar, #selector(MaterialXDocument.showDocumentSidebar(_:))),
                                  Item(.librarySidebar, #selector(MaterialXDocument.showLibrarySidebar(_:))),
                                  .separator,
                                  Item(.sidebar, #selector(NSSplitViewController.toggleSidebar(_:))),
                                  Item(.viewport, #selector(MaterialXDocument.toggleViewport(_:))),
                                  Item(.inspector, #selector(MaterialXDocument.toggleInspector(_:))),
                                  .separator,
                                  Item(.fullScreen, #selector(NSWindow.toggleFullScreen(_:)))))

        // Graph: canvas commands (M4a), handled by the canvas view
        // (GraphEventView) when it has keyboard focus, and greyed out
        // otherwise. The single keys (Tab, A, F…; M4f, M7g) and Group in
        // Backdrop's ⌘G are the canvas's only (see the file comment).
        // Show Node Previews is the canvas bar's toggle, for every window
        // (AppDelegate).
        let graphMenu: NSMenu = menu("Graph",
                                     Item(.addNode, #selector(GraphEventView.addNode(_:))),
                                     Item(.frameAll, #selector(GraphEventView.frameAll(_:))),
                                     Item(.frameSelection, #selector(GraphEventView.frameSelection(_:))),
                                     .separator,
                                     Item(.openNode, #selector(GraphEventView.openSelectedNode(_:))),
                                     Item(.goUp, #selector(GraphEventView.goUpOneLevel(_:))),
                                     .separator,
                                     Item(.solo, #selector(GraphEventView.showSelectionAlone(_:))),
                                     Item("Show Node Previews", #selector(AppDelegate.toggleNodePreviews(_:))),
                                     .separator,
                                     Item(.arrange, #selector(GraphEventView.arrange(_:))),
                                     Item(.groupInBackdrop, #selector(GraphEventView.groupInBackdrop(_:))),
                                     .separator,
                                     Item(.collapse, #selector(GraphEventView.collapseIntoNodeGraph(_:))),
                                     Item(.ungroup, #selector(GraphEventView.ungroupNodeGraph(_:))))
        bar.addItem(submenu: graphMenu)

        // Scripts (M6d): the commands, first (updateScriptCommands), then
        // the startup scripts' own items, AppDelegate's.
        let scriptsMenu: NSMenu = menu("Scripts",
                                       .separator,
                                       Item(.stopScript, #selector(AppDelegate.stopScript(_:))),
                                       .separator,
                                       Item("Reload Startup Scripts", #selector(AppDelegate.reloadStartupScripts(_:))),
                                       Item("Open Scripts Folder", #selector(AppDelegate.openScriptsFolder(_:))))
        self.scriptsMenu = scriptsMenu
        updateScriptCommands()
        commandsObserver = NotificationCenter.default.addObserver(forName: Python.commandsDidChange, object: nil,
                                                                  queue: .main) { _ in
            MainActor.assumeIsolated {
                updateScriptCommands()
            }
        }
        bar.addItem(submenu: scriptsMenu)

        // Window. Registering it as the windows menu makes AppKit list the
        // open windows at its end.
        let windowMenu: NSMenu = menu("Window",
                                      Item(.minimize, #selector(NSWindow.performMiniaturize(_:))),
                                      Item("Zoom", #selector(NSWindow.performZoom(_:))),
                                      .separator,
                                      Item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = windowMenu
        bar.addItem(submenu: windowMenu)

        // Help. Registering it adds the system's search field to it.
        let helpMenu: NSMenu = menu("Help",
                                    Item("Acknowledgements", #selector(AppDelegate.showAcknowledgements(_:))))
        NSApp.helpMenu = helpMenu
        bar.addItem(submenu: helpMenu)

        shareScopedKeys()
        return bar
    }

    // MARK: Keys that apply only on the canvas, or only outside it (M4d, M7g)

    /// The items whose key applies only on the canvas or only outside it,
    /// with their shortcut: given the key when it applies, and only then.
    ///
    /// SWIFT: `static var` on a `@MainActor` type: shared state, only used
    /// on the main thread, which the compiler checks.
    private static var scopedItems: [(NSMenuItem, Shortcut)] = []
    /// The registration for window updates, kept so it lasts.
    private static var focusObserver: (any NSObjectProtocol)? = nil

    /// Gives the scoped items their keys for the focus now, and again
    /// whenever a window updates: after every event, so after every change
    /// of focus too.
    ///
    /// SWIFT: The observer's closure may be called from any thread as far
    /// as the compiler knows; `queue: .main` makes it the main thread, and
    /// `MainActor.assumeIsolated` tells the compiler so (it checks, at run
    /// time, and stops the app if it isn't).
    private static func shareScopedKeys() {
        giveScopedKeys()
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil,
                                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                giveScopedKeys()
            }
        }
    }

    /// The canvas's keys if the key window's focus is a canvas, the others
    /// otherwise. Items are only changed when their key must change.
    private static func giveScopedKeys() {
        let onCanvas: Bool = NSApp.keyWindow?.firstResponder is GraphEventView
        let applies: (Shortcut) -> Bool = { shortcut in
            shortcut.scope == .canvas ? onCanvas : !onCanvas
        }
        // Keys taken first: AppKit wouldn't give an item a key another has
        // (⌘G, moving between Find Next and Group in Backdrop).
        for (item, shortcut) in scopedItems where !applies(shortcut) && !item.keyEquivalent.isEmpty {
            item.keyEquivalent = ""
        }
        for (item, shortcut) in scopedItems where applies(shortcut) && item.keyEquivalent != shortcut.key {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
    }

    // MARK: Scripts (M6d)

    private static var scriptsMenu: NSMenu? = nil
    /// The registration for `Python.commandsDidChange`, kept so it lasts.
    private static var commandsObserver: (any NSObjectProtocol)? = nil

    /// Puts the commands scripts registered at the top of the Scripts
    /// menu, in the order they were registered, replacing those there; a
    /// greyed-out "No Commands" if there are none. Each item's represented
    /// object is its command's title, which MaterialXDocument.runCommand
    /// runs: in the front window, as with any document command, and
    /// greyed out with no window open.
    private static func updateScriptCommands() {
        guard let scriptsMenu else {
            return
        }
        // The items before the first separator are the commands.
        while let first = scriptsMenu.items.first, !first.isSeparatorItem {
            scriptsMenu.removeItem(first)
        }
        let commands: [String] = Python.commands
        guard !commands.isEmpty else {
            // No action: AppKit greys it out, and the palette leaves it out.
            scriptsMenu.insertItem(NSMenuItem(title: "No Commands", action: nil, keyEquivalent: ""), at: 0)
            return
        }
        for (index, title) in commands.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(MaterialXDocument.runCommand(_:)), keyEquivalent: "")
            item.representedObject = title
            scriptsMenu.insertItem(item, at: index)
        }
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
            let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
            menuItem.tag = item.tag
            if let shortcut = item.shortcut {
                if shortcut.scope == .anywhere {
                    menuItem.keyEquivalent = shortcut.key
                    menuItem.keyEquivalentModifierMask = shortcut.modifiers
                } else {
                    // Given its key by giveScopedKeys, when it applies.
                    scopedItems.append((menuItem, shortcut))
                }
            }
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
