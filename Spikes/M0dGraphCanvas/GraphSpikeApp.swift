// GraphSpikeApp.swift
//
// Demo app for spike M0d: a synthetic node graph drawn by either renderer
// (SwiftUI Canvas or Core Animation), with a built-in benchmark.
//
// Interactive: drag nodes, marquee-select on empty canvas (Shift adds),
// two-finger scroll to pan, pinch or ⌥-scroll to zoom.
//
// Benchmark from the command line (results go to the file, then it quits):
//
//   open -W GraphSpike.app --args -renderer layers -nodes 500 -out /tmp/result.txt
//
// Introduces (SWIFT): `UserDefaults` reading command-line arguments,
// `NSApplication.shared.terminate`, `Picker` with `.tag`, `CGContext`
// bitmap drawing, `DispatchQueue.main.asyncAfter`.

import AppKit
import GraphKit
import SwiftUI

@main
struct GraphSpikeApp: App {
    var body: some Scene {
        WindowGroup("Graph Canvas Spike") {
            GraphSpikeView()
        }
        .defaultSize(width: 1600, height: 1000)
    }
}

/// The two renderers being compared.
enum Renderer: String, CaseIterable, Identifiable {
    case canvas, layers
    var id: String { rawValue }
    var label: String { self == .canvas ? "SwiftUI Canvas" : "Core Animation" }
}

/// Settings passed on the command line. `-renderer canvas -nodes 500 -out path`
/// starts a benchmark immediately.
///
/// SWIFT: `UserDefaults` reads `-key value` pairs from the command line as
/// well as stored preferences, so `-nodes 500` arrives as the "nodes" key.
struct LaunchOptions {
    let renderer: Renderer?
    let nodeCount: Int?
    let outputPath: String?
    /// Start at this zoom, centred on the graph, instead of framing it all.
    let zoom: Double?

    static let current: LaunchOptions = {
        let defaults = UserDefaults.standard
        return LaunchOptions(renderer: defaults.string(forKey: "renderer").flatMap(Renderer.init(rawValue:)),
                             nodeCount: defaults.object(forKey: "nodes") == nil ? nil : defaults.integer(forKey: "nodes"),
                             outputPath: defaults.string(forKey: "out"),
                             zoom: defaults.object(forKey: "zoom") == nil ? nil : defaults.double(forKey: "zoom"))
    }()
}

struct GraphSpikeView: View {
    @State private var renderer: Renderer = LaunchOptions.current.renderer ?? .layers
    @State private var nodeCount: Int = LaunchOptions.current.nodeCount ?? 500
    @State private var controller = GraphCanvasController(model: .synthetic(nodeCount: LaunchOptions.current.nodeCount ?? 500))
    @State private var results: String = ""
    @State private var isRunning: Bool = false
    @State private var benchmark: GraphBenchmark? = nil

    /// The same thumbnail on every node (a shaded sphere), standing in for
    /// the live previews from PreviewKit.
    private let thumbnail: CGImage? = Self.makeThumbnail(size: 192)

    var body: some View {
        // SWIFT: `ZStack` layers its children on top of each other.
        ZStack(alignment: .bottomLeading) {
            switch renderer {
            case .canvas:
                CanvasGraphView(controller: controller, thumbnail: thumbnail)
            case .layers:
                LayerGraphRepresentable(controller: controller, thumbnail: thumbnail)
                    // A new view (and layer tree) for each controller.
                    .id(ObjectIdentifier(controller))
            }
            if !results.isEmpty {
                Text(results)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .toolbar {
            Picker("Renderer", selection: $renderer) {
                ForEach(Renderer.allCases) { renderer in
                    Text(renderer.label).tag(renderer)
                }
            }
            .pickerStyle(.segmented)
            Picker("Nodes", selection: $nodeCount) {
                // SWIFT: `.tag(n)` is the value the Picker writes into
                // `nodeCount` when this row is chosen.
                ForEach([100, 500, 1000, 2000], id: \.self) { count in
                    Text("\(count) nodes").tag(count)
                }
            }
            Button("Frame All") {
                controller.frameAll(viewSize: canvasSize())
            }
            Button(isRunning ? "Running…" : "Benchmark") {
                runBenchmark(outputPath: nil)
            }
            .disabled(isRunning)
        }
        .onChange(of: nodeCount) {
            controller = GraphCanvasController(model: .synthetic(nodeCount: nodeCount))
            controller.frameAll(viewSize: canvasSize())
        }
        .onAppear {
            // Let the window appear and settle before framing or measuring.
            // SWIFT: `asyncAfter` schedules a closure on a queue after a delay,
            // like `dispatch_after`.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                controller.frameAll(viewSize: canvasSize())
                if let zoom = LaunchOptions.current.zoom {
                    let size: CGSize = canvasSize()
                    controller.zoom(by: zoom / controller.zoom, at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
                if let path = LaunchOptions.current.outputPath {
                    runBenchmark(outputPath: path)
                }
            }
        }
    }

    /// The size of the window's content area, where the canvas is.
    private func canvasSize() -> CGSize {
        NSApplication.shared.windows.first?.contentView?.bounds.size ?? CGSize(width: 1600, height: 1000)
    }

    private func runBenchmark(outputPath: String?) {
        guard let contentView = NSApplication.shared.windows.first?.contentView else {
            return
        }
        isRunning = true
        results = "Running…"
        let screen: NSScreen? = contentView.window?.screen
        let header: String = "\(renderer.label), \(controller.model.nodes.count) nodes, "
            + "\(controller.model.wires.count) wires, view \(Int(contentView.bounds.width))×\(Int(contentView.bounds.height)) pt, "
            + "\(screen?.localizedName ?? "?") @ \(screen?.maximumFramesPerSecond ?? 0) Hz, scale \(screen?.backingScaleFactor ?? 0)"
        let benchmark = GraphBenchmark(controller: controller, view: contentView)
        self.benchmark = benchmark
        benchmark.run(GraphBenchmark.standardScenarios()) { resultList in
            var lines: [String] = [header] + resultList.map(\.summary)
            if let failure = benchmark.failure {
                lines.append("STOPPED: \(failure)")
            }
            let text: String = lines.joined(separator: "\n")
            results = text
            isRunning = false
            self.benchmark = nil
            if let outputPath {
                try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Draws a simple shaded sphere into a bitmap.
    static func makeThumbnail(size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }
        let colors = [CGColor(red: 0.95, green: 0.75, blue: 0.6, alpha: 1),
                      CGColor(red: 0.45, green: 0.25, blue: 0.18, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        let s = CGFloat(size)
        context.addEllipse(in: CGRect(x: 0, y: 0, width: s, height: s))
        context.clip()
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: s * 0.35, y: s * 0.65), startRadius: 0,
                                   endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s / 2, options: [])
        return context.makeImage()
    }
}
