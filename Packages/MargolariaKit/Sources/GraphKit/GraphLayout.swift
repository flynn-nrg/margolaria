// GraphLayout.swift
//
// Where things are on the canvas, in graph coordinates: node frames, port
// positions and wire curves. Both renderers (Canvas and Core Animation) and
// hit testing use these functions, so they always agree.
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
//   └──────────────────────┘
//
// Introduces (SWIFT): `enum` as a namespace for constants and static
// functions, `CGPath`/`CGMutablePath`, `extension` on a type from another
// module.

import CoreGraphics

/// Fixed sizes and geometry functions for the canvas.
public enum GraphLayout {
    public static let nodeWidth: CGFloat = 180
    public static let headerHeight: CGFloat = 24
    public static let thumbnailSize: CGFloat = 96
    public static let rowHeight: CGFloat = 20
    public static let bottomPadding: CGFloat = 6
    public static let cornerRadius: CGFloat = 6
    public static let portRadius: CGFloat = 5

    /// The node's frame (position and size), in graph coordinates.
    public static func frame(of node: GraphNode) -> CGRect {
        let thumbnail: CGFloat = node.hasThumbnail ? thumbnailSize + 8 : 0
        let rows: CGFloat = CGFloat(node.outputs.count + node.inputs.count)
        let height: CGFloat = headerHeight + thumbnail + rows * rowHeight + bottomPadding
        return CGRect(x: node.position.x, y: node.position.y, width: nodeWidth, height: height)
    }

    /// The thumbnail's frame inside the node, in graph coordinates.
    public static func thumbnailFrame(of node: GraphNode) -> CGRect {
        CGRect(x: node.position.x + (nodeWidth - thumbnailSize) / 2,
               y: node.position.y + headerHeight + 4,
               width: thumbnailSize, height: thumbnailSize)
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

    /// The path of every wire in `model`, in graph coordinates.
    public static func wiresPath(for model: GraphModel) -> CGPath {
        let path = CGMutablePath()
        for wire in model.wires {
            let start: CGPoint = outputPoint(of: model.nodes[wire.from.node], index: wire.from.index)
            let end: CGPoint = inputPoint(of: model.nodes[wire.to.node], index: wire.to.index)
            addWire(from: start, to: end, to: path)
        }
        return path
    }

    /// The bounding box of all nodes, or an empty rect for an empty graph.
    public static func bounds(of model: GraphModel) -> CGRect {
        // SWIFT: `reduce` folds a collection into one value: start with the
        // first argument, then combine it with each element in turn.
        model.nodes.reduce(CGRect.null) { (result: CGRect, node: GraphNode) in
            result.union(frame(of: node))
        }
    }
}

/// The canvas's colours, as RGBA components (0...1). Kept as plain numbers
/// so the SwiftUI and Core Graphics renderers can both use them.
public enum GraphPalette {
    public static let background: (CGFloat, CGFloat, CGFloat) = (0.13, 0.13, 0.14)
    public static let nodeBody: (CGFloat, CGFloat, CGFloat) = (0.22, 0.22, 0.24)
    public static let text: (CGFloat, CGFloat, CGFloat) = (0.88, 0.88, 0.9)
    public static let secondaryText: (CGFloat, CGFloat, CGFloat) = (0.6, 0.6, 0.63)
    public static let wire: (CGFloat, CGFloat, CGFloat) = (0.62, 0.62, 0.66)
    public static let selection: (CGFloat, CGFloat, CGFloat) = (0.25, 0.55, 1.0)

    /// Muted header colours by category.
    public static func header(_ category: NodeCategory) -> (CGFloat, CGFloat, CGFloat) {
        switch category {
        case .pbr: return (0.45, 0.30, 0.30)
        case .texture: return (0.30, 0.38, 0.30)
        case .procedural: return (0.35, 0.32, 0.45)
        case .geometry: return (0.30, 0.38, 0.45)
        case .math: return (0.33, 0.33, 0.36)
        case .adjustment: return (0.42, 0.38, 0.28)
        case .compositing: return (0.40, 0.30, 0.40)
        case .conditional: return (0.30, 0.40, 0.40)
        case .channel: return (0.36, 0.36, 0.30)
        }
    }

    /// Pin colours by type.
    public static func pin(_ type: PortType) -> (CGFloat, CGFloat, CGFloat) {
        switch type {
        case .float, .integer, .boolean: return (0.65, 0.65, 0.65)
        case .color3, .color4: return (0.90, 0.75, 0.25)
        case .vector2, .vector3, .vector4: return (0.40, 0.60, 0.95)
        case .filename, .string: return (0.55, 0.80, 0.55)
        case .surfaceshader, .displacementshader: return (0.85, 0.45, 0.45)
        case .material: return (0.95, 0.55, 0.30)
        }
    }
}
