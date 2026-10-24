// ViewportPanel.swift
//
// The 3D preview for one document (PLAN.md §4.1, region 4): a material
// picker above the Storm viewport from ViewportKit, which shows the chosen
// material on a sphere. Drag to orbit, scroll to zoom.
//
// Storm reads the .mtlx file itself (through OpenUSD's UsdMtlx plugin), so
// the preview needs a file on disk: an untitled document shows a message
// instead. Until editing arrives (M2) the file on disk and the document are
// the same.
//
// Introduces (SWIFT): `Picker` with an optional selection, `.id(_:)` to
// force a view to be recreated.

import MXKit
import SwiftUI
import ViewportKit

struct ViewportPanel: View {
    let document: MaterialXDocument

    /// The MaterialX name of the material shown. ContentView owns it, so
    /// the sidebar can change it too.
    @Binding var materialName: String?

    /// The document's materials (top-level elements of type "material"), in
    /// file order.
    private var materials: [MXElementSummary] {
        document.elements.filter { $0.type == "material" }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // SWIFT: The selection is a `String?`, so each row's tag must
                // be a `String?` too; `Optional(name)` makes one.
                Picker("Material", selection: $materialName) {
                    ForEach(materials) { material in
                        Text(material.name).tag(Optional(material.name))
                    }
                }
                .labelsHidden()
                .disabled(materials.count < 2)
                Spacer()
                Text("Storm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Rendered by Hydra Storm on Metal, as in usdview")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()

            if let fileURL = document.content.fileURL, !materials.isEmpty {
                ViewportView(fileURL: fileURL, materialName: materialName)
                    // A new viewport (and Storm renderer) when the document
                    // is read again (Revert, or a change on disk): the
                    // renderer reads the file once, when it is created.
                    // Edits don't reach it yet; M2c renders the edited
                    // document instead of the file.
                    //
                    // SWIFT: `.id(_:)` gives the view an identity; when the
                    // value changes, SwiftUI throws the old view and its
                    // `@State` away and builds a new one.
                    .id(document.loadGeneration)
            } else {
                ContentUnavailableView(materials.isEmpty ? "No Materials" : "Not Saved Yet",
                                       systemImage: "circle.lefthalf.filled",
                                       description: Text(materials.isEmpty
                                                         ? "The preview shows the document's materials on a sphere."
                                                         : "Save the document to preview it."))
            }
        }
        // Show the first material until one is chosen, and again if the
        // chosen one disappears (the file changed on disk).
        .onChange(of: document.elements, initial: true) {
            if materialName == nil || !materials.contains(where: { $0.name == materialName }) {
                materialName = materials.first?.name
            }
        }
    }
}
