// MargolariaApp.swift
//
// The app's entry point: starts AppKit, installs the main menu and the app
// delegate. Documents are AppKit `NSDocument`s (MaterialXDocument.swift);
// everything inside their windows is SwiftUI.
//
// Why AppKit at the top rather than a SwiftUI `App`: SwiftUI's own document
// support (`DocumentGroup` with `ReferenceFileDocument`) only hands a
// document the file's *contents*, not its location. A MaterialX file needs
// its location: `xi:include` and texture paths are relative to it. NSDocument
// knows the file's URL, and brings the full Mac document behaviour with it
// (autosave, versions, Revert To, Duplicate, Rename, Move To). The decision
// is in docs/PLAN.md §3.
//
// The app delegate also runs the user's startup scripts at launch (M6d),
// and handles the Scripts menu's own items.
//
// Introduces (SWIFT): `@main` on a type with `static func main()`,
// `@MainActor` on a function, `withExtendedLifetime`, `NSObject` subclasses
// conforming to Objective-C protocols, selector-based notification observers.

import AppKit
import ScriptKit

/// The program's entry point.
///
/// SWIFT: `@main` marks the type whose `static func main()` runs when the
/// program starts, like C's `main()`. An enum with no cases is used because
/// nothing ever creates an instance of it.
@main
enum MargolariaApp {
    /// Sets up the application object and runs the event loop. Never returns.
    ///
    /// SWIFT: `@MainActor`: this runs on the main thread, where all AppKit
    /// calls must happen. Swift 6 checks that every AppKit call below is
    /// made from main-actor code.
    @MainActor
    static func main() {
        // The shared application object, NSApp in Objective-C.
        let application: NSApplication = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.mainMenu = MainMenu.make()

        // NSApplication holds its delegate *weakly*, as most Cocoa
        // delegates are held. Nothing else refers to `delegate`, so without
        // help ARC could free it right after the assignment above: Swift may
        // end a local's lifetime after its last use, not at the closing
        // brace as C++ would.
        //
        // SWIFT: `withExtendedLifetime(x) { ... }` guarantees that `x` stays
        // alive until the closure returns. `run()` only returns when the app
        // quits, so the delegate lives as long as the app.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

/// Receives application-level events from AppKit.
///
/// SWIFT: AppKit's delegate protocols are Objective-C protocols, so the class
/// must inherit from `NSObject` to conform. `NSApplicationDelegate` methods
/// are all optional; we implement the few we need.
///
/// SWIFT: `@MainActor` on the class puts all of it on the main actor. The
/// delegate methods already were (the protocol says so), but the
/// notification method below is our own, and would otherwise be
/// nonisolated, unable to touch windows without a warning.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Lets macOS restore open windows securely after a relaunch. Apple
    /// requires `true` for new apps.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// The name under which AppKit saves the colour panel's position.
    private static let colorPanelFrameName: String = "MargolariaColorPanel"

    /// True once the colour panel has been given a position.
    private var colorPanelPlaced: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The inspector's colour wells open AppKit's shared colour panel.
        // The first time, it has no saved position and appears at the
        // screen's origin, the bottom-left corner. Watch for it becoming
        // visible and place it then.
        //
        // SWIFT: The selector-based `addObserver` calls an `@objc` method
        // of `self`, on the thread that posts the notification (here the
        // main thread: AppKit posts window notifications there).
        NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        runStartupScripts()
    }

    // MARK: Startup scripts (M6d)

    /// How long launch waits for each startup script before going on
    /// (it then ends in the background), as a window waits for a script.
    private static let startupPatience: TimeInterval = 0.25

    /// Runs the startup scripts (ScriptKit's StartupScripts); the windows'
    /// Consoles report them when they end. Python only starts if there are
    /// any.
    private func runStartupScripts() {
        StartupScripts.run(from: .inApp(), waitingUpTo: Self.startupPatience) { reports in
            MaterialXDocument.startupScriptsEnded(reports)
        }
    }

    /// Scripts > Reload Startup Scripts: runs them again, after forgetting
    /// their commands, so a script just edited takes effect. Modules they
    /// import aren't read again: Python keeps them until Margolaria quits.
    @objc func reloadStartupScripts(_ sender: Any?) {
        runStartupScripts()
    }

    /// Scripts > Open Scripts Folder: shows the startup scripts' folder in
    /// the Finder, made first if it isn't there.
    @objc func openScriptsFolder(_ sender: Any?) {
        do {
            try FileManager.default.createDirectory(at: StartupScripts.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(StartupScripts.folder)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// Scripts > Stop Script: stops the script running, wherever it was
    /// started: a startup script, which has no window and no Stop button
    /// of its own, or a window's (as its sheet's Stop does).
    @objc func stopScript(_ sender: Any?) {
        ScriptRun.current?.stop()
    }

    /// Places the colour panel the first time it appears: where it was
    /// left last time, or else beside the pointer, which is on the colour
    /// well that opened it. Its position is saved from then on.
    @objc private func windowOcclusionChanged(_ notification: Notification) {
        // SWIFT: `as?` (a conditional cast) also filters: other windows'
        // notifications give nil and return here.
        guard !colorPanelPlaced, let panel = notification.object as? NSColorPanel, panel.isVisible else {
            return
        }
        colorPanelPlaced = true
        if !panel.setFrameUsingName(Self.colorPanelFrameName) {
            panel.setFrame(Self.frameBesidePointer(size: panel.frame.size), display: true)
        }
        panel.setFrameAutosaveName(Self.colorPanelFrameName)
    }

    /// A frame of `size` to the left of the pointer, centred on it
    /// vertically, kept on the pointer's screen. (Screen coordinates: y up.)
    private static func frameBesidePointer(size: CGSize) -> CGRect {
        let pointer: CGPoint = NSEvent.mouseLocation
        let screen: NSScreen? = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        var frame = CGRect(x: pointer.x - size.width - 24, y: pointer.y - size.height / 2,
                           width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        return frame
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Stop Script while a script runs; Reload Startup Scripts while none
    /// does (they would be refused).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(stopScript(_:)):
            return ScriptRun.current.map { !$0.isStopping } ?? false
        case #selector(reloadStartupScripts(_:)):
            return ScriptRun.current == nil && !StartupScripts.isRunning
        default:
            return true
        }
    }
}
