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
// Tab asks the app for its node search (M2e). The keys are actions too,
// in the Graph menu and the command palette (M4f), and all of them are in
// Shortcuts.swift (M7g). The right button is kept
// free for a context menu. Copy, Cut, Paste, Duplicate, Collapse into
// Nodegraph and Ungroup come from the menus, through the responder chain
// (M4a), and so does Group in Backdrop (M4d).
//
// Introduces (SWIFT): `open class` vs `final class`, `isFlipped` override as
// a computed property, `convert(_:from:)`, `NSEvent.ModifierFlags` option
// sets, building an NSMenu in code with `#selector` actions;
// `NSMenuItemValidation` in an extension (M4a); a `case` matching a value
// computed elsewhere (M7g).

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
    /// a node (M2e); S solos the selected node, as ⌥-click does (M3d), and
    /// so does P, the Graph Editor's key (M7g); Return opens the selected
    /// nodegraph, L arranges the level (M7g). The keys are Shortcuts.swift's.
    /// While the canvas has focus, the menus have most of them too, and
    /// take them first; these are for P, which has no menu item, and for a
    /// canvas without the app's menus (tests, the spikes).
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
        // SWIFT: `case Shortcut.frameAll.key:` matches a value computed
        // elsewhere, not only a literal: Swift compares it with `==`.
        case Shortcut.frameAll.key:
            frameAll(nil)
        case Shortcut.frameSelection.key:
            frameSelection(nil)
        case Shortcut.goUp.key:
            goUpOneLevel(nil)
        case Shortcut.solo.key, Shortcut.soloPin.key:
            showSelectionAlone(nil)
        case Shortcut.arrange.key:
            arrange(nil)
        case Shortcut.openNode.key:
            openSelectedNode(nil)
        case Shortcut.addNode.key:
            // Tab: add a node where the pointer is (M2e).
            addNode(nil)
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

    // MARK: Menu commands (M4a)

    /// Edit > Copy: the selected nodes, as MaterialX, to the pasteboard.
    /// The app does the work (GraphCanvasController.onCommand), as for
    /// the actions below.
    @objc public func copy(_ sender: Any?) {
        perform(.copy)
    }

    /// Edit > Cut: copies the selected nodes, then deletes them.
    @objc public func cut(_ sender: Any?) {
        perform(.cut)
    }

    /// Edit > Paste: adds the nodes on the pasteboard under the pointer.
    @objc public func paste(_ sender: Any?) {
        perform(.paste)
    }

    /// Edit > Duplicate (⌘D). Not `duplicate(_:)`, which is NSDocument's
    /// File > Duplicate: the canvas, first in the responder chain, would
    /// take it.
    @objc public func duplicateNodes(_ sender: Any?) {
        perform(.duplicate)
    }

    /// Graph > Collapse into Nodegraph (⌥⌘G).
    @objc public func collapseIntoNodeGraph(_ sender: Any?) {
        perform(.collapse)
    }

    /// Graph > Ungroup Nodegraph (⇧⌥⌘G).
    @objc public func ungroupNodeGraph(_ sender: Any?) {
        perform(.ungroup)
    }

    /// Graph > Group in Backdrop (⌘G, M4d).
    @objc public func groupInBackdrop(_ sender: Any?) {
        perform(.backdrop)
    }

    private func perform(_ command: GraphCommand) {
        if !controller.perform(command, at: pointerLocation()) {
            NSSound.beep()
        }
    }

    /// The commands above, by action, for enabling their menu items.
    fileprivate static let commands: [Selector: GraphCommand] = [
        #selector(copy(_:)): .copy,
        #selector(cut(_:)): .cut,
        #selector(paste(_:)): .paste,
        #selector(duplicateNodes(_:)): .duplicate,
        #selector(collapseIntoNodeGraph(_:)): .collapse,
        #selector(ungroupNodeGraph(_:)): .ungroup,
        #selector(groupInBackdrop(_:)): .backdrop,
    ]

    // MARK: Canvas keys as actions (M4f)

    // The single keys above, also as actions, for the Graph menu and the
    // command palette (which lists the menus). Their items have no key
    // equivalents: a menu item's key equivalent is looked for before the
    // focused view sees the key, so a plain "a" there would take the
    // letter from every text field. The palette shows the keys from
    // `keys` instead.

    /// Graph > Add Node… (Tab): the node search, under the pointer, or in
    /// the middle if the pointer isn't on the canvas.
    @objc public func addNode(_ sender: Any?) {
        controller.requestNodeSearch(at: pointerLocation())
    }

    /// Graph > Frame All (A).
    @objc public func frameAll(_ sender: Any?) {
        controller.frame(.all)
    }

    /// Graph > Frame Selection (F).
    @objc public func frameSelection(_ sender: Any?) {
        controller.frame(.selection)
    }

    /// Graph > Go Up One Level (U): out of a nodegraph.
    @objc public func goUpOneLevel(_ sender: Any?) {
        controller.onNavigateUp?()
    }

    /// Graph > Show in Viewport Alone (S, or P): solo the selected node,
    /// or stop.
    @objc public func showSelectionAlone(_ sender: Any?) {
        if !controller.soloSelection() {
            NSSound.beep()
        }
    }

    /// Graph > Open Nodegraph (Return, M7g): opens the selected node, as a
    /// double-click does.
    @objc public func openSelectedNode(_ sender: Any?) {
        if !controller.openSelection() {
            NSSound.beep()
        }
    }

    /// Graph > Arrange (L, M7g): the canvas bar's Arrange button.
    @objc public func arrange(_ sender: Any?) {
        guard let onArrange = controller.onArrange else {
            NSSound.beep()
            return
        }
        onArrange()
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

// SWIFT: Conforming in an extension keeps the protocol's method together
// with the conformance. `NSMenuItemValidation` is AppKit's protocol for
// it: AppKit asks the object that will receive a menu item's action
// before showing the menu, and greys the item out if it says no.
extension GraphEventView: NSMenuItemValidation {
    /// Enables a menu item whose action this view implements only when it
    /// would do something: Copy with nothing selected is greyed out.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, let command = Self.commands[action] {
            return controller.canPerform(command)
        }
        if menuItem.action == #selector(goUpOneLevel(_:)) {
            // Set only inside a nodegraph (GraphPanel).
            return controller.onNavigateUp != nil
        }
        if menuItem.action == #selector(showSelectionAlone(_:)) {
            return controller.selection.count == 1
        }
        if menuItem.action == #selector(openSelectedNode(_:)) {
            return controller.canOpenSelection
        }
        if menuItem.action == #selector(arrange(_:)) {
            return controller.onArrange != nil && !controller.model.nodes.isEmpty
        }
        if menuItem.action == #selector(delete(_:)) {
            let deletable: GraphDeletion = controller.deletableSelection
            return !deletable.nodes.isEmpty || !deletable.backdrops.isEmpty
        }
        return true
    }
}
