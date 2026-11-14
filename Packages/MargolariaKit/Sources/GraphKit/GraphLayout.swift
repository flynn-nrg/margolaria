// GraphLayout.swift
//
// Where things are on the canvas, in graph coordinates: node frames, port
// positions, wire curves and backdrops (M4d). Both renderers (Canvas and Core Animation) and
// hit testing use these functions, so they always agree. Also the canvas's
// colours, dark and light (GraphPalette, light since M7b).
//
// Node anatomy (PLAN.md §4.1), top to bottom:
//
//   ┌──────────────────────┐
//   │ header (category)    │  headerHeight
//   │   ┌──────────────┐   │
//   │   │  thumbnail   │   │  thumbnailSize (if hasThumbnail)
//   │   └──────────────┘   │
//   │               out ●  │  one row per output
//   │ ● in    0.5          │  one row per input (value if unconnected)
//   │   +3 more inputs     │  if some inputs are collapsed ("Fewer
//   │                      │  inputs" once expanded)
//   └──────────────────────┘
//
// Introduces (SWIFT): `enum` as a namespace for constants and static
// functions, `CGPath`/`CGMutablePath`, `extension` on a type from another
// module.

import CoreGraphics

/// Fixed sizes and geometry functions for the canvas.
public enum GraphLayout {
    /// Wide enough for "specular_roughness" and a colour value side by side.
    public static let nodeWidth: CGFloat = 220
    public static let headerHeight: CGFloat = 24
    public static let thumbnailSize: CGFloat = 96
    public static let rowHeight: CGFloat = 20
    public static let bottomPadding: CGFloat = 6
    public static let cornerRadius: CGFloat = 6
    public static let portRadius: CGFloat = 5

    /// The node's frame (position and size), in graph coordinates.
    public static func frame(of node: GraphNode) -> CGRect {
        let thumbnail: CGFloat = node.hasThumbnail ? thumbnailSize + 8 : 0
        let rows: CGFloat = CGFloat(rowCount(of: node))
        let height: CGFloat = headerHeight + thumbnail + rows * rowHeight + bottomPadding
        return CGRect(x: node.position.x, y: node.position.y, width: nodeWidth, height: height)
    }

    /// The thumbnail's frame inside the node, in graph coordinates.
    public static func thumbnailFrame(of node: GraphNode) -> CGRect {
        CGRect(x: node.position.x + (nodeWidth - thumbnailSize) / 2,
               y: node.position.y + headerHeight + 4,
               width: thumbnailSize, height: thumbnailSize)
    }

    /// How many rows a node has: outputs, inputs, and the "+N more" row.
    static func rowCount(of node: GraphNode) -> Int {
        node.outputs.count + node.inputs.count + (node.hasInputToggle ? 1 : 0)
    }

    /// The vertical centre of the "+N more inputs" row (the last row).
    public static func inputToggleRowCentre(of node: GraphNode) -> CGFloat {
        rowCentre(of: node, row: node.outputs.count + node.inputs.count)
    }

    /// The full width of output `index`'s row, in graph coordinates.
    public static func outputRowFrame(of node: GraphNode, index: Int) -> CGRect {
        rowFrame(of: node, row: index)
    }

    /// The full width of input `index`'s row.
    public static func inputRowFrame(of node: GraphNode, index: Int) -> CGRect {
        rowFrame(of: node, row: node.outputs.count + index)
    }

    /// The "+N more inputs" row, if the node has one.
    public static func inputToggleRowFrame(of node: GraphNode) -> CGRect? {
        node.hasInputToggle ? rowFrame(of: node, row: node.outputs.count + node.inputs.count) : nil
    }

    static func rowFrame(of node: GraphNode, row: Int) -> CGRect {
        CGRect(x: node.position.x, y: rowCentre(of: node, row: row) - rowHeight / 2,
               width: nodeWidth, height: rowHeight)
    }

    /// The vertical centre of row `row` (outputs first, then inputs).
    static func rowCentre(of node: GraphNode, row: Int) -> CGFloat {
        let thumbnail: CGFloat = node.hasThumbnail ? thumbnailSize + 8 : 0
        return node.position.y + headerHeight + thumbnail + (CGFloat(row) + 0.5) * rowHeight
    }

    /// The centre of output `index`'s pin, on the node's right edge.
    public static func outputPoint(of node: GraphNode, index: Int) -> CGPoint {
        CGPoint(x: node.position.x + nodeWidth, y: rowCentre(of: node, row: index))
    }

    /// The centre of input `index`'s pin, on the node's left edge.
    public static func inputPoint(of node: GraphNode, index: Int) -> CGPoint {
        CGPoint(x: node.position.x, y: rowCentre(of: node, row: node.outputs.count + index))
    }

    /// A wire's curve: a cubic Bézier that leaves the output horizontally to
    /// the right and enters the input horizontally from the left.
    public static func addWire(from start: CGPoint, to end: CGPoint, to path: CGMutablePath) {
        // The further apart, the wider the curve; never less than 40 points,
        // so wires going backwards still loop around visibly.
        let bend: CGFloat = max(40, abs(end.x - start.x) * 0.5)
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x + bend, y: start.y),
                      control2: CGPoint(x: end.x - bend, y: end.y))
    }

    /// The node's header: its frame's top `headerHeight`, with the top
    /// corners rounded.
    public static func headerPath(for frame: CGRect) -> CGPath {
        let header = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: headerHeight)
        return roundedPath(header, topRadius: cornerRadius, bottomRadius: 0)
    }

    /// The node's body below the header, with the bottom corners rounded.
    public static func bodyPath(for frame: CGRect) -> CGPath {
        let body = CGRect(x: frame.minX, y: frame.minY + headerHeight,
                          width: frame.width, height: frame.height - headerHeight)
        return roundedPath(body, topRadius: 0, bottomRadius: cornerRadius)
    }

    /// The whole node outline, all corners rounded (for selection highlights).
    public static func outlinePath(for frame: CGRect) -> CGPath {
        CGPath(roundedRect: frame, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    /// A rectangle with separate radii for the top and bottom corners, in
    /// y-down coordinates.
    static func roundedPath(_ rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: topRadius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: topRadius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: bottomRadius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: bottomRadius)
        path.closeSubpath()
        return path
    }

    /// Below this zoom, node titles are not drawn (too small to read).
    public static let titleMinimumZoom: CGFloat = 0.4
    /// Below this zoom, port names and values are not drawn.
    public static let portLabelMinimumZoom: CGFloat = 0.6

    /// The path of every wire in `model`, in graph coordinates, except
    /// those in `excluded` (a wire being dragged, or about to be cut).
    public static func wiresPath(for model: GraphModel, excluding excluded: Set<GraphWire> = []) -> CGPath {
        let path = CGMutablePath()
        for wire in model.wires where !excluded.contains(wire) {
            addWire(wire, in: model, to: path)
        }
        return path
    }

    /// Adds one wire of `model` to `path`.
    public static func addWire(_ wire: GraphWire, in model: GraphModel, to path: CGMutablePath) {
        let start: CGPoint = outputPoint(of: model.nodes[wire.from.node], index: wire.from.index)
        let end: CGPoint = inputPoint(of: model.nodes[wire.to.node], index: wire.to.index)
        addWire(from: start, to: end, to: path)
    }

    /// Points along a wire's curve, `count` segments' worth, for testing
    /// what crosses it. Uses the same control points as ``addWire(from:to:to:)``.
    public static func wirePoints(from start: CGPoint, to end: CGPoint, count: Int = 24) -> [CGPoint] {
        let bend: CGFloat = max(40, abs(end.x - start.x) * 0.5)
        let c1 = CGPoint(x: start.x + bend, y: start.y)
        let c2 = CGPoint(x: end.x - bend, y: end.y)
        // SWIFT: `(0...count).map` runs the closure for each integer in the
        // closed range and collects the results: count + 1 points.
        return (0...count).map { (step: Int) -> CGPoint in
            // The cubic Bézier formula, B(t) = (1-t)³P0 + 3(1-t)²t C1 +
            // 3(1-t)t² C2 + t³P1.
            let t: CGFloat = CGFloat(step) / CGFloat(count)
            let u: CGFloat = 1 - t
            let a: CGFloat = u * u * u
            let b: CGFloat = 3 * u * u * t
            let c: CGFloat = 3 * u * t * t
            let d: CGFloat = t * t * t
            return CGPoint(x: a * start.x + b * c1.x + c * c2.x + d * end.x,
                           y: a * start.y + b * c1.y + c * c2.y + d * end.y)
        }
    }

    /// True if the segments p1–p2 and q1–q2 cross or touch. A segment of
    /// zero length (a cut that hasn't moved yet) crosses nothing.
    public static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> Bool {
        guard p1 != p2, q1 != q2 else {
            return false
        }
        // Each segment's ends must lie on opposite sides of the other's
        // line (or on it: a cut through one of a curve's sample points
        // touches both segments there). The sign of a 2D cross product
        // says which side a point is on.
        func side(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
            (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        }
        let d1: CGFloat = side(q1, q2, p1)
        let d2: CGFloat = side(q1, q2, p2)
        let d3: CGFloat = side(p1, p2, q1)
        let d4: CGFloat = side(p1, p2, q2)
        return d1 * d2 <= 0 && d3 * d4 <= 0
    }

    /// The bounding box of all nodes and backdrops, or an empty rect for
    /// an empty graph.
    public static func bounds(of model: GraphModel) -> CGRect {
        // SWIFT: `reduce` folds a collection into one value: start with the
        // first argument, then combine it with each element in turn.
        let nodes: CGRect = model.nodes.reduce(CGRect.null) { (result: CGRect, node: GraphNode) in
            result.union(frame(of: node))
        }
        return model.backdrops.reduce(nodes) { $0.union($1.frame) }
    }

    // MARK: Backdrops (M4d)
    //
    //   ┌──────────────────────────────┐
    //   │ title                        │  backdropHeaderHeight
    //   │ note, wrapped                │
    //   │      ┌──────┐   ┌──────┐     │  the nodes it contains,
    //   │      │ node │   │ node │     │  backdropPadding from its edges
    //   │      └──────┘   └──────┘   ◢ │  the grip resizes it
    //   └──────────────────────────────┘

    public static let backdropHeaderHeight: CGFloat = 28
    /// Space between a new backdrop's edges and the nodes it frames.
    public static let backdropPadding: CGFloat = 30
    /// The smallest a backdrop can be resized to.
    public static let backdropMinimumSize = CGSize(width: 160, height: 80)
    /// The square in the bottom-right corner that resizes it.
    public static let backdropGripSize: CGFloat = 16
    public static let backdropCornerRadius: CGFloat = 8
    /// The widest a backdrop's note is drawn: wider lines are hard to read.
    public static let backdropNoteMaximumWidth: CGFloat = 420

    /// A backdrop around `frames` (nodes' frames): padded, with room for
    /// its header, and at least the minimum size. Nil if `frames` is empty.
    public static func backdropFrame(around frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else {
            return nil
        }
        let bounds: CGRect = frames.dropFirst().reduce(first) { $0.union($1) }
        let padded = CGRect(x: bounds.minX - backdropPadding, y: bounds.minY - backdropPadding - backdropHeaderHeight,
                            width: bounds.width + 2 * backdropPadding,
                            height: bounds.height + 2 * backdropPadding + backdropHeaderHeight)
        return CGRect(origin: padded.origin, size: CGSize(width: max(padded.width, backdropMinimumSize.width),
                                                          height: max(padded.height, backdropMinimumSize.height)))
    }

    /// A backdrop's header: the top of its frame, where it is picked up.
    public static func backdropHeaderFrame(of backdrop: GraphBackdrop) -> CGRect {
        CGRect(x: backdrop.frame.minX, y: backdrop.frame.minY, width: backdrop.frame.width,
               height: min(backdropHeaderHeight, backdrop.frame.height))
    }

    /// The grip in a backdrop's bottom-right corner, which resizes it.
    public static func backdropGripFrame(of backdrop: GraphBackdrop) -> CGRect {
        CGRect(x: backdrop.frame.maxX - backdropGripSize, y: backdrop.frame.maxY - backdropGripSize,
               width: backdropGripSize, height: backdropGripSize)
    }

    /// The middle of a node: it is in a backdrop when this is (moving
    /// and resizing decide what a backdrop contains by it).
    public static func centre(of node: GraphNode) -> CGPoint {
        let frame: CGRect = frame(of: node)
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// The canvas's colours, as RGB components (0...1), for a dark or a light
/// appearance (light since M7b; the canvas follows the system's, as the
/// rest of the window does). Kept as plain numbers so the SwiftUI and Core
/// Graphics renderers can both use them.
///
/// SWIFT: A struct with two `static let` instances, rather than an enum of
/// constants: the views hold the palette for their appearance in a
/// variable and read `palette.background`, whichever it is. A typealias
/// names the tuple type once.
public struct GraphPalette: Sendable {
    /// Red, green and blue, 0...1, in sRGB.
    public typealias RGB = (CGFloat, CGFloat, CGFloat)

    public let isDark: Bool
    public let background: RGB
    public let nodeBody: RGB
    /// A hairline around each node, for the light canvas, where white nodes
    /// on a light background need an edge; nil for none.
    public let nodeEdge: RGB?
    /// The disc where a swatch will appear, until it does.
    public let thumbnailPlaceholder: RGB
    public let text: RGB
    public let secondaryText: RGB
    public let wire: RGB
    public let selection: RGB
    /// The node shown alone in the viewport (M3d).
    public let solo: RGB
    /// The ⌥-drag cut line, and the wires it will cut.
    public let cut: RGB
    /// How strongly rows a dragged wire can't connect to are dimmed: the
    /// opacity of the background colour laid over them.
    public let dimOpacity: CGFloat
    /// Backdrops (M4d): a muted violet, laid over the background at
    /// `backdropOpacity` (its header twice as strong), with an edge and a
    /// title in a stronger violet, as in the mockup (docs/mockup).
    public let backdrop: RGB
    public let backdropOpacity: CGFloat
    public let backdropEdge: RGB
    public let backdropTitle: RGB

    /// The dark canvas, as it has been since M0d, with the secondary text
    /// and the "other" header adjusted for contrast in M7b.
    public static let dark = GraphPalette(
        isDark: true,
        background: (0.13, 0.13, 0.14), nodeBody: (0.22, 0.22, 0.24), nodeEdge: nil,
        thumbnailPlaceholder: (0.27, 0.27, 0.29), text: (0.88, 0.88, 0.9), secondaryText: (0.64, 0.64, 0.67),
        wire: (0.62, 0.62, 0.66), selection: (0.25, 0.55, 1.0), solo: (0.98, 0.68, 0.2), cut: (0.95, 0.35, 0.3),
        dimOpacity: 0.7,
        backdrop: (0.31, 0.29, 0.53), backdropOpacity: 0.14, backdropEdge: (0.43, 0.40, 0.72),
        backdropTitle: (0.71, 0.69, 0.94))

    /// The light canvas (M7b): near-white nodes with a hairline edge on a
    /// light grey, dark text, pastel headers (``header(_:)``) and slightly
    /// deeper pins (``pin(_:)``), so each keeps its contrast.
    public static let light = GraphPalette(
        isDark: false,
        background: (0.88, 0.88, 0.9), nodeBody: (0.98, 0.98, 0.99), nodeEdge: (0.72, 0.72, 0.75),
        thumbnailPlaceholder: (0.88, 0.88, 0.9), text: (0.1, 0.1, 0.12), secondaryText: (0.38, 0.38, 0.42),
        wire: (0.45, 0.45, 0.5), selection: (0.0, 0.45, 0.95), solo: (0.9, 0.5, 0.0), cut: (0.85, 0.2, 0.15),
        dimOpacity: 0.7,
        backdrop: (0.42, 0.38, 0.8), backdropOpacity: 0.12, backdropEdge: (0.45, 0.4, 0.75),
        backdropTitle: (0.3, 0.26, 0.62))

    /// The palette for a dark or a light appearance.
    public static func forDark(_ isDark: Bool) -> GraphPalette {
        isDark ? .dark : .light
    }

    /// Muted header colours by category; on the light canvas, the same
    /// hues mixed 60% with white, under dark text.
    public func header(_ category: NodeCategory) -> RGB {
        let dark: RGB = Self.darkHeader(category)
        guard !isDark else {
            return dark
        }
        let white: CGFloat = 0.6
        return (dark.0 + (1 - dark.0) * white, dark.1 + (1 - dark.1) * white, dark.2 + (1 - dark.2) * white)
    }

    /// Pin colours by type family; on the light canvas, 20% darker, to
    /// stand out against white.
    public func pin(_ type: PortType) -> RGB {
        let bright: RGB = Self.darkPin(type)
        return isDark ? bright : (bright.0 * 0.8, bright.1 * 0.8, bright.2 * 0.8)
    }

    /// The dark canvas's header colours.
    private static func darkHeader(_ category: NodeCategory) -> RGB {
        switch category {
        case .pbr: return (0.45, 0.30, 0.30)
        case .material: return (0.50, 0.36, 0.24)
        case .texture: return (0.30, 0.38, 0.30)
        case .procedural: return (0.35, 0.32, 0.45)
        case .geometry: return (0.30, 0.38, 0.45)
        case .math: return (0.33, 0.33, 0.36)
        case .adjustment: return (0.42, 0.38, 0.28)
        case .compositing: return (0.40, 0.30, 0.40)
        case .conditional: return (0.30, 0.40, 0.40)
        case .channel: return (0.36, 0.36, 0.30)
        case .organization: return (0.30, 0.30, 0.30)
        case .nodeGraph: return (0.24, 0.34, 0.52)
        case .graphInterface: return (0.26, 0.26, 0.28)
        case .other: return (0.37, 0.37, 0.37)
        }
    }

    /// The dark canvas's pin colours by type family.
    private static func darkPin(_ type: PortType) -> RGB {
        switch type.family {
        case .scalar: return (0.65, 0.65, 0.65)
        case .color: return (0.90, 0.75, 0.25)
        case .vector: return (0.40, 0.60, 0.95)
        case .matrix: return (0.30, 0.75, 0.75)
        case .text: return (0.55, 0.80, 0.55)
        case .shader: return (0.85, 0.45, 0.45)
        case .closure: return (0.80, 0.50, 0.80)
        case .material: return (0.95, 0.55, 0.30)
        case .other: return (0.85, 0.85, 0.85)
        }
    }
}
