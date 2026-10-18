// ViewportView.swift
//
// The 3D viewport: a SwiftUI view showing a .mtlx material on a sphere,
// rendered by Hydra Storm (MGStormRenderer). Drag to orbit, scroll to zoom.
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
// `.task(id:)`, `[weak self]` capture lists, `===` identity comparison.

import AppKit
import MetalKit
import SwiftUI

/// Shows the first material in a .mtlx file on a sphere, rendered with Storm.
public struct ViewportView: View {
    /// The .mtlx file to show.
    public let fileURL: URL

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
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public var body: some View {
        // SWIFT: `Group` is an invisible container, needed here so the
        // `.task` modifier below applies to whichever branch is shown.
        Group {
            switch content {
            case .loading:
                ProgressView()
            case .ready(let renderer):
                StormView(renderer: renderer)
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

    func makeNSView(context: Context) -> StormMTKView {
        StormMTKView(renderer: renderer)
    }

    func updateNSView(_ view: StormMTKView, context: Context) {
        // SWIFT: `!==` compares object identity (are these the same
        // instance?), like comparing two pointers in C. `!=` would compare
        // values, which a plain class doesn't support.
        if view.renderer !== renderer {
            view.renderer = renderer
        }
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
    init(renderer: MGStormRenderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)

        // Storm's output is half-float RGBA. Using the same format for the
        // screen lets us copy the frame with a blit instead of a shader.
        colorPixelFormat = .rgba16Float
        // Storm's colour correction already encoded the pixels as sRGB.
        // Tell the window server, so it doesn't apply the curve twice.
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // A blit writes into the drawable, which "framebuffer only"
        // textures don't allow.
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

    // MARK: Drawing

    /// Renders a frame with Storm and copies it to the screen.
    ///
    /// SWIFT: `override` is mandatory when replacing a superclass method;
    /// forgetting it, or writing it on a method that doesn't exist in the
    /// superclass, is a compile error. Objective-C had no such check.
    override func draw(_ dirtyRect: NSRect) {
        let width: Int = Int(drawableSize.width)
        let height: Int = Int(drawableSize.height)

        // SWIFT: One `guard` can unwrap several optionals and check
        // conditions; if any fails, the `else` branch must leave the function.
        guard let frame = renderer.render(withWidth: width, height: height),
              let drawable = currentDrawable,
              frame.pixelFormat == drawable.texture.pixelFormat,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            return
        }

        // Copy Storm's frame into the drawable. The command buffer comes from
        // Storm's own queue, so it runs after Storm's rendering commands.
        let size = MTLSize(width: min(width, frame.width, drawable.texture.width),
                           height: min(height, frame.height, drawable.texture.height),
                           depth: 1)
        blit.copy(from: frame, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
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
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // Zoom by a constant factor per scroll step, so it feels the same
        // close up and far away. Keep the camera outside the sphere.
        let factor: Double = exp(-event.scrollingDeltaY * 0.01)
        renderer.distance = min(max(renderer.distance * factor, 1.5), 50.0)
        needsDisplay = true
    }
}
