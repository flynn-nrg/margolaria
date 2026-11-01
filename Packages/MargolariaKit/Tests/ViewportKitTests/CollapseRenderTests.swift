// CollapseRenderTests.swift
//
// M4a's exit criterion, for the viewport: collapsing a connected group of
// nodes into a nodegraph, in every example, leaves every material looking
// the same in Storm, and so does ungrouping it again. Storm misdraws some
// nodegraphs (PLAN.md §8.2), so the viewport's text ungroups those
// (MXDocument.viewportXMLString): this checks that too. The groups are those
// MXKitTests' corpus test collapses (each top-level node that isn't a
// material or a nodegraph, alone and with the nodes it reads directly).
//
// Storm compiles a shader per material and group, so this takes a few
// minutes.
//
// Introduces (SWIFT): nothing new.

import CoreGraphics
import Foundation
import MXKit
import Testing
import ViewportKit

extension StormRendererTests {
    /// The groups to collapse, as in MXNodeGraphEditTests.groups(in:)
    /// (test targets can't share code).
    static func collapsibleGroups(in graph: MXGraph) -> [[String]] {
        let movable: Set<String> = Set(graph.nodes.filter { $0.type != "material" && !$0.isNodeGraph && !$0.isIncluded }
            .map(\.name))
        var groups: [[String]] = []
        for node in graph.nodes where movable.contains(node.name) {
            groups.append([node.name])
            let upstream: [String] = node.inputs.compactMap { $0.connection?.sourceNodeName }.filter { movable.contains($0) }
            if !upstream.isEmpty {
                groups.append([node.name] + Set(upstream).sorted())
            }
        }
        return groups
    }

    /// Every material of `document`, rendered by `renderer` (which shows
    /// the document's preview text afterwards), by name.
    static func renderMaterials(of document: MXDocument, with renderer: MGStormRenderer) throws -> [String: CGImage] {
        try renderer.updateMaterialXString(try document.viewportXMLString())
        var images: [String: CGImage] = [:]
        for path in renderer.materialPaths {
            #expect(renderer.bindMaterial(atPath: path))
            images[(path as NSString).lastPathComponent] = renderer.snapshot(width: 64, height: 64,
                                                                            viewTransform: untoneMapped)
        }
        return images
    }

    /// Records an issue for each material that looks different in
    /// `after` than in `before`, at a few points across the sphere.
    static func compare(_ before: [String: CGImage], _ after: [String: CGImage], _ label: String) {
        #expect(Set(after.keys) == Set(before.keys), "\(label): the materials changed")
        for (material, a) in before {
            guard let b = after[material] else {
                continue
            }
            for (x, y) in [(32, 32), (24, 24), (40, 26), (32, 44)] {
                let p = Fixtures.pixel(a, x: x, y: y)
                let q = Fixtures.pixel(b, x: x, y: y)
                let difference: Int = abs(Int(p.r) - Int(q.r)) + abs(Int(p.g) - Int(q.g)) + abs(Int(p.b) - Int(q.b))
                #expect(difference <= 6, "\(label) \(material) at (\(x), \(y)): \(p) before, \(q) after")
            }
        }
    }

    @Test("Collapsing a group into a nodegraph, and ungrouping it, keeps every example's materials looking the same",
          .enabled(if: !Examples.files.isEmpty, "Run scripts/fetch-materialx-examples.sh to fetch the examples"),
          arguments: Examples.files)
    func collapseRendersTheSame(_ url: URL) throws {
        let document = try MXDocument.read(from: url)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let renderer = try MGStormRenderer(materialXString: try document.viewportXMLString())
        let original: [String: CGImage] = try Self.renderMaterials(of: document, with: renderer)
        let name: String = url.lastPathComponent
        for group in Self.collapsibleGroups(in: try document.graph(at: "")) {
            let before: MXDocument = document.copy()
            let graph: String = try document.collapse(group)
            Self.compare(original, try Self.renderMaterials(of: document, with: renderer), "\(name) collapsing \(group)")
            try document.ungroup(graph)
            Self.compare(original, try Self.renderMaterials(of: document, with: renderer), "\(name) ungrouping \(group)")
            document.restore(from: before)
        }
    }
}
