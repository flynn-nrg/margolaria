// CommandPaletteTests.swift
//
// Tests for what the command palette lists and how it ranks it (M4f):
// fuzzy matching, the menu items read as commands (only the enabled ones,
// grouped by menu, with their shortcuts), and running one sends its action
// as the menu would. M4f's exit criterion, "every menu command can be
// found and run from the palette", for a menu bar built like the app's
// (the app's own is built in the app, which has no test target): every
// enabled item is listed, its title finds it first, and running it sends
// its action.
//
// Introduces (SWIFT): an `NSObject` subclass in a test, with `@objc`
// actions, standing in for the responder that would receive them.

import AppKit
import Testing
@testable import GraphKit

@MainActor
@Suite("Command palette")
struct CommandPaletteTests {
    // MARK: Fuzzy matching

    @Test("Letters in order match; out of order, or missing, don't")
    func matching() {
        #expect(FuzzyMatch.score("fs", in: "Frame Selection") != nil)
        #expect(FuzzyMatch.score("FRAME", in: "Frame Selection") != nil)
        #expect(FuzzyMatch.score("frame sel", in: "Frame Selection") != nil)
        #expect(FuzzyMatch.score("sf", in: "Frame Selection") == nil)
        #expect(FuzzyMatch.score("frames", in: "Frame") == nil)
        #expect(FuzzyMatch.score("x", in: "Frame Selection") == nil)
        #expect(FuzzyMatch.score("", in: "Frame Selection") == 0)
        #expect(FuzzyMatch.score("  ", in: "") == 0)
        #expect(FuzzyMatch.score("a", in: "") == nil)
    }

    @Test("Starts of words score more than letters inside them")
    func wordStarts() throws {
        // "Sel" at a word start, not the "s" of "Paste" and "el" later.
        let start = try #require(FuzzyMatch.score("sel", in: "Select All"))
        let inside = try #require(FuzzyMatch.score("sel", in: "Pastel"))
        #expect(start > inside)
        // The best placement is found, not the first: "fs" uses the "S"
        // of "Selection", not the "s" of "Frames".
        let best = try #require(FuzzyMatch.score("fs", in: "Frames Selection"))
        let adjacentOnly = try #require(FuzzyMatch.score("fs", in: "Frxxs"))
        #expect(best > adjacentOnly)
        // Underscores separate words in node names; capitals in camelCase.
        #expect(try #require(FuzzyMatch.score("ps", in: "open_pbr_surface"))
                > #require(FuzzyMatch.score("ps", in: "openpbrsurface")))
        #expect(try #require(FuzzyMatch.score("ps", in: "openPbrSurface"))
                > #require(FuzzyMatch.score("ps", in: "openpbrsurface")))
    }

    @Test("Letters together score more than spread out")
    func consecutive() throws {
        let together = try #require(FuzzyMatch.score("dup", in: "Duplicate"))
        let spread = try #require(FuzzyMatch.score("dup", in: "Delete Unused Parts"))
        // Spread out, each is at a word start (6 each), but "Duplicate"'s
        // "D" is the text's start (8) and the others follow it (4 each).
        #expect(together == 3 + 8 + 4 + 4)
        #expect(spread == 3 + 8 + 6 + 6)
        #expect(FuzzyMatch.score("dup", in: "xdup")! < together)
    }

    @Test("Ranking: best score first, then shorter, then in order; an empty query keeps everything")
    func ranking() {
        let titles = ["Paste", "Select All", "Delete", "Frame Selection", "Selection", "Save"]
        let ranked = FuzzyMatch.rank(titles, by: "sel") { [$0] }
        #expect(ranked == ["Selection", "Select All", "Frame Selection"])
        #expect(FuzzyMatch.rank(titles, by: "") { [$0] } == titles)
        #expect(FuzzyMatch.rank(titles, by: "zz") { [$0] }.isEmpty)
        // A second text counts too: the group before the title.
        let commands = [("Duplicate", "File"), ("Duplicate", "Edit"), ("Delete", "Edit")]
        let edit = FuzzyMatch.rank(commands, by: "edit dup") { [$0.0, "\($0.1) \($0.0)"] }
        #expect(edit.map(\.1) == ["Edit"])
        // A title that matches beats any match through the group, however
        // well the group matches (seen in the app: "const" listed
        // colortransform nodes before "contrast").
        let nodes = [("srgb_texture_to_lin_rec709", "Add Node · colortransform"), ("contrast", "Add Node · adjustment"),
                     ("constant", "Add Node · procedural")]
        let const = FuzzyMatch.rank(nodes, by: "const") { [$0.0, "\($0.1) \($0.0)"] }
        #expect(const.map(\.0) == ["constant", "contrast", "srgb_texture_to_lin_rec709"])
    }

    // MARK: Menus

    /// Stands in for the responder chain: implements some actions, and
    /// enables only some of them.
    final class Receiver: NSObject, NSMenuItemValidation {
        var received: [String] = []
        var canFrame: Bool = false

        @objc func copy(_ sender: Any?) { received.append("copy") }
        @objc func frameAll(_ sender: Any?) { received.append("frameAll") }
        @objc func findNext(_ sender: Any?) {
            // Reads the item that sent it, as performTextFinderAction does.
            received.append("find \((sender as? NSMenuItem)?.tag ?? -1)")
        }
        @objc func palette(_ sender: Any?) { received.append("palette") }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            menuItem.action != #selector(frameAll(_:)) || canFrame
        }
    }

    /// A menu bar like the app's: Edit and Graph menus, a submenu, a
    /// separator, an item nobody implements, a hidden one.
    func menuBar(_ receiver: Receiver) -> NSMenu {
        // Menus read and send actions through NSApp.
        _ = NSApplication.shared
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = receiver
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            return top
        }
        let find = item("Find Next", #selector(Receiver.findNext(_:)), "g")
        find.tag = 2
        let unimplemented = item("Nothing", Selector(("nothing:")))
        let hidden = item("Hidden", #selector(Receiver.copy(_:)))
        hidden.isHidden = true
        let bar = NSMenu()
        bar.addItem(menu("Edit", [item("Copy", #selector(Receiver.copy(_:)), "c"), .separator(),
                                  menu("Find", [find]), unimplemented, hidden]))
        bar.addItem(menu("Graph", [item("Frame All", #selector(Receiver.frameAll(_:))),
                                   item("Collapse", #selector(Receiver.copy(_:)), "G", [.command, .option])]))
        bar.addItem(menu("View", [item("Command Palette…", #selector(Receiver.palette(_:)), "k")]))
        return bar
    }

    @Test("Enabled menu items become commands, grouped by menu, with their shortcuts")
    func menuCommands() {
        let receiver = Receiver()
        let bar = menuBar(receiver)
        let skipping: Set<Selector> = [#selector(Receiver.palette(_:))]
        let keys: [Selector: String] = [#selector(Receiver.frameAll(_:)): "A"]

        var commands = MenuCommands.commands(in: bar, skipping: skipping, keys: keys)
        // No Frame All (disabled), no Nothing (no one implements it), no
        // Hidden, no palette; Collapse's capital G is Shift.
        #expect(commands.map(\.id) == ["Edit/Copy", "Edit › Find/Find Next", "Graph/Collapse"])
        #expect(commands.map(\.shortcut) == ["⌘C", "⌘G", "⌥⇧⌘G"])

        receiver.canFrame = true
        commands = MenuCommands.commands(in: bar, skipping: skipping, keys: keys)
        let frame = commands.first { $0.title == "Frame All" }
        #expect(frame?.group == "Graph")
        // No key equivalent: the key given for its action.
        #expect(frame?.shortcut == "A")

        // Running them sends their actions, from their items.
        commands.forEach { $0.run() }
        #expect(receiver.received == ["copy", "find 2", "frameAll", "copy"])
    }

    @Test("Every command is found first by its own title, and by its menu and title")
    func everyCommandFound() {
        let receiver = Receiver()
        receiver.canFrame = true
        let commands = MenuCommands.commands(in: menuBar(receiver))
        #expect(commands.count == 5)
        for command in commands {
            let byTitle = FuzzyMatch.rank(commands, by: command.title) { [$0.title, "\($0.group) \($0.title)"] }
            #expect(byTitle.first?.id == command.id, "\(command.id)")
            let byGroup = FuzzyMatch.rank(commands, by: "\(command.group) \(command.title)") {
                [$0.title, "\($0.group) \($0.title)"]
            }
            #expect(byGroup.first?.id == command.id, "\(command.id)")
        }
    }

    @Test("Shortcuts are written as menus write them")
    func shortcuts() {
        #expect(MenuCommands.shortcut(key: "s", modifiers: [.command, .shift]) == "⇧⌘S")
        #expect(MenuCommands.shortcut(key: "f", modifiers: [.command, .control]) == "⌃⌘F")
        #expect(MenuCommands.shortcut(key: "\r", modifiers: .command) == "⌘↩")
        #expect(MenuCommands.shortcut(key: "", modifiers: .command) == "")
        #expect(MenuCommands.shortcut(key: ",", modifiers: .command) == "⌘,")
    }
}
