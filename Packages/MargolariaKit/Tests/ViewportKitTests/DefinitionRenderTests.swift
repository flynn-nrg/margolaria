// DefinitionRenderTests.swift
//
// M4c1's exit criterion: a nodegraph made into a node definition, and
// used as a node, renders the same as the graph did. For every example,
// each nodegraph that can be is made into one (its uses becoming nodes of
// the new kind), and every material must look the same in Storm.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import MXKit
import Testing
import ViewportKit

extension StormRendererTests {
    @Test("Every example's nodegraphs made into node definitions, used as nodes, render the same",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    func definitionRendersTheSame(_ url: URL) throws {
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let graphs: [MXNode] = try document.graph(at: "").nodes
            .filter { $0.isNodeGraph && !$0.isIncluded && $0.nodeDefName == nil && !$0.outputs.isEmpty }
        guard !graphs.isEmpty else {
            return
        }
        let renderer = try MGStormRenderer(materialXString: try document.viewportXMLString())
        let original: [String: CGImage] = try Self.renderMaterials(of: document, with: renderer)
        for graph in graphs {
            var spec = MXNodeDefSpec.suggested(for: graph)
            spec.node = "mg_" + spec.node
            spec.name = MXNodeDefSpec.nodeDefName(for: spec.node, outputs: graph.outputs)
            try document.makeNodeDefinition(from: graph.path, as: spec)
        }
        Self.compare(original, try Self.renderMaterials(of: document, with: renderer),
                     "\(url.lastPathComponent) with \(graphs.count) definitions")
    }
}
