// ViewportSpikeApp.swift
//
// Demo app for spike M0b: one window with the Storm viewport showing a .mtlx
// material on a sphere. It starts with the bundled brushed_copper.mtlx; the
// Open button picks another file. Drag to orbit, scroll to zoom.
//
// This is a throwaway target, kept small on purpose. The viewport itself
// (Packages/ViewportKit) is what moves into the real app in M1.
//
// Introduces (SWIFT): `WindowGroup`, `.fileImporter`, `Result` and its
// `switch`, `.toolbar` with a button, `UTType` from a file extension.

import SwiftUI
import UniformTypeIdentifiers
import ViewportKit

/// The spike app: a single window.
@main
struct ViewportSpikeApp: App {
    var body: some Scene {
        // SWIFT: `WindowGroup` is a plain window (not document-based, unlike
        // the main app's `DocumentGroup`).
        WindowGroup("Storm Viewport Spike") {
            SpikeWindow()
        }
    }
}

/// The window's content: the viewport and an Open button.
private struct SpikeWindow: View {
    /// The file on show. Starts with the copy of brushed_copper.mtlx in the
    /// app's resources.
    ///
    /// SWIFT: `Bundle.main.url(...)` returns an optional (the file may be
    /// missing); `!` asserts it isn't. The file is part of this target, so a
    /// crash here would mean a broken build, not a user error.
    @State private var fileURL: URL = Bundle.main.url(forResource: "brushed_copper", withExtension: "mtlx")!

    /// Whether the Open panel is showing.
    @State private var isImporting: Bool = false

    var body: some View {
        ViewportView(fileURL: fileURL)
            .frame(minWidth: 400, minHeight: 400)
            .navigationTitle(fileURL.lastPathComponent)
            .toolbar {
                Button("Open…") {
                    isImporting = true
                }
            }
            // SWIFT: `.fileImporter` shows the system Open panel while
            // `isPresented` is true, then calls the closure with a `Result`:
            // an enum holding either the success value or an error, like Go's
            // `(value, err)` pair folded into one value.
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [Self.materialXType]) { result in
                switch result {
                case .success(let url):
                    fileURL = url
                case .failure(let error):
                    print("Open failed: \(error)")
                }
            }
    }

    /// The .mtlx file type. The main app declares it in its Info.plist; the
    /// spike just derives it from the extension.
    ///
    /// SWIFT: `static let` is a type-level constant, computed once, like a
    /// `static const` member in C++. `Self` is the enclosing type.
    private static let materialXType: UTType = UTType(filenameExtension: "mtlx") ?? .xml
}
