// BuildFromNothingTests.swift
//
// M2e's exit criterion: "A material can be built from an empty document
// without touching the XML". The test starts from File > New's empty
// template and builds a textured material using only what the canvas and
// the inspector call: the node search (Tab, and wires dropped on empty
// canvas, with the catalog's choice of variant and port), wiring by drag,
// changing a type variant, and setting values. Then the document must be
// valid, read back the same after saving, and render in Storm with the
// texture's colour.
//
// The steps mirror GraphPanel's: after every edit, the level is rebuilt
// from the document, as the app does.
//
// Introduces (SWIFT): drawing a CGImage with a `CGContext`.

import CoreGraphics
import Foundation
import GraphKit
import MXKit
import Testing
import ViewportKit

@MainActor
@Suite("Building a material from nothing (M2e exit criterion)", .serialized)
struct BuildFromNothingTests {
    /// The document's top level on a canvas, as GraphPanel builds it; zoom
    /// 1 and no offset, so view and graph coordinates are the same.
    struct Canvas {
        let graph: DocumentGraph
        let controller: GraphCanvasController

        /// The canvas node for the element at `path`.
        func node(_ path: String) throws -> GraphNode {
            graph.model.nodes[try #require(graph.nodeIndex(forPath: path))]
        }

        func outputPin(of path: String) throws -> CGPoint {
            GraphLayout.outputPoint(of: try node(path), index: 0)
        }

        func inputPin(_ name: String, of path: String) throws -> CGPoint {
            let node: GraphNode = try node(path)
            return GraphLayout.inputPoint(of: node, index: try #require(node.inputs.firstIndex(where: { $0.name == name })))
        }

        /// Empty canvas, to the right of every node (or left, for a node
        /// that will feed an input).
        func emptySpot(left: Bool = false) -> CGPoint {
            let bounds: CGRect = GraphLayout.bounds(of: graph.model)
            if bounds.isNull {
                return CGPoint(x: 300, y: 300)
            }
            return CGPoint(x: left ? bounds.minX - 400 : bounds.maxX + 400, y: bounds.midY)
        }
    }

    func canvas(_ document: MXDocument, expanded: Set<String> = []) throws -> Canvas {
        var graph: DocumentGraph = GraphBuilder.build(try document.graph(at: ""), expanded: expanded)
        graph.layout()
        let controller = GraphCanvasController(model: graph.model)
        controller.zoom = 1
        controller.offset = .zero
        return Canvas(graph: graph, controller: controller)
    }

    /// A drag on the canvas, as GraphEventView plays it. Returns the node
    /// search it asked for, if any, and the connection it made, if any.
    func drag(from: CGPoint, to: CGPoint, on canvas: Canvas) -> (NodeSearchRequest?, WireConnection?) {
        var request: NodeSearchRequest? = nil
        var connection: WireConnection? = nil
        canvas.controller.onRequestNodeSearch = { request = $0 }
        canvas.controller.onConnect = { connection = $0 }
        canvas.controller.mouseDown(at: from, extend: false)
        canvas.controller.mouseDragged(to: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
        canvas.controller.mouseDragged(to: to)
        _ = canvas.controller.mouseUp()
        return (request, connection)
    }

    /// What GraphPanel does when a search result is chosen: add the node
    /// where the search was, and connect it to the search's wire.
    func add(_ match: MXNodeMatch, for request: NodeSearchRequest, on canvas: Canvas,
             in document: MXDocument) throws -> String {
        let path: String = try document.addNode(nodeDef: match.variant.name)
        let position: CGPoint = canvas.controller.newNodePosition(atView: request.location, for: request.wire)
        try document.setPosition(DocumentGraph.units(fromPoints: position), of: path)
        if let wire = request.wire {
            try canvas.graph.connect(newNode: path, port: try #require(match.port),
                                     outputCount: match.variant.outputs.count, to: wire, in: document)
        }
        return path
    }

    /// A small red texture in the temporary folder.
    func redTexture() throws -> URL {
        // SWIFT: A `CGContext` is a Core Graphics drawing surface, here a
        // bitmap in memory; `makeImage()` copies what was drawn into a
        // CGImage. The same calls as in C, with Swift names.
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try Fixtures.save(try #require(context.makeImage()), as: "m2e-red.png")
    }

    @Test("A textured material, from an empty document, by the canvas's calls alone")
    func buildTexturedMaterial() throws {
        let document: MXDocument = try MXDocumentTemplate.empty.makeDocument()
        document.setDataLibrary(try MXLibrary.bundled.get())
        let catalog = MXNodeCatalog(document: document)

        // 1. Tab on the empty canvas, "open pbr": the shader.
        var canvas: Canvas = try canvas(document)
        var request: NodeSearchRequest? = nil
        canvas.controller.onRequestNodeSearch = { request = $0 }
        canvas.controller.requestNodeSearch(at: canvas.emptySpot())
        let shaderMatch: MXNodeMatch = try #require(catalog.search("open pbr", for: nil).first)
        #expect(shaderMatch.kind.node == "open_pbr_surface")
        let shader: String = try add(shaderMatch, for: try #require(request), on: canvas, in: document)

        // 2. A wire from the shader's output, dropped on nothing: "surfacem"
        //    finds the material, which takes the wire.
        canvas = try self.canvas(document)
        let (materialRequest, _) = drag(from: try canvas.outputPin(of: shader), to: canvas.emptySpot(), on: canvas)
        let fromShader: NodeSearchRequest = try #require(materialRequest)
        let materialMatch: MXNodeMatch = try #require(catalog.search("surfacem", for: .input("surfaceshader")).first)
        #expect(materialMatch.kind.node == "surfacematerial")
        let material: String = try add(materialMatch, for: fromShader, on: canvas, in: document)

        // 3. Show the shader's inputs ("+N more inputs"), drag a wire from
        //    base_color to nothing: "image", as its colour variant.
        canvas = try self.canvas(document, expanded: [shader])
        let (imageRequest, _) = drag(from: try canvas.inputPin("base_color", of: shader),
                                     to: canvas.emptySpot(left: true), on: canvas)
        let intoBaseColor: NodeSearchRequest = try #require(imageRequest)
        let imageMatch: MXNodeMatch = try #require(catalog.search("image", for: .output("color3")).first)
        #expect(imageMatch.variant.name == "ND_image_color3")
        let image: String = try add(imageMatch, for: intoBaseColor, on: canvas, in: document)

        // 4. The inspector: the image's file.
        let texture: URL = try redTexture()
        try document.setValue(texture.path(percentEncoded: false), ofInput: "file", on: image)

        // 5. A wire from the image to nothing: a multiply, as color3, then
        //    changed to the "color3 (in2: float)" variant, with in2 = 0.5.
        canvas = try self.canvas(document, expanded: [shader])
        let (multiplyRequest, _) = drag(from: try canvas.outputPin(of: image), to: canvas.emptySpot(), on: canvas)
        let fromImage: NodeSearchRequest = try #require(multiplyRequest)
        let multiplyMatch: MXNodeMatch = try #require(catalog.search("multiply", for: .input("color3")).first)
        #expect(multiplyMatch.variant.name == "ND_multiply_color3" && multiplyMatch.port == "in1")
        let multiply: String = try add(multiplyMatch, for: fromImage, on: canvas, in: document)
        try document.changeNodeDef(of: multiply, to: "ND_multiply_color3FA")
        try document.setValue("0.5", ofInput: "in2", on: multiply)

        // 6. Drag the multiply's output onto base_color: it replaces the
        //    image's wire.
        canvas = try self.canvas(document, expanded: [shader])
        let (_, connection) = drag(from: try canvas.outputPin(of: multiply),
                                   to: try canvas.inputPin("base_color", of: shader), on: canvas)
        try canvas.graph.connect(try #require(connection), in: document)

        // The graph: image → multiply (×0.5) → base_color, shader → material.
        let graph: MXGraph = try document.graph()
        let baseColor: MXPort? = graph.node(named: shader)?.inputs.first(where: { $0.name == "base_color" })
        #expect(baseColor?.connection == .node(multiply, output: nil))
        let multiplyNode: MXNode? = graph.node(named: multiply)
        #expect(multiplyNode?.nodeDefName == "ND_multiply_color3FA")
        #expect(multiplyNode?.inputs.first(where: { $0.name == "in1" })?.connection == .node(image, output: nil))
        #expect(graph.node(named: material)?.inputs.first?.connection == .node(shader, output: nil))

        // Valid, and saved and read back unchanged.
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues().map(\.message))")
        let saved: String = try document.xmlString()
        let reread = try MXDocument(xml: saved)
        #expect(reread.difference(from: document) == nil)

        // Storm shows it: the red texture, halved.
        let renderer = try MGStormRenderer(materialXString: try document.previewXMLString())
        let image128: CGImage = try #require(renderer.snapshot(width: 128, height: 128))
        _ = try Fixtures.save(image128, as: "m2e-built-from-nothing.png")
        let lit = Fixtures.pixel(image128, x: 55, y: 55)
        #expect(lit.r > lit.g + 40 && lit.r > lit.b + 40, "red, got \(lit)")
    }

    @Test("The material templates are valid and render")
    func templates() throws {
        for template in MXDocumentTemplate.allCases {
            let document: MXDocument = try template.makeDocument()
            document.setDataLibrary(try MXLibrary.bundled.get())
            #expect(document.validationIssues().isEmpty, "\(template)")
            guard template != .empty else {
                #expect(document.topLevelElements.isEmpty)
                continue
            }
            let renderer = try MGStormRenderer(materialXString: try document.previewXMLString())
            #expect(renderer.boundMaterialPath.hasSuffix("/material"), "\(template)")
            let lit = Fixtures.pixel(try #require(renderer.snapshot(width: 128, height: 128)), x: 55, y: 55)
            // A grey-white default: lit, not black.
            #expect(Int(lit.r) + Int(lit.g) + Int(lit.b) > 150, "\(template): \(lit)")
        }
    }
}
