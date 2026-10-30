// SwatchService.swift
//
// Draws the canvas's swatches off the main thread (M3c): PLAN.md §8.3 asks
// for swatches "rendered off the main thread, cancellable, re-rendered only
// downstream of an edit".
//
//   SwatchCache (main actor)   per document: the swatches drawn so far, by
//    │                         node; asks for the stale ones after an edit
//    └─ SwatchService (actor)  one for the app: parses the document text,
//        └─ SwatchRenderer     generates each shader, compiles the new ones
//                              in parallel, draws, hands each image back
//
// Why the document *text*: an MXDocument isn't safe to share between
// threads, and the app edits its own on the main thread. The text
// (MaterialXDocument's previewXML, already written after every edit, with
// absolute texture paths) is a plain String, which can go anywhere; the
// service parses its own copy, in a millisecond or two.
//
// What an edit costs. Generating a node's shader takes 2–10 ms. A value
// edit leaves the shaders' source as it was (values are uniforms), so
// their pipelines come from the renderer's cache and drawing takes about a
// millisecond. A graph edit (connecting, adding, changing a node's type)
// changes the source of the swatches downstream, and each new source must
// be compiled: 170–450 ms, several at a time. Until then the canvas keeps
// the old swatch.
//
// Cancelling: each edit cancels the work for the one before. Shaders being
// compiled are finished and cached anyway (the next edit probably needs
// them), but nothing more is drawn for a cancelled request.
//
// Introduces (SWIFT): `actor`, cancelling a `Task` (`cancel()`,
// `Task.isCancelled`), `withTaskGroup` (structured concurrency),
// `@MainActor @Sendable` closures.

import ColorKit
import CoreGraphics
import Foundation
import Metal
import MXKit
import Observation

/// A drawn swatch, or why there is none.
///
/// SWIFT: `@unchecked Sendable`, because CGImage isn't marked Sendable in
/// the SDK, although Core Graphics images are immutable and documented as
/// safe to use from any thread.
public enum Swatch: @unchecked Sendable {
    case image(CGImage)
    /// The shader couldn't be generated or compiled: MaterialX's or Metal's
    /// message.
    case failed(String)
}

/// How swatches look: the same light and view transform as the viewport.
public struct SwatchSettings: Hashable, Sendable {
    /// The environment image; nil for OpenUSD's StinsonBeach.hdr.
    public var environmentURL: URL?
    /// The view transform; nil for plain sRGB.
    public var viewTransform: ViewTransform?
    /// The swatches' width and height in pixels.
    public var pixelSize: Int

    public init(environmentURL: URL?, viewTransform: ViewTransform?, pixelSize: Int) {
        self.environmentURL = environmentURL
        self.viewTransform = viewTransform
        self.pixelSize = pixelSize
    }
}

/// Generates, compiles and draws swatches, one batch at a time.
///
/// SWIFT: An `actor` is a class whose methods never run at the same time:
/// calls from other threads wait their turn, like methods guarded by one
/// mutex, but the waiting is an `await`, which frees the caller's thread
/// instead of blocking it. That protects the renderer and the document
/// parsed here, neither of which is thread-safe. Actor code runs on the
/// system's pool of background threads, never on the main thread.
public actor SwatchService {
    /// Created by the first batch, in the background: making it loads the
    /// environment and computes its irradiance, which the main thread
    /// (opening the first document) shouldn't wait for.
    private var renderer: SwatchRenderer? = nil
    private let library: MXLibrary

    /// How many shaders are compiled at once: half the processor cores,
    /// from 2 to 8. Metal's compiler runs in its own processes, so more
    /// at once finishes sooner; half leaves the rest to the app (and
    /// Storm). The 28 swatches of the brick example's nodegraph, none
    /// compiled before, took 5.0 s one at a time, 1.65 s four at a time
    /// and 1.15 s eight at a time (an M-series Mac with 8 performance
    /// and 4 efficiency cores).
    static let parallelCompiles: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// The service for the whole app, or nil if Metal or MaterialX's
    /// libraries are unavailable (the canvas then shows no swatches).
    ///
    /// SWIFT: An actor is `Sendable` (safe to share), so it can be a
    /// `static let`, unlike SwatchRenderer.
    public static let shared: SwatchService? = try? SwatchService()

    /// Checks that swatches can be drawn at all: a Metal GPU, and
    /// MaterialX's libraries. Quick; the renderer itself comes later.
    public init() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw PreviewError.metal("No Metal device")
        }
        library = try MXLibrary.bundled.get()
    }

    /// The renderer, set up for `settings`: created the first time, then
    /// changed when the settings change.
    private func renderer(for settings: SwatchSettings) throws -> SwatchRenderer {
        if let renderer {
            try renderer.setEnvironment(settings.environmentURL)
            try renderer.setViewTransform(settings.viewTransform)
            return renderer
        }
        let created = try SwatchRenderer(environment: settings.environmentURL, viewTransform: settings.viewTransform)
        renderer = created
        return created
    }

    /// Draws `requests` from the document `xml`, in order, with `settings`,
    /// calling `deliver` on the main thread with each swatch as soon as it
    /// is ready. Returns when all are done, or soon after its task is
    /// cancelled.
    public func render(_ requests: [SwatchRequest], xml: String, settings: SwatchSettings,
                       deliver: @escaping @MainActor @Sendable (SwatchRequest, Swatch) -> Void) async {
        let renderer: SwatchRenderer
        do {
            renderer = try self.renderer(for: settings)
        } catch {
            for request in requests {
                await deliver(request, .failed(String(describing: error)))
            }
            return
        }
        let document: MXDocument
        do {
            document = try MXDocument(xml: xml)
        } catch {
            // The document's text is what MaterialX wrote, so this would be
            // a bug; keep the old swatches.
            return
        }
        document.setDataLibrary(library)

        // 1. Generate every shader; draw at once those already compiled.
        var toCompile: [(request: SwatchRequest, shader: MXGeneratedShader)] = []
        for request in requests {
            // SWIFT: `Task.isCancelled` is true once someone called
            // `cancel()` on the task running this code. Cancelling is
            // cooperative: nothing stops, the code checks and returns.
            if Task.isCancelled {
                return
            }
            let shader: MXGeneratedShader
            do {
                shader = try document.generateMSL(for: request.shaderPath, library: library)
            } catch {
                await deliver(request, .failed(String(describing: error)))
                continue
            }
            if renderer.hasPipeline(for: shader) {
                await deliver(request, draw(shader, with: renderer, size: settings.pixelSize))
            } else {
                toCompile.append((request, shader))
            }
        }

        // 2. Compile the rest, a few at a time, drawing each as it is done.
        let device: any MTLDevice = renderer.device
        // SWIFT: `withTaskGroup` runs child tasks concurrently and waits for
        // all of them before returning (structured concurrency: no task
        // outlives the group). `for await` receives their results in the
        // order they finish. The child tasks don't run on this actor, so
        // they may only use what they are given: the shader and the device.
        await withTaskGroup(of: (Int, Result<SwatchPipeline, any Error>).self) { group in
            var next: Int = 0
            func startNext() {
                guard next < toCompile.count, !Task.isCancelled else {
                    return
                }
                let index: Int = next
                let shader: MXGeneratedShader = toCompile[index].shader
                next += 1
                group.addTask {
                    // SWIFT: `Result { try ... }` would need a synchronous
                    // closure; with `await`, do/catch builds it by hand.
                    do {
                        return (index, .success(try await SwatchPipeline.compile(shader, device: device)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<Self.parallelCompiles {
                startNext()
            }
            for await (index, result) in group {
                let (request, shader) = toCompile[index]
                switch result {
                case .success(let pipeline):
                    // Cached even if cancelled: the next edit probably needs it.
                    renderer.add(pipeline, for: shader)
                    if !Task.isCancelled {
                        await deliver(request, draw(shader, with: renderer, size: settings.pixelSize))
                    }
                case .failure(let error):
                    if !Task.isCancelled {
                        await deliver(request, .failed(String(describing: error)))
                    }
                }
                startNext()
            }
        }
    }

    /// Draws one swatch with a compiled shader.
    private func draw(_ shader: MXGeneratedShader, with renderer: SwatchRenderer, size: Int) -> Swatch {
        do {
            return .image(try renderer.image(shader, size: size))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Forgets the loaded file textures, so the next swatches read the
    /// files again.
    public func reloadImages() {
        renderer?.reloadImages()
    }
}

/// One document's swatches: the latest drawn for each canvas node, and the
/// work under way to bring them up to date.
///
/// SWIFT: `@MainActor`: used by the canvas, on the main thread. The work
/// itself runs in the SwatchService actor; this class only starts it and
/// stores what comes back. `@Observable`, so a view showing a swatch's
/// state (the inspector, for a failed one) updates when it arrives.
@MainActor
@Observable
public final class SwatchCache {
    /// What is known about one node's swatch.
    struct Entry {
        let fingerprint: Int
        let settings: SwatchSettings
        let swatch: Swatch
    }

    private let service: SwatchService
    /// The latest swatch of each node, by element path, even if out of
    /// date (it is shown until the new one is ready).
    private var entries: [String: Entry] = [:]
    /// The work started by the last ``update(_:xml:settings:changed:)``.
    @ObservationIgnored private var task: Task<Void, Never>? = nil

    public init(service: SwatchService) {
        self.service = service
    }

    /// The latest swatch of the node at `path`, possibly out of date, or
    /// nil if none has been drawn yet.
    public func swatch(for path: String) -> Swatch? {
        entries[path]?.swatch
    }

    /// Brings the swatches of `requests` up to date: draws again, in the
    /// background, those drawn with another fingerprint or other settings,
    /// or not at all, and calls `changed` on the main thread for each new
    /// one. Cancels the work of the previous call.
    public func update(_ requests: [SwatchRequest], xml: String, settings: SwatchSettings,
                       changed: @escaping @MainActor @Sendable (String, Swatch) -> Void) {
        task?.cancel()
        let stale: [SwatchRequest] = requests.filter { request in
            guard let entry = entries[request.nodePath] else {
                return true
            }
            return entry.fingerprint != request.fingerprint || entry.settings != settings
        }
        guard !stale.isEmpty else {
            task = nil
            return
        }
        // SWIFT: `Task { ... }` starts asynchronous work and returns at
        // once, like dispatch_async. Created here, on the main actor, the
        // closure runs on the main actor too, until it `await`s the
        // service, whose code runs on the service's actor. `[weak self]`
        // in both closures: the task mustn't keep a closed document's cache
        // alive until its last swatches are drawn.
        let service: SwatchService = self.service
        task = Task { [weak self] in
            await service.render(stale, xml: xml, settings: settings) { [weak self] request, swatch in
                self?.entries[request.nodePath] = Entry(fingerprint: request.fingerprint, settings: settings,
                                                        swatch: swatch)
                changed(request.nodePath, swatch)
            }
        }
    }

    /// Waits for the work started by the last update to finish (tests).
    public func waitUntilDone() async {
        await task?.value
    }
}
