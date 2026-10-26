// GraphCanvasController.swift
//
// The canvas's state and behaviour, independent of how it is drawn: the
// graph, pan and zoom, the selection, and what mouse and trackpad input does.
// Both renderers forward their events here and draw from here, so they
// behave identically.
//
// Coordinates: *graph* coordinates are where nodes live (points at zoom 1,
// y down). *View* coordinates are points in the canvas view (y down, origin
// top-left). `view = graph * zoom + offset`.
//
// Wiring (M2d): drag from an output to an input to connect, or from an
// input to an output; drag a connected input's wire away to disconnect it
// (or drop it on another input to move it); ⌥-drag across wires to cut
// them. While a wire is dragged, what it can't connect to is dimmed
// (GraphWiring.swift has the rules). Dropping a wire on a node rather than
// a row offers that node's compatible inputs, hidden ones included.
//
// Adding nodes (M2e): Tab, or a new wire dropped on empty canvas, asks the
// app for its node search (onRequestNodeSearch). A dropped wire stays
// drawn, dangling, until the app reports the search closed
// (endNodeSearch), having added and connected a node or not.
//
// Introduces (SWIFT): `@Observable` classes, `@MainActor` on a type,
// `Set`, `enum` state machines with associated values, `private(set)`,
// matching several patterns in one `case`, a struct stored in an enum
// case and updated by reassigning the case.

import CoreGraphics
import Observation

/// What is under a point.
public enum GraphHit: Equatable, Sendable {
    case node(Int)
    case output(PortReference)
    case input(PortReference)
    /// The node's "+N more inputs" (or "Fewer inputs") row.
    case inputToggle(Int)
    case empty
}

/// What a wire being dragged would connect to if dropped now.
public enum WireTarget: Equatable, Sendable {
    /// An input row (dragging from an output).
    case input(PortReference)
    /// An output row (dragging from an input).
    case output(PortReference)
    /// A node, but no row: dropping offers its compatible inputs (or
    /// outputs) in a menu, or connects the only one.
    case node(Int)
}

/// The wire being dragged, as drawn: from an output end to an input end,
/// in graph coordinates. One end is a pin, the other the pointer (or the
/// pin it snaps to).
public struct WirePreview: Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint
    /// The type of the pin it was dragged from, for its colour.
    public var type: PortType
}

/// The line of an ⌥-drag that cuts wires, in graph coordinates.
public struct CutLine: Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint
}

/// A menu to show where a wire was dropped on a node with several inputs
/// it could connect to. The view shows it, then calls
/// ``GraphCanvasController/chooseConnection(_:)`` with the choice.
public struct WireMenu: Equatable, Sendable {
    /// Such as "Connect to SR_copper".
    public let title: String
    /// One item per possible connection, in order.
    public let items: [String]
    /// Where to show it, in view coordinates.
    public let location: CGPoint
}

/// A wire dropped on empty canvas, for a new node to connect to (M2e).
public enum DanglingWire: Equatable, Sendable {
    /// Dragged from this output: the new node takes it on an input of
    /// `type`.
    case fromOutput(PortReference, type: PortType)
    /// Dragged from this input: the new node feeds it from an output of
    /// `type`.
    case intoInput(InputSlot, type: PortType)
}

/// A request for the app's node search: Tab, or a wire dropped on empty
/// canvas.
public struct NodeSearchRequest: Equatable, Sendable {
    /// Where to show the search and put the node, in view coordinates.
    public let location: CGPoint
    /// The wire the new node connects to, when the search came from one.
    public let wire: DanglingWire?

    public init(location: CGPoint, wire: DanglingWire? = nil) {
        self.location = location
        self.wire = wire
    }
}

/// Pan, zoom, selection and interaction for one canvas.
///
/// SWIFT: `@Observable` (Swift's Observation framework) makes every stored
/// property observable: a SwiftUI view that reads `zoom` while computing
/// `body` is redrawn when `zoom` changes, with no `@Published` needed. It is
/// the modern replacement for `ObservableObject` (used in ContentView.swift).
///
/// SWIFT: `@MainActor` means every method and property may only be used on
/// the main thread, and the compiler checks every caller. UI state belongs
/// there, and it makes the class safe to share with views without locks.
@MainActor
@Observable
public final class GraphCanvasController {
    /// The graph being shown. Changing node positions changes this.
    public var model: GraphModel

    /// Scale from graph to view coordinates. 1 = 100%.
    public var zoom: CGFloat = 1
    /// Where graph coordinate (0, 0) appears in the view.
    public var offset: CGPoint = CGPoint(x: 40, y: 40)

    /// IDs of the selected nodes.
    public var selection: Set<Int> = []

    /// The marquee rectangle being dragged, in graph coordinates, or nil.
    public private(set) var marquee: CGRect? = nil

    /// The wire being dragged, or nil.
    public private(set) var wirePreview: WirePreview? = nil
    /// While a wire is dragged: what it can connect to. Renderers dim the
    /// rest.
    public private(set) var wireCandidates: WireCandidates? = nil
    /// What the dragged wire would connect to if dropped now, for a
    /// highlight.
    public private(set) var wireTarget: WireTarget? = nil
    /// Wires not to draw: the one being dragged off its input.
    public private(set) var hiddenWires: Set<GraphWire> = []
    /// The ⌥-drag cut line, and the wires it crosses (drawn highlighted).
    public private(set) var cutLine: CutLine? = nil
    public private(set) var cutWires: Set<GraphWire> = []

    /// Bumped whenever node positions change, so renderers that cache
    /// geometry (Core Animation) know to update it.
    ///
    /// SWIFT: `private(set)`: anyone can read it, only this class can write it.
    public private(set) var positionsRevision: Int = 0

    /// Zoom limits: below 10% nothing is legible; above 400% a node fills the screen.
    public static let zoomRange: ClosedRange<CGFloat> = 0.1...4

    /// What a mouse drag is doing, decided on mouse-down.
    ///
    /// SWIFT: An enum as a small state machine; each case carries the data
    /// that state needs, so impossible combinations (dragging nodes *and* a
    /// marquee) can't be represented.
    private enum DragState {
        case idle
        /// Moving the selected nodes; their positions at mouse-down.
        /// `toggle` is the node whose "+N more inputs" row was pressed: if
        /// nothing moves, the click expands (or collapses) it.
        case movingNodes(start: CGPoint, original: [Int: CGPoint], toggle: Int?)
        /// Rubber-band selection from `start`; the selection before it began
        /// (kept when Shift is held).
        case marquee(start: CGPoint, base: Set<Int>)
        /// Dragging a wire from a pin.
        case wiring(WireDrag)
        /// ⌥-dragging a line from `start` to cut the wires it crosses.
        case cutting(start: CGPoint)
        /// A wire was dropped on a node with several inputs (or outputs) it
        /// could connect to; the view is showing a menu of these.
        case choosing([WireConnection])
        /// A new wire was dropped on empty canvas; the app is showing its
        /// node search, and the wire stays drawn until it closes.
        case awaitingNode
    }

    /// A wire drag in progress.
    private struct WireDrag {
        /// The end that stays on its pin: an output when the wire is
        /// looking for an input, an input when it is looking for an output.
        enum Anchor {
            case output(PortReference)
            case input(PortReference)
        }
        var anchor: Anchor
        /// The node whose pin was pressed: a click without dragging selects
        /// it. (Not always the anchor's node: pressing a connected input
        /// picks up the wire by its far end.)
        var pressedNode: Int
        /// The existing wire being pulled off its input, if any.
        var detached: GraphWire?
        /// What the wire can connect to.
        var candidates: WireCandidates
        /// Where the button went down, and where the pointer is now (graph
        /// coordinates).
        var start: CGPoint
        var pointer: CGPoint
        /// False until the pointer has moved a few points: until then, a
        /// release is a click on the pin, which selects its node.
        var moved: Bool = false
    }

    /// How far, in view points, the pointer must move before pressing a
    /// pin becomes dragging a wire.
    private static let dragThreshold: CGFloat = 3

    private var drag: DragState = .idle

    /// Called when a node is double-clicked, with its ID. The app uses it to
    /// step into nodegraphs.
    ///
    /// SWIFT: `@ObservationIgnored` excludes a property of an `@Observable`
    /// class from observation: changing it redraws nothing. Callbacks and
    /// bookkeeping that views never display should be ignored like this.
    @ObservationIgnored public var onOpenNode: (@MainActor (Int) -> Void)? = nil

    /// Called when the user asks to leave the current graph (the U key).
    @ObservationIgnored public var onNavigateUp: (@MainActor () -> Void)? = nil

    /// Called when a drag has moved nodes, with their new positions (graph
    /// coordinates), when the mouse button is released. The app saves them
    /// in the document; the canvas has already moved them.
    @ObservationIgnored public var onNodesMoved: (@MainActor ([Int: CGPoint]) -> Void)? = nil

    /// Called with the IDs of the nodes to delete (see ``deleteSelection()``).
    @ObservationIgnored public var onDeleteNodes: (@MainActor (Set<Int>) -> Void)? = nil

    /// Called when a wire is dropped on an input (or output) it can
    /// connect to. The canvas doesn't change its model: the app makes the
    /// edit and shows the result.
    @ObservationIgnored public var onConnect: (@MainActor (WireConnection) -> Void)? = nil

    /// Called with inputs to disconnect: a wire pulled off its input and
    /// dropped on empty canvas, or wires cut with ⌥-drag.
    @ObservationIgnored public var onDisconnect: (@MainActor ([InputSlot]) -> Void)? = nil

    /// Called when a node's "+N more inputs" row is clicked, with its ID.
    /// The app rebuilds the node with every input shown (or, once
    /// expanded, only the set ones).
    @ObservationIgnored public var onToggleInputs: (@MainActor (Int) -> Void)? = nil

    /// Called when the user asks to add a node (M2e): with Tab (see
    /// ``requestNodeSearch(at:)``), or by dropping a new wire on empty
    /// canvas. The app shows its node search at the request's location,
    /// and calls ``endNodeSearch()`` when it closes.
    @ObservationIgnored public var onRequestNodeSearch: (@MainActor (NodeSearchRequest) -> Void)? = nil

    /// The size of the view showing the canvas, kept up to date by the view.
    /// Framing needs it; until the view has been laid out it is zero.
    @ObservationIgnored public var viewSize: CGSize = .zero {
        didSet {
            // Framing again for the new size: a frame requested before the
            // view had a size, or the last one, if the user hasn't panned or
            // zoomed since. (While a window opens, its views get several
            // sizes in turn; framing only once would use one of the early
            // ones. It also keeps the graph framed while resizing.)
            if viewSize.width > 0, viewSize.height > 0, let request = pendingFrame ?? activeFrame {
                pendingFrame = nil
                frame(request)
            }
        }
    }

    /// What ``frame(_:)`` can fit in the view.
    public enum FrameRequest: Sendable {
        /// The whole graph (the A key).
        case all
        /// The selected nodes (the F key), or everything if none are.
        case selection
    }

    @ObservationIgnored private var pendingFrame: FrameRequest? = nil

    /// The last frame applied, until the user pans or zooms.
    @ObservationIgnored private var activeFrame: FrameRequest? = nil

    public init(model: GraphModel) {
        self.model = model
    }

    // MARK: Coordinates

    public func graphPoint(fromView point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / zoom, y: (point.y - offset.y) / zoom)
    }

    public func viewPoint(fromGraph point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + offset.x, y: point.y * zoom + offset.y)
    }

    /// The part of the graph visible in a view of `size`, in graph coordinates.
    public func visibleGraphRect(viewSize size: CGSize) -> CGRect {
        let origin: CGPoint = graphPoint(fromView: .zero)
        return CGRect(x: origin.x, y: origin.y, width: size.width / zoom, height: size.height / zoom)
    }

    // MARK: Hit testing

    /// What is at `point` (graph coordinates). Pins win over node bodies, and
    /// nodes drawn later (on top) win over earlier ones.
    public func hitTest(_ point: CGPoint) -> GraphHit {
        let pinSlop: CGFloat = GraphLayout.portRadius + 3
        // SWIFT: `reversed()` iterates back to front without copying.
        for node in model.nodes.reversed() {
            let frame: CGRect = GraphLayout.frame(of: node)
            // Quick reject: outside the frame plus the pins sticking out.
            guard frame.insetBy(dx: -pinSlop, dy: 0).contains(point) else {
                continue
            }
            for index in node.outputs.indices {
                if Self.distance(point, GraphLayout.outputPoint(of: node, index: index)) <= pinSlop {
                    return .output(PortReference(node: node.id, index: index))
                }
            }
            for index in node.inputs.indices {
                if Self.distance(point, GraphLayout.inputPoint(of: node, index: index)) <= pinSlop {
                    return .input(PortReference(node: node.id, index: index))
                }
            }
            if let toggle = GraphLayout.inputToggleRowFrame(of: node), toggle.contains(point) {
                return .inputToggle(node.id)
            }
            if frame.contains(point) {
                return .node(node.id)
            }
        }
        return .empty
    }

    /// IDs of the nodes that intersect `rect` (graph coordinates).
    public func nodes(in rect: CGRect) -> Set<Int> {
        var result: Set<Int> = []
        for node in model.nodes where GraphLayout.frame(of: node).intersects(rect) {
            result.insert(node.id)
        }
        return result
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx: CGFloat = a.x - b.x
        let dy: CGFloat = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Mouse and trackpad

    /// Mouse button pressed at `viewPoint`. `extend` is true when Shift is
    /// held, `cut` when Option is (an ⌥-drag cuts wires).
    public func mouseDown(at viewPoint: CGPoint, extend: Bool, cut: Bool = false) {
        let point: CGPoint = graphPoint(fromView: viewPoint)
        // A click while a dropped wire waits for its node: the app's
        // search is closing; don't leave the wire behind.
        if case .awaitingNode = drag {
            endNodeSearch()
        }
        if cut {
            drag = .cutting(start: point)
            cutLine = CutLine(start: point, end: point)
            return
        }

        let hit: GraphHit = hitTest(point)
        // Pins start wires. A locked node's inputs can't be rewired, so
        // pressing one acts like pressing the node.
        switch hit {
        case .output(let port):
            beginWire(.output(port), at: point)
            return
        case .input(let port) where !model.nodes[port.node].isLocked:
            // SWIFT: `case ... where` adds a condition to a pattern; if it
            // is false, the switch tries the next case.
            if let wire = model.wire(into: port) {
                // Pick up the existing wire by its input end.
                beginWire(.output(wire.from), at: point, detaching: wire)
            } else {
                beginWire(.input(port), at: point)
            }
            return
        default:
            break
        }

        // Which node was hit, if any.
        //
        // SWIFT: One `case` can match several patterns if they bind the
        // same names with the same types: `.node(let id)` and
        // `.inputToggle(let id)` both bind an Int called `id`. (Patterns
        // can take enums and tuples apart, not structs, which is why
        // `port.node` is read in the body.)
        let hitNode: Int?
        var toggle: Int? = nil
        switch hit {
        case .node(let id):
            hitNode = id
        case .inputToggle(let id):
            hitNode = id
            toggle = id
        case .output(let port), .input(let port):
            hitNode = port.node
        case .empty:
            hitNode = nil
        }

        // SWIFT: `if let id = hitNode` unwraps the optional into `id` for the
        // first branch only.
        if let id = hitNode {
            if extend {
                // Shift-click toggles.
                if selection.contains(id) {
                    selection.remove(id)
                } else {
                    selection.insert(id)
                }
            } else if !selection.contains(id) {
                selection = [id]
            }
            var original: [Int: CGPoint] = [:]
            // Locked nodes stay where they are.
            for selected in selection where !model.nodes[selected].isLocked {
                original[selected] = model.nodes[selected].position
            }
            drag = .movingNodes(start: point, original: original, toggle: toggle)
        } else {
            if !extend {
                selection = []
            }
            drag = .marquee(start: point, base: selection)
            marquee = CGRect(origin: point, size: .zero)
        }
    }

    /// Mouse moved with the button down.
    public func mouseDragged(to viewPoint: CGPoint) {
        let point: CGPoint = graphPoint(fromView: viewPoint)
        switch drag {
        case .idle, .choosing, .awaitingNode:
            break
        case .movingNodes(let start, let original, _):
            moveNodes(original, by: CGSize(width: point.x - start.x, height: point.y - start.y))
        case .marquee(let start, let base):
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            marquee = rect
            // SWIFT: `union` returns a new Set with the elements of both.
            selection = base.union(nodes(in: rect))
        case .wiring(var wire):
            // SWIFT: `case .wiring(var wire)` binds a mutable *copy* of the
            // struct in the enum. Changing the copy doesn't change `drag`,
            // so it is stored back at the end.
            wire.pointer = point
            if !wire.moved {
                guard Self.distance(point, wire.start) * zoom >= Self.dragThreshold else {
                    return
                }
                // The drag has begun: show what the wire can connect to.
                wire.moved = true
                wireCandidates = wire.candidates
                hiddenWires = wire.detached.map { [$0] } ?? []
            }
            wireTarget = target(at: point, for: wire)
            wirePreview = preview(of: wire, target: wireTarget)
            drag = .wiring(wire)
        case .cutting(let start):
            cutLine = CutLine(start: start, end: point)
            cutWires = model.wires(crossing: start, point)
        }
    }

    /// Mouse button released. Returns a menu for the view to show when a
    /// wire was dropped on a node with several inputs it could connect to;
    /// the view then calls ``chooseConnection(_:)``.
    @discardableResult
    public func mouseUp() -> WireMenu? {
        // SWIFT: `defer` runs when the function returns, whichever way.
        defer {
            marquee = nil
        }
        switch drag {
        case .movingNodes(_, let original, let toggle):
            drag = .idle
            // Report a finished move, once, with the new positions.
            var moved: [Int: CGPoint] = [:]
            for (id, start) in original where model.nodes[id].position != start {
                moved[id] = model.nodes[id].position
            }
            if !moved.isEmpty {
                onNodesMoved?(moved)
            } else if let toggle {
                onToggleInputs?(toggle)
            }
            return nil
        case .wiring(let wire):
            drag = .idle
            return endWire(wire)
        case .cutting:
            drag = .idle
            let inputs: [InputSlot] = cutWires.filter { !model.nodes[$0.to.node].isLocked }.map { model.slot(of: $0.to) }
            cutLine = nil
            cutWires = []
            if !inputs.isEmpty {
                onDisconnect?(inputs)
            }
            return nil
        case .idle, .marquee, .choosing, .awaitingNode:
            if case .marquee = drag {
                drag = .idle
            }
            return nil
        }
    }

    /// The user picked item `index` of the ``WireMenu`` from ``mouseUp()``,
    /// or nil if they dismissed it.
    public func chooseConnection(_ index: Int?) {
        guard case .choosing(let connections) = drag else {
            return
        }
        drag = .idle
        clearWire()
        if let index, connections.indices.contains(index) {
            onConnect?(connections[index])
        }
    }

    /// Asks the app for its node search at `viewPoint`, with no wire to
    /// connect (the Tab key).
    public func requestNodeSearch(at viewPoint: CGPoint) {
        onRequestNodeSearch?(NodeSearchRequest(location: viewPoint))
    }

    /// The app's node search has closed: stops drawing the wire that was
    /// dropped on empty canvas, if any. (The node added, if one was, comes
    /// with the rebuilt model.)
    public func endNodeSearch() {
        if case .awaitingNode = drag {
            drag = .idle
            clearWire()
        }
    }

    /// Escape during a wire drag or a cut: abandons it.
    public func cancelDrag() {
        switch drag {
        case .wiring, .cutting, .choosing, .awaitingNode:
            drag = .idle
            clearWire()
            cutLine = nil
            cutWires = []
        case .idle, .movingNodes, .marquee:
            break
        }
    }

    // MARK: Wiring

    /// Starts dragging a wire from `anchor`, which was pressed at `point`.
    private func beginWire(_ anchor: WireDrag.Anchor, at point: CGPoint, detaching wire: GraphWire? = nil) {
        let candidates: WireCandidates
        switch anchor {
        case .output(let output):
            candidates = model.candidates(from: output)
        case .input(let input):
            candidates = model.candidates(into: input)
        }
        let pressed: Int
        switch anchor {
        case .output(let port), .input(let port):
            pressed = port.node
        }
        drag = .wiring(WireDrag(anchor: anchor, pressedNode: wire?.to.node ?? pressed, detached: wire,
                                candidates: candidates, start: point, pointer: point))
    }

    /// What a wire dropped at `point` would connect to. The topmost node
    /// under the pointer decides: one of its rows that the wire fits, or
    /// the node itself if anything on it does.
    private func target(at point: CGPoint, for wire: WireDrag) -> WireTarget? {
        // As generous as hit testing pins: a row reaches out past the
        // node's edge by the pin's radius and a bit.
        let slop: CGFloat = GraphLayout.portRadius + 3
        for node in model.nodes.reversed() {
            let frame: CGRect = GraphLayout.frame(of: node)
            guard frame.insetBy(dx: -slop, dy: 0).contains(point) else {
                continue
            }
            switch wire.anchor {
            case .output:
                for index in node.inputs.indices
                where GraphLayout.inputRowFrame(of: node, index: index).insetBy(dx: -slop, dy: 0).contains(point) {
                    let input = PortReference(node: node.id, index: index)
                    return wire.candidates.inputs.contains(input) ? .input(input) : nil
                }
                return wire.candidates.inputSlots(on: node).isEmpty ? nil : .node(node.id)
            case .input:
                for index in node.outputs.indices
                where GraphLayout.outputRowFrame(of: node, index: index).insetBy(dx: -slop, dy: 0).contains(point) {
                    let output = PortReference(node: node.id, index: index)
                    return wire.candidates.outputs.contains(output) ? .output(output) : nil
                }
                return wire.candidates.outputRefs(on: node).isEmpty ? nil : .node(node.id)
            }
        }
        return nil
    }

    /// The wire as drawn: from its anchor to the pointer, or to the pin
    /// of the row it would connect to.
    private func preview(of wire: WireDrag, target: WireTarget?) -> WirePreview {
        switch wire.anchor {
        case .output(let output):
            let node: GraphNode = model.nodes[output.node]
            var end: CGPoint = wire.pointer
            if case .input(let input) = target {
                end = GraphLayout.inputPoint(of: model.nodes[input.node], index: input.index)
            }
            return WirePreview(start: GraphLayout.outputPoint(of: node, index: output.index), end: end,
                               type: node.outputs[output.index].type)
        case .input(let input):
            let node: GraphNode = model.nodes[input.node]
            var start: CGPoint = wire.pointer
            if case .output(let output) = target {
                start = GraphLayout.outputPoint(of: model.nodes[output.node], index: output.index)
            }
            return WirePreview(start: start, end: GraphLayout.inputPoint(of: node, index: input.index),
                               type: node.inputs[input.index].type)
        }
    }

    /// Finishes a wire drag: connects, disconnects, asks (returning a
    /// menu), or does nothing.
    private func endWire(_ wire: WireDrag) -> WireMenu? {
        let target: WireTarget? = wireTarget
        guard wire.moved else {
            // A click on a pin selects its node.
            clearWire()
            selection = [wire.pressedNode]
            return nil
        }

        let movedFrom: InputSlot? = wire.detached.map { model.slot(of: $0.to) }
        var connections: [WireConnection] = []
        // SWIFT: Switching on a tuple matches both values at once; each
        // case takes both apart. `target` is optional: `.input(let x)?`
        // matches an optional that holds `.input`, and `nil` one that
        // holds nothing.
        switch (wire.anchor, target) {
        case (.output(let output), .input(let input)?):
            connections = [WireConnection(output: output, input: model.slot(of: input), movedFrom: movedFrom)]
        case (.output(let output), .node(let id)?):
            connections = wire.candidates.inputSlots(on: model.nodes[id]).map {
                WireConnection(output: output, input: $0, movedFrom: movedFrom)
            }
        case (.input(let input), .output(let output)?):
            connections = [WireConnection(output: output, input: model.slot(of: input))]
        case (.input(let input), .node(let id)?):
            connections = wire.candidates.outputRefs(on: model.nodes[id]).map {
                WireConnection(output: $0, input: model.slot(of: input))
            }
        case (_, nil):
            // Dropped on nothing: a wire pulled off its input is removed.
            if let movedFrom {
                clearWire()
                onDisconnect?([movedFrom])
                return nil
            }
            // A new wire: offer to add a node at its end. The wire stays
            // drawn, without the dimming, while the app's search is open.
            if let dangling = danglingWire(for: wire.anchor), let onRequestNodeSearch {
                wireCandidates = nil
                wireTarget = nil
                drag = .awaitingNode
                onRequestNodeSearch(NodeSearchRequest(location: viewPoint(fromGraph: wire.pointer), wire: dangling))
                return nil
            }
            clearWire()
            return nil
        default:
            // A target of the other kind can't happen (target(at:for:)
            // only returns rows on the side the wire is looking for).
            break
        }
        // Dropping a wire where it already is changes nothing.
        connections.removeAll(where: { isUnchanged($0) })

        if connections.count > 1, case .node(let id)? = target {
            // Keep the wire on screen while the menu is up.
            wireCandidates = nil
            drag = .choosing(connections)
            let items: [String] = connections.map { connection in
                switch wire.anchor {
                case .output:
                    return connection.input.name
                case .input:
                    return model.nodes[connection.output.node].outputs[connection.output.index].name
                }
            }
            return WireMenu(title: "Connect to \(model.nodes[id].title)", items: items,
                            location: viewPoint(fromGraph: wire.pointer))
        }
        clearWire()
        if let connection = connections.first {
            onConnect?(connection)
        }
        return nil
    }

    /// The wire from `anchor`, for a new node to connect to. Nil for a
    /// `uniform` input, which no node's output can feed.
    private func danglingWire(for anchor: WireDrag.Anchor) -> DanglingWire? {
        switch anchor {
        case .output(let output):
            return .fromOutput(output, type: model.nodes[output.node].outputs[output.index].type)
        case .input(let input):
            let port: GraphPort = model.nodes[input.node].inputs[input.index]
            return port.isUniform ? nil : .intoInput(model.slot(of: input), type: port.type)
        }
    }

    /// True if `connection` is already in the graph: a wire dropped back
    /// on its own input, or a second wire from the same output to the same
    /// input.
    private func isUnchanged(_ connection: WireConnection) -> Bool {
        if connection.movedFrom == connection.input {
            return true
        }
        return model.wires.contains(where: { wire in
            wire.from == connection.output && model.slot(of: wire.to) == connection.input
        })
    }

    /// Stops showing a wire drag.
    private func clearWire() {
        wirePreview = nil
        wireCandidates = nil
        wireTarget = nil
        hiddenWires = []
    }

    /// Asks the app to delete the selected nodes (the Delete key, or Edit >
    /// Delete). Locked nodes are left out; nothing happens if none remain.
    public func deleteSelection() {
        let deletable: Set<Int> = selection.filter { !model.nodes[$0].isLocked }
        if !deletable.isEmpty {
            onDeleteNodes?(deletable)
        }
    }

    /// Moves the nodes in `original` to their original position plus `delta`.
    public func moveNodes(_ original: [Int: CGPoint], by delta: CGSize) {
        for (id, position) in original {
            model.nodes[id].position = CGPoint(x: position.x + delta.width, y: position.y + delta.height)
        }
        positionsRevision += 1
    }

    /// Two-finger scroll (or mouse wheel): pan by `delta` view points.
    public func scroll(by delta: CGSize) {
        activeFrame = nil
        offset = CGPoint(x: offset.x + delta.width, y: offset.y + delta.height)
    }

    /// Pinch (or ⌥-scroll): zoom by `factor`, keeping the graph point under
    /// `viewPoint` where it is.
    public func zoom(by factor: CGFloat, at viewPoint: CGPoint) {
        activeFrame = nil
        let anchor: CGPoint = graphPoint(fromView: viewPoint)
        let newZoom: CGFloat = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        zoom = newZoom
        // Re-solve the offset so `anchor` maps back to `viewPoint`.
        offset = CGPoint(x: viewPoint.x - anchor.x * newZoom, y: viewPoint.y - anchor.y * newZoom)
    }

    /// Fits the whole graph in a view of `size`, with a margin.
    public func frameAll(viewSize size: CGSize) {
        fit(GraphLayout.bounds(of: model), in: size)
    }

    /// Fits the whole graph or the selection in the view (``viewSize``). If
    /// the view hasn't been laid out yet, this happens as soon as it has.
    public func frame(_ request: FrameRequest) {
        guard viewSize.width > 0, viewSize.height > 0 else {
            pendingFrame = request
            return
        }
        var bounds: CGRect = .null
        if request == .selection {
            for id in selection {
                bounds = bounds.union(GraphLayout.frame(of: model.nodes[id]))
            }
        }
        if bounds.isNull {
            bounds = GraphLayout.bounds(of: model)
        }
        // Don't zoom in past 100% just because one small node is selected.
        fit(bounds, in: viewSize, maximumZoom: 1)
        activeFrame = request
    }

    /// Sets zoom and offset so `bounds` (graph coordinates) fills a view of
    /// `size`, with a margin, centred.
    private func fit(_ bounds: CGRect, in size: CGSize, maximumZoom: CGFloat = zoomRange.upperBound) {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let margin: CGFloat = 40
        let fit: CGFloat = min((size.width - 2 * margin) / bounds.width, (size.height - 2 * margin) / bounds.height)
        zoom = min(max(fit, Self.zoomRange.lowerBound), maximumZoom)
        offset = CGPoint(x: (size.width - bounds.width * zoom) / 2 - bounds.minX * zoom,
                         y: (size.height - bounds.height * zoom) / 2 - bounds.minY * zoom)
    }

    /// Where a new node placed at `viewPoint` goes, in graph coordinates.
    /// (A node's position is its top-left corner.) On its own: its header
    /// centred on the point, as if the user had just picked it up there.
    /// At the end of a wire: beside the point, on the side away from the
    /// wire, so the wire reaches the node's near edge (inputs are on the
    /// left, outputs on the right).
    public func newNodePosition(atView viewPoint: CGPoint, for wire: DanglingWire? = nil) -> CGPoint {
        let point: CGPoint = graphPoint(fromView: viewPoint)
        let y: CGFloat = point.y - GraphLayout.headerHeight / 2
        switch wire {
        case nil:
            return CGPoint(x: point.x - GraphLayout.nodeWidth / 2, y: y)
        case .fromOutput?:
            return CGPoint(x: point.x, y: y)
        case .intoInput?:
            return CGPoint(x: point.x - GraphLayout.nodeWidth, y: y)
        }
    }

    /// A double-click at `viewPoint`: opens the node there, if any.
    public func doubleClick(at viewPoint: CGPoint) {
        switch hitTest(graphPoint(fromView: viewPoint)) {
        case .node(let id):
            onOpenNode?(id)
        case .output(let port), .input(let port):
            onOpenNode?(port.node)
        case .inputToggle:
            // The first click already expanded or collapsed the node.
            break
        case .empty:
            break
        }
    }
}
