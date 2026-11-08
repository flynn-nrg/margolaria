// CxxString.swift
//
// Conversion from C++ std::string to Swift String, in one place.
//
// Introduces (SWIFT): importing C++ (`import CxxStdlib`), how C++ types look in
// Swift, `internal` access, extensions on imported C++ types.

// SWIFT: With C++ interop turned on (see Package.swift), C++ headers are
// imported as Swift modules. `CxxStdlib` is the C++ standard library: after
// this import, `std.string` is the Swift name for `std::string`, and `std` is
// the namespace, written with a dot instead of `::`.
import CxxStdlib

// SWIFT: This adds a property to the C++ type `std::string` itself. Extensions
// work on imported C++ types just as on Swift types. The added property
// exists only on the Swift side; the C++ class is unchanged.
//
// SWIFT: `package` means visible to every module of this Swift package
// (ScriptKit uses it too, M6) but not to the app. Swift's access levels,
// from most to least visible: `public`/`open` (other modules), `package`
// (this package's modules), `internal` (this module, the default),
// `fileprivate` (this file), `private` (this declaration and its extensions
// in this file).
extension std.string {
    /// This C++ string as a Swift `String`. The bytes are copied and decoded as UTF-8.
    ///
    /// The obvious spelling, `String(cxxString)`, should work: the Swift
    /// C++ overlay defines that initializer. With the SwiftUsd module graph in
    /// the build, Swift 6.4 fails to select it ("no exact matches in call to
    /// initializer"). `description` does the same conversion inside the overlay
    /// and does resolve, so we go through it, and keep the workaround in this
    /// one place. See docs/spikes/M0a-materialx-from-swift.md.
    package var swiftString: String {
        description
    }
}
