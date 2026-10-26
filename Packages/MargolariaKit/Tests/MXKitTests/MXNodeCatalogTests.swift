// MXNodeCatalogTests.swift
//
// Tests for the node library (MXNodeCatalog.swift) over the real data
// libraries: each node is listed once with its variants, new nodes start
// as a sensible variant, every variant has its own label, search finds
// what a user types, and changing a node's variant keeps what still fits.
//
// Introduces (SWIFT): nothing new.

import Foundation
import Testing
@testable import MXKit

@Suite("MXNodeCatalog")
struct MXNodeCatalogTests {
    /// An empty document with the data libraries: the catalog is the
    /// libraries' alone.
    func libraryCatalog() throws -> MXNodeCatalog {
        let document = try MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
        document.setDataLibrary(try MXLibrary.bundled.get())
        return MXNodeCatalog(document: document)
    }

    @Test("Each node is listed once, with its type variants")
    func kinds() throws {
        let catalog = try libraryCatalog()
        let multiply: MXNodeKind = try #require(catalog.kind(named: "multiply"))
        #expect(multiply.group == "math")
        #expect(multiply.variants.contains(where: { $0.name == "ND_multiply_color3FA" }))
        // Fewer kinds than nodedefs: the variants are folded together.
        let nodeDefCount: Int = catalog.kinds.reduce(0) { $0 + $1.variants.count }
        #expect(catalog.kinds.count < nodeDefCount / 2)
        // The older UsdUVTexture is left out; the default version stays.
        let texture: MXNodeKind = try #require(catalog.kind(named: "UsdUVTexture"))
        #expect(texture.variants.map(\.name) == ["ND_UsdUVTexture_23"])
    }

    @Test("New nodes start as the plain colour variant where there is one")
    func defaults() throws {
        let catalog = try libraryCatalog()
        #expect(catalog.kind(named: "multiply")?.defaultVariant.name == "ND_multiply_color3")
        #expect(catalog.kind(named: "mix")?.defaultVariant.name == "ND_mix_color3")
        #expect(catalog.kind(named: "image")?.defaultVariant.name == "ND_image_color3")
        #expect(catalog.kind(named: "noise2d")?.defaultVariant.name == "ND_noise2d_color3")
        #expect(catalog.kind(named: "open_pbr_surface")?.defaultVariant.type == "surfaceshader")
    }

    @Test("Every variant of a node has a label of its own")
    func labels() throws {
        let catalog = try libraryCatalog()
        let multiply: MXNodeKind = try #require(catalog.kind(named: "multiply"))
        #expect(multiply.label(for: try #require(multiply.variant(named: "ND_multiply_float"))) == "float")
        #expect(multiply.label(for: try #require(multiply.variant(named: "ND_multiply_color3FA")))
                == "color3 (in2: float)")
        let separate: MXNodeKind = try #require(catalog.kind(named: "separate3"))
        #expect(separate.label(for: try #require(separate.variant(named: "ND_separate3_vector3"))) == "in: vector3")

        var fallbacks: [String] = []
        for kind in catalog.kinds {
            let labels: [String] = kind.variants.map { kind.label(for: $0) }
            #expect(Set(labels).count == labels.count, "\(kind.node): \(labels)")
            fallbacks += zip(kind.variants, labels).filter { $0.0.name == $0.1 && kind.variants.count > 1 }.map(\.1)
        }
        // Variants told apart only by their names would be a poor menu.
        #expect(fallbacks.isEmpty, "named only by nodedef: \(fallbacks)")
    }

    @Test("Groups: the material-building ones first, the document's own at the top")
    func groups() throws {
        let catalog = try libraryCatalog()
        #expect(catalog.groups.first?.name == "pbr")
        #expect(catalog.groups.first(where: { $0.name == "texture2d" })?.title == "Texture 2D")
        #expect(!catalog.groups.contains(where: { $0.name == "document" }))

        let document = try MXDocument(xml: """
            <?xml version="1.0"?>
            <materialx version="1.39">
              <nodedef name="ND_tint" node="tint" nodegroup="adjustment">
                <input name="in" type="color3" value="1, 1, 1" />
                <output name="out" type="color3" />
              </nodedef>
            </materialx>
            """)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let withOwn = MXNodeCatalog(document: document)
        #expect(withOwn.groups.first?.name == "document")
        #expect(withOwn.groups.first?.kinds.map(\.node) == ["tint"])
    }

    @Test("Search: exact names first, then prefixes, then words, every word must match")
    func search() throws {
        let catalog = try libraryCatalog()
        #expect(catalog.search("multiply").first?.node == "multiply")
        let surfaces: [String] = catalog.search("surf").map(\.node)
        #expect(surfaces.contains("open_pbr_surface") && surfaces.contains("standard_surface"))
        #expect(catalog.search("pbr surf").first?.node == "open_pbr_surface")
        #expect(catalog.search("Open_PBR").first?.node == "open_pbr_surface")
        #expect(catalog.search("").count == catalog.kinds.count)
        #expect(catalog.search("zzzz").isEmpty)
        // Names starting with "noise" before those only containing it.
        #expect(catalog.search("noise").prefix(3).map(\.node) == ["noise2d", "noise3d", "cellnoise2d"])
    }

    // MARK: Changing a node's variant

    /// A multiply feeding an add, and a separate3 feeding another add.
    static let xml = """
        <?xml version="1.0"?>
        <materialx version="1.39">
          <nodegraph name="NG">
            <input name="amount" type="float" value="0.5" />
            <multiply name="scale" type="float">
              <input name="in1" type="float" interfacename="amount" />
              <input name="in2" type="float" value="2" />
            </multiply>
            <add name="offset" type="float">
              <input name="in1" type="float" nodename="scale" />
            </add>
            <separate3 name="split" type="multioutput">
              <input name="in" type="vector3" value="1, 2, 3" />
            </separate3>
            <add name="sum" type="float">
              <input name="in1" type="float" nodename="split" output="outx" />
            </add>
            <output name="out" type="float" nodename="offset" />
          </nodegraph>
        </materialx>
        """

    func document() throws -> MXDocument {
        let document = try MXDocument(xml: Self.xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        #expect(document.validationIssues().isEmpty, "the starting document is valid")
        return document
    }

    @Test("Changing the variant keeps the inputs and connections that still fit")
    func changeVariant() throws {
        let document = try document()
        try document.changeNodeDef(of: "NG/scale", to: "ND_multiply_color3FA")
        let graph: MXGraph = try document.graph(at: "NG")
        let scale: MXNode = try #require(graph.node(named: "scale"))
        #expect(scale.nodeDefName == "ND_multiply_color3FA")
        #expect(scale.type == "color3")
        // in1 is a colour now: its float connection went. in2 is still a float.
        #expect(scale.inputs.first(where: { $0.name == "in1" })?.connection == nil)
        #expect(scale.inputs.first(where: { $0.name == "in2" })?.value == "2")
        // offset wanted a float from it.
        #expect(graph.node(named: "offset")?.inputs.first(where: { $0.name == "in1" })?.connection == nil)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")

        // And back: the type is float again, in2 still set.
        try document.changeNodeDef(of: "NG/scale", to: "ND_multiply_float")
        let back: MXNode = try #require(try document.graph(at: "NG").node(named: "scale"))
        #expect(back.type == "float" && back.nodeDefName == "ND_multiply_float")
        #expect(back.inputs.first(where: { $0.name == "in2" })?.value == "2")
    }

    @Test("Multi-output variants: connections from outputs that don't exist any more go")
    func changeMultiOutput() throws {
        let document = try document()
        // The colour variant's outputs are outr/outg/outb, not outx.
        try document.changeNodeDef(of: "NG/split", to: "ND_separate3_color3")
        let graph: MXGraph = try document.graph(at: "NG")
        #expect(graph.node(named: "split")?.outputs.map(\.name) == ["outr", "outg", "outb"])
        #expect(graph.node(named: "sum")?.inputs.first(where: { $0.name == "in1" })?.connection == nil)
        #expect(document.validationIssues().isEmpty, "\(document.validationIssues())")
    }

    @Test("Only variants of the same node, and only on nodes")
    func changeRefused() throws {
        let document = try document()
        #expect(throws: MXError.self) {
            try document.changeNodeDef(of: "NG/scale", to: "ND_add_float")
        }
        #expect(throws: MXError.self) {
            try document.changeNodeDef(of: "NG", to: "ND_multiply_float")
        }
        #expect(throws: MXError.self) {
            try document.changeNodeDef(of: "NG/scale", to: "ND_no_such_thing")
        }
    }
}

@Suite("MXNodeCatalog over the whole library")
struct MXNodeCatalogLibraryTests {
    @Test("Every node can be added as its default variant, then changed to each of its others")
    func everyVariant() throws {
        let document = try MXDocument(xml: #"<?xml version="1.0"?><materialx version="1.39" />"#)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let catalog = MXNodeCatalog(document: document)
        var problems: [String] = []
        for kind in catalog.kinds {
            let path: String = try document.addNode(nodeDef: kind.defaultVariant.name)
            for variant in kind.variants + [kind.defaultVariant] {
                do {
                    try document.changeNodeDef(of: path, to: variant.name)
                } catch {
                    problems.append("\(variant.name): \(error)")
                    continue
                }
                let node: MXNode? = try document.graph().node(named: path)
                if node?.nodeDefName != variant.name || node?.type != variant.type {
                    problems.append("\(variant.name): became \(node?.nodeDefName ?? "nothing")")
                }
            }
            // A lone node with only default inputs: MaterialX accepts it.
            for issue in document.validationIssues() {
                problems.append("\(issue.elementPath): \(issue.message)")
            }
            // One node at a time keeps the document, and each check, small.
            try document.removeNode(at: path)
        }
        #expect(problems.isEmpty, "\(problems.prefix(10))")
    }
}
