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
// Introduces (SWIFT): `@main` on a type with `static func main()`,
// `@MainActor` on a function, `withExtendedLifetime`, `NSObject` subclasses
// conforming to Objective-C protocols.

import AppKit

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
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Lets macOS restore open windows securely after a relaunch. Apple
    /// requires `true` for new apps.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
