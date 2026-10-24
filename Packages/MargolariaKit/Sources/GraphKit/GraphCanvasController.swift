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
// Introduces (SWIFT): `@Observable` classes, `@MainActor` on a type,
// `Set`, `enum` state machines with associated values, `private(set)`,
// matching several patterns in one `case`.

import CoreGraphics
import Observation

/// What is under a point.
public enum GraphHit: Equatable, Sendable {
    case node(Int)
    case output(PortReference)
    case input(PortReference)
    case empty
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
        case movingNodes(start: CGPoint, original: [Int: CGPoint])
        /// Rubber-band selection from `start`; the selection before it began
        /// (kept when Shift is held).
        case marquee(start: CGPoint, base: Set<Int>)
    }

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

    /// Mouse button pressed at `viewPoint`. `extend` is true when Shift is held.
    public func mouseDown(at viewPoint: CGPoint, extend: Bool) {
        let point: CGPoint = graphPoint(fromView: viewPoint)
        // Which node was hit, if any. Pins count as their node in this
        // spike; dragging wires from pins comes with editing (M2).
        //
        // SWIFT: One `case` can match several patterns if they bind the
        // same names with the same types: here `.output(let port)` and
        // `.input(let port)` both bind a PortReference called `port`.
        // (Patterns can take enums and tuples apart, not structs, which is
        // why `port.node` is read in the body.)
        let hitNode: Int?
        switch hitTest(point) {
        case .node(let id):
            hitNode = id
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
            drag = .movingNodes(start: point, original: original)
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
        case .idle:
            break
        case .movingNodes(let start, let original):
            moveNodes(original, by: CGSize(width: point.x - start.x, height: point.y - start.y))
        case .marquee(let start, let base):
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            marquee = rect
            // SWIFT: `union` returns a new Set with the elements of both.
            selection = base.union(nodes(in: rect))
        }
    }

    /// Mouse button released.
    public func mouseUp() {
        // Report a finished move, once, with the new positions.
        if case .movingNodes(_, let original) = drag {
            var moved: [Int: CGPoint] = [:]
            for (id, start) in original where model.nodes[id].position != start {
                moved[id] = model.nodes[id].position
            }
            if !moved.isEmpty {
                onNodesMoved?(moved)
            }
        }
        drag = .idle
        marquee = nil
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

    /// A double-click at `viewPoint`: opens the node there, if any.
    public func doubleClick(at viewPoint: CGPoint) {
        switch hitTest(graphPoint(fromView: viewPoint)) {
        case .node(let id):
            onOpenNode?(id)
        case .output(let port), .input(let port):
            onOpenNode?(port.node)
        case .empty:
            break
        }
    }
}
