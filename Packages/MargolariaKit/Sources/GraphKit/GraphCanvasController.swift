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
// Solo (M3d): ⌥-clicking a node's swatch, or its title bar, or S with the
// node selected, asks the app to show that node alone in the viewport
// (onSoloNode); ⌥-dragging anywhere
// else still cuts wires. The app says which node is soloed (`soloNode`),
// and the renderers outline it.
//
// Adding nodes (M2e): Tab, or a new wire dropped on empty canvas, asks the
// app for its node search (onRequestNodeSearch). A dropped wire stays
// drawn, dangling, until the app reports the search closed
// (endNodeSearch), having added and connected a node or not.
//
// Promoting (M4b): inside a nodegraph, ⌥-dragging an unconnected input to
// the left of its node and dropping it on empty canvas asks the app to
// make it one of the graph's inputs (onPromoteInput). Elsewhere ⌥-drag
// still cuts wires.
//
// Menu commands (M4a): Copy, Cut, Paste, Duplicate, Collapse into
// Nodegraph and Ungroup reach the canvas view through the responder
// chain; the controller says which can apply to the selection, and passes
// them to the app (onCommand).
//
// Backdrops (M4d): Group in Backdrop (⌘G) asks the app for one around the
// selection (onCommand). A backdrop is picked up by its header: clicking
// it selects it (Shift adds it to the selection), dragging moves it with
// the nodes it contains, and its corner grip resizes it. Its body lets
// clicks through, so a marquee can start inside it; a marquee selects the
// backdrops entirely inside it. What a backdrop contains follows the
// nodes: one dragged out of it leaves it, one dropped in it joins it, and
// resizing it takes in or leaves out the nodes its edges pass. Moves,
// resizes and the new contents are reported together when the button is
// released (onMove).
//
// Introduces (SWIFT): `@Observable` classes, `@MainActor` on a type,
// `Set`, `enum` state machines with associated values, `private(set)`,
// matching several patterns in one `case`, a struct stored in an enum
// case and updated by reassigning the case; `formUnion` (M4d).

import CoreGraphics
import Observation

/// What is under a point.
public enum GraphHit: Equatable, Sendable {
    case node(Int)
    case output(PortReference)
    case input(PortReference)
    /// The node's "+N more inputs" (or "Fewer inputs") row.
    case inputToggle(Int)
    /// A backdrop's header (M4d), by its ID.
    case backdrop(Int)
    /// The grip in a backdrop's bottom-right corner, which resizes it.
    case backdropGrip(Int)
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

/// What a node's thumbnail shows (M3c). The app draws swatches in the
/// background and sets them in ``GraphCanvasController/thumbnails`` as
/// they arrive; until then a node shows an empty disc.
public enum NodeThumbnail {
    /// The swatch, transparent around the sphere.
    case image(CGImage)
    /// No swatch can be drawn for this node (its shader failed to generate
    /// or compile); the app says why elsewhere (the inspector).
    case unavailable
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

/// A command on the canvas's selection, from the Edit and Graph menus
/// (M4a). The canvas only passes it on; the app does it.
public enum GraphCommand: Sendable {
    /// Edit > Copy, Cut, Paste and Duplicate.
    case copy, cut, paste, duplicate
    /// Graph > Collapse into Nodegraph (⌥⌘G) and Ungroup Nodegraph.
    case collapse, ungroup
    /// Graph > Group in Backdrop (⌘G, M4d): a backdrop around the selected
    /// nodes, or an empty one under the pointer.
    case backdrop
}

/// A command to do, with the nodes it applies to and where the pointer is.
public struct GraphCommandRequest: Sendable {
    public let command: GraphCommand
    /// The selected nodes; locked ones are left out of those that change
    /// the graph (cut, collapse, ungroup). To copy, cut or duplicate,
    /// the selected backdrops' contents too, as they move with them.
    public let nodes: Set<Int>
    /// The selected backdrops to copy, cut or duplicate (M7b); empty for
    /// the other commands.
    public let backdrops: Set<Int>
    /// Where pasted nodes go, in view coordinates: the pointer, or the
    /// middle of the view when the pointer is elsewhere (on the menu bar).
    public let location: CGPoint

    public init(command: GraphCommand, nodes: Set<Int>, backdrops: Set<Int> = [], location: CGPoint) {
        self.command = command
        self.nodes = nodes
        self.backdrops = backdrops
        self.location = location
    }
}

/// What a drag moved or resized (M4d), reported once, when the button is
/// released: new positions and frames (graph coordinates), and what the
/// backdrops whose contents changed now contain.
public struct GraphMove: Equatable, Sendable {
    /// Moved nodes' new positions, by ID.
    public var nodes: [Int: CGPoint] = [:]
    /// Moved or resized backdrops' new frames, by ID.
    public var backdrops: [Int: CGRect] = [:]
    /// The new contents of the backdrops nodes left or joined, by ID.
    public var contents: [Int: Set<Int>] = [:]

    public init(nodes: [Int: CGPoint] = [:], backdrops: [Int: CGRect] = [:], contents: [Int: Set<Int>] = [:]) {
        self.nodes = nodes
        self.backdrops = backdrops
        self.contents = contents
    }
}

/// What Delete removes: nodes and backdrops, by ID, none of them locked.
/// Deleting a backdrop leaves what it contains.
public struct GraphDeletion: Equatable, Sendable {
    public var nodes: Set<Int>
    public var backdrops: Set<Int>

    public init(nodes: Set<Int>, backdrops: Set<Int> = []) {
        self.nodes = nodes
        self.backdrops = backdrops
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
    /// IDs of the selected backdrops (M4d). Selected with nodes or alone;
    /// moving any of the selection moves them all.
    public var backdropSelection: Set<Int> = []

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

    /// The node shown alone in the viewport (M3d), if it is on this level.
    public var soloNode: Int? = nil

    /// Each node's swatch, by node ID, for the nodes that have a thumbnail
    /// (``GraphNode/hasThumbnail``). Nodes not in it show an empty disc.
    public var thumbnails: [Int: NodeThumbnail] = [:]

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
        /// Moving the selected nodes and backdrops, and what the backdrops
        /// contain; their positions and frames at mouse-down. `toggle` is
        /// the node whose "+N more inputs" row was pressed: if nothing
        /// moves, the click expands (or collapses) it.
        case movingNodes(start: CGPoint, original: [Int: CGPoint], backdrops: [Int: CGRect], toggle: Int?)
        /// Rubber-band selection from `start`; the selection before it began
        /// (kept when Shift is held), of nodes and of backdrops.
        case marquee(start: CGPoint, base: Set<Int>, baseBackdrops: Set<Int>)
        /// Dragging a backdrop's grip (M4d); its frame at mouse-down.
        case resizingBackdrop(Int, start: CGPoint, original: CGRect)
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
        /// ⌥-dragging an unconnected input towards the graph's edge, to
        /// promote it (M4b); where the pointer is.
        case promoting(input: PortReference, pointer: CGPoint)
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

    /// True if the node with this ID opens (``onOpenNode`` does
    /// something for it), for enabling Graph > Open Nodegraph (M7g). Nil:
    /// any node may.
    @ObservationIgnored public var canOpenNode: (@MainActor (Int) -> Bool)? = nil

    /// Called when the user asks to leave the current graph (the U key).
    /// Nil at the top level, where there is nowhere to go.
    @ObservationIgnored public var onNavigateUp: (@MainActor () -> Void)? = nil

    /// Called for Graph > Arrange (the L key, M7g): the app lays the level
    /// out again, as its Arrange button does. Nil when it can't.
    @ObservationIgnored public var onArrange: (@MainActor () -> Void)? = nil

    /// Called when a drag has moved nodes or backdrops, or resized a
    /// backdrop, when the mouse button is released (see ``GraphMove``).
    /// The app saves it in the document; the canvas has already moved them.
    @ObservationIgnored public var onMove: (@MainActor (GraphMove) -> Void)? = nil

    /// Called with the nodes and backdrops to delete (see ``deleteSelection()``).
    @ObservationIgnored public var onDelete: (@MainActor (GraphDeletion) -> Void)? = nil

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
    /// Called on ⌥-click on a node's swatch or title bar: show it alone in
    /// the viewport, or stop if it already is (M3d).
    @ObservationIgnored public var onSoloNode: (@MainActor (Int) -> Void)? = nil

    /// Called with a menu command on the selection (M4a, see
    /// ``perform(_:at:)``).
    @ObservationIgnored public var onCommand: (@MainActor (GraphCommandRequest) -> Void)? = nil

    /// Called when an input is ⌥-dragged out to the left of its node and
    /// dropped on empty canvas: make it one of the nodegraph's inputs
    /// (M4b). Nil where that can't be done (the document's top level):
    /// ⌥-dragging from a pin then cuts wires, as elsewhere.
    @ObservationIgnored public var onPromoteInput: (@MainActor (InputSlot) -> Void)? = nil

    /// Asked whether Paste has anything to paste (the pasteboard is the
    /// app's business). Nil: it always has.
    @ObservationIgnored public var canPaste: (@MainActor () -> Bool)? = nil

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
        /// The whole graph, but not so small that port names and values
        /// aren't drawn (M7b): for a level just opened or arranged. In a
        /// narrow canvas (the viewport and inspector open), a graph that
        /// doesn't fit at that zoom starts at its left edge, where its
        /// inputs and first nodes are, and goes on out of view to the
        /// right, rather than being shown unreadably small; A shows it all.
        case readable
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

    /// The nodes on screen or within half a screen of it, nearest the
    /// middle of the view first: the ones whose swatches to draw (M3c).
    /// Empty before the view has a size, or below `minimumZoom`.
    public func nodesNearView(minimumZoom: CGFloat = 0) -> [Int] {
        guard viewSize.width > 0, viewSize.height > 0, zoom >= minimumZoom else {
            return []
        }
        let visible: CGRect = visibleGraphRect(viewSize: viewSize)
        let near: CGRect = visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 2)
        let centre = CGPoint(x: visible.midX, y: visible.midY)
        // SWIFT: `filter` then `sorted(by:)` on the result; `hypot` is C's
        // distance function.
        let distance: (Int) -> CGFloat = { id in
            let frame: CGRect = GraphLayout.frame(of: self.model.nodes[id])
            return hypot(frame.midX - centre.x, frame.midY - centre.y)
        }
        return model.nodes.indices
            .filter { GraphLayout.frame(of: model.nodes[$0]).intersects(near) }
            .sorted { distance($0) < distance($1) }
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
        // Backdrops are under the nodes, and only their header and grip
        // can be picked up.
        for backdrop in model.backdrops.reversed() {
            if GraphLayout.backdropGripFrame(of: backdrop).contains(point) {
                return .backdropGrip(backdrop.id)
            }
            if GraphLayout.backdropHeaderFrame(of: backdrop).contains(point) {
                return .backdrop(backdrop.id)
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

    /// IDs of the backdrops entirely inside `rect`: a marquee over part of
    /// a big backdrop selects the nodes in it, not the backdrop.
    public func backdrops(inside rect: CGRect) -> Set<Int> {
        Set(model.backdrops.filter { rect.contains($0.frame) }.map(\.id))
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
        // ⌥ on a node's swatch or title bar solos it; elsewhere it cuts.
        if cut, case .node(let id) = hitTest(point), Self.isSoloSpot(point, of: model.nodes[id]) {
            onSoloNode?(id)
            return
        }
        // ⌥ on an unconnected input, inside a nodegraph: drag it to the
        // graph's edge to promote it (M4b).
        if cut, onPromoteInput != nil, case .input(let port) = hitTest(point), !model.nodes[port.node].isLocked,
           model.nodes[port.node].category != .graphInterface, model.wire(into: port) == nil {
            drag = .promoting(input: port, pointer: point)
            return
        }
        if cut {
            drag = .cutting(start: point)
            cutLine = CutLine(start: point, end: point)
            return
        }

        let hit: GraphHit = hitTest(point)
        // Pins start wires. A locked node's inputs can't be rewired, nor
        // can wires start at a top-level <output> (M7b), so pressing one
        // acts like pressing the node.
        switch hit {
        case .output(let port) where model.nodes[port.node].outputs[port.index].startsWires:
            beginWire(.output(port), at: point)
            return
        case .input(let port) where !model.nodes[port.node].isLocked:
            // SWIFT: `case ... where` adds a condition to a pattern; if it
            // is false, the switch tries the next case.
            if let wire = model.wire(into: port), model.nodes[wire.from.node].outputs[wire.from.index].startsWires {
                // Pick up the existing wire by its input end.
                beginWire(.output(wire.from), at: point, detaching: wire)
            } else {
                beginWire(.input(port), at: point)
            }
            return
        default:
            break
        }

        // A backdrop's grip resizes it, alone; its header selects it, and
        // moves it with the rest of the selection (M4d).
        switch hit {
        case .backdropGrip(let id) where !model.backdrops[id].isLocked:
            backdropSelection = [id]
            selection = []
            drag = .resizingBackdrop(id, start: point, original: model.backdrops[id].frame)
            return
        case .backdrop(let id), .backdropGrip(let id):
            if extend {
                if backdropSelection.remove(id) == nil {
                    backdropSelection.insert(id)
                }
            } else if !backdropSelection.contains(id) {
                backdropSelection = [id]
                selection = []
            }
            drag = movingSelection(from: point, toggle: nil)
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
        case .empty, .backdrop, .backdropGrip:
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
                backdropSelection = []
            }
            drag = movingSelection(from: point, toggle: toggle)
        } else {
            if !extend {
                selection = []
                backdropSelection = []
            }
            drag = .marquee(start: point, base: selection, baseBackdrops: backdropSelection)
            marquee = CGRect(origin: point, size: .zero)
        }
    }

    /// A drag from `point` moving the selection: the selected nodes, the
    /// selected backdrops and what they contain. Locked ones stay where
    /// they are.
    private func movingSelection(from point: CGPoint, toggle: Int?) -> DragState {
        var nodes: Set<Int> = selection
        var backdrops: [Int: CGRect] = [:]
        for id in backdropSelection where !model.backdrops[id].isLocked {
            backdrops[id] = model.backdrops[id].frame
            // SWIFT: `formUnion` adds another set's elements in place;
            // `union` would return a new set.
            nodes.formUnion(model.backdrops[id].contents)
        }
        var original: [Int: CGPoint] = [:]
        for id in nodes where !model.nodes[id].isLocked {
            original[id] = model.nodes[id].position
        }
        return .movingNodes(start: point, original: original, backdrops: backdrops, toggle: toggle)
    }

    /// Mouse moved with the button down.
    public func mouseDragged(to viewPoint: CGPoint) {
        let point: CGPoint = graphPoint(fromView: viewPoint)
        switch drag {
        case .idle, .choosing, .awaitingNode:
            break
        case .movingNodes(let start, let original, let backdrops, _):
            let delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            for (id, frame) in backdrops {
                model.backdrops[id].frame = frame.offsetBy(dx: delta.width, dy: delta.height)
            }
            moveNodes(original, by: delta)
        case .marquee(let start, let base, let baseBackdrops):
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            marquee = rect
            // SWIFT: `union` returns a new Set with the elements of both.
            selection = base.union(nodes(in: rect))
            backdropSelection = baseBackdrops.union(backdrops(inside: rect))
        case .resizingBackdrop(let id, let start, let original):
            let minimum: CGSize = GraphLayout.backdropMinimumSize
            model.backdrops[id].frame.size = CGSize(width: max(minimum.width, original.width + point.x - start.x),
                                                    height: max(minimum.height, original.height + point.y - start.y))
            positionsRevision += 1
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
        case .promoting(let input, _):
            // A wire from the pointer into the input, as if from the
            // graph input it will become.
            let node: GraphNode = model.nodes[input.node]
            wirePreview = WirePreview(start: point, end: GraphLayout.inputPoint(of: node, index: input.index),
                                      type: node.inputs[input.index].type)
            drag = .promoting(input: input, pointer: point)
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
        case .movingNodes(_, let original, let backdrops, let toggle):
            drag = .idle
            // Report a finished move, once, with the new positions.
            var move = GraphMove()
            for (id, start) in original where model.nodes[id].position != start {
                move.nodes[id] = model.nodes[id].position
            }
            for (id, start) in backdrops where model.backdrops[id].frame != start {
                move.backdrops[id] = model.backdrops[id].frame
            }
            if !move.nodes.isEmpty || !move.backdrops.isEmpty {
                move.contents = contents(afterMoving: original, with: Set(backdrops.keys))
                onMove?(move)
            } else if let toggle {
                onToggleInputs?(toggle)
            }
            return nil
        case .resizingBackdrop(let id, _, let original):
            drag = .idle
            let frame: CGRect = model.backdrops[id].frame
            if frame != original {
                var move = GraphMove(backdrops: [id: frame])
                if let contents = contents(of: id, resizedFrom: original) {
                    move.contents[id] = contents
                }
                onMove?(move)
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
        case .promoting(let input, let pointer):
            drag = .idle
            wirePreview = nil
            // Dropped on empty canvas, on the left of its node: towards the
            // graph's inputs.
            let frame: CGRect = GraphLayout.frame(of: model.nodes[input.node])
            if hitTest(pointer) == .empty, pointer.x < frame.minX {
                onPromoteInput?(model.slot(of: input))
            }
            return nil
        case .idle, .marquee, .choosing, .awaitingNode:
            if case .marquee = drag {
                drag = .idle
            }
            return nil
        }
    }

    /// What the backdrops that didn't move contain after the nodes in
    /// `original` moved (from those positions) with the backdrops
    /// `moving`: a node whose middle is now inside one is in it, a node
    /// dragged out of one isn't. Only the changed backdrops are returned,
    /// and the model is updated. (A node a file puts in a backdrop it
    /// isn't drawn in stays in it until it is dragged in and out.)
    private func contents(afterMoving original: [Int: CGPoint], with moving: Set<Int>) -> [Int: Set<Int>] {
        var changed: [Int: Set<Int>] = [:]
        for backdrop in model.backdrops where !backdrop.isLocked && !moving.contains(backdrop.id) {
            var contents: Set<Int> = backdrop.contents
            for (id, start) in original {
                var before: GraphNode = model.nodes[id]
                before.position = start
                if backdrop.frame.contains(GraphLayout.centre(of: model.nodes[id])) {
                    contents.insert(id)
                } else if backdrop.frame.contains(GraphLayout.centre(of: before)) {
                    contents.remove(id)
                }
            }
            if contents != backdrop.contents {
                model.backdrops[backdrop.id].contents = contents
                changed[backdrop.id] = contents
            }
        }
        return changed
    }

    /// What the backdrop `id` contains after being resized from `original`:
    /// the nodes its edges passed over are taken in or left out. Nil if
    /// that is nothing; otherwise the model is updated.
    private func contents(of id: Int, resizedFrom original: CGRect) -> Set<Int>? {
        let frame: CGRect = model.backdrops[id].frame
        var contents: Set<Int> = model.backdrops[id].contents
        for node in model.nodes {
            let centre: CGPoint = GraphLayout.centre(of: node)
            if frame.contains(centre), !original.contains(centre) {
                contents.insert(node.id)
            } else if original.contains(centre), !frame.contains(centre) {
                contents.remove(node.id)
            }
        }
        guard contents != model.backdrops[id].contents else {
            return nil
        }
        model.backdrops[id].contents = contents
        return contents
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
        case .wiring, .cutting, .choosing, .awaitingNode, .promoting:
            drag = .idle
            clearWire()
            cutLine = nil
            cutWires = []
        case .idle, .movingNodes, .marquee, .resizingBackdrop:
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

    /// The selected nodes and backdrops Delete would remove: those that
    /// aren't locked.
    public var deletableSelection: GraphDeletion {
        GraphDeletion(nodes: selection.filter { !model.nodes[$0].isLocked },
                      backdrops: backdropSelection.filter { !model.backdrops[$0].isLocked })
    }

    /// Asks the app to delete the selected nodes and backdrops (the Delete
    /// key, or Edit > Delete). Locked ones are left out; nothing happens if
    /// none remain.
    public func deleteSelection() {
        let deletable: GraphDeletion = deletableSelection
        if !deletable.nodes.isEmpty || !deletable.backdrops.isEmpty {
            onDelete?(deletable)
        }
    }

    /// The selected nodes `command` applies to: all of them to copy, the
    /// ones that aren't locked to change the graph; none if the command
    /// can't apply (Ungroup needs exactly one nodegraph). Copying, cutting
    /// and duplicating take the selected backdrops' contents too (M7b).
    private func nodes(for command: GraphCommand) -> Set<Int> {
        // SWIFT: `reduce(into:)` with `formUnion` gathers every selected
        // backdrop's contents into one set.
        let framed: Set<Int> = backdrops(for: command).reduce(into: []) { $0.formUnion(model.backdrops[$1].contents) }
        let unlocked: Set<Int> = selection.filter { !model.nodes[$0].isLocked }
        switch command {
        case .copy, .duplicate:
            return selection.union(framed)
        case .backdrop:
            return selection
        case .cut:
            return unlocked.union(framed.filter { !model.nodes[$0].isLocked })
        case .collapse:
            return unlocked
        case .ungroup:
            return unlocked.count == 1 && unlocked.allSatisfy { model.nodes[$0].category == .nodeGraph } ? unlocked : []
        case .paste:
            return []
        }
    }

    /// The selected backdrops `command` applies to (M7b): all of them to
    /// copy or duplicate, the ones that aren't locked to cut.
    private func backdrops(for command: GraphCommand) -> Set<Int> {
        switch command {
        case .copy, .duplicate:
            return backdropSelection
        case .cut:
            return backdropSelection.filter { !model.backdrops[$0].isLocked }
        case .paste, .collapse, .ungroup, .backdrop:
            return []
        }
    }

    /// True if `command` can be done now: there are nodes (or backdrops)
    /// for it, or, for Paste, something to paste. Menus are enabled by
    /// this.
    public func canPerform(_ command: GraphCommand) -> Bool {
        if command == .paste {
            return canPaste?() ?? true
        }
        // With nothing selected, an empty backdrop under the pointer.
        if command == .backdrop {
            return true
        }
        return !nodes(for: command).isEmpty || !backdrops(for: command).isEmpty
    }

    /// Asks the app to do `command` (see ``onCommand``), with the pointer
    /// at `viewPoint`. Returns false, doing nothing, if it can't be done.
    @discardableResult
    public func perform(_ command: GraphCommand, at viewPoint: CGPoint) -> Bool {
        guard canPerform(command) else {
            return false
        }
        onCommand?(GraphCommandRequest(command: command, nodes: nodes(for: command), backdrops: backdrops(for: command),
                                       location: viewPoint))
        return true
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
        var bounds: CGRect = request == .selection ? selectionBounds : .null
        if bounds.isNull {
            bounds = GraphLayout.bounds(of: model)
        }
        // Don't zoom in past 100% just because one small node is selected.
        fit(bounds, in: viewSize, minimumZoom: request == .readable ? GraphLayout.portLabelMinimumZoom : Self.zoomRange.lowerBound,
            maximumZoom: 1, fromLeft: request == .readable)
        activeFrame = request
    }

    /// Frames the selection only if some of it is out of view (M7b): what
    /// is selected from elsewhere (the XML tab's caret, an issue) is shown
    /// without the canvas moving when it is already on screen.
    public func reveal() {
        let bounds: CGRect = selectionBounds
        if viewSize.width > 0, viewSize.height > 0, !bounds.isNull, visibleGraphRect(viewSize: viewSize).contains(bounds) {
            return
        }
        frame(.selection)
    }

    /// The selected nodes and backdrops' frames together; null when
    /// nothing is selected.
    private var selectionBounds: CGRect {
        var bounds: CGRect = .null
        for id in selection {
            bounds = bounds.union(GraphLayout.frame(of: model.nodes[id]))
        }
        for id in backdropSelection {
            bounds = bounds.union(model.backdrops[id].frame)
        }
        return bounds
    }

    /// Sets zoom and offset so `bounds` (graph coordinates) fills a view of
    /// `size`, with a margin, centred; at no less than `minimumZoom`. When
    /// it is then wider than the view, it is centred too, or, with
    /// `fromLeft`, starts at the view's left margin.
    private func fit(_ bounds: CGRect, in size: CGSize, minimumZoom: CGFloat = zoomRange.lowerBound,
                     maximumZoom: CGFloat = zoomRange.upperBound, fromLeft: Bool = false) {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let margin: CGFloat = 40
        let fit: CGFloat = min((size.width - 2 * margin) / bounds.width, (size.height - 2 * margin) / bounds.height)
        zoom = min(max(fit, minimumZoom), maximumZoom)
        offset = CGPoint(x: (size.width - bounds.width * zoom) / 2 - bounds.minX * zoom,
                         y: (size.height - bounds.height * zoom) / 2 - bounds.minY * zoom)
        if fromLeft && bounds.width * zoom > size.width - 2 * margin {
            offset.x = margin - bounds.minX * zoom
        }
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

    /// Solos the selected node, or stops soloing it, as an ⌥-click on it
    /// does (the S key). Returns false, doing nothing, unless exactly one
    /// node is selected.
    @discardableResult
    public func soloSelection() -> Bool {
        guard selection.count == 1, let id = selection.first else {
            return false
        }
        onSoloNode?(id)
        return true
    }

    /// True if exactly one node is selected, and it opens (canOpenNode).
    public var canOpenSelection: Bool {
        guard selection.count == 1, let id = selection.first else {
            return false
        }
        return canOpenNode?(id) ?? true
    }

    /// Opens the selected node, as a double-click on it does (the Return
    /// key, M7g). Returns false, doing nothing, unless canOpenSelection.
    @discardableResult
    public func openSelection() -> Bool {
        guard canOpenSelection, let id = selection.first else {
            return false
        }
        onOpenNode?(id)
        return true
    }

    /// True if an ⌥-click at `point` (graph coordinates) on `node` solos
    /// it: on its swatch, or on its title bar.
    static func isSoloSpot(_ point: CGPoint, of node: GraphNode) -> Bool {
        let frame: CGRect = GraphLayout.frame(of: node)
        let header = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: GraphLayout.headerHeight)
        return header.contains(point) || (node.hasThumbnail && GraphLayout.thumbnailFrame(of: node).contains(point))
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
        case .backdrop, .backdropGrip, .empty:
            break
        }
    }
}
