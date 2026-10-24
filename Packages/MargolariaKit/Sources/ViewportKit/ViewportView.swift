// ViewportView.swift
//
// The 3D viewport: a SwiftUI view showing a .mtlx material on a sphere,
// rendered by Hydra Storm (MGStormRenderer). Drag to orbit, scroll to zoom.
// Frames are rendered at twice the size and scaled down (Downsampler.swift),
// which smooths the edges.
//
// Structure:
//
//   ViewportView (SwiftUI)    creates the renderer, shows errors
//    └─ StormView             NSViewRepresentable: puts an AppKit view in SwiftUI
//        └─ StormMTKView      MTKView subclass: renders and presents frames
//
// Introduces (SWIFT): `NSViewRepresentable`, subclassing an AppKit class and
// `override`, `init` rules for subclasses (`super.init`, `required init?`),
// `fatalError`, `Result`, `enum` with associated values as view state,
// `.task(id:)`, `[weak self]` capture lists, `===` identity comparison,
// `Task.sleep(for:)`, `Date` arithmetic, bridging a String to NSString.

import AppKit
import MetalKit
import SwiftUI

/// Shows the first material in a .mtlx file on a sphere, rendered with Storm.
public struct ViewportView: View {
    /// The .mtlx file to show.
    public let fileURL: URL

    /// The MaterialX name of the material to show, such as "M_BrushedCopper",
    /// or nil for the file's first material.
    public let materialName: String?

    /// What the viewport currently shows.
    ///
    /// SWIFT: An enum with *associated values* is a tagged union: each case
    /// can carry its own data. `.ready` carries a renderer, `.failed` a
    /// message. Unlike a C union, Swift always knows which case is active and
    /// only lets you read the data of that case (through `switch`).
    private enum Content {
        case loading
        case ready(MGStormRenderer)
        case failed(String)
    }

    /// SWIFT: `@State` keeps the renderer alive across redraws of this view.
    /// The renderer is expensive (a whole Hydra engine), so it must not be
    /// recreated every time SwiftUI re-evaluates `body`.
    @State private var content: Content = .loading

    /// SWIFT: A `public` struct gets no public memberwise initializer for
    /// free; the automatic one is `internal`. Code in other modules (the app)
    /// needs this explicit `public init`.
    public init(fileURL: URL, materialName: String? = nil) {
        self.fileURL = fileURL
        self.materialName = materialName
    }

    public var body: some View {
        // SWIFT: `Group` is an invisible container, needed here so the
        // `.task` modifier below applies to whichever branch is shown.
        Group {
            switch content {
            case .loading:
                ProgressView()
            case .ready(let renderer):
                StormView(renderer: renderer, materialName: materialName)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        // SWIFT: `.task(id:)` runs the closure when the view appears, and
        // again whenever `id` changes (a different file). It runs on the main
        // actor, because SwiftUI views are `@MainActor`.
        .task(id: fileURL) {
            content = makeContent()
        }
    }

    /// Creates the renderer, or describes why it couldn't be created.
    private func makeContent() -> Content {
        // SWIFT: `do`/`catch` handles the error thrown by a `throws`
        // initializer. MGStormRenderer's Objective-C initializer reports
        // failure through `NSError **`; Swift turns that into `throws`
        // automatically. Inside `catch`, the error is available as `error`.
        do {
            let renderer = try MGStormRenderer(materialXFile: fileURL)
            return .ready(renderer)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Puts a StormMTKView (AppKit) into the SwiftUI hierarchy.
///
/// SWIFT: `NSViewRepresentable` is the protocol for wrapping an NSView in
/// SwiftUI. SwiftUI calls `makeNSView` once to create the view, and
/// `updateNSView` whenever this struct's inputs change. The NSView itself is
/// long-lived; this struct is re-created freely, like any SwiftUI view.
private struct StormView: NSViewRepresentable {
    let renderer: MGStormRenderer
    let materialName: String?

    func makeNSView(context: Context) -> StormMTKView {
        let view = StormMTKView(renderer: renderer)
        view.bindMaterial(named: materialName)
        return view
    }

    func updateNSView(_ view: StormMTKView, context: Context) {
        // SWIFT: `!==` compares object identity (are these the same
        // instance?), like comparing two pointers in C. `!=` would compare
        // values, which a plain class doesn't support.
        if view.renderer !== renderer {
            view.renderer = renderer
        }
        view.bindMaterial(named: materialName)
    }
}

/// An MTKView that renders Storm frames on demand and orbits on drag.
///
/// It only draws when something changes (resize, drag, Storm still busy),
/// instead of at 60 frames per second.
///
/// SWIFT: `final` forbids subclassing this class, which lets the compiler
/// call its methods directly instead of through the vtable.
final class StormMTKView: MTKView {
    /// The renderer whose frames this view shows.
    ///
    /// SWIFT: `didSet` is a *property observer*: code that runs after every
    /// assignment, like a setter override in Objective-C.
    var renderer: MGStormRenderer {
        didSet {
            device = renderer.device
            needsDisplay = true
        }
    }

    /// SWIFT: A subclass's designated initializer must set all of its own
    /// stored properties *before* calling `super.init`, and may only use
    /// `self` after it. That is the reverse of the Objective-C habit of
    /// calling `[super init]` first; it guarantees that no method (even an
    /// override called from the superclass's init) ever sees an
    /// uninitialized property.
    /// Scales Storm's double-size frames down to the screen. Nil if its
    /// shaders failed to compile; frames are then copied as they are.
    private let downsampler: Downsampler?

    /// When the camera last moved. Double-size frames cost about three
    /// times as much (22 ms instead of 7 for a 1040 × 1500 viewport), so
    /// while the user is orbiting or zooming, frames are rendered at normal
    /// size, and the smooth one follows once they stop.
    private var lastCameraMove: Date = .distantPast

    /// How long after the last camera move the smooth frame is drawn.
    private static let settleDelay: TimeInterval = 0.15

    init(renderer: MGStormRenderer) {
        self.renderer = renderer
        // SWIFT: `try?` turns a thrown error into nil: without the
        // downsampler the viewport still works, just with jagged edges.
        downsampler = try? Downsampler(device: renderer.device, pixelFormat: .rgba16Float)
        super.init(frame: .zero, device: renderer.device)

        // Storm's output is half-float RGBA. The screen uses the same
        // format, so the fallback path can copy frames with a blit.
        colorPixelFormat = .rgba16Float
        // Storm's colour correction already encoded the pixels as sRGB.
        // Tell the window server, so it doesn't apply the curve twice.
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // The fallback blit writes into the drawable, which "framebuffer
        // only" textures don't allow.
        framebufferOnly = false

        // Draw only when asked (`needsDisplay = true`), like a normal NSView.
        isPaused = true
        enableSetNeedsDisplay = true
    }

    /// SWIFT: NSView declares `init?(coder:)` as `required`, so every
    /// subclass must provide it (it is used when a view is loaded from a
    /// storyboard or nib). We never do that, so it just stops the program.
    /// `fatalError` is Swift's `abort()` with a message.
    required init(coder: NSCoder) {
        fatalError("StormMTKView is not used in nibs or storyboards")
    }

    /// Binds the material called `name` (a MaterialX name, such as
    /// "M_BrushedCopper"), or the file's first material for nil, and redraws
    /// if that changes what is bound.
    func bindMaterial(named name: String?) {
        // SWIFT: `(path as NSString).lastPathComponent`: Swift's String has
        // no path methods, but bridges to NSString, which does.
        let path: String? = name == nil
            ? renderer.materialPaths.first
            : renderer.materialPaths.first(where: { ($0 as NSString).lastPathComponent == name })
        guard let path, path != renderer.boundMaterialPath else {
            return
        }
        if renderer.bindMaterial(atPath: path) {
            needsDisplay = true
        }
    }

    // MARK: Drawing

    /// Renders a frame with Storm and copies it to the screen.
    ///
    /// SWIFT: `override` is mandatory when replacing a superclass method;
    /// forgetting it, or writing it on a method that doesn't exist in the
    /// superclass, is a compile error. Objective-C had no such check.
    override func draw(_ dirtyRect: NSRect) {
        let width: Int = Int(drawableSize.width)
        let height: Int = Int(drawableSize.height)
        // Render larger for anti-aliasing, if the downsampler is available
        // and the camera is still.
        let moving: Bool = Date().timeIntervalSince(lastCameraMove) < Self.settleDelay
        let factor: Int = (downsampler == nil || moving) ? 1 : Downsampler.factor

        // SWIFT: One `guard` can unwrap several optionals and check
        // conditions; if any fails, the `else` branch must leave the function.
        guard let frame = renderer.render(withWidth: width * factor, height: height * factor),
              let drawable = currentDrawable,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else {
            return
        }

        // The command buffer comes from Storm's own queue, so what it does
        // runs after Storm's rendering commands.
        if let downsampler {
            // Draw the frame into the drawable at its real size: scaled down
            // if it is double size, a plain copy otherwise.
            downsampler.encode(from: frame, to: drawable.texture, in: commandBuffer)
        } else if frame.pixelFormat == drawable.texture.pixelFormat,
                  let blit = commandBuffer.makeBlitCommandEncoder() {
            // Fallback: copy Storm's frame into the drawable as it is.
            let size = MTLSize(width: min(width, frame.width, drawable.texture.width),
                               height: min(height, frame.height, drawable.texture.height),
                               depth: 1)
            blit.copy(from: frame, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Storm compiles shaders and loads textures in the background. Keep
        // drawing until it has finished, so the final image appears without
        // the user having to move the camera.
        if !renderer.isConverged {
            // SWIFT: Setting `needsDisplay` inside `draw` would be ignored, so
            // ask again on the next turn of the main run loop. `Task { }`
            // schedules a closure; `@MainActor` makes it run on the main
            // thread. `[weak self]` captures `self` without retaining it, as
            // `__weak` does for an Objective-C block, so a pending task
            // doesn't keep a closed view alive. `self?` is nil if it's gone.
            Task { @MainActor [weak self] in
                self?.needsDisplay = true
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Camera

    override func mouseDragged(with event: NSEvent) {
        // Half a degree per point of mouse movement.
        renderer.azimuth -= event.deltaX * 0.5
        renderer.elevation += event.deltaY * 0.5
        cameraMoved()
    }

    override func scrollWheel(with event: NSEvent) {
        // Zoom by a constant factor per scroll step, so it feels the same
        // close up and far away. Keep the camera outside the sphere.
        let factor: Double = exp(-event.scrollingDeltaY * 0.01)
        renderer.distance = min(max(renderer.distance * factor, 1.5), 50.0)
        cameraMoved()
    }

    /// Redraws now (fast, normal size) and schedules the smooth frame for
    /// when the camera has been still for `settleDelay`.
    private func cameraMoved() {
        lastCameraMove = Date()
        needsDisplay = true
        // SWIFT: `Task.sleep(for:)` suspends the task without blocking the
        // main thread; `try?` ignores the error it throws if the task is
        // cancelled. If the camera moved again meanwhile, a later task will
        // do the redraw, so this one does nothing.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay + 0.02))
            guard let self, Date().timeIntervalSince(self.lastCameraMove) >= Self.settleDelay else {
                return
            }
            self.needsDisplay = true
        }
    }
}
