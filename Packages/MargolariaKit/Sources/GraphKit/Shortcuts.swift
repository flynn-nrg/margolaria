// Shortcuts.swift
//
// Every keyboard shortcut of the app, in one table (M7g, PLAN.md §8.4).
// The menus take their keys from it (App/MainMenu.swift), the canvas its
// single keys (GraphEventView), and docs/SHORTCUTS.md lists it; tests
// check that no two commands share a key where both apply, that none takes
// a key macOS keeps for itself, that keys with a meaning on every Mac
// (⌘C, ⌘Q) keep it, and that the docs say the same as the table.
//
// Where a key applies (`Shortcut.Scope`):
//   - anywhere in a document window;
//   - on the canvas, while it has keyboard focus: the single keys (A, F,
//     U…), which would take letters from text fields anywhere else, and ⌘G,
//     which is Group in Backdrop there and Find Next elsewhere (M4d). Their
//     menu items show the key only while the canvas has focus; the menu
//     bar gives and takes it as the focus moves;
//   - outside the canvas (Find Next's ⌘G);
//   - in the XML tab, while its text has focus (Apply, Revert).
//
// Introduces (SWIFT): `static let` constants of a struct's own type
// (`Shortcut.frameAll`), used as a namespace of named values.

import AppKit

/// One command's keyboard shortcut.
public struct Shortcut: Sendable, Equatable {
    /// Where a shortcut applies; see the file comment.
    public enum Scope: String, Sendable, CaseIterable {
        case anywhere
        case canvas
        case outsideCanvas
        case xmlTab

        /// True if a key could mean both a command of this scope and one
        /// of `other`'s at the same moment.
        public func overlaps(_ other: Scope) -> Bool {
            switch (self, other) {
            case (.anywhere, _), (_, .anywhere):
                return true
            case (.canvas, .canvas):
                return true
            case (.canvas, _), (_, .canvas):
                // The canvas has the focus, or something else has.
                return false
            default:
                // Outside the canvas and in the XML tab: the XML tab is
                // outside the canvas.
                return true
            }
        }
    }

    /// The command, as the menus name it: "Graph › Frame All". For a key
    /// with no menu item, where it is used: "XML tab › Apply".
    public let command: String
    /// The key, as a menu item's key equivalent: lowercase, so Shift is
    /// in `modifiers`; "\t", "\r", "\u{7F}" (Delete) and "\u{1B}" (Escape)
    /// for keys with no character of their own. (Delete is "\u{7F}", the
    /// character the key sends: a menu item given "\u{8}", backspace,
    /// shows ⌫ too but isn't chosen by the key.)
    public let key: String
    /// ⌘, ⌥, ⌃ and ⇧; empty for a single key.
    public let modifiers: NSEvent.ModifierFlags
    public let scope: Scope

    public init(_ command: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
                _ scope: Scope = .anywhere) {
        self.command = command
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
    }

    /// The shortcut as menus show it: "⌥⌘G", "F", "⇥".
    public var symbols: String {
        MenuCommands.shortcut(key: key, modifiers: modifiers)
    }

    /// The menu item's title: the command's last part.
    public var title: String {
        command.components(separatedBy: " › ").last ?? command
    }

    /// True if `other` is pressed the same way: the same key, the same
    /// modifiers.
    public func samePress(as other: Shortcut) -> Bool {
        key == other.key && modifiers.rawValue == other.modifiers.rawValue
    }

    public static func == (a: Shortcut, b: Shortcut) -> Bool {
        a.command == b.command && a.samePress(as: b) && a.scope == b.scope
    }
}

// MARK: - The table

/// SWIFT: `static let`s of the struct's own type, in an extension: named
/// values (`Shortcut.frameAll`) that MainMenu and GraphEventView use, so
/// the key is written once, here.
extension Shortcut {
    // The app menu: the Mac's own.
    public static let settings = Shortcut("Margolaria › Settings…", ",")
    public static let hide = Shortcut("Margolaria › Hide Margolaria", "h")
    public static let hideOthers = Shortcut("Margolaria › Hide Others", "h", [.command, .option])
    public static let quit = Shortcut("Margolaria › Quit Margolaria", "q")

    // File.
    public static let new = Shortcut("File › New", "n")
    public static let open = Shortcut("File › Open…", "o")
    public static let close = Shortcut("File › Close", "w")
    public static let save = Shortcut("File › Save", "s")
    public static let duplicateDocument = Shortcut("File › Duplicate", "s", [.command, .shift])
    public static let exportUSD = Shortcut("File › Export as USD…", "e", [.command, .shift])
    public static let exportUSDZ = Shortcut("File › Export as USDZ…", "e", [.command, .shift, .option])
    public static let runScript = Shortcut("File › Run Script…", "r")

    // Edit.
    public static let undo = Shortcut("Edit › Undo", "z")
    public static let redo = Shortcut("Edit › Redo", "z", [.command, .shift])
    public static let cut = Shortcut("Edit › Cut", "x")
    public static let copy = Shortcut("Edit › Copy", "c")
    public static let paste = Shortcut("Edit › Paste", "v")
    public static let duplicateNodes = Shortcut("Edit › Duplicate", "d")
    /// The Delete key (⌫); Forward Delete (⌦) does it too (GraphEventView).
    public static let delete = Shortcut("Edit › Delete", "\u{7F}", [], .canvas)
    public static let selectAll = Shortcut("Edit › Select All", "a")
    public static let find = Shortcut("Edit › Find…", "f")
    public static let findNext = Shortcut("Edit › Find Next", "g", .command, .outsideCanvas)
    public static let findPrevious = Shortcut("Edit › Find Previous", "g", [.command, .shift])

    // View.
    public static let commandPalette = Shortcut("View › Command Palette…", "k")
    public static let graphView = Shortcut("View › Graph", "1")
    public static let splitView = Shortcut("View › Split", "2")
    public static let textView = Shortcut("View › Text", "3")
    public static let xmlPanel = Shortcut("View › XML", "1", [.command, .option])
    public static let issuesPanel = Shortcut("View › Issues", "2", [.command, .option])
    public static let shaderPanel = Shortcut("View › Generated Shader", "3", [.command, .option])
    public static let consolePanel = Shortcut("View › Console", "4", [.command, .option])
    public static let documentSidebar = Shortcut("View › Document", "1", [.command, .control])
    public static let librarySidebar = Shortcut("View › Library", "2", [.command, .control])
    public static let viewport = Shortcut("View › Show Viewport", "p", [.command, .option])
    public static let inspector = Shortcut("View › Show Inspector", "i", [.command, .option])
    public static let sidebar = Shortcut("View › Show Sidebar", "s", [.command, .control])
    public static let fullScreen = Shortcut("View › Enter Full Screen", "f", [.command, .control])

    // Graph: the canvas's single keys, as in MaterialX's Graph Editor
    // (Tab, F, U, P) where it has one.
    public static let addNode = Shortcut("Graph › Add Node…", "\t", [], .canvas)
    public static let frameAll = Shortcut("Graph › Frame All", "a", [], .canvas)
    public static let frameSelection = Shortcut("Graph › Frame Selection", "f", [], .canvas)
    public static let openNode = Shortcut("Graph › Open Nodegraph", "\r", [], .canvas)
    public static let goUp = Shortcut("Graph › Go Up One Level", "u", [], .canvas)
    public static let solo = Shortcut("Graph › Show in Viewport Alone", "s", [], .canvas)
    /// The same command as `solo`, on the Graph Editor's key for pinning
    /// the node it renders; not in the menu, which shows S.
    public static let soloPin = Shortcut("Graph › Show in Viewport Alone", "p", [], .canvas)
    public static let arrange = Shortcut("Graph › Arrange", "l", [], .canvas)
    public static let groupInBackdrop = Shortcut("Graph › Group in Backdrop", "g", .command, .canvas)
    public static let collapse = Shortcut("Graph › Collapse into Nodegraph", "g", [.command, .option])
    public static let ungroup = Shortcut("Graph › Ungroup Nodegraph", "g", [.command, .option, .shift])

    // Scripts.
    public static let stopScript = Shortcut("Scripts › Stop Script", ".")

    // Window.
    public static let minimize = Shortcut("Window › Minimize", "m")

    // The XML tab's buttons (M4e), while its text has focus.
    public static let applyXML = Shortcut("XML tab › Apply", "\r", .command, .xmlTab)
    public static let revertXML = Shortcut("XML tab › Revert", "\u{1B}", [], .xmlTab)

    /// Every shortcut, in the menus' order.
    public static let all: [Shortcut] = [
        settings, hide, hideOthers, quit,
        new, open, close, save, duplicateDocument, exportUSD, exportUSDZ, runScript,
        undo, redo, cut, copy, paste, duplicateNodes, delete, selectAll, find, findNext, findPrevious,
        commandPalette, graphView, splitView, textView, xmlPanel, issuesPanel, shaderPanel, consolePanel,
        documentSidebar, librarySidebar, viewport, inspector, sidebar, fullScreen,
        addNode, frameAll, frameSelection, openNode, goUp, solo, soloPin, arrange,
        groupInBackdrop, collapse, ungroup,
        stopScript,
        minimize,
        applyXML, revertXML,
    ]
}

// MARK: - Checks

/// What the tests check the table against.
public enum ShortcutRules {
    /// Keys macOS takes before any app sees them, in its default settings:
    /// Spotlight, the app switcher, screenshots, Force Quit, locking the
    /// screen, Mission Control and Spaces, the Dock, the Help menu's
    /// search, the character viewer.
    public static let reservedBySystem: [Shortcut] = [
        Shortcut("Spotlight", " "),
        Shortcut("Input sources", " ", .control),
        Shortcut("Finder search", " ", [.command, .option]),
        Shortcut("Emoji & Symbols", " ", [.command, .control]),
        Shortcut("App switcher", "\t"),
        Shortcut("App switcher, back", "\t", [.command, .shift]),
        Shortcut("Next window", "`"),
        Shortcut("Screenshot", "3", [.command, .shift]),
        Shortcut("Screenshot of part", "4", [.command, .shift]),
        Shortcut("Screenshot tool", "5", [.command, .shift]),
        Shortcut("Screenshot to clipboard", "3", [.command, .shift, .control]),
        Shortcut("Screenshot of part to clipboard", "4", [.command, .shift, .control]),
        Shortcut("Force Quit", "\u{1B}", [.command, .option]),
        Shortcut("Lock Screen", "q", [.command, .control]),
        Shortcut("Log Out", "q", [.command, .shift]),
        Shortcut("Log Out now", "q", [.command, .shift, .option]),
        Shortcut("Hide the Dock", "d", [.command, .option]),
        Shortcut("Help search", "/", [.command, .shift]),
    ] + (1...9).map { Shortcut("Switch to Space \($0)", String($0), .control) }

    /// Keys that mean the same thing in every Mac app, by the title of the
    /// command they mean. A command using one must be that command, except
    /// on the canvas, where Group in Backdrop deliberately takes ⌘G (M4d).
    public static let conventions: [Shortcut] = [
        Shortcut("New", "n"), Shortcut("Open…", "o"), Shortcut("Close", "w"), Shortcut("Save", "s"),
        Shortcut("Duplicate", "s", [.command, .shift]), Shortcut("Print…", "p"),
        Shortcut("Undo", "z"), Shortcut("Redo", "z", [.command, .shift]),
        Shortcut("Cut", "x"), Shortcut("Copy", "c"), Shortcut("Paste", "v"), Shortcut("Select All", "a"),
        Shortcut("Find…", "f"), Shortcut("Find Next", "g"), Shortcut("Find Previous", "g", [.command, .shift]),
        Shortcut("Use Selection for Find", "e"),
        Shortcut("Hide Margolaria", "h"), Shortcut("Hide Others", "h", [.command, .option]),
        Shortcut("Minimize", "m"), Shortcut("Quit Margolaria", "q"), Shortcut("Settings…", ","),
        Shortcut("Enter Full Screen", "f", [.command, .control]),
    ]

    /// Pairs of different commands pressed the same way where both apply.
    public static func clashes(in shortcuts: [Shortcut] = Shortcut.all) -> [(Shortcut, Shortcut)] {
        var found: [(Shortcut, Shortcut)] = []
        for (i, a) in shortcuts.enumerated() {
            for b in shortcuts[(i + 1)...] where a.command != b.command && a.samePress(as: b)
                && a.scope.overlaps(b.scope) {
                found.append((a, b))
            }
        }
        return found
    }
}
