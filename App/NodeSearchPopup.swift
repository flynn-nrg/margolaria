// NodeSearchPopup.swift
//
// The canvas's node search (M2e): Tab on the canvas opens it under the
// pointer, in a popover. Type part of a name, pick a result with the arrow
// keys (or the mouse), and Return adds that node there; Escape closes it.
// The results are MXNodeCatalog.search's, best first.
//
// Opened by a wire dropped on empty canvas, it lists only the nodes that
// can take the wire, each as the variant that does, and shows which of
// its ports the wire will go to.
//
// Introduces (SWIFT): `.onKeyPress`, `ScrollViewReader`.

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

    /// One result: the node's name, its group and type, and the port a
    /// wire would go to ("math · float · in1").
    private func row(_ match: MXNodeMatch, isHighlighted: Bool) -> some View {
        HStack {
            Text(match.kind.node)
            Spacer()
            Text([match.kind.group, match.variant.type, match.port].compactMap { $0 }.joined(separator: " · "))
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
