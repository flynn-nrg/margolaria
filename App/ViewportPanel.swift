// ViewportPanel.swift
//
// The 3D preview for one document (PLAN.md §4.1, region 4): a material
// picker above the Storm viewport from ViewportKit, which shows the chosen
// material on a sphere. Drag to orbit, scroll to zoom.
//
// The viewport shows the document as it is in memory (M2c), edits included,
// saved or not: after each edit it gets the new text (`previewXML`), and
// Storm shows the change in the next frame. Values update while a slider
// is dragged: an update costs about 3 ms on top of a 10 ms frame
// (StormUpdateTests), so no throttling is needed.
//
// Introduces (SWIFT): `Picker` with an optional selection.

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

            if !materials.isEmpty, !document.previewXML.isEmpty {
                ViewportView(source: .text(document.previewXML), materialName: materialName)
            } else {
                ContentUnavailableView("No Materials", systemImage: "circle.lefthalf.filled",
                                       description: Text("The preview shows the document's materials on a sphere."))
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
