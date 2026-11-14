// NodeSearchPopup.swift
//
// The app's two searches, both a field over a list picked from with the
// arrow keys and Return:
//
// NodeSearchPopup: the canvas's node search (M2e). Tab on the canvas opens
// it under the pointer, in a popover. Type part of a name, pick a result
// with the arrow keys (or the mouse), and Return adds that node there;
// Escape closes it. Nodes defined in library files the document doesn't
// include yet are listed too (M7c), with their file; adding one includes it. The results are MXNodeCatalog.search's, best first.
// Opened by a wire dropped on empty canvas, it lists only the nodes that
// can take the wire, each as the variant that does, and shows which of
// its ports the wire will go to.
//
// CommandPalette: the command palette (⌘K, M4f), at the top of the
// window. It lists every menu command enabled where the focus was
// (MaterialXDocument reads the menus), the inspector's actions for the
// selection and the toolbar's (which views add with `.paletteCommands`),
// and every node, library files' included (M7c; Return adds it in the
// middle of the canvas, as the Library does). Fuzzy-matched (GraphKit's FuzzyMatch), with each
// command's shortcut. Escape, ⌘K again or a click outside closes it.
//
// Introduces (SWIFT): `.onKeyPress`, `ScrollViewReader`; `PreferenceKey`
// and `.transformPreference` (M4f: values passed up the view tree, as
// bindings pass them down), `.onExitCommand`, `LazyVStack`.

import GraphKit
import MXKit
import SwiftUI

struct NodeSearchPopup: View {
    let catalog: MXNodeCatalog
    /// What the new node must offer to take a dropped wire; nil for none.
    let need: MXConnectionNeed?
    /// Called with the node chosen.
    let onChoose: (MXNodeMatch) -> Void

    @State private var query: String = ""

    /// The result Return would add, as an index into `results`.
    @State private var highlighted: Int = 0

    /// SWIFT: `@FocusState` tracks whether a view has keyboard focus, and
    /// setting it moves the focus there: the search field takes the keys
    /// as soon as the popover opens.
    @FocusState private var fieldFocused: Bool

    /// How many results to list; more than this means: type more.
    private static let maximumResults: Int = 30

    private var results: [MXNodeMatch] {
        Array(catalog.search(query, for: need).prefix(Self.maximumResults))
    }

    var body: some View {
        // `results` searches the catalog; compute it once per update.
        let results: [MXNodeMatch] = results
        VStack(alignment: .leading, spacing: 0) {
            TextField("Add Node", text: $query, prompt: Text(need == nil ? "Add a node…" : "Add a connected node…"))
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(8)
                .focused($fieldFocused)
                .onSubmit {
                    if results.indices.contains(highlighted) {
                        onChoose(results[highlighted])
                    }
                }
                // SWIFT: `.onKeyPress` sees keys before the view handles
                // them; returning `.handled` stops them there, `.ignored`
                // lets them through. The field would otherwise use the
                // arrows to move its cursor.
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, results.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
            Divider()
            if results.isEmpty {
                Text("No nodes match")
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                // SWIFT: `ScrollViewReader` gives a proxy that can scroll
                // to a child by its `.id`, to keep the highlighted row in
                // view as the arrows move it.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(results.indices, id: \.self) { index in
                                row(results[index], isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture {
                                        onChoose(results[index])
                                    }
                            }
                        }
                    }
                    .onChange(of: highlighted) {
                        proxy.scrollTo(highlighted)
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 300)
        .onAppear {
            fieldFocused = true
        }
        // A new query starts at its best result.
        .onChange(of: query) {
            highlighted = 0
        }
    }

    /// One result: the node's name, its group (or, for a library file's,
    /// the file, M7c) and type, and the port a wire would go to
    /// ("math · float · in1").
    private func row(_ match: MXNodeMatch, isHighlighted: Bool) -> some View {
        HStack {
            Text(match.kind.node)
            Spacer()
            Text([match.variant.libraryFile?.lastPathComponent ?? match.kind.group, match.variant.type, match.port]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHighlighted ? Color.accentColor.opacity(0.35) : .clear)
        // SWIFT: `.contentShape` makes the whole row clickable, not just
        // its text.
        .contentShape(.rect)
    }
}

// MARK: - Command palette (M4f)

/// The commands views offer the palette: the inspector's for the
/// selection, the toolbar's. Collected from the whole window.
///
/// SWIFT: A *preference* passes values up the view tree, from children to
/// an ancestor, the opposite of how bindings and plain properties pass
/// them down. Each view that has commands adds them under this key;
/// `reduce` combines siblings' values; the window reads the result
/// (`.overlayPreferenceValue`, ContentView). Views that aren't shown
/// (a hidden inspector) offer nothing.
struct PaletteCommandsKey: PreferenceKey {
    /// SWIFT: A computed `static var`, not a stored one: Swift 6 refuses
    /// a stored static `var` (global mutable state, unsafe across threads).
    static var defaultValue: [PaletteCommand] { [] }

    static func reduce(value: inout [PaletteCommand], nextValue: () -> [PaletteCommand]) {
        value += nextValue()
    }
}

extension View {
    /// Offers `commands` to the command palette while this view is shown.
    ///
    /// SWIFT: `.transformPreference` adds to what the view's children
    /// offered; `.preference(key:value:)` would replace it.
    func paletteCommands(_ commands: [PaletteCommand]) -> some View {
        transformPreference(PaletteCommandsKey.self) { value in
            value += commands
        }
    }
}

struct CommandPalette: View {
    /// Everything it can run, in the order listed for an empty query.
    let commands: [PaletteCommand]
    /// Closes the palette (before a command runs, too).
    let onClose: () -> Void

    @State private var query: String = ""

    /// The result Return would run, as an index into the results.
    @State private var highlighted: Int = 0

    @FocusState private var fieldFocused: Bool

    /// The commands matching the query, best first. A command's title is
    /// matched, and its group then its title ("edit dup" finds Edit ›
    /// Duplicate).
    /// Before anything is typed, only the commands that list then.
    private var results: [PaletteCommand] {
        if query.allSatisfy({ $0 == " " }) {
            return commands.filter(\.listsBeforeTyping)
        }
        return FuzzyMatch.rank(commands, by: query) { [$0.title, "\($0.group) \($0.title)"] }
    }

    var body: some View {
        // Ranking every command and node: once per update.
        let results: [PaletteCommand] = results
        VStack(alignment: .leading, spacing: 0) {
            TextField("Command", text: $query, prompt: Text("Search commands and nodes…"))
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(10)
                .focused($fieldFocused)
                .onSubmit {
                    if results.indices.contains(highlighted) {
                        run(results[highlighted])
                    }
                }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, results.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                // SWIFT: `.onExitCommand` runs on Escape (AppKit's
                // `cancelOperation:`), which a text field doesn't use itself.
                .onExitCommand(perform: onClose)
            Divider()
            if results.isEmpty {
                Text("No commands or nodes match")
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // SWIFT: `LazyVStack` makes its rows only as they
                        // scroll into view: with every node listed, there
                        // are over a thousand.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results.indices, id: \.self) { index in
                                row(results[index], isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture {
                                        run(results[index])
                                    }
                            }
                        }
                    }
                    .onChange(of: highlighted) {
                        proxy.scrollTo(highlighted)
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator)
        }
        .shadow(radius: 20, y: 8)
        .onAppear {
            fieldFocused = true
        }
        .onChange(of: query) {
            highlighted = 0
        }
    }

    /// Closes the palette, then runs `command`, once the palette has gone:
    /// a command may open a sheet or move the focus, which the palette
    /// (with the focus, over the window) would get in the way of.
    ///
    /// SWIFT: `Task { @MainActor in ... }` runs the closure later, on the
    /// main thread, after the current event (like `dispatch_async` to the
    /// main queue in C).
    private func run(_ command: PaletteCommand) {
        onClose()
        Task { @MainActor in
            command.run()
        }
    }

    /// One command: its title, where it comes from, and its shortcut.
    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(command.title)
                .lineLimit(1)
            Text(command.group)
                .font(.caption)
                .foregroundStyle(isHighlighted ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            if !command.shortcut.isEmpty {
                Text(command.shortcut)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isHighlighted ? Color.accentColor.opacity(0.35) : .clear)
        .contentShape(.rect)
    }
}
