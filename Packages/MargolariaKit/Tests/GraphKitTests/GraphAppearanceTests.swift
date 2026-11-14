// GraphAppearanceTests.swift
//
// Tests for the canvas in light and dark mode (M7b): both palettes keep
// text and lines readable (by WCAG's contrast ratio), and the Core
// Animation canvas changes palette with its appearance, its nodes drawn
// in the new colours. How it looks is checked by the user.
//
// Introduces (SWIFT): nothing new.

import AppKit
import CoreGraphics
import Testing
@testable import GraphKit

@MainActor
@Suite("Light and dark canvas")
struct GraphAppearanceTests {
    /// WCAG 2's relative luminance of an sRGB colour.
    static func luminance(_ rgb: GraphPalette.RGB) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    /// WCAG 2's contrast ratio, 1 (none) to 21 (black on white).
    static func contrast(_ a: GraphPalette.RGB, _ b: GraphPalette.RGB) -> CGFloat {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test("Text and lines keep their contrast in both palettes", arguments: [GraphPalette.dark, .light])
    func contrast(_ palette: GraphPalette) {
        let name: String = palette.isDark ? "dark" : "light"
        // Body text: WCAG's AA for small text, 4.5.
        #expect(Self.contrast(palette.text, palette.nodeBody) >= 4.5, "\(name)")
        #expect(Self.contrast(palette.secondaryText, palette.nodeBody) >= 4.5, "\(name)")
        let categories: [NodeCategory] = [.pbr, .material, .texture, .procedural, .geometry, .math, .adjustment,
                                          .compositing, .conditional, .channel, .organization, .nodeGraph,
                                          .graphInterface, .other]
        for category in categories {
            #expect(Self.contrast(palette.text, palette.header(category)) >= 4.5, "\(name): \(category)'s header")
        }
        // Lines and titles on the background: 3, for graphics and large text.
        #expect(Self.contrast(palette.wire, palette.background) >= 3, "\(name): wires")
        #expect(Self.contrast(palette.backdropTitle, palette.background) >= 3, "\(name): backdrop titles")
        #expect(Self.contrast(palette.selection, palette.background) >= 3, "\(name): selection")
        // Pins on the node: told apart from it.
        for type in [PortType.float, .color3, .vector3, .string, .surfaceshader, .material, PortType("BSDF")] {
            #expect(Self.contrast(palette.pin(type), palette.nodeBody) >= 1.6, "\(name): \(type.name) pins")
        }
        // The light canvas's nodes need their edge to stand out.
        #expect((palette.nodeEdge != nil) == !palette.isDark)
    }

    @Test("The canvas takes its appearance's palette, and redraws its nodes in it")
    func followsAppearance() throws {
        let controller = GraphCanvasController(model: .synthetic(nodeCount: 3))
        let view = LayerGraphView(controller: controller)
        view.setFrameSize(NSSize(width: 400, height: 300))

        for (appearance, palette) in [(NSAppearance.Name.aqua, GraphPalette.light), (.darkAqua, .dark),
                                      (.accessibilityHighContrastAqua, .light)] {
            view.appearance = NSAppearance(named: appearance)
            #expect(view.layer?.backgroundColor == LayerGraphView.cgColor(palette.background), "\(appearance)")
            let nodeLayer: NodeLayer = try #require(view.layer?.sublayers?.first?.sublayers?
                .compactMap { $0 as? NodeLayer }.first)
            #expect(nodeLayer.palette.isDark == palette.isDark)
            // The node drawn: its body and its header in the palette's
            // colours, near its bottom and top left-hand corners. (Which
            // row is which depends on whether Core Animation flips the
            // layer; either way, one is each.)
            let corners: [[UInt8]] = try leftPixels(of: nodeLayer)
            let header: GraphPalette.RGB = palette.header(controller.model.nodes[0].category)
            #expect(Set(corners) == [Self.bytes(palette.nodeBody), Self.bytes(header)], "\(appearance)")
        }
    }

    /// Two pixels inside `layer`'s node, drawn at one pixel per point:
    /// 12 points in from its left edge, 4 from its top and bottom.
    func leftPixels(of layer: NodeLayer) throws -> [[UInt8]] {
        let width = Int(layer.bounds.width)
        let height = Int(layer.bounds.height)
        let context: CGContext = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        layer.draw(in: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let x: Int = Int(NodeLayer.margin) + 12
        return [4, height - 4].map { y in
            let offset: Int = (y * width + x) * 4
            return [data[offset], data[offset + 1], data[offset + 2]]
        }
    }

    /// A palette colour as 8-bit sRGB.
    static func bytes(_ rgb: GraphPalette.RGB) -> [UInt8] {
        [rgb.0, rgb.1, rgb.2].map { UInt8(($0 * 255).rounded()) }
    }
}
