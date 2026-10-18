// CanvasGraphView.swift
//
// Renderer 1 of 2: the graph drawn with SwiftUI's `Canvas`, an immediate-mode
// drawing view. Every frame, the closure redraws everything that is visible
// (wires, nodes, thumbnails, text) from the controller's state.
//
// Mouse and trackpad input comes from a transparent AppKit view laid over the
// canvas (GraphEventView), because SwiftUI on macOS has no scroll-wheel or
// pinch events of the precision a canvas needs.
//
// Introduces (SWIFT): `Canvas` and `GraphicsContext`, `Color(red:green:blue:)`,
// `Path(_ cgPath:)`, reading `@Observable` properties in `body`, `.overlay`.

import SwiftUI

/// The graph, drawn with SwiftUI's Canvas.
public struct CanvasGraphView: View {
    /// SWIFT: A plain `let` of an `@Observable` class is enough: SwiftUI
    /// records which of its properties `body` reads and redraws when they
    /// change. (With the older ObservableObject, this needed @ObservedObject.)
    let controller: GraphCanvasController
    /// The image drawn as every node's thumbnail.
    let thumbnail: CGImage?

    public init(controller: GraphCanvasController, thumbnail: CGImage?) {
        self.controller = controller
        self.thumbnail = thumbnail
    }

    public var body: some View {
        // Read the observed state here, in `body`, so SwiftUI tracks it.
        // The Canvas closure runs later, during rendering, where reads may
        // not be tracked. The struct copies are cheap (copy-on-write).
        let model: GraphModel = controller.model
        let zoom: CGFloat = controller.zoom
        let offset: CGPoint = controller.offset
        let selection: Set<Int> = controller.selection
        let marquee: CGRect? = controller.marquee
        let thumbnailImage: Image? = thumbnail.map { Image(decorative: $0, scale: 1) }

        // SWIFT: `Canvas { context, size in ... }` calls the closure to draw.
        // `context` is a GraphicsContext, SwiftUI's drawing API (similar to a
        // CGContext, but it takes SwiftUI shapes, colours, text and images).
        Canvas(rendersAsynchronously: false) { context, size in
            // Graph coordinates from here on.
            context.translateBy(x: offset.x, y: offset.y)
            context.scaleBy(x: zoom, y: zoom)
            let visible = CGRect(x: -offset.x / zoom, y: -offset.y / zoom,
                                 width: size.width / zoom, height: size.height / zoom)

            Self.drawWires(model, visible: visible, in: &context)
            for node in model.nodes {
                let frame: CGRect = GraphLayout.frame(of: node)
                // Culling: skip nodes outside the view. Pins stick out by
                // their radius, so widen the test a little.
                guard frame.insetBy(dx: -10, dy: -10).intersects(visible) else {
                    continue
                }
                Self.drawNode(node, frame: frame, selected: selection.contains(node.id),
                              zoom: zoom, thumbnail: thumbnailImage, in: &context)
            }
            if let marquee {
                let path = Path(marquee)
                context.fill(path, with: .color(Self.color(GraphPalette.selection, opacity: 0.15)))
                context.stroke(path, with: .color(Self.color(GraphPalette.selection)), lineWidth: 1 / zoom)
            }
        }
        .background(Self.color(GraphPalette.background))
        .overlay(GraphEventCatcher(controller: controller))
    }

    // MARK: Drawing

    /// Wires whose bounding box is visible, as one stroked path.
    ///
    /// SWIFT: `inout GraphicsContext`: drawing changes the context's state,
    /// and GraphicsContext is a struct, so it is passed by reference.
    static func drawWires(_ model: GraphModel, visible: CGRect, in context: inout GraphicsContext) {
        let path = CGMutablePath()
        for wire in model.wires {
            let start: CGPoint = GraphLayout.outputPoint(of: model.nodes[wire.from.node], index: wire.from.index)
            let end: CGPoint = GraphLayout.inputPoint(of: model.nodes[wire.to.node], index: wire.to.index)
            // A curve stays inside the box of its end points widened by its bend.
            let box = CGRect(x: min(start.x, end.x) - 60, y: min(start.y, end.y),
                             width: abs(end.x - start.x) + 120, height: abs(end.y - start.y))
            if box.intersects(visible) {
                GraphLayout.addWire(from: start, to: end, to: path)
            }
        }
        context.stroke(Path(path), with: .color(color(GraphPalette.wire)), lineWidth: 2)
    }

    static func drawNode(_ node: GraphNode, frame: CGRect, selected: Bool, zoom: CGFloat,
                         thumbnail: Image?, in context: inout GraphicsContext) {
        context.fill(Path(GraphLayout.bodyPath(for: frame)), with: .color(color(GraphPalette.nodeBody)))
        context.fill(Path(GraphLayout.headerPath(for: frame)), with: .color(color(GraphPalette.header(node.category))))

        if let thumbnail, node.hasThumbnail {
            context.draw(thumbnail, in: GraphLayout.thumbnailFrame(of: node))
        }

        // Pins.
        for (index, port) in node.outputs.enumerated() {
            drawPin(at: GraphLayout.outputPoint(of: node, index: index), type: port.type, in: &context)
        }
        for (index, port) in node.inputs.enumerated() {
            drawPin(at: GraphLayout.inputPoint(of: node, index: index), type: port.type, in: &context)
        }

        // Text, only when large enough to read (level of detail).
        if zoom >= GraphLayout.titleMinimumZoom {
            let title = Text(node.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(GraphPalette.text))
            context.draw(title, at: CGPoint(x: frame.minX + 8, y: frame.minY + GraphLayout.headerHeight / 2),
                         anchor: .leading)
        }
        if zoom >= GraphLayout.portLabelMinimumZoom {
            for (index, port) in node.outputs.enumerated() {
                let point: CGPoint = GraphLayout.outputPoint(of: node, index: index)
                context.draw(label(port.name), at: CGPoint(x: point.x - 10, y: point.y), anchor: .trailing)
            }
            for (index, port) in node.inputs.enumerated() {
                let point: CGPoint = GraphLayout.inputPoint(of: node, index: index)
                context.draw(label(port.name), at: CGPoint(x: point.x + 10, y: point.y), anchor: .leading)
                if let value = port.value {
                    context.draw(label(value, secondary: true),
                                 at: CGPoint(x: frame.maxX - 8, y: point.y), anchor: .trailing)
                }
            }
        }

        if selected {
            context.stroke(Path(GraphLayout.outlinePath(for: frame)),
                           with: .color(color(GraphPalette.selection)), lineWidth: 2)
        }
    }

    static func drawPin(at point: CGPoint, type: PortType, in context: inout GraphicsContext) {
        let r: CGFloat = GraphLayout.portRadius
        context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(color(GraphPalette.pin(type))))
    }

    static func label(_ string: String, secondary: Bool = false) -> Text {
        Text(string)
            .font(.system(size: 10))
            .foregroundStyle(color(secondary ? GraphPalette.secondaryText : GraphPalette.text))
    }

    /// A SwiftUI colour from palette components.
    static func color(_ rgb: (CGFloat, CGFloat, CGFloat), opacity: Double = 1) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2, opacity: opacity)
    }
}

/// Puts a GraphEventView over the Canvas, to receive mouse and trackpad events.
struct GraphEventCatcher: NSViewRepresentable {
    let controller: GraphCanvasController

    func makeNSView(context: Context) -> GraphEventView {
        GraphEventView(controller: controller)
    }

    func updateNSView(_ view: GraphEventView, context: Context) {}
}
