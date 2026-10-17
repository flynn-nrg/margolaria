// swift-tools-version: 6.1
//
// Package.swift: the manifest for MXKit, Margolaria's MaterialX layer.
//
// SWIFT: A Swift package is described by Swift code, not by a data file. This
// file is compiled and run by SwiftPM (`swift build`, `swift test`, or Xcode)
// to find out what the package contains. The comment on the very first line
// is not decoration: it tells SwiftPM which manifest API version to use.
//
// The package has two "targets" (a target is roughly a library or a module):
//
//   MXBridge  C++. The only code that includes MaterialX headers. It catches
//             C++ exceptions and exposes a small, Swift-friendly C++ API.
//   MXKit     Swift. The API the app uses. It wraps MXBridge in Swift types.
//
// Why the split: Swift can call C++ directly, but not every C++ construct
// imports cleanly (heavy templates, exceptions, MaterialX's shared_ptr-based
// API). Keeping MaterialX behind a narrow C++ API we control means the Swift
// side only ever sees simple types. See docs/spikes/M0a-materialx-from-swift.md.

// SWIFT: `import` makes another module's public declarations visible, like
// `#include` plus a namespace, but it imports a compiled module rather than
// pasting text. PackageDescription is the module that defines `Package`,
// `.target(...)` and so on.
import PackageDescription

// SWIFT: `let` declares a constant (it can never be reassigned). `var` would
// declare a variable. SwiftPM looks for a top-level constant named `package`.
let package = Package(
    // SWIFT: Arguments are labelled (`name:`), like Objective-C message
    // arguments. The labels are part of the function's name and are required.
    name: "MXKit",

    // SwiftUsd requires macOS 14; we match the app's minimum (Config/Base.xcconfig).
    // SWIFT: `[...]` is an array literal. `.macOS(.v15)` is shorthand for
    // `SupportedPlatform.macOS(.v15)`: when Swift already knows the expected
    // type, you can leave out the type name and write just `.member`.
    platforms: [.macOS(.v15)],

    // Products are what other packages and the app can depend on.
    products: [
        .library(name: "MXKit", targets: ["MXKit"]),
    ],

    // External packages this package depends on, fetched by SwiftPM.
    dependencies: [
        // apple/SwiftUsd: OpenUSD v26.08 plus MaterialX 1.39.5, as prebuilt
        // dynamic frameworks. `from:` accepts any 8.x version at or above 8.1.0.
        .package(url: "https://github.com/apple/SwiftUsd", from: "8.1.0"),
    ],

    targets: [
        // C++ shim around MaterialX. SwiftPM compiles every .cpp file in
        // Sources/MXBridge, and its public headers live in Sources/MXBridge/include.
        .target(
            name: "MXBridge",
            dependencies: [
                // Linking the OpenUSD product links the MaterialX frameworks.
                // It also puts the MaterialX headers on our include path:
                // SwiftUsd ships them in its public include directory.
                .product(name: "OpenUSD", package: "SwiftUsd"),
            ]
        ),

        // The Swift API.
        .target(
            name: "MXKit",
            dependencies: ["MXBridge"],
            swiftSettings: [
                // Lets this Swift module import C++ headers (MXBridge).
                // Any module that imports MXKit must turn this on too; the app
                // does it with SWIFT_OBJC_INTEROP_MODE in Config/Base.xcconfig.
                .interoperabilityMode(.Cxx),
            ]
        ),

        // Unit tests, run with `swift test` from this directory.
        .testTarget(
            name: "MXKitTests",
            dependencies: ["MXKit"],
            // SWIFT: Files listed as resources are copied into the test bundle,
            // where tests find them with `Bundle.module`.
            resources: [.copy("Fixtures")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],

    // OpenUSD and MaterialX are built as GNU C++17; our C++ must match.
    cxxLanguageStandard: .gnucxx17
)
