// MargolariaApp.swift
//
// The app's entry point: declares the app and its document windows.
//
// Introduces (SWIFT): `@main`, the SwiftUI `App` protocol, `some` (opaque
// types), result builders (the `{ ... }` UI syntax), trailing closures.

// SWIFT: SwiftUI is Apple's declarative UI framework. You describe what the UI
// should look like for the current data, and SwiftUI works out how to create
// and update the actual AppKit views. Compare AppKit, where you create views
// and then mutate them yourself.
import SwiftUI

/// Margolaria, the application.
///
/// SWIFT: `@main` marks the program's entry point, replacing C's `main()`.
/// The type must provide a `static func main()`; conforming to SwiftUI's `App`
/// protocol supplies one that starts the AppKit event loop.
///
/// SWIFT: The app is a `struct`. SwiftUI types describing UI are almost always
/// small structs: they are descriptions, created and thrown away often, and
/// SwiftUI keeps the real long-lived objects (windows, views) itself.
@main
struct MargolariaApp: App {
    /// The app's scenes (window groups). The `App` protocol requires this property.
    ///
    /// SWIFT: `some Scene` is an *opaque type*: "a specific type conforming to
    /// Scene, which the compiler knows but which I don't have to spell out".
    /// The real type here is a long generic one (something like
    /// DocumentGroup<MaterialXFileDocument, ContentView>). Compare C++'s
    /// `auto` return type.
    ///
    /// SWIFT: The braces after `body` hold a *result builder* block: each
    /// expression in it becomes part of the result, without commas or
    /// `return`. That's how SwiftUI's nested UI syntax works. It is still
    /// ordinary Swift, transformed by the compiler.
    var body: some Scene {
        // DocumentGroup gives us the standard Mac document app for free: File >
        // New/Open/Save, Open Recent, tabs, autosave and versions. The first
        // closure creates a new, untitled document; the second builds the view
        // for each open document.
        //
        // SWIFT: `{ MaterialXFileDocument() }` is a closure that takes no
        // arguments and returns a new document. `file in` names the second
        // closure's parameter (a configuration object giving access to the
        // document). Writing a closure after the call's parentheses is
        // *trailing closure* syntax, and additional trailing closures get labels
        // (`editor:`).
        DocumentGroup {
            MaterialXFileDocument()
        } editor: { file in
            ContentView(file: file.document)
        }
    }
}
