// swift-tools-version: 6.1
//
// Package.swift: the manifest for MargolariaKit, all of Margolaria's code
// that talks to OpenUSD and MaterialX.
//
// SWIFT: A Swift package is described by Swift code, not by a data file. This
// file is compiled and run by SwiftPM (`swift build`, `swift test`, or Xcode)
// to find out what the package contains. The comment on the very first line
// is not decoration: it tells SwiftPM which manifest API version to use.
//
// The package has four "targets" (a target is roughly a library or a module),
// in two layers:
//
//   MXBridge        C++. The only code that includes MaterialX headers.
//   MXKit           Swift. The MaterialX API the app uses (documents, libraries).
//   ViewportBridge  Objective-C++. The only code that includes OpenUSD headers;
//                   runs Hydra Storm on Metal.
//   ViewportKit     Swift. The SwiftUI viewport.
//
// Why bridges: Swift can call C++ directly, but not every C++ construct
// imports cleanly (heavy templates, exceptions, shared_ptr-based APIs).
// Keeping OpenUSD and MaterialX behind narrow APIs we control means the Swift
// side only ever sees simple types. See docs/spikes/M0a-materialx-from-swift.md
// and docs/spikes/M0b-storm-viewport.md.
//
// Why one package rather than one per kit: every package builds its own copy
// of everything it depends on, in its own .build folder. With OpenUSD in the
// dependencies, that was minutes per package. Here, all targets share one
// build. Add new modules as targets in this package.

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
    name: "MargolariaKit",

    // SwiftUsd requires macOS 14; we match the app's minimum (Config/Base.xcconfig).
    // SWIFT: `[...]` is an array literal. `.macOS(.v15)` is shorthand for
    // `SupportedPlatform.macOS(.v15)`: when Swift already knows the expected
    // type, you can leave out the type name and write just `.member`.
    platforms: [.macOS(.v15)],

    // Products are what other packages and the app can depend on.
    products: [
        .library(name: "MXKit", targets: ["MXKit"]),
        .library(name: "ViewportKit", targets: ["ViewportKit"]),
    ],

    // Packages this package depends on.
    dependencies: [
        // apple/SwiftUsd: OpenUSD v26.08 plus MaterialX 1.39.5, as prebuilt
        // dynamic frameworks. A local copy, patched to add the `OpenUSDCxx`
        // product (headers and frameworks only, without SwiftUsd's Swift
        // overlay, which we don't use and which dominated build times).
        // Create it with scripts/fetch-swiftusd.sh, which also pins the version.
        .package(name: "OpenUSD", path: "../../Vendor/SwiftUsd"),
    ],

    targets: [
        // C++ shim around MaterialX. SwiftPM compiles every .cpp file in
        // Sources/MXBridge, and its public headers live in Sources/MXBridge/include.
        .target(
            name: "MXBridge",
            dependencies: [
                // Links the OpenUSD and MaterialX frameworks, and puts their
                // headers on our include path.
                .product(name: "OpenUSDCxx", package: "OpenUSD"),
            ]
        ),

        // The MaterialX Swift API.
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

        // Objective-C++ (.mm) wrapper around UsdImagingGLEngine and Storm.
        .target(
            name: "ViewportBridge",
            dependencies: [
                .product(name: "OpenUSDCxx", package: "OpenUSD"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
            ]
        ),

        // The viewport: a SwiftUI view around an MTKView.
        .target(
            name: "ViewportKit",
            dependencies: ["ViewportBridge"],
            swiftSettings: [
                // ViewportBridge's own header is plain Objective-C, but its
                // module depends on OpenUSD's C++ modules, which Swift can
                // only load with C++ interop on.
                .interoperabilityMode(.Cxx),
            ]
        ),

        // Unit tests, run with `swift test` from this directory, or with
        // `xcodebuild test -scheme Margolaria` (shares the app's build).
        .testTarget(
            name: "MXKitTests",
            dependencies: ["MXKit"],
            // SWIFT: Files listed as resources are copied into the test bundle,
            // where tests find them with `Bundle.module`.
            resources: [.copy("Fixtures")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),

        // Renders frames offscreen and saves them as PNGs, so a render can
        // be checked without running the app.
        .testTarget(
            name: "ViewportKitTests",
            dependencies: ["ViewportKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],

    // OpenUSD and MaterialX are built as GNU C++17; our C++ must match.
    cxxLanguageStandard: .gnucxx17
)
