// ViewportView.swift
//
// The 3D viewport: a SwiftUI view showing a MaterialX material on a sphere,
// or since M7a another ViewportShape, rendered by Hydra Storm (MGStormRenderer). Drag to orbit, scroll to zoom.
// It shows a .mtlx file, or a document's text; when the text changes (an
// edit, M2c), the same renderer shows the new version.
// Frames are rendered at twice the size and scaled down, which smooths the
// edges, and converted for the screen by an OCIO view transform (M3b); both
// in DisplayPass.swift. The sphere is lit by a ViewportEnvironment. Since
// M5e, another Hydra renderer can draw it instead of Storm
// (ViewportRenderer); MGStormRenderer keeps its name, but renders with
// whichever it is told.
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
// `Task.sleep(for:)`, `Date` arithmetic, bridging a String to NSString, an
// `init` that calls another (`self.init`), `.overlay(alignment:)`; since
// M3b, `oldValue` in `didSet`, and observers not running in `init`; since
// M5e, a `BOOL ... error:` method called as a throwing one.

import AppKit
import ColorKit
import MetalKit
import PreviewKit
import SwiftUI

/// What a viewport shows: a .mtlx file, or a MaterialX document as text.
///
/// SWIFT: `Hashable` lets a `Source` be compared and used as `.task(id:)`;
/// the compiler writes `==` and hashing for enums whose associated values
/// are all Hashable.
public enum ViewportSource: Hashable, Sendable {
    /// A file on disk, read once when the viewport appears (the M0b spike).
    case file(URL)
    /// MaterialX XML, as MXKit's `previewXMLString()` writes it (M2c).
    /// When the text changes, the viewport shows the new version, keeping
    /// its camera and renderer.
    case text(String)
}

/// Shows a material on a sphere, rendered with Storm.
public struct ViewportView: View {
    /// What to show.
    public let source: ViewportSource

    /// The MaterialX name of the material to show, such as "M_BrushedCopper",
    /// or nil for the first material.
    public let materialName: String?

    /// The light around the sphere.
    public let environment: ViewportEnvironment

    /// How Storm's light is shown on the screen, or nil to let Storm encode
    /// sRGB itself (also what happens if OCIO is unavailable).
    public let viewTransform: ViewTransform?

    /// The Hydra renderer that draws it (M5e).
    public let renderer: ViewportRenderer

    /// The shape the material is shown on (M7a).
    public let shape: ViewportShape

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

    /// Why the last change of text couldn't be shown, if it couldn't. The
    /// viewport keeps showing the version before.
    @State private var updateError: String? = nil

    /// SWIFT: A `public` struct gets no public memberwise initializer for
    /// free; the automatic one is `internal`. Code in other modules (the app)
    /// needs this explicit `public init`.
    public init(source: ViewportSource, materialName: String? = nil, environment: ViewportEnvironment = .studio,
                viewTransform: ViewTransform? = .standard, renderer: ViewportRenderer = .storm,
                shape: ViewportShape = .sphere) {
        self.source = source
        self.materialName = materialName
        self.environment = environment
        self.viewTransform = viewTransform
        self.renderer = renderer
        self.shape = shape
    }

    /// Shows a .mtlx file (the M0b spike).
    public init(fileURL: URL, materialName: String? = nil) {
        self.init(source: .file(fileURL), materialName: materialName)
    }

    public var body: some View {
        // SWIFT: `Group` is an invisible container, needed here so the
        // modifiers below apply to whichever branch is shown.
        Group {
            switch content {
            case .loading:
                ProgressView()
            case .ready(let renderer):
                StormView(renderer: renderer, text: text, materialName: materialName,
                          environment: environment, viewTransform: viewTransform,
                          rendererID: self.renderer.id, shape: shape) { error in
                    updateError = error
                }
                // A short note along the bottom when an edit can't be shown.
                .overlay(alignment: .bottom) {
                    if let updateError {
                        Text("Preview not updated: \(updateError)")
                            .font(.caption)
                            .lineLimit(2)
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        // SWIFT: `.task(id:)` runs the closure when the view appears, and
        // again whenever `id` changes. It runs on the main actor, because
        // SwiftUI views are `@MainActor`. Text changes don't make a new
        // renderer (StormView updates the one it has), so the id is the
        // file, or nothing for text.
        .task(id: fileURL) {
            content = makeContent()
        }
        // Text that couldn't make a renderer (no material yet) may be able
        // to now.
        .onChange(of: text) {
            if case .failed = content {
                content = makeContent()
            }
        }
    }

    /// The file shown, for `.file`; nil for text.
    private var fileURL: URL? {
        if case .file(let url) = source {
            return url
        }
        return nil
    }

    /// The text shown, for `.text`; nil for a file.
    private var text: String? {
        if case .text(let text) = source {
            return text
        }
        return nil
    }

    /// Creates the renderer, or describes why it couldn't be created.
    private func makeContent() -> Content {
        // SWIFT: `do`/`catch` handles the error thrown by a `throws`
        // initializer. MGStormRenderer's Objective-C initializer reports
        // failure through `NSError **`; Swift turns that into `throws`
        // automatically. Inside `catch`, the error is available as `error`.
        do {
            switch source {
            case .file(let url):
                return .ready(try MGStormRenderer(materialXFile: url))
            case .text(let text):
                return .ready(try MGStormRenderer(materialXString: text))
            }
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
    /// The document text, for a renderer made from text; nil for a file.
    let text: String?
    let materialName: String?
    let environment: ViewportEnvironment
    let viewTransform: ViewTransform?
    /// The Hydra renderer plugin to draw with (M5e).
    let rendererID: String
    let shape: ViewportShape
    /// Told whether the latest text could be shown: nil if so, otherwise why not.
    let onUpdate: (String?) -> Void

    func makeNSView(context: Context) -> StormMTKView {
        let view = StormMTKView(renderer: renderer, environment: environment, viewTransform: viewTransform)
        view.rendererID = rendererID
        view.shape = shape
        // The renderer was made from this text already.
        view.shownText = text
        view.bindMaterial(named: materialName)
        return view
    }

    func updateNSView(_ view: StormMTKView, context: Context) {
        // SWIFT: `!==` compares object identity (are these the same
        // instance?), like comparing two pointers in C. `!=` would compare
        // values, which a plain class doesn't support.
        if view.renderer !== renderer {
            view.renderer = renderer
            view.shownText = text
        }
        if let text, text != view.shownText {
            let error: String? = view.show(text)
            // SWIFT: SwiftUI forbids changing state while it is updating
            // views (this method). A `Task` on the main actor runs the
            // callback just after, which is allowed.
            Task { @MainActor in
                onUpdate(error)
            }
        }
        view.bindMaterial(named: materialName)
        view.environment = environment
        view.viewTransform = viewTransform
        view.rendererID = rendererID
        view.shape = shape
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
            // A new renderer starts with its own lighting, Storm, and the
            // sphere.
            renderer.use(environment)
            renderer.shape = shape.bridged
            useRenderer()
            needsDisplay = true
        }
    }

    /// The Hydra renderer plugin to draw with (M5e), Storm until set.
    var rendererID: String = ViewportRenderer.storm.id {
        didSet {
            if rendererID != oldValue {
                useRenderer()
                needsDisplay = true
            }
        }
    }

    /// Switches the renderer to `rendererID`. One that can't be loaded
    /// (a plugin gone since the choice was stored) leaves the renderer
    /// as it was.
    private func useRenderer() {
        // SWIFT: The Objective-C method is `-setRendererID:error:`,
        // returning a BOOL. Swift imports a `BOOL ... error:` method as one
        // that throws and returns nothing: NO becomes the thrown NSError.
        do {
            try renderer.setRendererID(rendererID)
        } catch {
            NSLog("Viewport: %@", error.localizedDescription)
        }
    }

    /// The shape shown (M7a), the sphere until set.
    var shape: ViewportShape = .sphere {
        didSet {
            if shape != oldValue {
                renderer.shape = shape.bridged
                needsDisplay = true
            }
        }
    }

    /// The light around the shape.
    var environment: ViewportEnvironment {
        didSet {
            // SWIFT: `oldValue` is the value before the assignment, given
            // to `didSet` for free.
            if environment != oldValue {
                renderer.use(environment)
                needsDisplay = true
            }
        }
    }

    /// The view transform, or nil to show Storm's sRGB as it is.
    var viewTransform: ViewTransform? {
        didSet {
            if viewTransform != oldValue {
                configurePass()
                needsDisplay = true
            }
        }
    }

    /// SWIFT: A subclass's designated initializer must set all of its own
    /// stored properties *before* calling `super.init`, and may only use
    /// `self` after it. That is the reverse of the Objective-C habit of
    /// calling `[super init]` first; it guarantees that no method (even an
    /// override called from the superclass's init) ever sees an
    /// uninitialized property.
    /// Scales Storm's double-size frames down to the screen and applies
    /// the view transform. Nil if its shaders failed to compile; frames
    /// are then copied as they are.
    private var pass: DisplayPass? = nil

    /// When the camera last moved. Double-size frames cost about three
    /// times as much (22 ms instead of 7 for a 1040 × 1500 viewport), so
    /// while the user is orbiting or zooming, frames are rendered at normal
    /// size, and the smooth one follows once they stop.
    private var lastCameraMove: Date = .distantPast

    /// How long after the last camera move the smooth frame is drawn.
    private static let settleDelay: TimeInterval = 0.15

    init(renderer: MGStormRenderer, environment: ViewportEnvironment, viewTransform: ViewTransform?) {
        self.renderer = renderer
        self.environment = environment
        self.viewTransform = viewTransform
        super.init(frame: .zero, device: renderer.device)
        // SWIFT: Property observers (`didSet`) don't run for assignments
        // made in the type's own initializer, so apply these by hand.
        renderer.use(environment)

        // Storm's output is half-float RGBA. The screen uses the same
        // format, so the fallback path can copy frames with a blit.
        // (Embree's is 32-bit float, M5e: without the pass, it isn't shown.)
        colorPixelFormat = .rgba16Float
        // The fallback blit writes into the drawable, which "framebuffer
        // only" textures don't allow.
        framebufferOnly = false
        configurePass()

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

    /// The text the renderer last showed, for a renderer made from text.
    var shownText: String? = nil

    /// Shows a new version of the document: updates the renderer and
    /// redraws. Returns nil, or why the text couldn't be shown (the old
    /// version stays).
    func show(_ text: String) -> String? {
        shownText = text
        do {
            try renderer.updateMaterialXString(text)
        } catch {
            return error.localizedDescription
        }
        needsDisplay = true
        return nil
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

    /// Makes the display pass for `viewTransform`, and tells the screen
    /// what colour space its pixels are in. Without a transform, or if
    /// OCIO's shader can't be built, the pass only scales, and Storm's
    /// sRGB values are shown as they are.
    private func configurePass() {
        // SWIFT: `try?` turns a thrown error into nil.
        if let viewTransform, let shader = try? viewTransform.shader(),
           let transforming = try? DisplayPass(device: renderer.device, pixelFormat: .rgba16Float, transform: shader) {
            pass = transforming
            // The pixels are encoded for the transform's display. Tell the
            // window server, so macOS converts them correctly for the
            // actual screen (and doesn't apply a curve twice).
            colorspace = viewTransform.colorSpace
        } else {
            // Without the pass the viewport still works, with jagged edges.
            pass = try? DisplayPass(device: renderer.device, pixelFormat: .rgba16Float)
            colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    /// Renders a frame with Storm and copies it to the screen.
    ///
    /// SWIFT: `override` is mandatory when replacing a superclass method;
    /// forgetting it, or writing it on a method that doesn't exist in the
    /// superclass, is a compile error. Objective-C had no such check.
    override func draw(_ dirtyRect: NSRect) {
        let width: Int = Int(drawableSize.width)
        let height: Int = Int(drawableSize.height)
        // Render larger for anti-aliasing, if the pass is available and the
        // camera is still.
        let moving: Bool = Date().timeIntervalSince(lastCameraMove) < Self.settleDelay
        let factor: Int = (pass == nil || moving) ? 1 : DisplayPass.factor

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
        if let pass {
            // Draw the frame into the drawable at its real size: scaled down
            // if it is double size, and through the view transform.
            pass.encode(from: frame, to: drawable.texture, in: commandBuffer)
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
