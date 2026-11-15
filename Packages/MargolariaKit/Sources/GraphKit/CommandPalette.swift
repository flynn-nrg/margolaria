// CommandPalette.swift
//
// What the command palette (⌘K, M4f) lists and how it finds things in it.
// The palette itself is a SwiftUI view in the app (NodeSearchPopup.swift);
// this file is the part that can be tested without a window:
//
//   - PaletteCommand: one thing the palette can run, with where it comes
//     from ("Edit", "Inspector", "Add Node") and its shortcut;
//   - MenuCommands: every menu item of the menu bar that is enabled right
//     now, as commands. Reading the menus, rather than keeping a list of
//     commands beside them, means a new menu item is in the palette
//     without anyone remembering to add it;
//   - FuzzyMatch: scores a query against a title, as Xcode's Open Quickly
//     does: the query's letters in order, anywhere, ranked by how well they
//     line up with the starts of words ("fs" finds "Frame Selection");
//   - InputCommands (M7c): an input's right-click actions in the
//     inspector, Reset to Default and Promote, when each applies, and as
//     palette commands for every input of the selection.
//
// Introduces (SWIFT): a stored closure property in a struct (`run`),
// `@MainActor` on a closure type, recursion with an `inout` array,
// optional protocol methods called with `?.`, `Array(text)` for indexing
// characters, dynamic programming with `[Int](repeating:count:)`, a
// generic function (`rank<Item>`), sorting by a tuple with a negated key.

import AppKit
import MXKit

/// One command the palette can run.
///
/// SWIFT: A struct holding a closure (`run`): the code to run is data, as
/// a C function pointer with its context would be, but the closure
/// captures what it needs by itself. Not `Equatable`: closures can't be
/// compared.
public struct PaletteCommand: Identifiable {
    /// Unique among the commands listed together: the group and title.
    public let id: String
    /// What the palette shows and searches: "Duplicate", "open_pbr_surface".
    public let title: String
    /// Where it comes from, shown beside the title and searched too:
    /// "Edit", "File › Open Recent", "Inspector", "Add Node".
    public let group: String
    /// Its keyboard shortcut, as menus show it ("⌘D", "⌥⌘G", "F"); empty
    /// for none.
    public let shortcut: String
    /// False for commands listed only once something is typed: one of a
    /// family ("Add Output: float" and its thirteen siblings), which would
    /// otherwise fill the list before anything is typed.
    public let listsBeforeTyping: Bool
    /// Runs the command. The palette has closed by then.
    ///
    /// SWIFT: `@MainActor` on a closure type: it may only be called on the
    /// main thread, and may therefore touch AppKit and SwiftUI state.
    public let run: @MainActor () -> Void

    public init(title: String, group: String, shortcut: String = "", listsBeforeTyping: Bool = true,
                run: @escaping @MainActor () -> Void) {
        self.id = "\(group)/\(title)"
        self.title = title
        self.group = group
        self.shortcut = shortcut
        self.listsBeforeTyping = listsBeforeTyping
        self.run = run
    }
}

// MARK: - Menu commands

/// Reads the menu bar's commands.
@MainActor
public enum MenuCommands {
    /// Every enabled item of `menu` and its submenus, in menu order, as
    /// commands that send the item's action as choosing it would.
    ///
    /// Call it while the window's focus is where the commands should go:
    /// AppKit enables items by asking the responder chain (the focused
    /// view first), so this is what the menus would show now. Running a
    /// command later sends its action from the key window's focus then:
    /// put the focus back first.
    ///
    /// - Parameters:
    ///   - skipping: actions left out (the palette's own item).
    ///   - keys: shortcuts to show for actions whose items have none right
    ///     now. The app passes none since M7g: the canvas's single keys are
    ///     on their items while the canvas has focus (MainMenu.swift), the
    ///     only time their commands are enabled and listed.
    public static func commands(in menu: NSMenu, skipping: Set<Selector> = [],
                                keys: [Selector: String] = [:]) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        collect(menu, group: [], skipping: skipping, keys: keys, into: &commands)
        return commands
    }

    /// Adds `menu`'s enabled items to `commands`, then its submenus' (the
    /// top-level menus' items are grouped under their titles, "Edit").
    ///
    /// SWIFT: Recursion, as in C; `inout` passes `commands` by reference
    /// (`&commands` at the call), so every level appends to the same array.
    private static func collect(_ menu: NSMenu, group: [String], skipping: Set<Selector>,
                                keys: [Selector: String], into commands: inout [PaletteCommand]) {
        // Menus filled in as they open (Open Recent, Revert To) fill in
        // now, and every item is enabled or not, as when the menu opens.
        // SWIFT: `?.` twice: no delegate, or a delegate without the
        // optional method, both skip the call.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        // The app menu's Services are other apps' commands, on a selection.
        if menu === NSApp?.servicesMenu {
            return
        }
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                // The menu bar's own items have no title of their own to
                // show: they are the group.
                collect(submenu, group: group + [item.title], skipping: skipping, keys: keys, into: &commands)
                continue
            }
            guard item.isEnabled, let action = item.action, !skipping.contains(action), !item.title.isEmpty else {
                continue
            }
            let shortcut: String = item.keyEquivalent.isEmpty ? keys[action] ?? "" : Self.shortcut(of: item)
            // SWIFT: The closure captures `item` (a class instance, kept
            // alive by the closure) and sends what the menu would: the
            // item is the sender, so actions that read its tag (Find Next)
            // or its represented object (Open Recent's files) still work.
            commands.append(PaletteCommand(title: item.title, group: group.joined(separator: " › "),
                                           shortcut: shortcut) {
                NSApp.sendAction(action, to: item.target, from: item)
            })
        }
    }

    /// A menu item's shortcut as menus show it: "⇧⌘S", "⌥⌘G".
    ///
    /// Modifiers in AppKit's order (⌃⌥⇧⌘), then the key in capitals. A
    /// capital letter as the key equivalent means Shift.
    public static func shortcut(of item: NSMenuItem) -> String {
        shortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
    }

    /// See ``shortcut(of:)``.
    ///
    /// `nonisolated`: it only formats its arguments, so Shortcuts.swift's
    /// table may call it from any thread (M7g).
    public nonisolated static func shortcut(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else {
            return ""
        }
        // SWIFT: `allSatisfy` is true if every character is; "G" is
        // uppercase, "g" and "," aren't.
        let shifted: Bool = modifiers.contains(.shift) || key.allSatisfy(\.isUppercase)
        var text: String = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if shifted { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        // Keys with no printable character of their own.
        let names: [String: String] = ["\r": "↩", "\t": "⇥", " ": "Space", "\u{1B}": "⎋", "\u{7F}": "⌫",
                                       "\u{8}": "⌫"]
        return text + (names[key] ?? key.uppercased())
    }
}

// MARK: - Fuzzy matching

/// Scores how well a query matches a title, for the palette's ranking.
public enum FuzzyMatch {
    /// The query's score in `text`, higher is better; nil if `text` doesn't
    /// have the query's letters in order. Case and spaces in the query are
    /// ignored; an empty query matches everything, with score 0.
    ///
    /// Each matched letter scores 1, and more where it lines up well: at
    /// the very start of the text, at the start of a word (after a space,
    /// "_", "›", or a lowercase letter before a capital), or right after
    /// the letter before it. The best way to place the letters is found by
    /// trying them all (dynamic programming, below), not by taking the
    /// first of each: "sel" in "Select All" and in "Frame Selection" picks
    /// the "Sel" at a word start, not a stray "s".
    public static func score(_ query: String, in text: String) -> Int? {
        // SWIFT: `Array(...)` of a String's characters gives random access
        // by Int, which String itself doesn't (its characters vary in size
        // in memory, so `text[5]` would have to count from the start).
        let wanted: [Character] = Array(query.lowercased().filter { $0 != " " })
        guard !wanted.isEmpty else {
            return 0
        }
        let original: [Character] = Array(text)
        let letters: [Character] = Array(text.lowercased())
        // `lowercased()` can change a string's length ("ß" stays, but
        // some letters become two); match the original's characters one
        // by one then.
        let lower: [Character] = letters.count == original.count ? letters : original.map { $0.lowercased().first ?? $0 }
        guard wanted.count <= lower.count else {
            return nil
        }
        // What each position of the text is worth as a match.
        let bonus: [Int] = original.indices.map { position(at: $0, in: original) }

        // best[j]: the best score with the query's letters so far all
        // placed, the last one at text position j, or `impossible`. One
        // row per query letter; only the previous row is kept.
        //
        // SWIFT: Not `Int.min`, which would overflow (and stop the program:
        // Swift checks arithmetic) as soon as a bonus is added to it.
        let impossible: Int = -1_000_000
        var previous = [Int](repeating: impossible, count: lower.count)
        for (index, letter) in wanted.enumerated() {
            var row = [Int](repeating: impossible, count: lower.count)
            // The best of previous[0 ... j - 2], kept up to date as j
            // grows: this letter placed at j after a gap.
            var bestBefore: Int = impossible
            for j in lower.indices {
                if j >= 2 {
                    bestBefore = max(bestBefore, previous[j - 2])
                }
                guard lower[j] == letter else {
                    continue
                }
                if index == 0 {
                    row[j] = 1 + bonus[j]
                    continue
                }
                // Right after the previous letter, or after a gap.
                let adjacent: Int = j >= 1 ? previous[j - 1] + Self.consecutive : impossible
                let before: Int = max(bestBefore, adjacent)
                if before > impossible / 2 {
                    row[j] = before + 1 + bonus[j]
                }
            }
            previous = row
        }
        let result: Int = previous.max() ?? impossible
        return result > impossible / 2 ? result : nil
    }

    /// The bonus for a letter right after the one before it in the query.
    static let consecutive: Int = 4

    /// What a match at `index` is worth beyond its 1: the start of the
    /// text 8, the start of a word 6, elsewhere 0.
    private static func position(at index: Int, in text: [Character]) -> Int {
        if index == 0 {
            return 8
        }
        let before: Character = text[index - 1]
        let current: Character = text[index]
        if before == " " || before == "_" || before == "›" || before == "-" || before == "/" {
            return 6
        }
        // "camelCase": a capital after a lowercase letter starts a word.
        if before.isLowercase && current.isUppercase {
            return 6
        }
        return 0
    }

    /// `items` that match `query`, best first. An empty query keeps them
    /// all, in order.
    ///
    /// - Parameter texts: what to match in each item, most important
    ///   first, such as its title, then its group and title ("Edit
    ///   Duplicate", so "edit dup" finds it too). Items are ranked by the
    ///   first text that matches: every item whose title matches comes
    ///   before those found only through their group ("const" lists
    ///   "contrast" before nodes in the "colortransform" group). Then by
    ///   score; then shorter first (the basic command before its
    ///   relatives), then in their given order.
    ///
    /// SWIFT: `<Item>` makes this a *generic* function, like a C++ function
    /// template: it works for an array of any type, and the closure says
    /// how to get text out of one. The compiler checks the body once, for
    /// every possible `Item`, rather than for each use as C++ does.
    public static func rank<Item>(_ items: [Item], by query: String, texts: (Item) -> [String]) -> [Item] {
        if query.allSatisfy({ $0 == " " }) {
            return items
        }
        // SWIFT: `enumerated()` pairs each item with its position, kept to
        // break ties in the original order (`sorted` isn't guaranteed to
        // keep equal items in order).
        let scored: [(tier: Int, score: Int, length: Int, order: Int, item: Item)] =
            items.enumerated().compactMap { order, item in
                let itemTexts: [String] = texts(item)
                // The first text that matches, and its score.
                for (tier, text) in itemTexts.enumerated() {
                    if let score = score(query, in: text) {
                        return (tier, score, itemTexts[0].count, order, item)
                    }
                }
                return nil
            }
        // SWIFT: Tuples compare element by element, the first difference
        // deciding; negating the score sorts the highest first.
        return scored.sorted { a, b in
            (a.tier, -a.score, a.length, a.order) < (b.tier, -b.score, b.length, b.order)
        }
        .map(\.item)
    }
}

/// The actions on one input that the inspector's rows offer when
/// right-clicked (M2, M4b), and the palette lists for every input of the
/// element shown (M7c), whether or not its row is on screen.
public enum InputCommands {
    /// Whether the input can go back to its default: one the document
    /// sets, with a nodedef default (a value or a geometry property).
    /// Removing any other input (a nodegraph's own) would delete it.
    public static func canReset(_ input: MXPort, isReadOnly: Bool) -> Bool {
        input.isAuthored && !isReadOnly && (input.defaultValue != nil || input.ui.defaultGeomProp != nil)
    }

    /// Whether the input can become its nodegraph's (M4b): an unconnected
    /// input of a node inside a nodegraph (`ownerPath` has a "/"). Not a
    /// nodegraph's own input, whose owner is the graph at the top level.
    public static func canPromote(_ input: MXPort, ownerPath: String, isReadOnly: Bool) -> Bool {
        !isReadOnly && input.connection == nil && ownerPath.contains("/")
    }

    /// The palette's commands for `inputs` of the element at `ownerPath`:
    /// "Reset Base Color to Default" and "Promote in2 to Nodegraph Input"
    /// where they apply, named by each input's label. Listed once
    /// something is typed: a shader has dozens.
    public static func paletteCommands(for inputs: [MXPort], ownerPath: String, isReadOnly: Bool,
                                       reset: @escaping @MainActor (MXPort) -> Void,
                                       promote: @escaping @MainActor (MXPort) -> Void) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        for input in inputs {
            let label: String = input.ui.name ?? input.name
            if canReset(input, isReadOnly: isReadOnly) {
                commands.append(PaletteCommand(title: "Reset \(label) to Default", group: "Inspector",
                                               listsBeforeTyping: false) { reset(input) })
            }
            if canPromote(input, ownerPath: ownerPath, isReadOnly: isReadOnly) {
                commands.append(PaletteCommand(title: "Promote \(label) to Nodegraph Input", group: "Inspector",
                                               listsBeforeTyping: false) { promote(input) })
            }
        }
        return commands
    }
}
