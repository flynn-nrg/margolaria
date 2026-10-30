// StormUpdateTests.swift
//
// M2c: a renderer made from MaterialX text, updated as the document is
// edited. Checks that updates show up in the next frame, and measures what
// they cost: a value change (dragging a slider) against a change to the
// graph (a new node), to decide whether the viewport must throttle updates
// (PLAN.md §8.1).
//
// Introduces (SWIFT): `ContinuousClock` and `Duration` for timing,
// `String.replacingOccurrences(of:with:)`.

import CoreGraphics
import Foundation
import Testing
import ViewportKit

@Suite("Storm renderer updates (M2c)", .serialized)
struct StormUpdateTests {
    /// A red plastic, with `color` as its base colour.
    static func material(color: String, extraNode: Bool = false) -> String {
        // An extra node feeding the colour changes the shader's graph, not
        // just a value.
        let colorInput: String = extraNode
            ? #"<input name="base_color" type="color3" nodename="tint" />"#
            : #"<input name="base_color" type="color3" value="\#(color)" />"#
        let tint: String = extraNode
            ? #"<multiply name="tint" type="color3"><input name="in1" type="color3" value="\#(color)" /><input name="in2" type="float" value="1.0" /></multiply>"#
            : ""
        // SWIFT: `\#(x)` interpolates inside a raw string `#"..."#`; a plain
        // `\(x)` would be taken literally there.
        return #"""
            <?xml version="1.0"?>
            <materialx version="1.39">
              \#(tint)
              <open_pbr_surface name="SR" type="surfaceshader">
                \#(colorInput)
                <input name="specular_roughness" type="float" value="0.6" />
              </open_pbr_surface>
              <surfacematerial name="M" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="SR" />
              </surfacematerial>
            </materialx>
            """#
    }

    /// The lit side of the sphere, as in StormRendererTests.
    static func litPixel(_ renderer: MGStormRenderer) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        Fixtures.pixel(try #require(renderer.snapshot(width: 128, height: 128)), x: 55, y: 55)
    }

    @Test("Made from text, it shows the document")
    func fromText() throws {
        let renderer = try MGStormRenderer(materialXString: Self.material(color: "0.8, 0.05, 0.05"))
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M")
        let red = try Self.litPixel(renderer)
        #expect(red.r > red.b + 40, "red, got \(red)")
    }

    @Test("An update shows in the next frame, and keeps the bound material")
    func update() throws {
        let renderer = try MGStormRenderer(materialXString: Self.material(color: "0.8, 0.05, 0.05"))
        _ = try Self.litPixel(renderer)

        try renderer.updateMaterialXString(Self.material(color: "0.05, 0.05, 0.8"))
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M")
        let blue = try Self.litPixel(renderer)
        #expect(blue.b > blue.r + 40, "blue after the update, got \(blue)")

        // A new node in the graph.
        try renderer.updateMaterialXString(Self.material(color: "0.05, 0.8, 0.05", extraNode: true))
        let green = try Self.litPixel(renderer)
        #expect(green.g > green.r + 40, "green through the new node, got \(green)")
    }

    /// A material whose colour comes from a nodegraph, whose output is
    /// connected to `source`: "red" or "blue".
    static func graphMaterial(source: String) -> String {
        """
        <?xml version="1.0"?>
        <materialx version="1.39">
          <nodegraph name="NG">
            <constant name="red" type="color3"><input name="value" type="color3" value="0.8, 0.05, 0.05" /></constant>
            <constant name="blue" type="color3"><input name="value" type="color3" value="0.05, 0.05, 0.8" /></constant>
            <output name="out" type="color3" nodename="\(source)" />
          </nodegraph>
          <open_pbr_surface name="SR" type="surfaceshader">
            <input name="base_color" type="color3" nodegraph="NG" output="out" />
          </open_pbr_surface>
          <surfacematerial name="M" type="material">
            <input name="surfaceshader" type="surfaceshader" nodename="SR" />
          </surfacematerial>
        </materialx>
        """
    }

    @Test("Reconnecting a nodegraph's output to another node shows in the next frame")
    func rewiredGraph() throws {
        // Storm alone kept the old network after this edit (M3d): the
        // renderer re-adds the MaterialX layer when connections change.
        let renderer = try MGStormRenderer(materialXString: Self.graphMaterial(source: "red"))
        let red = try Self.litPixel(renderer)
        #expect(red.r > red.b + 40, "red, got \(red)")
        try renderer.updateMaterialXString(Self.graphMaterial(source: "blue"))
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M")
        let blue = try Self.litPixel(renderer)
        #expect(blue.b > blue.r + 40, "blue after rewiring, got \(blue)")
    }

    @Test("Bad text is refused and the last document stays")
    func badText() throws {
        let renderer = try MGStormRenderer(materialXString: Self.material(color: "0.8, 0.05, 0.05"))
        #expect(throws: (any Error).self) {
            try renderer.updateMaterialXString("<materialx")
        }
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M")
        let red = try Self.litPixel(renderer)
        #expect(red.r > red.b + 40, "still red, got \(red)")
    }

    @Test("Removing the material unbinds it; adding one binds it")
    func materialsChange() throws {
        let renderer = try MGStormRenderer(materialXString: Self.material(color: "0.8, 0.05, 0.05"))
        try renderer.updateMaterialXString(#"<?xml version="1.0"?><materialx version="1.39"/>"#)
        #expect(renderer.materialPaths.isEmpty)
        #expect(renderer.boundMaterialPath == "")
        try renderer.updateMaterialXString(Self.material(color: "0.8, 0.05, 0.05"))
        #expect(renderer.boundMaterialPath == "/World/MaterialX/Materials/M")
    }

    /// Not a check: how long an update takes to reach the screen, for a
    /// value change and for a graph change. Each is timed from the update
    /// to Storm reporting it has finished (shaders compiled), at a
    /// viewport-like size.
    @Test("Statistics: cost of a value change and a graph change")
    func cost() throws {
        let renderer = try MGStormRenderer(materialXString: Self.material(color: "0.5, 0.5, 0.5"))
        _ = renderer.snapshot(width: 720, height: 720)

        // SWIFT: `ContinuousClock` measures elapsed time; `measure { }`
        // runs the closure and returns how long it took, as a `Duration`.
        let clock = ContinuousClock()

        // Like a slider drag: twenty small value changes.
        var valueTimes: [Duration] = []
        for step in 1...20 {
            let red: Double = 0.5 + Double(step) * 0.02
            valueTimes.append(try clock.measure {
                try renderer.updateMaterialXString(Self.material(color: "\(red), 0.5, 0.5"))
                _ = renderer.snapshot(width: 720, height: 720)
            })
        }

        // Alternating between two graphs.
        var graphTimes: [Duration] = []
        for step in 1...6 {
            graphTimes.append(try clock.measure {
                try renderer.updateMaterialXString(Self.material(color: "0.5, 0.5, 0.5", extraNode: step % 2 == 1))
                _ = renderer.snapshot(width: 720, height: 720)
            })
        }

        // A frame with no change, for comparison.
        let still: Duration = clock.measure {
            _ = renderer.snapshot(width: 720, height: 720)
        }

        // SWIFT: `sorted()[count / 2]` is the median, less thrown by the
        // first, slower update than an average.
        print("""
            Storm update cost (update + frames until converged, 720 × 720):
              no change:     \(still)
              value change:  median \(valueTimes.sorted()[valueTimes.count / 2]), first \(valueTimes[0]), max \(valueTimes.max()!)
              graph change:  median \(graphTimes.sorted()[graphTimes.count / 2]), max \(graphTimes.max()!)
            """)
    }
}
