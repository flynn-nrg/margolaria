// LayerGraphView.swift
//
// Renderer 2 of 2: the graph as a tree of Core Animation layers.
//
//   root layer (background)
//    └─ content layer          transform = pan + zoom; everything below is in graph coordinates
//        ├─ wires              one CAShapeLayer with every wire's curve
//        ├─ node 0 … node N    one layer per node, drawn once with Core Graphics
//        │   └─ selection      outline, hidden unless selected
//        └─ marquee            CAShapeLayer
//
// Panning and zooming change one transform; the window server composites the
// cached node images on the GPU, with no redrawing. Node images are redrawn
// only when the zoom crosses a resolution step (so text stays sharp) or a
// level-of-detail threshold, and then only for nodes on or near the screen;
// wires are rebuilt only when nodes move.
//
// Introduces (SWIFT): subclassing `CALayer` and overriding `draw(in:)`,
// `withObservationTracking`, CoreText from Swift, `CATransaction`,
// `log2`/`ceil` and `pow`.

import AppKit
import CoreText
import Observation
import QuartzCore
import SwiftUI

/// The graph, drawn with Core Animation layers.
public final class LayerGraphView: GraphEventView {
    private let thumbnail: CGImage?
    private let contentLayer = CALayer()
    private let wiresLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private var nodeLayers: [NodeLayer] = []

    /// The detail level the node images were last drawn at; see `detail(for:)`.
    private var drawnDetail: NodeLayer.Detail? = nil
    /// The part of the graph that was on screen at the last update.
    private var drawnVisible: CGRect = .null
    private var drawnRevision: Int = -1
    private var drawnSelection: Set<Int> = []

    public init(controller: GraphCanvasController, thumbnail: CGImage?) {
        self.thumbnail = thumbnail
        super.init(controller: controller)

        wantsLayer = true
        // Draw the background via the layer, not via `draw(_:)`.
        layer?.backgroundColor = Self.cgColor(GraphPalette.background)

        // The content layer's origin is the graph origin; its transform maps
        // graph to view coordinates.
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        layer?.addSublayer(contentLayer)

        wiresLayer.fillColor = nil
        wiresLayer.strokeColor = Self.cgColor(GraphPalette.wire)
        wiresLayer.lineWidth = 2
        contentLayer.addSublayer(wiresLayer)

        for node in controller.model.nodes {
            let nodeLayer = NodeLayer(node: node, thumbnail: thumbnail)
            nodeLayers.append(nodeLayer)
            contentLayer.addSublayer(nodeLayer)
        }

        marqueeLayer.fillColor = Self.cgColor(GraphPalette.selection, alpha: 0.15)
        marqueeLayer.strokeColor = Self.cgColor(GraphPalette.selection)
        marqueeLayer.isHidden = true
        contentLayer.addSublayer(marqueeLayer)

        update()
        observeController()
    }

    required init?(coder: NSCoder) {
        fatalError("LayerGraphView is not used in nibs or storyboards")
    }

    /// Re-renders node images at the new screen's scale (Retina vs not).
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawnDetail = nil
        update()
    }

    /// Resizing the view shows more (or less) of the graph without any change
    /// to the controller, so newly visible nodes need drawing here too.
    public override func layout() {
        super.layout()
        update()
    }

    // MARK: Following the controller

    /// Calls `update()` after any change to the state it reads.
    ///
    /// SWIFT: `withObservationTracking` runs the first closure and records
    /// which `@Observable` properties it read. The first time any of them
    /// changes, `onChange` is called, once. So we re-register every time.
    /// `onChange` runs *before* the new value is stored ("will set"), so the
    /// update is scheduled for just after, on the main actor.
    private func observeController() {
        withObservationTracking {
            _ = controller.zoom
            _ = controller.offset
            _ = controller.selection
            _ = controller.marquee
            _ = controller.positionsRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observeController()
            }
        }
    }

    /// Brings the layer tree in line with the controller.
    func update() {
        // SWIFT/Core Animation: property changes on layers animate by default
        // (implicit animations). A canvas must follow the pointer exactly, so
        // switch them off for this transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // SWIFT: `defer` runs its block when the enclosing scope exits, however
        // it exits. Like a Go `defer`, or a C++ RAII guard.

        let zoom: CGFloat = controller.zoom
        let offset: CGPoint = controller.offset
        contentLayer.setAffineTransform(CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: zoom, y: zoom))
        marqueeLayer.lineWidth = 1 / zoom

        // Node positions and wires, only when nodes have moved.
        if controller.positionsRevision != drawnRevision {
            drawnRevision = controller.positionsRevision
            for (index, node) in controller.model.nodes.enumerated() {
                nodeLayers[index].frame = NodeLayer.layerFrame(for: node)
            }
            wiresLayer.path = GraphLayout.wiresPath(for: controller.model)
        }

        // Node images: redraw the visible nodes whose image was drawn at
        // another detail level. Off-screen nodes keep their old image until
        // they scroll into view: redrawing all 2,000 at once stalled for
        // 0.6 s in the M0d benchmark.
        let detail: NodeLayer.Detail = Self.detail(for: zoom, backingScale: window?.backingScaleFactor ?? 2)
        let visible: CGRect = controller.visibleGraphRect(viewSize: bounds.size)
        // A margin of half a screen on each side, so nodes are ready just
        // before they appear.
        let ready: CGRect = visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 2)
        if detail != drawnDetail || visible != drawnVisible {
            drawnDetail = detail
            drawnVisible = visible
            for nodeLayer in nodeLayers where nodeLayer.detail != detail && nodeLayer.frame.intersects(ready) {
                nodeLayer.detail = detail
                nodeLayer.contentsScale = detail.scale
                nodeLayer.setNeedsDisplay()
            }
        }

        // Selection outlines: only the nodes whose state changed.
        let selection: Set<Int> = controller.selection
        if selection != drawnSelection {
            // SWIFT: `symmetricDifference` is the set of elements in exactly
            // one of the two sets: here, nodes selected or deselected.
            for id in selection.symmetricDifference(drawnSelection) {
                nodeLayers[id].isSelected = selection.contains(id)
            }
            drawnSelection = selection
        }

        if let marquee = controller.marquee {
            marqueeLayer.isHidden = false
            marqueeLayer.path = CGPath(rect: marquee, transform: nil)
        } else {
            marqueeLayer.isHidden = true
        }
    }

    /// The detail level for a zoom: the image scale (rounded up to a power of
    /// two, so zooming redraws at most once per doubling) and which text to
    /// draw (the same thresholds as the Canvas renderer).
    static func detail(for zoom: CGFloat, backingScale: CGFloat) -> NodeLayer.Detail {
        // SWIFT: `log2`, `ceil` and `pow` are the C math functions, available
        // for CGFloat through Foundation/CoreGraphics overlays.
        let step: CGFloat = pow(2, ceil(log2(max(zoom, 0.125))))
        return NodeLayer.Detail(scale: backingScale * min(step, 4),
                                showsTitle: zoom >= GraphLayout.titleMinimumZoom,
                                showsPortLabels: zoom >= GraphLayout.portLabelMinimumZoom)
    }

    /// A Core Graphics colour from palette components, in sRGB like SwiftUI's
    /// `Color(red:green:blue:)`, so both renderers show the same colours.
    /// (`CGColor(red:green:blue:alpha:)` would use a generic RGB space and
    /// come out slightly lighter.)
    static func cgColor(_ rgb: (CGFloat, CGFloat, CGFloat), alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
    }
}

/// One node, drawn with Core Graphics into its own layer.
final class NodeLayer: CALayer {
    /// How much to draw, and at what resolution.
    struct Detail: Equatable {
        /// Pixels per graph point.
        var scale: CGFloat
        var showsTitle: Bool
        var showsPortLabels: Bool
    }

    private var node: GraphNode
    private let thumbnail: CGImage?
    /// The detail the current image was drawn at. Starts at scale 0, which
    /// no real detail has, so every layer is drawn when it first comes into view.
    var detail = Detail(scale: 0, showsTitle: false, showsPortLabels: false)
    private let selectionLayer = CAShapeLayer()

    var isSelected: Bool = false {
        didSet { selectionLayer.isHidden = !isSelected }
    }

    /// Pins stick out of the node's frame by their radius, so the layer is
    /// wider than the node by this much on each side.
    static let margin: CGFloat = GraphLayout.portRadius + 1

    static func layerFrame(for node: GraphNode) -> CGRect {
        GraphLayout.frame(of: node).insetBy(dx: -margin, dy: 0)
    }

    init(node: GraphNode, thumbnail: CGImage?) {
        self.node = node
        self.thumbnail = thumbnail
        super.init()
        frame = Self.layerFrame(for: node)
        // The node's own coordinates: (0, 0) is its top-left corner.
        let local = CGRect(x: Self.margin, y: 0, width: GraphLayout.nodeWidth, height: frame.height)
        selectionLayer.path = GraphLayout.outlinePath(for: local)
        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = LayerGraphView.cgColor(GraphPalette.selection)
        selectionLayer.lineWidth = 2
        selectionLayer.isHidden = true
        addSublayer(selectionLayer)
        // Don't fade contents in and out when they are redrawn.
        actions = ["contents": NSNull()]
    }

    /// Core Animation copies layers (for its presentation tree) with this
    /// initializer.
    override init(layer: Any) {
        let other = layer as! NodeLayer
        node = other.node
        thumbnail = other.thumbnail
        detail = other.detail
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("NodeLayer is not used in nibs or storyboards")
    }

    /// Draws the node. Called by Core Animation after `setNeedsDisplay()`.
    override func draw(in context: CGContext) {
        // Work in y-down coordinates with the node's top-left corner at
        // (margin, 0). In a flipped view hierarchy the context already is.
        if !contentsAreFlipped() {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        // Draw as if the node were at the graph origin.
        var local: GraphNode = node
        local.position = CGPoint(x: Self.margin, y: 0)
        let frame: CGRect = GraphLayout.frame(of: local)

        context.addPath(GraphLayout.bodyPath(for: frame))
        context.setFillColor(LayerGraphView.cgColor(GraphPalette.nodeBody))
        context.fillPath()
        context.addPath(GraphLayout.headerPath(for: frame))
        context.setFillColor(LayerGraphView.cgColor(GraphPalette.header(local.category)))
        context.fillPath()

        if let thumbnail, local.hasThumbnail {
            // CGContext.draw puts the image's first row at the bottom of the
            // rectangle, so flip locally to keep it upright in y-down space.
            let rect: CGRect = GraphLayout.thumbnailFrame(of: local)
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .medium
            context.draw(thumbnail, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }

        for (index, port) in local.outputs.enumerated() {
            Self.drawPin(at: GraphLayout.outputPoint(of: local, index: index), type: port.type, in: context)
        }
        for (index, port) in local.inputs.enumerated() {
            Self.drawPin(at: GraphLayout.inputPoint(of: local, index: index), type: port.type, in: context)
        }

        if detail.showsTitle {
            Self.drawText(local.title, font: Self.titleFont, color: GraphPalette.text,
                          at: CGPoint(x: frame.minX + 8, y: frame.minY + GraphLayout.headerHeight / 2),
                          alignRight: false, in: context)
        }
        if detail.showsPortLabels {
            for (index, port) in local.outputs.enumerated() {
                let point: CGPoint = GraphLayout.outputPoint(of: local, index: index)
                Self.drawText(port.name, font: Self.labelFont, color: GraphPalette.text,
                              at: CGPoint(x: point.x - 10, y: point.y), alignRight: true, in: context)
            }
            for (index, port) in local.inputs.enumerated() {
                let point: CGPoint = GraphLayout.inputPoint(of: local, index: index)
                Self.drawText(port.name, font: Self.labelFont, color: GraphPalette.text,
                              at: CGPoint(x: point.x + 10, y: point.y), alignRight: false, in: context)
                if let value = port.value {
                    Self.drawText(value, font: Self.labelFont, color: GraphPalette.secondaryText,
                                  at: CGPoint(x: frame.maxX - 8, y: point.y), alignRight: true, in: context)
                }
            }
        }
    }

    static func drawPin(at point: CGPoint, type: PortType, in context: CGContext) {
        let r: CGFloat = GraphLayout.portRadius
        context.setFillColor(LayerGraphView.cgColor(GraphPalette.pin(type)))
        context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
    }

    // MARK: Text

    /// The fonts, created once.
    ///
    /// SWIFT: Swift 6 rejects a plain `static let` of a non-`Sendable` type
    /// (it's a global any thread could reach; see SwatchRenderer.swift).
    /// CTFont is immutable and documented as thread-safe; CoreText just
    /// doesn't declare it `Sendable`. `nonisolated(unsafe)` tells the
    /// compiler "I have checked this myself": it turns the check off for
    /// this one declaration. Use it only with a reason like this one.
    nonisolated(unsafe) static let titleFont: CTFont = CTFontCreateUIFontForLanguage(.emphasizedSystem, 12, nil)!
    nonisolated(unsafe) static let labelFont: CTFont = CTFontCreateUIFontForLanguage(.system, 10, nil)!

    /// Draws one line of text, vertically centred on `point.y`, starting at
    /// (or, if `alignRight`, ending at) `point.x`.
    static func drawText(_ string: String, font: CTFont, color: (CGFloat, CGFloat, CGFloat),
                         at point: CGPoint, alignRight: Bool, in context: CGContext) {
        // SWIFT: A Swift dictionary bridges to the CFDictionary CoreText wants.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: LayerGraphView.cgColor(color),
        ]
        let line: CTLine = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let width: CGFloat = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ascent: CGFloat = CTFontGetAscent(font)
        let descent: CGFloat = CTFontGetDescent(font)

        context.saveGState()
        // CoreText draws with y up; flip the text matrix for y-down space.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let x: CGFloat = alignRight ? point.x - width : point.x
        // Baseline such that the glyphs' box is centred on point.y.
        context.textPosition = CGPoint(x: x, y: point.y + (ascent - descent) / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Puts a LayerGraphView into SwiftUI.
public struct LayerGraphRepresentable: NSViewRepresentable {
    let controller: GraphCanvasController
    let thumbnail: CGImage?

    public init(controller: GraphCanvasController, thumbnail: CGImage?) {
        self.controller = controller
        self.thumbnail = thumbnail
    }

    public func makeNSView(context: Context) -> LayerGraphView {
        LayerGraphView(controller: controller, thumbnail: thumbnail)
    }

    public func updateNSView(_ view: LayerGraphView, context: Context) {}
}
