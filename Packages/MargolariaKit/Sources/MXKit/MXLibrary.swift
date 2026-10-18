// MXLibrary.swift
//
// The MaterialX standard data libraries (node definitions), loaded once and
// shared by every open document.
//
// Introduces (SWIFT): `final class`, stored `let` properties, initializers,
// `static` members, lazy `static let`, `Result`, `throws`/`throw`, `guard`,
// optionals (`URL?`), multi-binding `guard let`, `@unchecked Sendable`,
// Foundation's `Bundle`/`URL`/`FileManager`.

// SWIFT: Foundation is Apple's base library (strings, URLs, files, dates). It
// is the same framework Objective-C uses; in Swift the classes have Swift
// names (`Bundle` is NSBundle, `URL` is NSURL as a value type).
import Foundation

// The C++ bridge. Its namespace shows up in Swift as `mxbridge`, so the C++
// class mxbridge::Library is `mxbridge.Library` here.
import MXBridge

/// The MaterialX data libraries: stdlib, pbrlib, bxdf, cmlib, lights, nprlib.
///
/// They contain the `<nodedef>` elements that give every node type its inputs,
/// outputs and defaults. Documents reference them for validation and lookups
/// (see ``MXDocument/setDataLibrary(_:)``).
///
/// SWIFT: `class` vs `struct`. Swift has both, and the difference is the most
/// important one in the language:
/// - A `struct` is a *value type*. Assigning or passing it copies it, like a C
///   struct or a C++ object passed by value. Most Swift types are structs:
///   String, Array, Int, URL.
/// - A `class` is a *reference type*. Assigning it copies a reference, and
///   ARC counts the references and frees the object when the last one goes
///   away, exactly like ObjC under ARC or `std::shared_ptr` in C++.
///
/// The library is loaded once and shared, so a class is the honest model.
/// `final` means no subclasses. It lets the compiler call methods directly
/// instead of dynamically, and states that this class isn't designed for
/// inheritance.
///
/// SWIFT: About `@unchecked Sendable`. Swift 6 only lets a value cross between
/// threads if its type is `Sendable`. For classes, the compiler can prove that
/// only in narrow cases, and it cannot see inside a C++ object. `@unchecked`
/// tells the compiler: "trust me, I have checked this by hand". The reasoning:
/// this class has no mutable state of its own (only `let` properties), and
/// after loading we only *read* the MaterialX document. MaterialX guards its
/// internal lookup cache with a mutex, so concurrent reads are safe. Use
/// `@unchecked` rarely, and always with a comment like this one.
public final class MXLibrary: @unchecked Sendable {
    /// The C++ handle. `let` means it is set once in `init` and never changes.
    ///
    /// SWIFT: `internal` (the default, no keyword) so MXDocument, in the same
    /// module, can pass it to C++, while the app cannot see C++ types at all.
    let handle: mxbridge.Library

    /// How many library files were loaded (56 for MaterialX 1.39.5).
    public let fileCount: Int

    /// How many node definitions the libraries contain (807 for MaterialX 1.39.5).
    public let nodeDefinitionCount: Int

    /// Loads the libraries found under `librariesRoot`, the folder that
    /// contains the `libraries` folder.
    ///
    /// SWIFT: `init` is the initializer, Swift's constructor. Every stored
    /// property must have a value before `init` finishes; the compiler checks
    /// this. `throws` means the initializer can fail by throwing an error
    /// instead of returning an object, so there is no half-built instance.
    ///
    /// SWIFT: Parameters have an *argument label* and a *parameter name*. Here
    /// they are the same (`librariesRoot`), so callers write
    /// `MXLibrary(librariesRoot: url)`.
    public init(librariesRoot: URL) throws {
        // SWIFT: `var` because C++ writes into it through the reference
        // parameter (`std::string& errorMessage`). Swift imports a non-const
        // C++ reference as an `inout` parameter, and you pass it with `&`. That
        // looks like C's address-of, but in Swift `&` only ever means "this
        // argument may be modified by the callee".
        var errorMessage = std.string()

        // SWIFT: `.path(percentEncoded: false)` gives the plain file-system
        // path ("/Applications/Margolaria.app/..."), without %20 for spaces.
        // `std.string(...)` converts a Swift String to a C++ std::string.
        let library = mxbridge.Library.loadStandard(
            std.string(librariesRoot.path(percentEncoded: false)),
            &errorMessage
        )

        // SWIFT: `guard condition else { ... }` is an early exit: if the
        // condition is false, the `else` block runs and must leave the scope
        // (here with `throw`). It keeps the "happy path" unindented and is
        // Swift's preferred way to check preconditions.
        guard library.isLoaded() else {
            // SWIFT: `throw` exits the initializer with an error. The caller
            // receives it in a `catch` block (see the tests and the app).
            throw MXError.libraryLoadFailed(errorMessage.swiftString)
        }

        // SWIFT: `self.` is needed only to tell the property apart from a
        // local or parameter with the same name. We write it here for clarity.
        // C++ `int` is imported as Swift `Int32`. Swift never converts
        // between number types implicitly, so `Int(...)` converts explicitly.
        self.handle = library
        self.fileCount = Int(library.fileCount())
        self.nodeDefinitionCount = Int(library.nodeDefinitionCount())
    }

    /// The libraries that ship inside SwiftUsd's `Usd_UsdMtlx` framework,
    /// loaded on first use and then shared by the whole process.
    ///
    /// This works both in the app (frameworks embedded in
    /// Margolaria.app/Contents/Frameworks) and in `swift test` (frameworks
    /// next to the test binary). Holds the error instead if loading failed,
    /// for example ``MXError/libraryNotFound``, so the UI can show what went
    /// wrong rather than crash.
    ///
    /// SWIFT: `static let` properties are initialised lazily, on first use,
    /// and exactly once, even if several threads ask at the same moment (like
    /// a C++ function-local static, or `dispatch_once`). That matters: the
    /// tests run in parallel, and when each test loaded the libraries itself,
    /// the concurrent framework lookups raced and one of them failed.
    ///
    /// SWIFT: `Result<Success, Failure>` is an enum with two cases,
    /// `.success(value)` and `.failure(error)`. `Result { try ... }` runs the
    /// closure and stores whichever outcome happened. Callers either `switch`
    /// over it, or call `.get()`, which returns the value or re-throws the error.
    ///
    /// SWIFT: Swift 6 accepts this shared global only because its type is
    /// `Sendable`: MXLibrary is (see the class comment), and every `Error` is.
    public static let bundled: Result<MXLibrary, any Error> = Result {
        try loadBundled()
    }

    /// Finds and loads the bundled libraries. Use ``bundled`` instead, so they
    /// are loaded only once.
    ///
    /// SWIFT: `static` makes this a type method, called on the type itself:
    /// `MXLibrary.loadBundled()`, like a C++ static member function or an ObjC
    /// `+` class method. It returns a new MXLibrary (`-> MXLibrary`). `private`
    /// means only code inside this type can call it.
    private static func loadBundled() throws -> MXLibrary {
        // SWIFT: `URL?` is an *optional*: either a URL or `nil`. Swift types
        // can't be nil unless they are optional, so a plain `URL` is
        // guaranteed to hold a value, like a C++ reference rather than a
        // pointer. `guard let` unwraps it: if the value is nil, take the
        // `else` branch; otherwise bind the unwrapped URL to `root` for the
        // rest of the function. Compare Go's `v, ok := m[k]; if !ok { ... }`.
        guard let root = bundledLibrariesRoot() else {
            throw MXError.libraryNotFound
        }
        // SWIFT: A call to a throwing function must be marked with `try`. It
        // doesn't catch anything; it marks the spot where an error can leave
        // this function, which is allowed because this function also `throws`.
        return try MXLibrary(librariesRoot: root)
    }

    /// The bundle identifier of SwiftUsd's `Usd_UsdMtlx` framework, which
    /// carries the MaterialX data libraries in its Resources folder.
    ///
    /// We look the framework up by identifier rather than by folder name:
    /// dyld loads it through its real path (`.../Versions/A/...`), so its
    /// folder name isn't reliable.
    private static let usdMtlxBundleIdentifier = "com.pixar.Usd-UsdMtlx"

    /// The folder containing `libraries/`, inside the loaded `Usd_UsdMtlx`
    /// framework, or `nil` if it can't be found.
    ///
    /// SWIFT: `private` means only this type (in this file) can call it.
    private static func bundledLibrariesRoot() -> URL? {
        // `Bundle(identifier:)` finds a *loaded* framework by its identifier.
        // SwiftUsd's frameworks are all linked, so loaded at launch (see the
        // spike notes). It returns nil if no loaded bundle has that identifier.
        //
        // SWIFT: Several `let` bindings in one `guard`, separated by commas,
        // must *all* succeed, otherwise `else` runs. Each binding can use the
        // ones before it. `bundle.resourceURL` is optional too: a bundle may
        // have no Resources folder.
        guard let bundle = Bundle(identifier: usdMtlxBundleIdentifier),
              let resources = bundle.resourceURL
        else {
            return nil
        }

        let root = resources.appending(path: "MaterialX_Libraries")
        let librariesFolder = root.appending(path: "libraries")
        // SWIFT: `FileManager.default` is the shared file manager (NSFileManager).
        guard FileManager.default.fileExists(atPath: librariesFolder.path(percentEncoded: false)) else {
            return nil
        }
        return root
    }
}
