// GraphPanel.swift
//
// The graph canvas for one document (PLAN.md §4.1, region 3): a breadcrumb
// bar showing which graph level is open, and the canvas below it.
//
// Editing (M2a): moving nodes saves their positions (`xpos`/`ypos`), and
// Delete removes the selected nodes, each as one undoable step through
// MaterialXDocument.edit. After every change the level is rebuilt from the
// document, keeping the camera and the selection.
//
// Wiring (M2d): the canvas reports connections and disconnections
// (GraphCanvasController.onConnect/onDisconnect), which DocumentGraph turns
// into document edits, one undo step each. Clicking "+N more inputs"
// expands a node; which nodes are expanded is view state, kept here by
// path, not saved in the document.
//
// Adding nodes (M2e): drop one from the Library tab onto the canvas, or
// press Tab for a search popover under the pointer, or double-click one
// in the library to add it in the middle. Dropping a new wire on empty
// canvas opens the search too, listing only the nodes that can take the
// wire; the node chosen is added there and connected, in one undo step. The new node is placed where it
// was asked for and selected; like a move, adding saves the positions of
// nodes placed by auto-layout, so they stay where they are. An empty
// level shows the canvas, so a document can be built from nothing.
//
// Navigation: double-click a nodegraph to open it; U, or a breadcrumb, to go
// back up. The sidebar opens levels and selects nodes through `level` and
// `focus` (see ContentView).
//
// Swatches (M3c): nodes with an output a swatch can show have one, drawn in
// the background by PreviewKit (SwatchCache, kept by the document). After
// every rebuild the level asks for its swatches again: only those whose
// fingerprint changed (the nodes downstream of an edit) are drawn, and the
// new canvas starts with the ones already drawn. Only nodes on or near the
// screen are drawn, nearest the middle first, and none while zoomed out
// too far to read them; panning and zooming ask for the rest, shortly
// after the camera stops. They use the viewport's light and view
// transform, from the same user defaults as its menus. The bar above the
// canvas hides them, for a more compact graph.
//
// Arranging (M3c): saved positions can make nodes overlap (they are taller
// with swatches than in the editor that saved them); the canvas pushes
// them apart on screen (DocumentGraph.layout), without changing the
// document. The bar's Arrange button lays the whole level out again and
// saves the positions, as one undo step.
//
// Introduces (SWIFT): `@Binding` (a property another view owns),
// `.onChange(of:initial:)`, `ContentUnavailableView`, a `@MainActor` class
// holding view state, closures capturing a binding, `.dropDestination`,
// `.popover` anchored to a point, `.allowsHitTesting`; `Dictionary(uniqueKeysWithValues:)`
// (M3c).

import ColorKit
import GraphKit
import MXKit
import PreviewKit
import SwiftUI
import ViewportKit

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
    /// The MaterialX graph it was built from, for the swatches' fingerprints.
    let source: MXGraph
    /// Every swatch this level shows, with its fingerprint: computed once,
    /// the first time they are asked for.
    var swatchRequests: [SwatchRequest]? = nil

    init(graph: DocumentGraph, source: MXGraph) {
        self.graph = graph
        self.source = source
        self.controller = GraphCanvasController(model: graph.model)
    }

    /// Shows `swatch` on the node at `path`, if it is on this level and
    /// has room for one.
    func show(_ swatch: Swatch, at path: String) {
        guard let id = graph.nodeIndex(forPath: path), graph.model.nodes[id].hasThumbnail else {
            return
        }
        switch swatch {
        case .image(let image):
            controller.thumbnails[id] = .image(image)
        case .failed:
            controller.thumbnails[id] = .unavailable
        }
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

    /// A node to add in the middle of the canvas (a nodedef's name), from
    /// the Library tab. Cleared once added.
    @Binding var nodeToAdd: String?

    /// The nodes showing all their inputs, by path.
    @State private var expandedPaths: Set<String> = []

    /// The node search open on the canvas (Tab, or a wire dropped on empty
    /// canvas): where it points, in view coordinates, and the wire, if any.
    @State private var searchRequest: NodeSearchRequest? = nil

    /// A node to select once the level has been rebuilt: one just added.
    @State private var pendingSelection: String? = nil

    /// Whether nodes show swatches (the bar's toggle), kept between launches.
    @AppStorage("showsNodePreviews") private var showsPreviews: Bool = true

    /// True after Arranging: the rebuilt level is framed, rather than
    /// keeping the camera, because its nodes have all moved.
    @State private var framesAfterRebuild: Bool = false

    /// The swatches asked for when the camera stops moving (see
    /// `cameraMoved`).
    @State private var pendingSwatchRequest: Task<Void, Never>? = nil

    /// The viewport's light and view transform (ViewportPanel's menus):
    /// swatches use the same, so they agree with the viewport.
    @AppStorage("viewportEnvironment") private var environment: ViewportEnvironment = .studio
    @AppStorage("viewportDisplay") private var display: String = ""
    @AppStorage("viewportView") private var view: String = ""

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(path: $levelPath, showsPreviews: $showsPreviews, canPreview: document.swatches != nil,
                          onArrange: level.map { shown in { arrange(shown) } })
            Divider()
            if let level {
                LayerGraphRepresentable(controller: level.controller, thumbnail: nil)
                    // A new canvas view for each level.
                    .id(ObjectIdentifier(level))
                    // SWIFT: `.overlay` draws a view on top of another, the
                    // same size. `.allowsHitTesting(false)` lets clicks go
                    // through it to the canvas.
                    .overlay {
                        if level.graph.model.nodes.isEmpty {
                            Text("Drag nodes here from the Library, or press Tab to add one.")
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
                    // SWIFT: `.dropDestination(for:)` accepts drops of a
                    // Transferable type; `location` is where, in this view's
                    // coordinates (y down, like the canvas's). Returning
                    // true tells the drag source the drop was taken.
                    .dropDestination(for: NodeDefinitionDrag.self) { items, location in
                        guard let item = items.first else {
                            return false
                        }
                        addNode(item.nodeDef, atView: location, in: level)
                        return true
                    }
                    // The node search, pointing at where the node will go.
                    //
                    // SWIFT: `attachmentAnchor: .rect(.rect(r))` anchors the
                    // popover to a rectangle in this view, rather than to
                    // the whole view; here a 1-point one at the pointer.
                    .popover(isPresented: isSearching,
                             attachmentAnchor: .rect(.rect(CGRect(origin: searchRequest?.location ?? .zero,
                                                                  size: CGSize(width: 1, height: 1)))),
                             arrowEdge: .bottom) {
                        NodeSearchPopup(catalog: document.catalog, need: searchRequest.flatMap(need(of:))) { match in
                            if let request = searchRequest {
                                addNode(match.variant.name, atView: request.location, in: level,
                                        connecting: request.wire, port: match.port)
                            }
                            searchRequest = nil
                            level.controller.endNodeSearch()
                        }
                    }
            } else {
                // SWIFT: `ContentUnavailableView` is the standard "nothing to
                // show here" placeholder: an icon, a title, a description.
                ContentUnavailableView(failure == nil ? "No Nodes" : "Can't Show This Graph",
                                       systemImage: "circle.grid.cross",
                                       description: Text(failure ?? "This level of the document has no nodes."))
                    // Fill the panel, so the breadcrumb bar stays at the
                    // top (see BottomPanel).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // SWIFT: `.onChange(of:initial:)` runs the closure when the value
        // changes, and with `initial: true` also when the view first appears.
        .onChange(of: levelPath, initial: true) {
            rebuild()
        }
        // Every change to the document (edit, undo, redo, reading the file
        // again) bumps its revision; show the new state.
        .onChange(of: document.revision) {
            rebuild()
        }
        // Expanding or collapsing a node's inputs is view state, not an
        // edit, but the canvas is built from it all the same. So is showing
        // swatches, which makes nodes taller.
        .onChange(of: expandedPaths) {
            rebuild()
        }
        .onChange(of: showsPreviews) {
            rebuild()
        }
        // Another light or view transform in the viewport: every swatch
        // again, on the same canvas.
        .onChange(of: swatchSettings) {
            if let level {
                requestSwatches(for: level)
            }
        }
        // Panning and zooming bring other nodes near the screen.
        .onChange(of: level?.controller.offset) {
            cameraMoved()
        }
        .onChange(of: level?.controller.zoom) {
            cameraMoved()
        }
        .onChange(of: focus) {
            applyFocus()
        }
        // A node from the Library tab, added in the middle of the canvas.
        .onChange(of: nodeToAdd) {
            guard let nodeDef = nodeToAdd else {
                return
            }
            nodeToAdd = nil
            guard let level else {
                NSSound.beep()
                return
            }
            let size: CGSize = level.controller.viewSize
            addNode(nodeDef, atView: CGPoint(x: size.width / 2, y: size.height / 2), in: level)
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
        // SWIFT: The closure decides each node's `hasThumbnail`. `swatches
        // != nil` is read once here, not for every node.
        let previews: Bool = showsPreviews && document.swatches != nil
        var graph: DocumentGraph = GraphBuilder.build(mxGraph, expanded: expandedPaths) { node in
            previews && SwatchPlan.shaderPath(for: node) != nil
        }
        graph.layout()

        // Rebuilding the level that is already shown (after an edit): keep
        // the camera and, by path, the selection. Opening another level
        // frames it instead.
        let previous: GraphLevel? = level?.graph.graphPath == levelPath ? level : nil

        let newLevel = GraphLevel(graph: graph, source: mxGraph)
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
        newLevel.controller.onNodesMoved = { [weak newLevel] moved in
            guard let newLevel else {
                return
            }
            saveMove(of: moved, in: newLevel)
        }
        newLevel.controller.onDeleteNodes = { [weak newLevel] ids in
            guard let newLevel else {
                return
            }
            delete(ids, in: newLevel)
        }
        newLevel.controller.onConnect = { [weak newLevel] connection in
            guard let newLevel else {
                return
            }
            document.edit(newLevel.graph.undoName(for: connection)) { content in
                try newLevel.graph.connect(connection, in: content)
            }
        }
        newLevel.controller.onDisconnect = { [weak newLevel] inputs in
            guard let newLevel else {
                return
            }
            document.edit(newLevel.graph.undoName(forDisconnecting: inputs)) { content in
                try newLevel.graph.disconnect(inputs, in: content)
            }
        }
        newLevel.controller.onRequestNodeSearch = { request in
            searchRequest = request
        }
        newLevel.controller.onToggleInputs = { [weak newLevel] id in
            guard let newLevel else {
                return
            }
            let path: String = newLevel.graph.elementPaths[id]
            // SWIFT: `remove` returns the element it removed, or nil if it
            // wasn't there; `== nil` then means "it wasn't expanded". The
            // `.onChange(of: expandedPaths)` below rebuilds the canvas.
            if expandedPaths.remove(path) == nil {
                expandedPaths.insert(path)
            }
        }

        if let previous, framesAfterRebuild {
            // Arranged: every node moved, so frame them all, at the same
            // view size, and keep the selection.
            newLevel.controller.viewSize = previous.controller.viewSize
            newLevel.controller.frame(.all)
            let selectedPaths: [String] = previous.controller.selection.map { previous.graph.elementPaths[$0] }
            newLevel.controller.selection = Set(selectedPaths.compactMap { graph.nodeIndex(forPath: $0) })
        } else if let previous {
            newLevel.controller.zoom = previous.controller.zoom
            newLevel.controller.offset = previous.controller.offset
            // The new canvas view sets it too, but only once it is laid
            // out; the swatches asked for below need it now.
            newLevel.controller.viewSize = previous.controller.viewSize
            let selectedPaths: [String] = previous.controller.selection.map { previous.graph.elementPaths[$0] }
            newLevel.controller.selection = Set(selectedPaths.compactMap { graph.nodeIndex(forPath: $0) })
        } else {
            newLevel.controller.frame(.all)
        }
        framesAfterRebuild = false
        if let path = pendingSelection, let index = graph.nodeIndex(forPath: path) {
            newLevel.controller.selection = [index]
        }
        pendingSelection = nil
        requestSwatches(for: newLevel)
        level = newLevel
        failure = nil
        applyFocus()
    }

    /// How swatches look now: the viewport's settings, at twice the
    /// thumbnail's size in points (for Retina screens).
    private var swatchSettings: SwatchSettings {
        SwatchSettings(environmentURL: environment.imageURL,
                       viewTransform: ViewTransform.preferred(display: display, view: view),
                       pixelSize: Int(GraphLayout.thumbnailSize * 2))
    }

    /// Shows the swatches already drawn for `level`'s nodes, and asks for
    /// those near the screen that are missing or out of date.
    private func requestSwatches(for level: GraphLevel) {
        guard let swatches = document.swatches, showsPreviews else {
            return
        }
        let requests: [SwatchRequest]
        if let known = level.swatchRequests {
            requests = known
        } else {
            let customNodeDefs = Set(document.elements.filter { $0.category == "nodedef" }.map(\.name))
            requests = SwatchPlan.requests(for: level.source, in: document.content, documentText: document.xml,
                                           customNodeDefs: customNodeDefs)
            level.swatchRequests = requests
            // A rebuilt canvas starts with the swatches it had (even if
            // about to change), rather than empty discs.
            for request in requests {
                if let swatch = swatches.swatch(for: request.nodePath) {
                    level.show(swatch, at: request.nodePath)
                }
            }
        }

        // Only the nodes near the screen, nearest first; none below the
        // zoom at which titles disappear, where a swatch is a few pixels.
        // SWIFT: `Dictionary(uniqueKeysWithValues:)` builds a dictionary
        // from (key, value) pairs; here, each request by its node's path.
        let byPath = Dictionary(uniqueKeysWithValues: requests.map { ($0.nodePath, $0) })
        let near: [SwatchRequest] = level.controller.nodesNearView(minimumZoom: GraphLayout.titleMinimumZoom)
            .compactMap { byPath[level.graph.elementPaths[$0]] }
        // SWIFT: `[weak level]`: a level replaced by the next edit is gone;
        // swatches arriving for it then have nowhere to go, and the next
        // level gets them from the cache.
        swatches.update(near, xml: document.previewXML, settings: swatchSettings) { [weak level] path, swatch in
            level?.show(swatch, at: path)
        }
    }

    /// Asks for the swatches near the screen once the camera has been
    /// still for a moment: while panning, the nodes passing by needn't
    /// all be drawn.
    private func cameraMoved() {
        pendingSwatchRequest?.cancel()
        // SWIFT: `try? await Task.sleep(for:)` waits without blocking; it
        // throws if the task is cancelled meanwhile (the camera moved
        // again), and the `guard` then gives up.
        pendingSwatchRequest = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let level else {
                return
            }
            requestSwatches(for: level)
        }
    }

    /// Lays the whole level out again (GraphAutoLayout) and saves every
    /// node's position, as one "Arrange" step. Nodes from included files
    /// can't move; the others are arranged around them.
    private func arrange(_ level: GraphLevel) {
        var model: GraphModel = level.controller.model
        GraphAutoLayout.apply(to: &model)
        let positions: [(String, CGPoint)] = model.nodes.filter { !$0.isLocked }.map { node in
            (level.graph.elementPaths[node.id], DocumentGraph.units(fromPoints: node.position))
        }
        guard !positions.isEmpty else {
            return
        }
        framesAfterRebuild = true
        document.edit("Arrange") { content in
            for (path, position) in positions {
                try content.setPosition(position, of: path)
            }
        }
    }

    /// Whether the node search is open, as a binding for `.popover`:
    /// closing it (Escape, a click elsewhere) clears `searchRequest`, and
    /// the canvas stops drawing the dangling wire, if there was one.
    private var isSearching: Binding<Bool> {
        Binding {
            searchRequest != nil
        } set: { isOpen in
            if !isOpen {
                searchRequest = nil
                level?.controller.endNodeSearch()
            }
        }
    }

    /// What a new node needs to take the request's wire: an input of the
    /// wire's type if it comes from an output, and the other way round.
    /// Nil for a search with no wire (Tab).
    private func need(of request: NodeSearchRequest) -> MXConnectionNeed? {
        switch request.wire {
        case .fromOutput(_, let type)?:
            return .input(type.name)
        case .intoInput(_, let type)?:
            return .output(type.name)
        case nil:
            return nil
        }
    }

    /// Adds a node of the nodedef `nodeDef` at `point` (view coordinates),
    /// as one undo step, and selects it. With `wire`, the node goes beside
    /// the wire's end and its `port` is connected to the wire.
    private func addNode(_ nodeDef: String, atView point: CGPoint, in level: GraphLevel,
                         connecting wire: DanglingWire? = nil, port: String? = nil) {
        let position: CGPoint = DocumentGraph.units(fromPoints: level.controller.newNodePosition(atView: point,
                                                                                                 for: wire))
        let positions: [String: CGPoint] = autoLayoutPositions(in: level)
        let parent: String = levelPath
        let definition: MXNodeDefinition? = document.catalog.definition(named: nodeDef)
        let name: String = definition?.node ?? nodeDef
        let graph: DocumentGraph = level.graph
        document.edit("Add \(name)") { content in
            for (path, saved) in positions {
                try content.setPosition(saved, of: path)
            }
            let path: String = try content.addNode(nodeDef: nodeDef, in: parent)
            try content.setPosition(position, of: path)
            if let wire, let port {
                try graph.connect(newNode: path, port: port, outputCount: definition?.outputs.count ?? 1,
                                  to: wire, in: content)
            }
            pendingSelection = path
        }
    }

    /// The positions auto-layout gave the level's nodes that have none in
    /// the document, in MaterialX units, by path. Saved with the first
    /// move or addition, so that later edits don't rearrange them.
    private func autoLayoutPositions(in level: GraphLevel) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        for node in level.controller.model.nodes where !node.isLocked && !level.graph.positioned.contains(node.id) {
            positions[level.graph.elementPaths[node.id]] = DocumentGraph.units(fromPoints: node.position)
        }
        return positions
    }

    /// Saves moved nodes' positions in the document, as one "Move" step.
    ///
    /// The first move in a level whose nodes were placed by auto-layout
    /// also saves every other node's position: otherwise the auto-layout
    /// could rearrange them after the next edit, around the moved ones.
    private func saveMove(of moved: [Int: CGPoint], in level: GraphLevel) {
        let model: GraphModel = level.controller.model
        var positions: [String: CGPoint] = autoLayoutPositions(in: level)
        for id in moved.keys where !model.nodes[id].isLocked {
            positions[level.graph.elementPaths[id]] = DocumentGraph.units(fromPoints: model.nodes[id].position)
        }
        document.edit(moved.count == 1 ? "Move" : "Move \(moved.count) Nodes") { content in
            for (path, position) in positions {
                try content.setPosition(position, of: path)
            }
        }
    }

    /// Deletes nodes from the document, as one step. A nodegraph's own
    /// inputs and outputs (shown at the graph's edges) aren't nodes, and
    /// are left alone.
    private func delete(_ ids: Set<Int>, in level: GraphLevel) {
        let nodes: [GraphNode] = ids.map { level.graph.model.nodes[$0] }.filter { $0.category != .graphInterface }
        guard !nodes.isEmpty else {
            NSSound.beep()
            return
        }
        let name: String = nodes.count == 1 ? "Delete \(nodes[0].title)" : "Delete \(nodes.count) Nodes"
        let paths: [String] = nodes.map { level.graph.elementPaths[$0.id] }
        level.controller.selection = []
        document.edit(name) { content in
            for path in paths {
                try content.removeNode(at: path)
            }
        }
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

/// "Document › NG_brass1": where the canvas is, each part clickable; and
/// the swatches' toggle.
private struct BreadcrumbBar: View {
    @Binding var path: String
    @Binding var showsPreviews: Bool
    /// False when swatches can't be drawn at all: the toggle is disabled.
    let canPreview: Bool
    /// Arranges the level shown; nil when there is none.
    let onArrange: (() -> Void)?

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
            Text("Tab adds a node · Drag between pins to connect · ⌥-drag cuts wires · Double-click a nodegraph to open it · U goes up · A frames all · F frames the selection · Pan: middle-drag or Space-drag · Wheel zooms")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button {
                onArrange?()
            } label: {
                Image(systemName: "rectangle.3.group")
            }
            .buttonStyle(.borderless)
            .disabled(onArrange == nil)
            .help("Arrange: lay out this level's nodes again, in columns, and save their positions")
            // SWIFT: A `Toggle` styled as a button shows as a small button
            // that stays pressed while on, like a toolbar toggle.
            Toggle(isOn: $showsPreviews) {
                Image(systemName: "circle.lefthalf.filled")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .disabled(!canPreview)
            .help(canPreview ? "Show a preview swatch on each node" : "Swatches need a Metal GPU and MaterialX's libraries")
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
