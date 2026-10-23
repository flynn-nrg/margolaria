// GraphBuilderTests.swift
//
// Tests for building canvas graphs from MaterialX documents (GraphBuilder)
// and laying them out (GraphAutoLayout): on a small fixture in detail, and
// on every graph in MaterialX's examples for the layout's guarantees.
//
// Introduces (SWIFT): nothing new; see MXCorpusTests.swift for the corpus
// helper this file repeats.

import CoreGraphics
import Foundation
import Testing
@testable import GraphKit
import MXKit

/// Test files.
enum Fixtures {
    /// The URL of a file in Tests/GraphKitTests/Fixtures.
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    /// MaterialX's examples (scripts/fetch-materialx-examples.sh), as in
    /// MXKitTests/MXCorpusTests.swift. Test targets can't share code, so
    /// the lookup is repeated here.
    static let examples: [URL] = {
        var root = URL(filePath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        root = root.appending(path: "Vendor/MaterialX/resources/Materials/Examples")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var files: [URL] = []
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".mtlx") {
                files.append(root.appending(path: path))
            }
        }
        return files.sorted(by: { $0.path < $1.path })
    }()

    /// Reads a document with the data libraries set.
    static func document(_ url: URL) throws -> MXDocument {
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return document
    }
}

@Suite("Graph builder")
struct GraphBuilderTests {
    @Test("The document root: nodes, collapsed inputs and wires")
    func root() throws {
        let document: MXDocument = try Fixtures.document(Fixtures.url("brushed_copper.mtlx"))
        let graph: DocumentGraph = GraphBuilder.build(try document.graph())
        let nodes: [GraphNode] = graph.model.nodes

        #expect(nodes.map(\.title) == ["NG_copper", "SR_copper", "M_BrushedCopper"])
        #expect(graph.elementPaths == ["NG_copper", "SR_copper", "M_BrushedCopper"])
        #expect(nodes[0].category == .nodeGraph)
        #expect(nodes[1].category == .pbr)
        #expect(nodes[2].category == .material)
        #expect(nodes[1].subtitle == "open_pbr_surface")

        // The shader shows the three inputs the file sets; the rest collapse.
        #expect(nodes[1].inputs.map(\.name) == ["base_color", "base_metalness", "specular_roughness"])
        #expect(nodes[1].collapsedInputCount > 30)
        #expect(nodes[1].inputs[0].value == "0.95, 0.64, 0.54")
        #expect(nodes[1].inputs[2].value == nil, "connected: no value shown")
        #expect(nodes[1].inputs[0].type.family == .color)

        // NG_copper.roughness_out → SR_copper.specular_roughness, and
        // SR_copper.out → M_BrushedCopper.surfaceshader.
        #expect(Set(graph.model.wires) == [
            GraphWire(from: PortReference(node: 0, index: 0), to: PortReference(node: 1, index: 2)),
            GraphWire(from: PortReference(node: 1, index: 0), to: PortReference(node: 2, index: 0)),
        ])
    }

    @Test("Inside a nodegraph: its outputs become nodes")
    func insideNodeGraph() throws {
        let document: MXDocument = try Fixtures.document(Fixtures.url("brushed_copper.mtlx"))
        let graph: DocumentGraph = GraphBuilder.build(try document.graph(at: "NG_copper"))
        #expect(graph.model.nodes.map(\.title) == ["grain", "roughness_out"])
        #expect(graph.elementPaths == ["NG_copper/grain", "NG_copper/roughness_out"])
        #expect(graph.model.nodes[1].category == .graphInterface)
        #expect(graph.model.wires == [GraphWire(from: PortReference(node: 0, index: 0),
                                                to: PortReference(node: 1, index: 0))])
        #expect(graph.nodeIndex(forPath: "NG_copper/grain") == 0)
    }

    @Test("Interface inputs become nodes, wired to what uses them")
    func interfaceInputs() throws {
        let xml = """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodegraph name="NG">
                <input name="amount" type="float" value="0.5" />
                <multiply name="scale" type="float">
                  <input name="in1" type="float" interfacename="amount" />
                </multiply>
                <output name="out" type="float" nodename="scale" />
              </nodegraph>
            </materialx>
            """
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let graph: DocumentGraph = GraphBuilder.build(try document.graph(at: "NG"))
        #expect(graph.model.nodes.map(\.title) == ["amount", "scale", "out"])
        #expect(graph.model.nodes[0].outputs.first?.name == "0.5", "shows the value")
        #expect(Set(graph.model.wires) == [
            GraphWire(from: PortReference(node: 0, index: 0), to: PortReference(node: 1, index: 0)),
            GraphWire(from: PortReference(node: 1, index: 0), to: PortReference(node: 2, index: 0)),
        ])
    }
}

@Suite("Auto-layout")
struct GraphAutoLayoutTests {
    @Test("Wires run left to right, and the copper graph has three columns")
    func copper() throws {
        let document: MXDocument = try Fixtures.document(Fixtures.url("brushed_copper.mtlx"))
        var model: GraphModel = GraphBuilder.build(try document.graph()).model
        GraphAutoLayout.apply(to: &model)
        let x: [CGFloat] = model.nodes.map(\.position.x)
        #expect(x[0] < x[1] && x[1] < x[2], "nodegraph, then shader, then material")
    }

    @Test("Every example graph: no backward wires, no overlapping nodes",
          .enabled(if: !Fixtures.examples.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Fixtures.examples)
    func examples(_ url: URL) throws {
        let document: MXDocument = try Fixtures.document(url)
        var paths: [String] = [""]
        paths += document.nodeGraphs.map(\.path)
        for path in paths {
            var model: GraphModel = GraphBuilder.build(try document.graph(at: path)).model
            GraphAutoLayout.apply(to: &model)

            for wire in model.wires {
                let source: CGRect = GraphLayout.frame(of: model.nodes[wire.from.node])
                let target: CGRect = GraphLayout.frame(of: model.nodes[wire.to.node])
                #expect(source.maxX < target.minX, "\(path): \(model.nodes[wire.from.node].title) → \(model.nodes[wire.to.node].title) runs backwards")
            }
            let frames: [CGRect] = model.nodes.map { GraphLayout.frame(of: $0) }
            for i in frames.indices {
                for j in frames.indices where j > i && frames[i].intersects(frames[j]) {
                    Issue.record("\(path): \(model.nodes[i].title) overlaps \(model.nodes[j].title)")
                }
            }
        }
    }
}
