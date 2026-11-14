// LayerGraphView.swift
//
// Renderer 2 of 2: the graph as a tree of Core Animation layers.
//
//   root layer (background)
//    └─ content layer          transform = pan + zoom; everything below is in graph coordinates
//        ├─ backdrop 0 … N     one layer per backdrop (M4d): shapes and two text layers
//        ├─ wires              one CAShapeLayer with every wire's curve
//        ├─ cut wires          the wires an ⌥-drag will cut, highlighted
//        ├─ node 0 … node N    one layer per node, drawn once with Core Graphics
//        │   ├─ thumbnail      the node's swatch (M3c), an image set as is
//        │   ├─ dim            covers the rows a dragged wire can't connect to
//        │   ├─ solo           outline, hidden unless shown in the viewport (M3d)
//        │   └─ selection      outline, hidden unless selected
//        ├─ dragged wire       the wire being dragged (M2d), over the nodes
//        ├─ target             a ring or outline where it would connect
//        ├─ cut line           the ⌥-drag line
//        └─ marquee            CAShapeLayer
//
// Panning and zooming change one transform; the window server composites the
// cached node images on the GPU, with no redrawing. Node images are redrawn
// only when the zoom crosses a resolution step (so text stays sharp) or a
// level-of-detail threshold, and then only for nodes on or near the screen;
// wires are rebuilt only when nodes move. Dragging a wire changes only the
// small layers above, and the dim layers' paths: no node is redrawn. A new
// swatch only replaces its thumbnail layer's image: the node isn't
// redrawn either, so swatches arriving during an edit cost almost nothing.
//
// Backdrops (M4d) aren't drawn into an image like nodes: one can be far
// bigger than a node, and an image of it at 400% on a Retina screen would
// take hundreds of megabytes. Shape layers (vectors, drawn by the GPU at
// any zoom) make its fill, header, edge and grip; text layers its title
// and note, sized to the text.
//
// Colours come from the palette for the view's appearance, dark or light
// (M7b, GraphPalette): a change of appearance recolours the layers, and
// node images are redrawn as they come into view, as after a zoom.
//
// Introduces (SWIFT): subclassing `CALayer` and overriding `draw(in:)`,
// `withObservationTracking`, CoreText from Swift, `CATransaction`,
// `log2`/`ceil` and `pow`, `@discardableResult`; `nonisolated` on one
// method of a main-actor type (M3c); `CATextLayer`, `insertSublayer(_:at:)`,
// `CTFramesetter` to measure wrapped text (M4d); `viewDidChangeEffectiveAppearance`
// and `NSAppearance.bestMatch(from:)` (M7b).

import AppKit
import CoreText
import Observation
import QuartzCore
import SwiftUI

/// The graph, drawn with Core Animation layers.
public final class LayerGraphView: GraphEventView {
    /// Shown by every node with a thumbnail that has no swatch of its own
    /// (the M0d spike's benchmark, which has no swatches).
    private let thumbnail: CGImage?
    private let contentLayer = CALayer()
    private let wiresLayer = CAShapeLayer()
    private let cutWiresLayer = CAShapeLayer()
    private let draggedWireLayer = CAShapeLayer()
    private let targetLayer = CAShapeLayer()
    private let cutLineLayer = CAShapeLayer()
    private let marqueeLayer = CAShapeLayer()
    private var nodeLayers: [NodeLayer] = []
    private var backdropLayers: [BackdropLayer] = []
    /// The colours for the view's appearance, dark or light (M7b).
    private var palette: GraphPalette = .dark

    /// The detail level the node images were last drawn at; see `detail(for:)`.
    private var drawnDetail: NodeLayer.Detail? = nil
    /// The part of the graph that was on screen at the last update.
    private var drawnVisible: CGRect = .null
    private var drawnRevision: Int = -1
    private var drawnHiddenWires: Set<GraphWire> = []
    private var drawnSelection: Set<Int> = []
    private var drawnBackdropSelection: Set<Int> = []
    private var drawnSolo: Int? = nil
    private var drawnCandidates: WireCandidates? = nil

    public init(controller: GraphCanvasController, thumbnail: CGImage? = nil) {
        self.thumbnail = thumbnail
        super.init(controller: controller)

        wantsLayer = true
        // Nodes outside the view must not draw over its neighbours (the
        // breadcrumb bar above it, in the app).
        layer?.masksToBounds = true
        palette = Self.palette(for: effectiveAppearance)

        // The content layer's origin is the graph origin; its transform maps
        // graph to view coordinates.
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        layer?.addSublayer(contentLayer)

        wiresLayer.fillColor = nil
        wiresLayer.lineWidth = 2
        contentLayer.addSublayer(wiresLayer)

        cutWiresLayer.fillColor = nil
        cutWiresLayer.lineWidth = 3
        contentLayer.addSublayer(cutWiresLayer)

        // Behind the wires and nodes, in order: later backdrops on top.
        // SWIFT/Core Animation: `insertSublayer(_:at:)` puts a layer at a
        // place in the stack, where `addSublayer` puts it on top.
        for (index, backdrop) in controller.model.backdrops.enumerated() {
            let backdropLayer = BackdropLayer(backdrop: backdrop, palette: palette)
            backdropLayers.append(backdropLayer)
            contentLayer.insertSublayer(backdropLayer, at: UInt32(index))
        }

        for node in controller.model.nodes {
            let nodeLayer = NodeLayer(node: node, thumbnail: thumbnail, palette: palette)
            nodeLayers.append(nodeLayer)
            contentLayer.addSublayer(nodeLayer)
        }

        draggedWireLayer.fillColor = nil
        draggedWireLayer.lineWidth = 2
        contentLayer.addSublayer(draggedWireLayer)

        targetLayer.fillColor = nil
        targetLayer.lineWidth = 2
        contentLayer.addSublayer(targetLayer)

        cutLineLayer.fillColor = nil
        contentLayer.addSublayer(cutLineLayer)

        marqueeLayer.isHidden = true
        contentLayer.addSublayer(marqueeLayer)

        applyPalette()
        update()
        observeController()
    }

    required init?(coder: NSCoder) {
        fatalError("LayerGraphView is not used in nibs or storyboards")
    }

    /// The palette for `appearance`: light unless it is a dark one (M7b).
    static func palette(for appearance: NSAppearance) -> GraphPalette {
        // SWIFT/AppKit: `bestMatch(from:)` says which of the names given
        // the appearance is closest to, also for its high-contrast
        // variants.
        GraphPalette.forDark(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// The appearance changed (System Settings, or the app's): new colours
    /// for the layers, and node images redrawn as they come into view.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let new: GraphPalette = Self.palette(for: effectiveAppearance)
        guard new.isDark != palette.isDark else {
            return
        }
        palette = new
        applyPalette()
        update()
    }

    /// Colours the view's own layers and hands the palette to the nodes
    /// and backdrops. A node's image is redrawn when next shown.
    private func applyPalette() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Draw the background via the layer, not via `draw(_:)`.
        layer?.backgroundColor = Self.cgColor(palette.background)
        wiresLayer.strokeColor = Self.cgColor(palette.wire)
        cutWiresLayer.strokeColor = Self.cgColor(palette.cut)
        targetLayer.strokeColor = Self.cgColor(palette.selection)
        cutLineLayer.strokeColor = Self.cgColor(palette.cut)
        marqueeLayer.fillColor = Self.cgColor(palette.selection, alpha: 0.15)
        marqueeLayer.strokeColor = Self.cgColor(palette.selection)
        for nodeLayer in nodeLayers where nodeLayer.palette.isDark != palette.isDark {
            nodeLayer.palette = palette
        }
        for backdropLayer in backdropLayers {
            backdropLayer.palette = palette
        }
        // The visible nodes are redrawn by the next update().
        drawnDetail = nil
    }

    /// Re-renders node images at the new screen's scale (Retina vs not).
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawnDetail = nil
        update()
    }

    /// Resizing the view shows more (or less) of the graph without any change
    /// to the controller, so newly visible nodes need drawing here too.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
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
            _ = controller.backdropSelection
            _ = controller.marquee
            _ = controller.positionsRevision
            _ = controller.wirePreview
            _ = controller.wireCandidates
            _ = controller.wireTarget
            _ = controller.hiddenWires
            _ = controller.cutLine
            _ = controller.cutWires
            _ = controller.thumbnails
            _ = controller.soloNode
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

        // Node positions and wires, only when nodes have moved, or a wire
        // was picked up or put back.
        if controller.positionsRevision != drawnRevision || controller.hiddenWires != drawnHiddenWires {
            drawnRevision = controller.positionsRevision
            drawnHiddenWires = controller.hiddenWires
            for (index, node) in controller.model.nodes.enumerated() {
                nodeLayers[index].frame = NodeLayer.layerFrame(for: node)
            }
            for (index, backdrop) in controller.model.backdrops.enumerated() {
                backdropLayers[index].place(at: backdrop.frame)
            }
            wiresLayer.path = GraphLayout.wiresPath(for: controller.model, excluding: drawnHiddenWires)
        }
        updateWiring()

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
            for backdropLayer in backdropLayers {
                backdropLayer.show(detail)
            }
        }

        // Swatches: each node layer ignores an image it already shows, so
        // this costs a comparison per node with a swatch.
        for (id, thumbnail) in controller.thumbnails where id < nodeLayers.count {
            nodeLayers[id].show(thumbnail)
        }

        // The solo outline: off the old node, on the new.
        if controller.soloNode != drawnSolo {
            if let old = drawnSolo, old < nodeLayers.count {
                nodeLayers[old].isSoloed = false
            }
            if let new = controller.soloNode, new < nodeLayers.count {
                nodeLayers[new].isSoloed = true
            }
            drawnSolo = controller.soloNode
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
        let backdropSelection: Set<Int> = controller.backdropSelection
        if backdropSelection != drawnBackdropSelection {
            for id in backdropSelection.symmetricDifference(drawnBackdropSelection) where id < backdropLayers.count {
                backdropLayers[id].isSelected = backdropSelection.contains(id)
            }
            drawnBackdropSelection = backdropSelection
        }

        if let marquee = controller.marquee {
            marqueeLayer.isHidden = false
            marqueeLayer.path = CGPath(rect: marquee, transform: nil)
        } else {
            marqueeLayer.isHidden = true
        }
    }

    /// The dragged wire, its target, the cut line, and dimming (M2d).
    private func updateWiring() {
        let model: GraphModel = controller.model
        if let preview = controller.wirePreview {
            let path = CGMutablePath()
            GraphLayout.addWire(from: preview.start, to: preview.end, to: path)
            draggedWireLayer.path = path
            draggedWireLayer.strokeColor = Self.cgColor(palette.pin(preview.type))
        } else {
            draggedWireLayer.path = nil
        }

        // SWIFT: `wireTarget` is optional; `.input(let port)?` matches when
        // it holds `.input`, `nil` when it holds nothing.
        switch controller.wireTarget {
        case .input(let port)?:
            targetLayer.path = Self.ring(around: GraphLayout.inputPoint(of: model.nodes[port.node], index: port.index))
        case .output(let port)?:
            targetLayer.path = Self.ring(around: GraphLayout.outputPoint(of: model.nodes[port.node], index: port.index))
        case .node(let id)?:
            let frame: CGRect = GraphLayout.frame(of: model.nodes[id]).insetBy(dx: -3, dy: -3)
            targetLayer.path = CGPath(roundedRect: frame, cornerWidth: GraphLayout.cornerRadius + 3,
                                      cornerHeight: GraphLayout.cornerRadius + 3, transform: nil)
        case nil:
            targetLayer.path = nil
        }

        if let cut = controller.cutLine {
            let path = CGMutablePath()
            path.move(to: cut.start)
            path.addLine(to: cut.end)
            cutLineLayer.path = path
            // A constant width and dash on screen, whatever the zoom.
            let zoom: CGFloat = controller.zoom
            cutLineLayer.lineWidth = 1.5 / zoom
            // SWIFT: Core Animation wants an array of NSNumber; Swift
            // converts the CGFloat literals with `as NSNumber`.
            cutLineLayer.lineDashPattern = [6 / zoom as NSNumber, 4 / zoom as NSNumber]
        } else {
            cutLineLayer.path = nil
        }
        let cutPath = CGMutablePath()
        for wire in controller.cutWires {
            GraphLayout.addWire(wire, in: model, to: cutPath)
        }
        cutWiresLayer.path = cutPath

        let candidates: WireCandidates? = controller.wireCandidates
        if candidates != drawnCandidates {
            drawnCandidates = candidates
            for nodeLayer in nodeLayers {
                nodeLayer.dim(except: candidates)
            }
        }
    }

    /// A circle just outside a pin, in graph coordinates.
    private static func ring(around point: CGPoint) -> CGPath {
        let r: CGFloat = GraphLayout.portRadius + 3
        return CGPath(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r), transform: nil)
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
    ///
    /// SWIFT: `nonisolated`: callable from any thread, although the view
    /// is main-actor-only (NSView). NodeLayer, a CALayer drawn wherever
    /// Core Animation chooses, calls it; it touches no state, so that is
    /// safe. Without it Swift 6 warned at every such call.
    nonisolated static func cgColor(_ rgb: (CGFloat, CGFloat, CGFloat), alpha: CGFloat = 1) -> CGColor {
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
    /// The node's swatch, or nil while there is none yet.
    private var thumbnail: NodeThumbnail?
    /// Its colours (M7b). A new palette recolours the outlines at once;
    /// the image is redrawn when the view next shows the node (its detail
    /// is reset, so it no longer matches the view's).
    var palette: GraphPalette {
        didSet {
            applyPalette()
            detail = Detail(scale: 0, showsTitle: false, showsPortLabels: false)
        }
    }
    /// The detail the current image was drawn at. Starts at scale 0, which
    /// no real detail has, so every layer is drawn when it first comes into view.
    var detail = Detail(scale: 0, showsTitle: false, showsPortLabels: false)
    /// Shows the swatch's image over the node's own drawing, which has an
    /// empty disc where the sphere will be.
    private let thumbnailLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let soloLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()

    /// Shown alone in the viewport (M3d): outlined in the solo colour,
    /// just outside the selection outline.
    var isSoloed: Bool = false {
        didSet { soloLayer.isHidden = !isSoloed }
    }

    var isSelected: Bool = false {
        didSet { selectionLayer.isHidden = !isSelected }
    }

    /// Pins stick out of the node's frame by their radius, so the layer is
    /// wider than the node by this much on each side.
    static let margin: CGFloat = GraphLayout.portRadius + 1

    static func layerFrame(for node: GraphNode) -> CGRect {
        GraphLayout.frame(of: node).insetBy(dx: -margin, dy: 0)
    }

    /// A layer for `node`, showing `thumbnail` (an image for every node
    /// with a thumbnail, from the M0d spike) until ``show(_:)`` replaces it.
    init(node: GraphNode, thumbnail: CGImage?, palette: GraphPalette) {
        self.node = node
        self.palette = palette
        super.init()
        frame = Self.layerFrame(for: node)
        // The node's own coordinates: (0, 0) is its top-left corner.
        let local = CGRect(x: Self.margin, y: 0, width: GraphLayout.nodeWidth, height: frame.height)
        if node.hasThumbnail {
            var placed: GraphNode = node
            placed.position = CGPoint(x: Self.margin, y: 0)
            thumbnailLayer.frame = GraphLayout.thumbnailFrame(of: placed)
            // Scaled to fit, smoothly: the image has twice the points'
            // pixels, and the canvas zooms.
            thumbnailLayer.contentsGravity = .resizeAspect
            thumbnailLayer.minificationFilter = .trilinear
            thumbnailLayer.actions = ["contents": NSNull()]
            addSublayer(thumbnailLayer)
            if let thumbnail {
                show(.image(thumbnail))
            }
        }
        addSublayer(dimLayer)
        let soloOutline: CGRect = local.insetBy(dx: -3, dy: -3)
        soloLayer.path = CGPath(roundedRect: soloOutline, cornerWidth: GraphLayout.cornerRadius + 3,
                                cornerHeight: GraphLayout.cornerRadius + 3, transform: nil)
        soloLayer.fillColor = nil
        soloLayer.lineWidth = 2
        soloLayer.isHidden = true
        addSublayer(soloLayer)
        selectionLayer.path = GraphLayout.outlinePath(for: local)
        selectionLayer.fillColor = nil
        selectionLayer.lineWidth = 2
        selectionLayer.isHidden = true
        addSublayer(selectionLayer)
        applyPalette()
        // Don't fade contents in and out when they are redrawn.
        actions = ["contents": NSNull()]
    }

    /// Colours the dimming and the outlines from the palette.
    private func applyPalette() {
        dimLayer.fillColor = LayerGraphView.cgColor(palette.background, alpha: palette.dimOpacity)
        soloLayer.strokeColor = LayerGraphView.cgColor(palette.solo)
        selectionLayer.strokeColor = LayerGraphView.cgColor(palette.selection)
    }

    /// Shows `thumbnail` as the node's swatch. An image goes into the
    /// thumbnail layer, without redrawing the node; becoming unavailable
    /// (or available again) changes the disc drawn under it, so it redraws.
    func show(_ thumbnail: NodeThumbnail) {
        // SWIFT: Switching over a tuple matches both values at once. The
        // patterns of one `case` must bind the same names, so the two
        // "nothing changed" cases are written separately.
        let wasUnavailable: Bool
        switch (self.thumbnail, thumbnail) {
        case (.image(let shown)?, .image(let image)) where shown === image:
            // SWIFT: `===` asks whether two references point at the same
            // object, like comparing pointers; CGImage is a class.
            return
        case (.unavailable?, .unavailable):
            return
        case (.unavailable?, _):
            wasUnavailable = true
        default:
            wasUnavailable = false
        }
        self.thumbnail = thumbnail
        switch thumbnail {
        case .image(let image):
            thumbnailLayer.contents = image
            if wasUnavailable {
                setNeedsDisplay()
            }
        case .unavailable:
            thumbnailLayer.contents = nil
            setNeedsDisplay()
        }
    }

    /// Dims the rows a dragged wire can't connect to: with `candidates`
    /// looking for inputs, every input row not in it (and the "+N more" row
    /// unless a hidden input fits); looking for outputs, every output row
    /// not in it. Nil clears the dimming.
    func dim(except candidates: WireCandidates?) {
        guard let candidates else {
            dimLayer.path = nil
            return
        }
        // The node's own coordinates, as in draw(in:).
        var local: GraphNode = node
        local.position = CGPoint(x: Self.margin, y: 0)
        let path = CGMutablePath()
        // Widen each row to cover its pin, which sticks out of the node.
        let pin: CGFloat = Self.margin
        if candidates.seeksOutputs {
            for index in local.outputs.indices where !candidates.outputs.contains(PortReference(node: node.id, index: index)) {
                let row: CGRect = GraphLayout.outputRowFrame(of: local, index: index)
                path.addRect(CGRect(x: row.minX, y: row.minY, width: row.width + pin, height: row.height))
            }
        } else {
            for index in local.inputs.indices where !candidates.inputs.contains(PortReference(node: node.id, index: index)) {
                let row: CGRect = GraphLayout.inputRowFrame(of: local, index: index)
                path.addRect(CGRect(x: row.minX - pin, y: row.minY, width: row.width + pin, height: row.height))
            }
            if let row = GraphLayout.inputToggleRowFrame(of: local), candidates.hiddenInputs[node.id] == nil {
                path.addRect(row)
            }
        }
        dimLayer.path = path
    }

    /// Core Animation copies layers (for its presentation tree) with this
    /// initializer.
    override init(layer: Any) {
        let other = layer as! NodeLayer
        node = other.node
        thumbnail = other.thumbnail
        palette = other.palette
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
        context.setFillColor(LayerGraphView.cgColor(palette.nodeBody))
        context.fillPath()
        context.addPath(GraphLayout.headerPath(for: frame))
        context.setFillColor(LayerGraphView.cgColor(palette.header(local.category)))
        context.fillPath()
        // The light canvas's hairline edge (M7b), just inside the node.
        if let edge = palette.nodeEdge {
            context.addPath(CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: GraphLayout.cornerRadius,
                                   cornerHeight: GraphLayout.cornerRadius, transform: nil))
            context.setStrokeColor(LayerGraphView.cgColor(edge))
            context.setLineWidth(1)
            context.strokePath()
        }

        if local.hasThumbnail {
            drawThumbnailBackground(in: GraphLayout.thumbnailFrame(of: local), context: context)
        }

        for (index, port) in local.outputs.enumerated() {
            Self.drawPin(at: GraphLayout.outputPoint(of: local, index: index), color: palette.pin(port.type), in: context)
        }
        for (index, port) in local.inputs.enumerated() {
            Self.drawPin(at: GraphLayout.inputPoint(of: local, index: index), color: palette.pin(port.type), in: context)
        }

        if detail.showsTitle {
            // The title, then the MaterialX category dimmed after it, both
            // shortened with "…" if the header is too narrow.
            let left: CGFloat = frame.minX + 8
            let available: CGFloat = frame.width - 16
            let titleWidth: CGFloat = Self.drawText(local.title, font: Self.titleFont, color: palette.text,
                                                    at: CGPoint(x: left, y: frame.minY + GraphLayout.headerHeight / 2),
                                                    alignRight: false, maxWidth: available, in: context)
            if let subtitle = local.subtitle, subtitle != local.title {
                let gap: CGFloat = 6
                let remaining: CGFloat = available - titleWidth - gap
                // Not worth drawing two or three letters of it.
                if remaining > 30 {
                    Self.drawText(subtitle, font: Self.labelFont, color: palette.secondaryText,
                                  at: CGPoint(x: left + titleWidth + gap, y: frame.minY + GraphLayout.headerHeight / 2),
                                  alignRight: false, maxWidth: remaining, in: context)
                }
            }
        }
        if detail.showsPortLabels {
            for (index, port) in local.outputs.enumerated() {
                let point: CGPoint = GraphLayout.outputPoint(of: local, index: index)
                Self.drawText(port.name, font: Self.labelFont, color: palette.text,
                              at: CGPoint(x: point.x - 10, y: point.y), alignRight: true,
                              maxWidth: frame.width - 20, in: context)
            }
            for (index, port) in local.inputs.enumerated() {
                let point: CGPoint = GraphLayout.inputPoint(of: local, index: index)
                // The name gets up to 60% of the row; the value what's left.
                let nameWidth: CGFloat = Self.drawText(port.name, font: Self.labelFont, color: palette.text,
                                                       at: CGPoint(x: point.x + 10, y: point.y), alignRight: false,
                                                       maxWidth: (frame.width - 18) * 0.6, in: context)
                if let value = port.value {
                    Self.drawText(value, font: Self.labelFont, color: palette.secondaryText,
                                  at: CGPoint(x: frame.maxX - 8, y: point.y), alignRight: true,
                                  maxWidth: frame.width - 18 - nameWidth - 10, in: context)
                }
            }
            if local.hasInputToggle {
                let count: Int = local.collapsedInputCount
                let text: String
                if local.isExpanded {
                    text = "Fewer inputs"
                } else {
                    text = count == 1 ? "+1 more input" : "+\(count) more inputs"
                }
                Self.drawText(text, font: Self.labelFont, color: palette.secondaryText,
                              at: CGPoint(x: frame.minX + 10, y: GraphLayout.inputToggleRowCentre(of: local)),
                              alignRight: false, maxWidth: frame.width - 20, in: context)
            }
        }
    }

    /// What is under the swatch: a disc the size of its sphere, so the
    /// node's layout is the same before its swatch arrives; outlined, with
    /// "No preview" across it, when there won't be one.
    private func drawThumbnailBackground(in rect: CGRect, context: CGContext) {
        // The swatch's sphere fills about 92% of its image
        // (SwatchRenderer's camera).
        let radius: CGFloat = rect.width / 2 * 0.92
        let disc = CGRect(x: rect.midX - radius, y: rect.midY - radius, width: 2 * radius, height: 2 * radius)
        if case .unavailable? = thumbnail {
            context.setStrokeColor(LayerGraphView.cgColor(palette.secondaryText, alpha: 0.5))
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.strokeEllipse(in: disc)
            context.setLineDash(phase: 0, lengths: [])
            if detail.showsPortLabels {
                let width: CGFloat = Self.textWidth("No preview", font: Self.labelFont)
                Self.drawText("No preview", font: Self.labelFont, color: palette.secondaryText,
                              at: CGPoint(x: rect.midX - width / 2, y: rect.midY), alignRight: false,
                              maxWidth: rect.width, in: context)
            }
        } else {
            context.setFillColor(LayerGraphView.cgColor(palette.thumbnailPlaceholder))
            context.fillEllipse(in: disc)
        }
    }

    static func drawPin(at point: CGPoint, color: GraphPalette.RGB, in context: CGContext) {
        let r: CGFloat = GraphLayout.portRadius
        context.setFillColor(LayerGraphView.cgColor(color))
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

    /// The width of `string` drawn in `font`, on one line.
    static func textWidth(_ string: String, font: CTFont) -> CGFloat {
        let line: CTLine = CTLineCreateWithAttributedString(NSAttributedString(string: string,
                                                                               attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Draws one line of text, vertically centred on `point.y`, starting at
    /// (or, if `alignRight`, ending at) `point.x`. Text wider than
    /// `maxWidth` is shortened with "…". Returns the width drawn.
    ///
    /// SWIFT: `@discardableResult` lets callers ignore the returned width
    /// without a warning; most of them do.
    @discardableResult
    static func drawText(_ string: String, font: CTFont, color: GraphPalette.RGB,
                         at point: CGPoint, alignRight: Bool, maxWidth: CGFloat, in context: CGContext) -> CGFloat {
        guard maxWidth > 0 else {
            return 0
        }
        // SWIFT: A Swift dictionary bridges to the CFDictionary CoreText wants.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: LayerGraphView.cgColor(color),
        ]
        var line: CTLine = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        var width: CGFloat = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > maxWidth {
            // CoreText cuts the line to fit and appends the token.
            let token: CTLine = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            // SWIFT: `CTLineCreateTruncatedLine` returns an optional (nil if
            // even the token doesn't fit); `if let` keeps the full line then.
            if let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) {
                line = truncated
                width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
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
        return width
    }
}

/// One backdrop (M4d): a tinted, outlined rectangle with a header, its
/// title and note, and a grip in the bottom-right corner. Built from shape
/// and text layers rather than drawn into an image (see the file comment).
final class BackdropLayer: CALayer {
    private let fillLayer = CAShapeLayer()
    private let headerLayer = CAShapeLayer()
    private let gripLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let titleLayer = CATextLayer()
    private let noteLayer = CATextLayer()
    private let note: String
    private var detail = NodeLayer.Detail(scale: 0, showsTitle: false, showsPortLabels: false)
    /// Its colours (M7b); a new palette recolours it at once.
    var palette: GraphPalette {
        didSet { applyPalette() }
    }

    var isSelected: Bool = false {
        didSet { selectionLayer.isHidden = !isSelected }
    }

    init(backdrop: GraphBackdrop, palette: GraphPalette) {
        note = backdrop.note
        self.palette = palette
        super.init()
        fillLayer.lineWidth = 1
        gripLayer.lineWidth = 1.5
        gripLayer.fillColor = nil
        // A backdrop from an included file can't be resized.
        gripLayer.isHidden = backdrop.isLocked
        selectionLayer.fillColor = nil
        selectionLayer.lineWidth = 2
        selectionLayer.isHidden = true

        // SWIFT/Core Animation: a CATextLayer draws a string in its bounds,
        // in a font of `fontSize` points (the font's own size is ignored),
        // at `contentsScale` pixels per point. A CTFont works as its font.
        titleLayer.string = backdrop.isLocked ? backdrop.title + " · included" : backdrop.title
        titleLayer.font = NodeLayer.titleFont
        titleLayer.fontSize = 13
        titleLayer.truncationMode = .end
        noteLayer.string = backdrop.note
        noteLayer.font = NodeLayer.labelFont
        noteLayer.fontSize = 11
        noteLayer.isWrapped = true
        noteLayer.truncationMode = .end
        noteLayer.isHidden = backdrop.note.isEmpty
        for layer in [fillLayer, headerLayer, gripLayer, titleLayer, noteLayer, selectionLayer] as [CALayer] {
            addSublayer(layer)
        }
        applyPalette()
        place(at: backdrop.frame)
    }

    /// Colours its parts from the palette.
    private func applyPalette() {
        let tint: GraphPalette.RGB = palette.backdrop
        fillLayer.fillColor = LayerGraphView.cgColor(tint, alpha: palette.backdropOpacity)
        fillLayer.strokeColor = LayerGraphView.cgColor(palette.backdropEdge, alpha: 0.5)
        headerLayer.fillColor = LayerGraphView.cgColor(tint, alpha: palette.backdropOpacity * 2)
        gripLayer.strokeColor = LayerGraphView.cgColor(palette.backdropEdge, alpha: 0.8)
        selectionLayer.strokeColor = LayerGraphView.cgColor(palette.selection)
        titleLayer.foregroundColor = LayerGraphView.cgColor(palette.backdropTitle)
        noteLayer.foregroundColor = LayerGraphView.cgColor(palette.text, alpha: 0.85)
    }

    override init(layer: Any) {
        let other = layer as! BackdropLayer
        note = other.note
        palette = other.palette
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("BackdropLayer is not used in nibs or storyboards")
    }

    /// Puts the backdrop at `rect` (graph coordinates), reshaping its parts
    /// for a new size.
    func place(at rect: CGRect) {
        let sizeChanged: Bool = rect.size != frame.size
        frame = rect
        guard sizeChanged else {
            return
        }
        // The layer's own coordinates: (0, 0) is its top-left corner (the
        // content layer is flipped, like the view).
        let local = CGRect(origin: .zero, size: rect.size)
        let radius: CGFloat = GraphLayout.backdropCornerRadius
        fillLayer.path = CGPath(roundedRect: local.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius,
                                transform: nil)
        let header = CGRect(x: 0, y: 0, width: local.width, height: min(GraphLayout.backdropHeaderHeight, local.height))
        headerLayer.path = GraphLayout.roundedPath(header, topRadius: radius, bottomRadius: 0)
        selectionLayer.path = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Three short diagonal lines in the corner.
        let grip = CGMutablePath()
        let size: CGFloat = GraphLayout.backdropGripSize
        for step in 1...3 {
            let inset: CGFloat = CGFloat(step) * size / 4
            grip.move(to: CGPoint(x: local.maxX - inset, y: local.maxY - 3))
            grip.addLine(to: CGPoint(x: local.maxX - 3, y: local.maxY - inset))
        }
        gripLayer.path = grip

        let left: CGFloat = 10
        titleLayer.frame = CGRect(x: left, y: (GraphLayout.backdropHeaderHeight - 17) / 2,
                                  width: max(0, local.width - 2 * left), height: 17)
        // The note under the header, no wider than is easy to read, and
        // only as tall as its text (or the backdrop) needs.
        let width: CGFloat = max(0, min(local.width - 2 * left, GraphLayout.backdropNoteMaximumWidth))
        let available: CGFloat = max(0, local.height - GraphLayout.backdropHeaderHeight - 10)
        noteLayer.frame = CGRect(x: left, y: GraphLayout.backdropHeaderHeight + 4, width: width,
                                 height: min(available, Self.height(of: note, width: width)))
    }

    /// Draws the text at the detail level's resolution; the note only when
    /// port labels are shown, the title only with node titles.
    func show(_ detail: NodeLayer.Detail) {
        guard detail != self.detail else {
            return
        }
        self.detail = detail
        titleLayer.contentsScale = detail.scale
        noteLayer.contentsScale = detail.scale
        titleLayer.isHidden = !detail.showsTitle
        noteLayer.isHidden = note.isEmpty || !detail.showsPortLabels
    }

    /// The height `text` takes wrapped at `width`, in the note's font.
    ///
    /// SWIFT/CoreText: a framesetter lays text out in a shape; asked for a
    /// size, it answers how much of a given width the text fills.
    private static func height(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else {
            return 0
        }
        let font: CTFont = CTFontCreateCopyWithAttributes(NodeLayer.labelFont, 11, nil, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter: CTFramesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size: CGSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return ceil(size.height) + 2
    }
}

/// Puts a LayerGraphView into SwiftUI.
public struct LayerGraphRepresentable: NSViewRepresentable {
    let controller: GraphCanvasController
    /// The image every node shows until it has a swatch of its own (the
    /// M0d spike); the app passes nil and sets the controller's thumbnails.
    let thumbnail: CGImage?

    public init(controller: GraphCanvasController, thumbnail: CGImage? = nil) {
        self.controller = controller
        self.thumbnail = thumbnail
    }

    public func makeNSView(context: Context) -> LayerGraphView {
        LayerGraphView(controller: controller, thumbnail: thumbnail)
    }

    public func updateNSView(_ view: LayerGraphView, context: Context) {}
}
