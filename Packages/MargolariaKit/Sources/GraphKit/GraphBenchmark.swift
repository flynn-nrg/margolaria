// GraphBenchmark.swift
//
// Measures how smoothly a canvas renderer keeps up while the view changes
// every frame. A display link (a callback once per screen refresh) moves
// the camera or the nodes along a fixed path and records when each callback
// arrives. When drawing takes longer than one refresh, callbacks arrive late
// and the intervals grow; that is what the results report.
//
// What it does not see: work done by the window server after the app has
// committed a frame (compositing Core Animation layers). A frame could be
// late there without the app noticing. For that, use Instruments'
// "Animation Hitches" template; this benchmark is a quick, repeatable first look.
//
// Introduces (SWIFT): `@objc` methods and `#selector` (target/action from
// Swift), `NSObject` subclasses, closures stored in structs, `sorted()`,
// `String(format:)`.

import AppKit
import QuartzCore

/// Drives a GraphCanvasController through scripted motions and times them.
@MainActor
public final class GraphBenchmark: NSObject {
    /// One scripted motion.
    public struct Scenario {
        public let name: String
        /// Seconds to run (after a short warm-up).
        public let duration: Double
        /// Called once before the run, to set zoom, position and selection.
        ///
        /// SWIFT: `@MainActor` in a function type: the closure runs on the
        /// main actor, so it may use the (main-actor) controller.
        let setup: @MainActor (GraphCanvasController, CGSize) -> Void
        /// Called every frame with the time since the start, in seconds.
        let step: @MainActor (GraphCanvasController, CGSize, Double) -> Void
    }

    /// Timing of one scenario.
    public struct Result: Sendable {
        public let scenario: String
        public let frames: Int
        /// The screen's refresh interval, in milliseconds (8.3 at 120 Hz).
        public let nominalMs: Double
        public let meanFPS: Double
        public let medianMs: Double
        public let p95Ms: Double
        public let maxMs: Double
        /// Share of frames that took more than 1.5 refresh intervals, i.e.
        /// that missed at least one refresh.
        public let slowPercent: Double

        public var summary: String {
            // `%-16@` would not pad an object (`%@`), so pad the name here.
            let name: String = scenario.padding(toLength: 16, withPad: " ", startingAt: 0)
            return name + String(format: "%4d frames  mean %6.1f fps  median %5.2f ms  p95 %6.2f ms  max %6.2f ms  slow %5.1f%%  (refresh %.2f ms)",
                                 frames, meanFPS, medianMs, p95Ms, maxMs, slowPercent, nominalMs)
        }
    }

    private let controller: GraphCanvasController
    private let view: NSView
    private var scenarios: [Scenario] = []
    private var results: [Result] = []
    private var completion: (([Result]) -> Void)? = nil

    private var link: CADisplayLink? = nil
    private var startTime: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var nominal: Double = 0
    private var frameIndex: Int = 0

    /// Seconds without a single frame after which the benchmark gives up.
    /// macOS stops display links while the screen is locked or asleep, or
    /// the window is hidden; without this, the benchmark would wait forever.
    private static let watchdogSeconds: Double = 5
    private var lastFrameDate: Date = Date()
    private var watchdog: Timer? = nil

    /// Why the run stopped early, if it did.
    public private(set) var failure: String? = nil

    /// Frames ignored at the start of each scenario (first draws, caches).
    private static let warmUpFrames: Int = 20

    /// `view` is any view in the canvas's window; it provides the display
    /// link for the screen the window is on.
    public init(controller: GraphCanvasController, view: NSView) {
        self.controller = controller
        self.view = view
    }

    /// Runs `scenarios` one after another, then calls `completion`.
    public func run(_ scenarios: [Scenario], completion: @escaping ([Result]) -> Void) {
        self.scenarios = scenarios
        self.results = []
        self.completion = completion
        self.failure = nil
        lastFrameDate = Date()
        // SWIFT: A repeating Timer on the main run loop. The closure is
        // `@Sendable` and not main-actor isolated, so it hops back to the
        // main actor with `MainActor.assumeIsolated`: the main run loop runs
        // on the main thread, which is what that call checks at run time.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkWatchdog()
            }
        }
        startNextScenario()
    }

    private func checkWatchdog() {
        guard Date().timeIntervalSince(lastFrameDate) > Self.watchdogSeconds else {
            return
        }
        failure = "No frames for \(Int(Self.watchdogSeconds)) s: is the screen locked or asleep, or the window hidden?"
        scenarios = []
        startNextScenario()
    }

    private func startNextScenario() {
        guard let scenario = scenarios.first else {
            link?.invalidate()
            link = nil
            watchdog?.invalidate()
            watchdog = nil
            completion?(results)
            return
        }
        scenario.setup(controller, view.bounds.size)
        intervals = []
        frameIndex = 0
        lastTimestamp = 0
        if link == nil {
            // SWIFT: `#selector(tick(_:))` names an Objective-C method for
            // target/action, checked at compile time. The method must be
            // `@objc`, and the class an NSObject subclass.
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            // Ask for the screen's full refresh rate.
            let maximum = Float(view.window?.screen?.maximumFramesPerSecond ?? 120)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum / 2, maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scenario = scenarios.first else {
            return
        }
        lastFrameDate = Date()
        frameIndex += 1
        if frameIndex == Self.warmUpFrames {
            startTime = link.timestamp
        }
        if frameIndex > Self.warmUpFrames {
            intervals.append(link.timestamp - lastTimestamp)
            nominal = link.targetTimestamp - link.timestamp
        }
        lastTimestamp = link.timestamp

        let t: Double = frameIndex > Self.warmUpFrames ? link.timestamp - startTime : 0
        scenario.step(controller, view.bounds.size, t)

        if frameIndex > Self.warmUpFrames && t >= scenario.duration {
            results.append(Self.summarize(scenario.name, intervals: intervals, nominal: nominal))
            scenarios.removeFirst()
            startNextScenario()
        }
    }

    private static func summarize(_ name: String, intervals: [Double], nominal: Double) -> Result {
        // SWIFT: `sorted()` returns a new, sorted array; the original is untouched.
        let sorted: [Double] = intervals.sorted()
        let total: Double = intervals.reduce(0, +)
        let slow: Int = intervals.filter { $0 > nominal * 1.5 }.count
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000
        }
        return Result(scenario: name, frames: intervals.count, nominalMs: nominal * 1000,
                      meanFPS: total > 0 ? Double(intervals.count) / total : 0,
                      medianMs: percentile(0.5), p95Ms: percentile(0.95),
                      maxMs: (sorted.last ?? 0) * 1000,
                      slowPercent: intervals.isEmpty ? 0 : Double(slow) * 100 / Double(intervals.count))
    }

    // MARK: Standard scenarios

    /// The scenarios used in the spike: pan zoomed out (every node visible,
    /// no text), pan zoomed in (fewer nodes, full detail), continuous zoom
    /// (crossing every detail level), and dragging 50 nodes (wires follow).
    public static func standardScenarios(duration: Double = 4) -> [Scenario] {
        // Starts centred on the graph at `zoom`.
        func centre(_ controller: GraphCanvasController, _ size: CGSize, zoom: CGFloat) {
            let bounds: CGRect = GraphLayout.bounds(of: controller.model)
            controller.zoom = zoom
            controller.offset = CGPoint(x: size.width / 2 - bounds.midX * zoom,
                                        y: size.height / 2 - bounds.midY * zoom)
        }
        // Circles the camera with a radius of `radius` view points.
        func pan(radius: CGFloat) -> @MainActor (GraphCanvasController, CGSize, Double) -> Void {
            var base: CGPoint? = nil
            return { controller, _, t in
                if base == nil { base = controller.offset }
                let angle: Double = t * 2 * .pi / 2   // one turn every 2 s
                controller.offset = CGPoint(x: base!.x + radius * cos(angle), y: base!.y + radius * sin(angle))
            }
        }

        let overview = Scenario(name: "pan overview", duration: duration,
                                setup: { controller, size in
                                    controller.selection = []
                                    controller.frameAll(viewSize: size)
                                },
                                step: pan(radius: 150))

        let detail = Scenario(name: "pan detail", duration: duration,
                              setup: { controller, size in centre(controller, size, zoom: 0.8) },
                              step: pan(radius: 300))

        let zoomScenario = Scenario(name: "zoom", duration: duration,
                                    setup: { controller, size in centre(controller, size, zoom: 0.15) },
                                    step: { controller, size, t in
            // From 0.15 to 1.2 and back every 3 s, around the view centre.
            let target: CGFloat = 0.15 * pow(8, 0.5 - 0.5 * cos(t * 2 * .pi / 3))
            controller.zoom(by: target / controller.zoom, at: CGPoint(x: size.width / 2, y: size.height / 2))
        })

        var dragOriginal: [Int: CGPoint] = [:]
        let drag = Scenario(name: "drag 50 nodes", duration: duration,
                            setup: { controller, size in
                                centre(controller, size, zoom: 0.5)
                                // The 50 nodes nearest the view centre.
                                let middle: CGPoint = controller.graphPoint(fromView: CGPoint(x: size.width / 2, y: size.height / 2))
                                let nearest = controller.model.nodes.sorted {
                                    hypot($0.position.x - middle.x, $0.position.y - middle.y)
                                        < hypot($1.position.x - middle.x, $1.position.y - middle.y)
                                }.prefix(50)
                                controller.selection = Set(nearest.map(\.id))
                                dragOriginal = [:]
                                for node in nearest {
                                    dragOriginal[node.id] = node.position
                                }
                            },
                            step: { controller, _, t in
            let angle: Double = t * 2 * .pi / 2
            controller.moveNodes(dragOriginal, by: CGSize(width: 120 * cos(angle), height: 120 * sin(angle)))
        })

        return [overview, detail, zoomScenario, drag]
    }
}
