// swift-tools-version: 6.1
//
// Package.swift: the manifest for ViewportKit, Margolaria's 3D viewport.
//
// Spike M0b (docs/spikes/M0b-storm-viewport.md): render a USD stage with a
// MaterialX material in Hydra Storm on Metal, inside an AppKit view.
//
// Targets:
//
//   ViewportBridge  Objective-C++. The only code that includes OpenUSD
//                   headers. Builds the stage and runs Storm; hands back a
//                   Metal texture. Same role as MXBridge in MXKit.
//   ViewportKit     Swift. A SwiftUI view that shows the renderer's output in
//                   an MTKView and orbits the camera on drag.
//
// The manifest mirrors Packages/MXKit/Package.swift; see that file for the
// Swift Package Manager basics.

import PackageDescription

let package = Package(
    name: "ViewportKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ViewportKit", targets: ["ViewportKit"]),
    ],
    dependencies: [
        // The same SwiftUsd as MXKit. SwiftPM resolves both to one copy.
        .package(url: "https://github.com/apple/SwiftUsd", from: "8.1.0"),
    ],
    targets: [
        // Objective-C++ (.mm) wrapper around UsdImagingGLEngine and Storm.
        .target(
            name: "ViewportBridge",
            dependencies: [
                .product(name: "OpenUSD", package: "SwiftUsd"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
            ]
        ),

        // The Swift API: a SwiftUI view around an MTKView.
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

        // Renders frames offscreen and saves them as PNGs, so a render can
        // be checked without running the app. `swift test` from this folder.
        .testTarget(
            name: "ViewportKitTests",
            dependencies: ["ViewportKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],

    // OpenUSD is built as GNU C++17; our C++ must match.
    cxxLanguageStandard: .gnucxx17
)
