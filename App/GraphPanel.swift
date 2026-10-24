// GraphPanel.swift
//
// The graph canvas for one document (PLAN.md §4.1, region 3): a breadcrumb
// bar showing which graph level is open, and the canvas below it.
//
// Read-only in M1: nodes can be selected, moved around and framed, but the
// document doesn't change. Moved nodes go back to the automatic layout when
// the level is opened again.
//
// Navigation: double-click a nodegraph to open it; U, or a breadcrumb, to go
// back up. The sidebar opens levels and selects nodes through `level` and
// `focus` (see ContentView).
//
// Introduces (SWIFT): `@Binding` (a property another view owns),
// `.onChange(of:initial:)`, `ContentUnavailableView`, a `@MainActor` class
// holding view state, closures capturing a binding.

import GraphKit
import MXKit
import SwiftUI

/// One open graph level: what was built from the document, and the canvas
/// controller showing it.
///
/// SWIFT: A class, so that the canvas callbacks below and the view share one
/// instance. `@MainActor` because it holds a GraphCanvasController, which is
/// main-actor-only.
@MainActor
final class GraphLevel {
    let graph: DocumentGraph
    let controller: GraphCanvasController

    init(graph: DocumentGraph) {
        self.graph = graph
        self.controller = GraphCanvasController(model: graph.model)
    }
}

struct GraphPanel: View {
    let document: MaterialXDocument

    /// The path of the nodegraph shown, or "" for the document's top level.
    ///
    /// SWIFT: `@Binding` is a reference to state that another view owns
    /// (here ContentView's `@State`). Reading it reads that state; writing
    /// it changes it, and both views update. It is what `$graphPath` passes.
    @Binding var levelPath: String

    /// An element to select and frame once its level is shown, then cleared.
    @Binding var focus: String?

    /// The path of the node selected on the canvas, when exactly one is;
    /// nil otherwise. Written here, read by the XML panel.
    @Binding var selectedPath: String?

    /// The level on screen. Rebuilt when the path or the document changes.
    @State private var level: GraphLevel? = nil

    /// Why the level couldn't be shown, if it couldn't.
    @State private var failure: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(path: $levelPath)
            Divider()
            if let level, !level.graph.model.nodes.isEmpty {
                LayerGraphRepresentable(controller: level.controller, thumbnail: nil)
                    // A new canvas view for each level.
                    .id(ObjectIdentifier(level))
            } else {
                // SWIFT: `ContentUnavailableView` is the standard "nothing to
                // show here" placeholder: an icon, a title, a description.
                ContentUnavailableView(failure == nil ? "No Nodes" : "Can't Show This Graph",
                                       systemImage: "circle.grid.cross",
                                       description: Text(failure ?? "This level of the document has no nodes."))
            }
        }
        // SWIFT: `.onChange(of:initial:)` runs the closure when the value
        // changes, and with `initial: true` also when the view first appears.
        .onChange(of: levelPath, initial: true) {
            rebuild()
        }
        // Revert, or another app changing the file, replaces the document's
        // content; show the new one. `ObjectIdentifier` is the object's
        // identity, so this fires when `content` is a different MXDocument.
        .onChange(of: ObjectIdentifier(document.content)) {
            rebuild()
        }
        .onChange(of: focus) {
            applyFocus()
        }
        // SWIFT: Reading `level?.controller.selection` here, in `body`, makes
        // SwiftUI observe it (the controller is `@Observable`), so this runs
        // whenever the canvas selection changes, or the level is replaced.
        .onChange(of: level?.controller.selection, initial: true) {
            guard let level, level.controller.selection.count == 1,
                  let id = level.controller.selection.first else {
                selectedPath = nil
                return
            }
            selectedPath = level.graph.elementPaths[id]
        }
    }

    /// Builds the canvas for `levelPath` from the document.
    private func rebuild() {
        let mxGraph: MXGraph
        do {
            mxGraph = try document.content.graph(at: levelPath)
        } catch {
            level = nil
            failure = String(describing: error)
            return
        }
        var graph: DocumentGraph = GraphBuilder.build(mxGraph)
        GraphAutoLayout.apply(to: &graph.model)

        let newLevel = GraphLevel(graph: graph)
        // Double-clicking a nodegraph opens it.
        //
        // SWIFT: These closures capture `levelPath`, a binding: writing to it
        // from inside the closure later still writes ContentView's state.
        // `[weak newLevel]` avoids a reference cycle: the controller (owned
        // by the level) holds the closure, so the closure must not hold the
        // level strongly.
        newLevel.controller.onOpenNode = { [weak newLevel] id in
            guard let newLevel, newLevel.graph.model.nodes[id].category == .nodeGraph else {
                return
            }
            levelPath = newLevel.graph.elementPaths[id]
        }
        newLevel.controller.onNavigateUp = {
            levelPath = BreadcrumbBar.parent(of: levelPath)
        }
        newLevel.controller.frame(.all)
        level = newLevel
        failure = nil
        applyFocus()
    }

    /// Selects and frames `focus`, if it is on the level shown.
    private func applyFocus() {
        guard let path = focus, let level, let index = level.graph.nodeIndex(forPath: path) else {
            return
        }
        level.controller.selection = [index]
        level.controller.frame(.selection)
        focus = nil
    }
}

/// "Document › NG_brass1": where the canvas is, each part clickable.
private struct BreadcrumbBar: View {
    @Binding var path: String

    var body: some View {
        HStack(spacing: 4) {
            crumb("Document", target: "")
            // SWIFT: `split(separator:)` cuts the path at each "/". Each part
            // is a Substring; `String(...)` copies it into its own String.
            let parts: [String] = path.split(separator: "/").map { String($0) }
            ForEach(parts.indices, id: \.self) { i in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                crumb(parts[i], target: parts[0...i].joined(separator: "/"))
            }
            Spacer()
            Text("Double-click a nodegraph to open it · U goes up · A frames all · F frames the selection · Pan: middle-drag or Space-drag · Wheel zooms")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// One part of the path; the last one (where we are) isn't a button.
    ///
    /// SWIFT: `@ViewBuilder` lets a function return different views from an
    /// `if`/`else`, like `body` does.
    @ViewBuilder
    private func crumb(_ title: String, target: String) -> some View {
        if target == path {
            Text(title)
                .fontWeight(.semibold)
        } else {
            Button(title) {
                path = target
            }
            .buttonStyle(.link)
        }
    }

    /// The path one level up: "A/B" → "A", "A" → "".
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else {
            return ""
        }
        // SWIFT: String indices aren't integers (characters vary in size),
        // so slicing uses `String.Index` values like `slash`.
        return String(path[..<slash])
    }
}
