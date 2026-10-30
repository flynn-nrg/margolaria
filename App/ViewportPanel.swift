// ViewportPanel.swift
//
// The 3D preview for one document (PLAN.md §4.1, region 4): a bar above
// the Storm viewport from ViewportKit, which shows the chosen material on a
// sphere. Drag to orbit, scroll to zoom. The bar picks the material, the
// light around the sphere, and the OCIO view transform (M3b).
//
// The viewport shows the document as it is in memory (M2c), edits included,
// saved or not: after each edit it gets the new text (`previewXML`), and
// Storm shows the change in the next frame. Values update while a slider
// is dragged: an update costs about 3 ms on top of a 10 ms frame
// (StormUpdateTests), so no throttling is needed.
//
// Solo (M3d): with `soloPath` set, the viewport shows that element on its
// own instead of the material: MXKit writes the preview text with a
// material wrapped around it (MXDocument.soloPreview), and the bar says
// what is soloed, with a button to stop. Data (a float or a vector, not a
// colour) is shown through the display's Raw view, as its swatch is.
//
// Introduces (SWIFT): `Picker` with an optional selection, `@AppStorage`,
// `Section` in a menu-style picker; an initializer as a function,
// `String.init` (M3d).

import ColorKit
import MXKit
import PreviewKit
import SwiftUI
import ViewportKit

struct ViewportPanel: View {
    let document: MaterialXDocument

    /// The MaterialX name of the material shown. ContentView owns it, so
    /// the sidebar can change it too.
    @Binding var materialName: String?

    /// The element shown alone instead of the material (M3d), by path.
    @Binding var soloPath: String?

    /// The light around the sphere, kept between launches.
    ///
    /// SWIFT: `@AppStorage("key")` is `@State` saved in the app's user
    /// defaults (NSUserDefaults) under that key: every viewport reads the
    /// same value, a change shows in all of them, and it is still there
    /// next launch. It stores strings, numbers and enums with a String or
    /// Int raw value, like ViewportEnvironment.
    @AppStorage("viewportEnvironment") private var environment: ViewportEnvironment = .studio

    /// The OCIO display and view chosen, kept between launches. Empty until
    /// one is chosen; the config's default is shown until then.
    @AppStorage("viewportDisplay") private var display: String = ""
    @AppStorage("viewportView") private var view: String = ""

    /// The view transform to use: the one chosen if the config still
    /// offers it, otherwise the config's default (nil without OCIO). The
    /// canvas's swatches read the same settings (GraphPanel).
    private var viewTransform: ViewTransform? {
        ViewTransform.preferred(display: display, view: view)
    }

    /// The soloed element's preview, or nil when nothing is soloed or it
    /// can't be shown (deleted by an edit, say). Written again after every
    /// edit: reading `document.revision` makes the view ask.
    private var solo: MXSoloPreview? {
        _ = document.revision
        guard let soloPath else {
            return nil
        }
        return try? document.content.soloPreview(for: soloPath)
    }

    /// The view transform for what is shown: the display's Raw view for a
    /// soloed value that is data, as its swatch shows it.
    private func shownTransform(for solo: MXSoloPreview?) -> ViewTransform? {
        if let solo, SwatchPlan.showsData(solo.outputType) {
            return viewTransform?.raw ?? viewTransform
        }
        return viewTransform
    }

    /// The document's materials (top-level elements of type "material"), in
    /// file order.
    private var materials: [MXElementSummary] {
        document.elements.filter { $0.type == "material" }
    }

    var body: some View {
        // Once per update of the view: writing it copies the document.
        let solo: MXSoloPreview? = self.solo
        VStack(spacing: 0) {
            HStack {
                // SWIFT: The selection is a `String?`, so each row's tag must
                // be a `String?` too; `Optional(name)` makes one.
                if let soloPath, solo != nil {
                    // SWIFT: `split(separator:).last` is the last part of
                    // the path: the node's name, a Substring. `String.init`
                    // names String's initializer as a function, so `map`
                    // can call it: the same as `.map { String($0) }`.
                    Label("Solo: " + (soloPath.split(separator: "/").last.map(String.init) ?? soloPath),
                          systemImage: "scope")
                        .foregroundStyle(Color(red: 0.98, green: 0.68, blue: 0.2))
                        .lineLimit(1)
                        .help("The node's output alone on the sphere. ⌥-click its swatch again, press S, or ✕, for the material.")
                    Button {
                        self.soloPath = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Show the material again")
                } else if materials.isEmpty {
                    // An empty menu would just be a blank button.
                    Text("No material")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Material", selection: $materialName) {
                        ForEach(materials) { material in
                            Text(material.name).tag(Optional(material.name))
                        }
                    }
                    .labelsHidden()
                    .disabled(materials.count < 2)
                }
                Spacer()
                Picker("Light", selection: $environment) {
                    ForEach(ViewportEnvironment.allCases) { environment in
                        Text(environment.title).tag(environment)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The light around the sphere")
                if let viewTransform {
                    viewTransformPicker(showing: viewTransform)
                }
                if let solo, SwatchPlan.showsData(solo.outputType) {
                    Text("Raw")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("A \(solo.outputType) is data, not light: its values are shown as they are, without the view transform")
                }
                Text("Storm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Rendered by Hydra Storm on Metal, as in usdview")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()

            if let solo {
                ViewportView(source: .text(solo.xml), materialName: solo.materialName,
                             environment: environment, viewTransform: shownTransform(for: solo))
            } else if !materials.isEmpty, !document.previewXML.isEmpty {
                ViewportView(source: .text(document.previewXML), materialName: materialName,
                             environment: environment, viewTransform: viewTransform)
            } else {
                ContentUnavailableView("No Materials", systemImage: "circle.lefthalf.filled",
                                       description: Text("The preview shows the document's materials on a sphere."))
                    // Fill the panel, so the material bar stays at the top
                    // (as GraphPanel does for an empty level).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // A soloed element that an edit removed: back to the material.
        .onChange(of: document.revision) {
            if soloPath != nil, self.solo == nil {
                soloPath = nil
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

    /// A menu of every view of every display the viewport offers, one
    /// section per display, with `current` ticked.
    private func viewTransformPicker(showing current: ViewTransform) -> some View {
        // SWIFT: A `Binding` is a getter and a setter that a control reads
        // and writes through. `$display` would bind one stored value; this
        // one is made from two closures, so the picker can choose a display
        // and a view together, stored in two settings.
        let selection = Binding<ViewTransform>(
            get: { current },
            set: { chosen in
                display = chosen.display
                view = chosen.view
            }
        )
        return Picker("View", selection: selection) {
            ForEach(ViewTransform.displays, id: \.self) { display in
                // SWIFT: In a menu-style picker, a `Section` is a group with
                // a heading, separated from the next by a line.
                Section(display) {
                    ForEach(ViewTransform.views(for: display), id: \.self) { view in
                        Text(view).tag(ViewTransform(display: display, view: view))
                    }
                }
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("OCIO view transform: \(current.display), \(current.view)")
    }
}
