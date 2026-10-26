// GraphEventView.swift
//
// An AppKit view that turns mouse and trackpad events into calls on a
// GraphCanvasController. The Canvas renderer lays a transparent one over
// itself; the Core Animation renderer is a subclass of it.
//
// Gestures:
//   - click/drag on a node selects and moves it; drag on empty canvas draws
//     a marquee (Shift adds to the selection); double-click opens a node;
//   - drag from a pin draws a wire (M2d), ⌥-drag cuts wires, Escape
//     abandons either; a wire dropped on a node may ask, with a menu,
//     which input to connect;
//   - pan: two-finger scroll on a trackpad, middle-button drag, or
//     Space + drag;
//   - zoom around the pointer: pinch, mouse wheel, or ⌥-scroll.
// Tab asks the app for its node search (M2e). The right button is kept
// free for a context menu.
//
// Introduces (SWIFT): `open class` vs `final class`, `isFlipped` override as
// a computed property, `convert(_:from:)`, `NSEvent.ModifierFlags` option
// sets, building an NSMenu in code with `#selector` actions.

import AppKit

/// Forwards input events to a GraphCanvasController.
///
/// SWIFT: `open` allows subclasses outside this module; inside the module,
/// a plain `class` (not `final`) would do. LayerGraphView subclasses it here,
/// so `class` is enough; it is not `final` for that reason.
public class GraphEventView: NSView {
    public let controller: GraphCanvasController

    /// Where the last pan-drag event was, while panning with the middle
    /// button or Space + drag; nil otherwise.
    private var panAnchor: CGPoint? = nil

    /// True while the Space bar is held down: left-drags pan instead.
    private var spaceHeld: Bool = false

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
        // Clicking the canvas gives it the keyboard (A, F, U below).
        window?.makeFirstResponder(self)
        // AppKit sends one mouseDown per click; `clickCount` is 2 for the
        // second click of a double-click.
        if event.clickCount == 2 {
            controller.doubleClick(at: location(of: event))
            return
        }
        if spaceHeld {
            beginPan(at: event)
            return
        }
        // SWIFT: `modifierFlags` is an *option set* (a bit mask with a Set-like
        // API): `.contains(.shift)` is `flags & NSEventModifierFlagShift`.
        controller.mouseDown(at: location(of: event), extend: event.modifierFlags.contains(.shift),
                             cut: event.modifierFlags.contains(.option))
    }

    /// The view can take keyboard focus (be the *first responder*).
    public override var acceptsFirstResponder: Bool { true }

    /// Takes keyboard focus when the canvas appears. The app puts a new
    /// canvas view in the window for each graph level, and the old one,
    /// which had focus, is gone; without this, the shortcuts below would do
    /// nothing until the user clicked the new canvas.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// Keyboard shortcuts, as in MaterialX's Graph Editor (PLAN.md §4.2):
    /// A frames everything, F the selection, U leaves a nodegraph; Tab adds
    /// a node (M2e).
    public override func keyDown(with event: NSEvent) {
        // Only plain keys; ⌘A and friends go to the menus.
        let modifiers: NSEvent.ModifierFlags = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }
        switch key {
        case " ":
            // Key repeat sends more key-downs while Space stays down; one
            // is enough.
            spaceHeld = true
        case "a":
            controller.frame(.all)
        case "f":
            controller.frame(.selection)
        case "u":
            controller.onNavigateUp?()
        case "\t":
            // Tab: add a node where the pointer is (M2e).
            controller.requestNodeSearch(at: pointerLocation())
        case "\u{1B}":
            // Escape: abandon a wire or cut being dragged.
            controller.cancelDrag()
        case "\u{7F}", String(Character(UnicodeScalar(NSDeleteFunctionKey)!)):
            // The Delete key (⌫, character 127) and Forward Delete (⌦).
            controller.deleteSelection()
        default:
            // Unhandled keys go up the responder chain (and beep at its end).
            super.keyDown(with: event)
        }
    }

    /// Where the pointer is in this view, or the view's centre if it is
    /// outside. Key events don't carry a location, so ask the window.
    private func pointerLocation() -> CGPoint {
        // SWIFT/AppKit: `mouseLocationOutsideOfEventStream` is the pointer's
        // position in window coordinates, right now.
        let point: CGPoint = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        return bounds.contains(point) ? point : CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Edit > Delete. AppKit finds this method through the responder chain
    /// when the canvas has keyboard focus, and enables the menu item.
    ///
    /// SWIFT: `@objc` makes the method visible to the Objective-C runtime,
    /// which is how menu actions find it. `delete(_:)` is a standard AppKit
    /// action name (NSText declares it too).
    @objc public func delete(_ sender: Any?) {
        controller.deleteSelection()
    }

    /// Keeps the controller's idea of the view size current, for framing.
    /// AppKit calls this whenever the view's size changes.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller.viewSize = newSize
    }

    public override func mouseDragged(with event: NSEvent) {
        if panAnchor != nil {
            continuePan(with: event)
            return
        }
        controller.mouseDragged(to: location(of: event))
    }

    public override func mouseUp(with event: NSEvent) {
        if panAnchor != nil {
            endPan()
            return
        }
        if let menu = controller.mouseUp() {
            showMenu(menu)
        }
    }

    // MARK: Choosing an input

    /// The item chosen from the last wire menu, set by `chooseItem(_:)`.
    private var chosenItem: Int? = nil

    /// Shows the menu of inputs a dropped wire could connect to, and
    /// passes the choice (or nil) to the controller.
    private func showMenu(_ wireMenu: WireMenu) {
        let menu = NSMenu(title: wireMenu.title)
        // A disabled first item works as a heading.
        let heading = NSMenuItem(title: wireMenu.title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for (index, title) in wireMenu.items.enumerated() {
            // SWIFT: `#selector(chooseItem(_:))` names an `@objc` method,
            // checked by the compiler; AppKit calls it on `target` when the
            // item is chosen. The item's `tag` says which one it was.
            let item = NSMenuItem(title: title, action: #selector(chooseItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        // Without this, AppKit would enable items by asking the responder
        // chain; these are always available.
        menu.autoenablesItems = false
        chosenItem = nil
        // `popUp` runs the menu and returns once it closes, after calling
        // the chosen item's action, if any.
        menu.popUp(positioning: nil, at: wireMenu.location, in: self)
        controller.chooseConnection(chosenItem)
    }

    @objc private func chooseItem(_ sender: NSMenuItem) {
        chosenItem = sender.tag
    }

    // MARK: Panning with a mouse

    // AppKit reports buttons other than left and right as "other mouse"
    // events; `buttonNumber` 2 is the middle button (or wheel click).
    public override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            beginPan(at: event)
        } else {
            super.otherMouseDown(with: event)
        }
    }

    public override func otherMouseDragged(with event: NSEvent) {
        if panAnchor != nil {
            continuePan(with: event)
        } else {
            super.otherMouseDragged(with: event)
        }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if panAnchor != nil {
            endPan()
        } else {
            super.otherMouseUp(with: event)
        }
    }

    private func beginPan(at event: NSEvent) {
        panAnchor = location(of: event)
        // The "grabbing" hand while dragging the canvas.
        NSCursor.closedHand.push()
    }

    private func continuePan(with event: NSEvent) {
        guard let last = panAnchor else {
            return
        }
        let point: CGPoint = location(of: event)
        // The graph follows the pointer.
        controller.scroll(by: CGSize(width: point.x - last.x, height: point.y - last.y))
        panAnchor = point
    }

    private func endPan() {
        panAnchor = nil
        // SWIFT/AppKit: `push` and `pop` keep a stack of cursors; this
        // removes the hand pushed in beginPan.
        NSCursor.pop()
    }

    /// Losing keyboard focus means the Space key-up may go elsewhere, so
    /// stop treating Space as held.
    public override func resignFirstResponder() -> Bool {
        spaceHeld = false
        return super.resignFirstResponder()
    }

    /// Space held down: left-drags pan until it's released.
    public override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            spaceHeld = false
        } else {
            super.keyUp(with: event)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        // Trackpads and the Magic Mouse send smooth ("precise") deltas in
        // points; a classic mouse wheel sends coarse steps. Smooth scrolling
        // pans, as in every Mac app; a wheel zooms, as in node editors.
        let isWheel: Bool = !event.hasPreciseScrollingDeltas
        if isWheel {
            // About 10% per wheel step.
            controller.zoom(by: exp(event.scrollingDeltaY * 0.1), at: location(of: event))
        } else if event.modifierFlags.contains(.option) {
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
