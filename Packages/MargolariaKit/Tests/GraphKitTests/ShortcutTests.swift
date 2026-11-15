// ShortcutTests.swift
//
// M7g's exit criterion: a table of every command and its shortcut in the
// docs (docs/SHORTCUTS.md), and a test that no two commands share one.
// Also: no shortcut takes a key macOS keeps for itself, the Mac's usual
// keys keep their meaning, and the docs say what the code does.
//
// Introduces (SWIFT): nothing new.

import AppKit
import Foundation
@testable import GraphKit
import Testing

@Suite("Keyboard shortcuts (M7g)")
struct ShortcutTests {
    @Test("No two commands share a key where both apply")
    func noClashes() {
        let clashes: [String] = ShortcutRules.clashes().map { "\($0.command) and \($1.command): \($0.symbols)" }
        #expect(clashes.isEmpty, "\(clashes)")
    }

    @Test("The clash check finds a clash, and lets ⌘G mean one thing on the canvas and another elsewhere")
    func clashCheck() {
        let a = Shortcut("Graph › One", "x", [], .canvas)
        let b = Shortcut("Graph › Two", "x", [], .canvas)
        let elsewhere = Shortcut("Edit › Three", "x", [], .outsideCanvas)
        #expect(ShortcutRules.clashes(in: [a, b]).count == 1)
        #expect(ShortcutRules.clashes(in: [a, elsewhere]).isEmpty)
        #expect(ShortcutRules.clashes(in: [elsewhere, Shortcut("XML tab › Four", "x", [], .xmlTab)]).count == 1)
        // One command on two keys is no clash; two on one key is.
        #expect(ShortcutRules.clashes(in: [Shortcut.solo, Shortcut.soloPin]).isEmpty)
        #expect(Shortcut.groupInBackdrop.samePress(as: Shortcut.findNext))
    }

    @Test("No shortcut takes a key macOS keeps for itself")
    func noSystemKeys() {
        let taken: [String] = Shortcut.all.flatMap { shortcut in
            ShortcutRules.reservedBySystem.filter { $0.samePress(as: shortcut) }
                .map { "\(shortcut.command) takes \($0.command)'s \($0.symbols)" }
        }
        #expect(taken.isEmpty, "\(taken)")
    }

    @Test("The Mac's usual keys keep their meaning, but on the canvas")
    func conventionsKept() {
        let changed: [String] = Shortcut.all.filter { $0.scope != .canvas }.flatMap { shortcut in
            ShortcutRules.conventions.filter { $0.samePress(as: shortcut) && $0.command != shortcut.title }
                .map { "\(shortcut.command) takes \($0.command)'s \($0.symbols)" }
        }
        #expect(changed.isEmpty, "\(changed)")
    }

    @Test("Shortcuts are shown as menus show them")
    func symbols() {
        #expect(Shortcut.exportUSDZ.symbols == "⌥⇧⌘E")
        #expect(Shortcut.documentSidebar.symbols == "⌃⌘1")
        #expect(Shortcut.frameAll.symbols == "A")
        #expect(Shortcut.addNode.symbols == "⇥")
        #expect(Shortcut.delete.symbols == "⌫")
        #expect(Shortcut.applyXML.symbols == "⌘↩")
        #expect(Shortcut.revertXML.symbols == "⎋")
        #expect(Shortcut.groupInBackdrop.title == "Group in Backdrop")
    }

    /// Receives the probe menu's actions.
    final class Receiver: NSObject {
        var chosen: [String] = []
        @objc func choose(_ sender: NSMenuItem) {
            chosen.append(sender.title)
        }
    }

    @Test("The canvas's keys reach their menu items, Delete and Tab included")
    @MainActor
    func canvasKeysReachMenus() throws {
        _ = NSApplication.shared
        let receiver = Receiver()
        let menu = NSMenu(title: "Probe")
        let canvasKeys: [Shortcut] = Shortcut.all.filter { $0.scope == .canvas && $0.modifiers.isEmpty }
        for shortcut in canvasKeys {
            let item = NSMenuItem(title: shortcut.symbols, action: #selector(Receiver.choose(_:)),
                                  keyEquivalent: shortcut.key)
            item.keyEquivalentModifierMask = shortcut.modifiers
            item.target = receiver
            menu.addItem(item)
        }
        // The keys' codes on a US keyboard, as the events carry them.
        let codes: [String: UInt16] = ["a": 0, "s": 1, "f": 3, "u": 32, "p": 35, "l": 37, "\t": 48, "\r": 36,
                                       "\u{7F}": 51]
        for shortcut in canvasKeys {
            let code: UInt16 = try #require(codes[shortcut.key], "no key code for \(shortcut.symbols)")
            let event: NSEvent = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: shortcut.key, charactersIgnoringModifiers: shortcut.key, isARepeat: false, keyCode: code))
            #expect(menu.performKeyEquivalent(with: event), "\(shortcut.symbols)")
        }
        #expect(receiver.chosen == canvasKeys.map(\.symbols))
    }

    @Test("docs/SHORTCUTS.md lists every shortcut as the table has it, and no other")
    func docsMatch() throws {
        // This file is Packages/MargolariaKit/Tests/GraphKitTests/; the
        // repository is four folders up.
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let text: String = try String(contentsOf: root.appending(path: "docs/SHORTCUTS.md"), encoding: .utf8)

        // The Commands table's rows: command, keys, where.
        var documented: [String: (keys: [String], scope: String)] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| ") && line.contains(" › ") {
            let cells: [String] = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // "", command, keys, where, "".
            try #require(cells.count == 5, "\(line)")
            let keys: [String] = cells[2] == "—" ? [] : cells[2].components(separatedBy: " or ")
            documented[cells[1]] = (keys, cells[3])
        }

        let scopes: [Shortcut.Scope: String] = [.anywhere: "Anywhere", .canvas: "Canvas",
                                                .outsideCanvas: "Outside the canvas", .xmlTab: "XML tab"]
        // Every shortcut, documented with its keys and where.
        for shortcut in Shortcut.all {
            let row = documented[shortcut.command]
            #expect(row?.keys.contains(shortcut.symbols) == true, "\(shortcut.command): \(shortcut.symbols)")
            #expect(row?.scope == scopes[shortcut.scope], "\(shortcut.command): \(shortcut.scope)")
        }
        // No key documented that the table doesn't have.
        for (command, row) in documented {
            let table: [String] = Shortcut.all.filter { $0.command == command }.map(\.symbols)
            #expect(Set(row.keys) == Set(table), "\(command): docs \(row.keys), table \(table)")
        }
    }
}
