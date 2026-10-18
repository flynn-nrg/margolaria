// SwatchSpikeApp.swift
//
// Demo app for spike M0c: a grid with one swatch for every node, nodegraph
// output and material in a .mtlx file, each rendered from MaterialX's own
// generated Metal shader by PreviewKit. Each cell shows how long its swatch
// took (generation + compilation + rendering). It starts with the bundled
// brushed_copper.mtlx; the Open button picks another file.
//
// Throwaway target, kept small on purpose. PreviewKit is what moves into the
// real app (node thumbnails in M3).
//
// Introduces (SWIFT): `LazyVGrid` and `GridItem`, `ForEach`, `async`
// functions and `await Task.yield()`, `ContinuousClock`, `indices`,
// mutating an element of an `@State` array in place.

import MXKit
import PreviewKit
import SwiftUI
import UniformTypeIdentifiers

/// The spike app: a single window.
@main
struct SwatchSpikeApp: App {
    var body: some Scene {
        WindowGroup("Swatch Spike") {
            SwatchGrid()
        }
    }
}

/// One cell of the grid: an element and, once rendered, its swatch.
struct SwatchItem: Identifiable {
    /// The element (node, output or material) the swatch shows.
    let element: MXElementSummary
    /// The swatch, or nil while it is pending or if it failed.
    var image: CGImage? = nil
    /// Why the swatch couldn't be made, if it couldn't.
    var error: String? = nil
    /// Time taken to generate, compile and render, in milliseconds.
    var milliseconds: Double = 0

    /// Required by `Identifiable`: the element's path is unique.
    var id: String { element.path }
}

/// The window's content: the swatch grid and an Open button.
struct SwatchGrid: View {
    @State private var fileURL: URL = Bundle.main.url(forResource: "brushed_copper", withExtension: "mtlx")!
    @State private var items: [SwatchItem] = []
    @State private var message: String? = nil
    @State private var isImporting: Bool = false

    var body: some View {
        ScrollView {
            if let message {
                Text(message).foregroundStyle(.secondary).padding()
            }
            // SWIFT: `LazyVGrid` lays its children out in a vertical grid,
            // creating cells only as they scroll into view. `.adaptive(minimum:)`
            // fits as many 170-point columns as the window width allows.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170))], spacing: 16) {
                // SWIFT: `ForEach` makes one view per element of a collection.
                // It uses `Identifiable` (`id`) to keep track of which cell
                // is which when the array changes.
                ForEach(items) { item in
                    SwatchCell(item: item)
                }
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 300)
        .navigationTitle(fileURL.lastPathComponent)
        .toolbar {
            Button("Open…") { isImporting = true }
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: [UTType(filenameExtension: "mtlx") ?? .xml]) { result in
            if case .success(let url) = result {
                fileURL = url
            }
        }
        // SWIFT: `.task` runs an `async` closure, and cancels it if the view
        // goes away or `id` changes before it finishes.
        .task(id: fileURL) {
            await renderSwatches()
        }
    }

    /// Lists the file's elements, then renders their swatches one by one.
    ///
    /// SWIFT: `async` marks a function that can suspend (pause without
    /// blocking the thread) at each `await`. This one runs on the main actor,
    /// like the view, so it may touch `items` directly.
    private func renderSwatches() async {
        items = []
        message = nil
        let library: MXLibrary
        let document: MXDocument
        let renderer: SwatchRenderer
        do {
            library = try MXLibrary.bundled.get()
            document = try MXDocument.read(from: fileURL)
            document.setDataLibrary(library)
            renderer = try SwatchRenderer()
        } catch {
            message = String(describing: error)
            return
        }

        // SWIFT: `.map { SwatchItem(element: $0) }` builds a new array by
        // calling the closure on every element, like a for loop with append.
        items = document.shadeableElements.map { SwatchItem(element: $0) }

        let clock = ContinuousClock()
        // SWIFT: `items.indices` is the range of valid indices (0..<count).
        // Looping over indices instead of elements lets us change each
        // element in place: `items[index].image = ...`. With `for item in
        // items`, `item` would be a copy (Array holds structs by value).
        for index in items.indices {
            let start: ContinuousClock.Instant = clock.now
            do {
                let shader = try document.generateMSL(for: items[index].element.path, library: library)
                items[index].image = try renderer.image(shader, size: 256)
            } catch {
                items[index].error = String(describing: error)
            }
            let elapsed: Duration = clock.now - start
            items[index].milliseconds = Double(elapsed.components.attoseconds) / 1e15
                + Double(elapsed.components.seconds) * 1000

            // Rendering runs on the main thread in this spike. Yielding after
            // each swatch lets SwiftUI redraw, so swatches appear one by one
            // instead of all at the end. (M3 moves this off the main thread.)
            await Task.yield()
            // Stop if a different file was opened meanwhile.
            if Task.isCancelled {
                return
            }
        }
    }
}

/// One swatch with its element's path, kind and timing.
struct SwatchCell: View {
    let item: SwatchItem

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = item.image {
                    // 256-pixel images at Retina scale 2: 128 points.
                    Image(decorative: image, scale: 2)
                } else if let error = item.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(6)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 128, height: 128)

            Text(item.element.path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(item.element.category) · \(item.element.type)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if item.image != nil || item.error != nil {
                // SWIFT: `.formatted(...)` turns a number into localized text,
                // here with no decimal places: "482 ms".
                Text("\(item.milliseconds.formatted(.number.precision(.fractionLength(0)))) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 170)
    }
}
