// WorkingSpaceMenu.swift
//
// The working space of the document or of a nodegraph (PLAN.md §8.3,
// "Working space"): the colour space their untagged colours are in. The
// inspector shows it for the document when nothing is selected, and for a
// selected nodegraph.
//
// Changing it changes what those colours mean, so if there are any, the
// menu asks first:
//
//   Convert Colours   they keep their look: values are converted to the
//                     new space, images tagged with the old one
//   Keep Numbers      the same numbers, now meaning colours in the new space
//
// Either way it is one undo step.
//
// Introduces (SWIFT): `.confirmationDialog(_:isPresented:presenting:)`.

import ColorKit
import MXKit
import SwiftUI

struct WorkingSpaceMenu: View {
    let document: MaterialXDocument
    /// "" for the document, or the nodegraph's path.
    let path: String
    let isReadOnly: Bool

    /// A change waiting for the question's answer.
    struct PendingChange {
        /// The new space; nil removes the `colorspace` (inherit it).
        let space: String?
        let title: String
        let values: Int
        let images: Int
    }

    @State private var pending: PendingChange? = nil

    var body: some View {
        let current: MXWorkingSpace = document.content.workingSpace(of: path)
        // SWIFT: As in ColorSpaceMenu, "" stands for "no colorspace".
        let choice = Binding<String>(
            get: { current.own ?? "" },
            set: { name in
                choose(name.isEmpty ? nil : name, current: current)
            }
        )
        Picker("Working space", selection: choice) {
            Text(path.isEmpty ? "Default (\(current.inheritedOrDefault))" : "Document's (\(current.inheritedOrDefault))")
                .tag("")
            Divider()
            ForEach(spaces(current)) { space in
                Text("\(space.name) — \(space.title)").tag(space.name)
            }
        }
        .disabled(isReadOnly)
        .help(path.isEmpty
              ? "The colour space of the document's colours that don't name one: values typed in, and images."
              : "The colour space of this nodegraph's colours that don't name one. Default: the document's.")
        // SWIFT: `.confirmationDialog(_:isPresented:presenting:)` shows
        // its buttons when `isPresented` turns true, and hands each the
        // value given in `presenting` (here the pending change), so the
        // buttons know what they confirm. Escape and Cancel close it.
        .confirmationDialog("Change the working space to \(pending?.title ?? "")?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { change in
            Button("Convert Colours") {
                apply(change.space, title: change.title, converting: true)
            }
            .keyboardShortcut(.defaultAction)
            Button("Keep Numbers") {
                apply(change.space, title: change.title, converting: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            Text(Self.message(values: change.values, images: change.images))
        }
    }

    /// The linear spaces OCIO knows, and the current one if it is another.
    private func spaces(_ current: MXWorkingSpace) -> [InputColorSpace] {
        var spaces: [InputColorSpace] = InputColorSpace.available().filter(\.isLinear)
        if let own = current.own, !spaces.contains(where: { $0.name == own }) {
            spaces.append(InputColorSpace(name: own, title: "not a standard linear space"))
        }
        return spaces
    }

    /// Changes at once if no colour depends on the space; asks otherwise.
    private func choose(_ space: String?, current: MXWorkingSpace) {
        guard space != current.own else {
            return
        }
        let title: String = space ?? current.inheritedOrDefault
        let uses: [MXColorUse] = document.content.colorsInWorkingSpace(of: path)
        if uses.isEmpty || (space ?? current.inheritedOrDefault) == current.active {
            apply(space, title: title, converting: false)
            return
        }
        let images: Int = uses.filter(\.isFile).count
        pending = PendingChange(space: space, title: title, values: uses.count - images, images: images)
    }

    /// "3 colour values and 1 image are in the current working space…"
    private static func message(values: Int, images: Int) -> String {
        var parts: [String] = []
        if values > 0 {
            parts.append(values == 1 ? "1 colour value" : "\(values) colour values")
        }
        if images > 0 {
            parts.append(images == 1 ? "1 image" : "\(images) images")
        }
        let verb: String = values + images == 1 ? "is" : "are"
        return "\(parts.joined(separator: " and ")) \(verb) in the current working space. "
            + "Convert Colours keeps their look: values are converted, and images are tagged with the current space. "
            + "Keep Numbers leaves them as they are, so they mean colours in the new space."
    }

    /// Makes the change, as one undo step.
    private func apply(_ space: String?, title: String, converting: Bool) {
        let path: String = path
        // SWIFT: A function value: ColorKit's conversion, passed to MXKit,
        // which doesn't know about OCIO.
        let convert: (([Double], String, String) throws -> [Double])? = converting
            ? { numbers, from, to in try InputColorSpace.convert(numbers, from: from, to: to) }
            : nil
        document.edit("Set Working Space to \(title)") { content in
            try content.setWorkingSpace(space, of: path, convert: convert)
        }
    }
}
