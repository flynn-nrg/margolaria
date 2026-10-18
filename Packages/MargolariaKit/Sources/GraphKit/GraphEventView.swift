// GraphEventView.swift
//
// An AppKit view that turns mouse and trackpad events into calls on a
// GraphCanvasController. The Canvas renderer lays a transparent one over
// itself; the Core Animation renderer is a subclass of it.
//
// Gestures: click/drag on a node selects and moves it; drag on empty canvas
// draws a marquee (Shift adds to the selection); two-finger scroll or mouse
// wheel pans; pinch, or ⌥-scroll, zooms around the pointer.
//
// Introduces (SWIFT): `open class` vs `final class`, `isFlipped` override as
// a computed property, `convert(_:from:)`, `NSEvent.ModifierFlags` option sets.

import AppKit

/// Forwards input events to a GraphCanvasController.
///
/// SWIFT: `open` allows subclasses outside this module; inside the module,
/// a plain `class` (not `final`) would do. LayerGraphView subclasses it here,
/// so `class` is enough; it is not `final` for that reason.
public class GraphEventView: NSView {
    public let controller: GraphCanvasController

    public init(controller: GraphCanvasController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("GraphEventView is not used in nibs or storyboards")
    }

    /// y grows downwards, as in graph coordinates.
    ///
    /// SWIFT: Overriding a property with a getter-only computed property.
    public override var isFlipped: Bool { true }

    /// Receive the first click even when the window isn't active.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The event's location in this view's (flipped) coordinates.
    private func location(of event: NSEvent) -> CGPoint {
        // SWIFT: `nil` for "from the window's coordinate space".
        convert(event.locationInWindow, from: nil)
    }

    public override func mouseDown(with event: NSEvent) {
        // SWIFT: `modifierFlags` is an *option set* (a bit mask with a Set-like
        // API): `.contains(.shift)` is `flags & NSEventModifierFlagShift`.
        controller.mouseDown(at: location(of: event), extend: event.modifierFlags.contains(.shift))
    }

    public override func mouseDragged(with event: NSEvent) {
        controller.mouseDragged(to: location(of: event))
    }

    public override func mouseUp(with event: NSEvent) {
        controller.mouseUp()
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            // ⌥-scroll zooms: about 1% per point scrolled.
            controller.zoom(by: exp(event.scrollingDeltaY * 0.01), at: location(of: event))
        } else {
            controller.scroll(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
    }

    public override func magnify(with event: NSEvent) {
        controller.zoom(by: 1 + event.magnification, at: location(of: event))
    }
}
