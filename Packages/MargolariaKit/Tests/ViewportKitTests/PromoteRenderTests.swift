// PromoteRenderTests.swift
//
// M4b's exit criterion, for the viewport: promoting every unconnected
// input of the examples' nodegraphs to the graph's interface leaves every
// material looking the same in Storm. Defaults, tagged files, uniform
// inputs and inputs that read geometry (`defaultgeomprop`) included.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import MXKit
import Testing
import ViewportKit

extension StormRendererTests {
    @Test("Promoting every unconnected input of the examples' nodegraphs keeps every material looking the same",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    func promoteRendersTheSame(_ url: URL) throws {
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let renderer = try MGStormRenderer(materialXString: try document.viewportXMLString())
        let original: [String: CGImage] = try Self.renderMaterials(of: document, with: renderer)
        var promoted: Int = 0
        // Nodegraphs whose interface can change: not included, not
        // implementing a nodedef.
        let editable: [MXNode] = try document.graph(at: "").nodes.filter { $0.isNodeGraph && !$0.isIncluded && $0.nodeDefName == nil }
        for graph in editable {
            for node in try document.graph(at: graph.path).nodes {
                for input in node.inputs where input.connection == nil {
                    try document.promote(input: input.name, on: node.path)
                    promoted += 1
                }
            }
        }
        guard promoted > 0 else {
            return
        }
        Self.compare(original, try Self.renderMaterials(of: document, with: renderer),
                     "\(url.lastPathComponent) with \(promoted) inputs promoted")
    }
}
