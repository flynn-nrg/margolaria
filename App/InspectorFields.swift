// InspectorFields.swift
//
// The inspector's value editors (PLAN.md §4.1, region 5; M2b): one view per
// kind of MaterialX value, chosen from the input's type and metadata by
// `InputEditor`. Numbers get a slider when the nodedef gives a range,
// colours a colour well with their colour space, enums a menu, files a
// Choose button, and everything has a text field.
//
// The editors never change the document themselves. They report new values,
// as MaterialX text, through `InputActions`, which InspectorPanel turns into
// undoable edits: `commit` for typing, menus and toggles (one undo step
// each), `scrub` and `endScrub` for drags (one step per drag).
//
// Introduces (SWIFT): `@FocusState`, `Binding(get:set:)` (a binding computed
// from closures), `Slider` with `onEditingChanged`, `ColorPicker` with a
// `CGColor`, `CGColorSpace` and converting colours between spaces,
// `NSOpenPanel`, `.onExitCommand`, structs of closures.

import AppKit
import ColorKit
import MXKit
import SwiftUI

/// What an editor can do with the input it shows.
///
/// SWIFT: A struct whose properties are closures: a small table of
/// callbacks, like a C struct of function pointers, except each closure
/// carries the values it captured (the document, the input's path).
struct InputActions {
    /// Sets the value, as one undo step (typing, menus, toggles, files).
    let commit: (String) -> Void
    /// Sets the value as part of a drag; all of a drag is one undo step.
    let scrub: (String) -> Void
    /// The drag is over: the next change is a new undo step.
    let endScrub: () -> Void
}

/// The editor for one input, chosen by its type and metadata.
struct InputEditor: View {
    let input: MXPort
    let actions: InputActions
    /// The document's folder, so chosen files can be stored relative to it.
    let baseFolder: URL?

    var body: some View {
        // SWIFT: A `switch` inside `body`: each case is a different view,
        // which the result builder wraps into one type (see ContentView).
        // `case .color(let count)` binds the associated value.
        switch input.valueType {
        case .float, .integer:
            if !input.ui.enumOptions.isEmpty {
                EnumEditor(input: input, actions: actions)
            } else {
                ScalarEditor(input: input, actions: actions)
            }
        case .boolean:
            BooleanEditor(input: input, actions: actions)
        case .color(let count):
            ColorEditor(input: input, componentCount: count, actions: actions)
        case .vector:
            VectorEditor(input: input, actions: actions)
        case .string:
            if !input.ui.enumOptions.isEmpty {
                EnumEditor(input: input, actions: actions)
            } else {
                TextValueEditor(input: input, actions: actions)
            }
        case .filename:
            FileEditor(input: input, actions: actions, baseFolder: baseFolder)
        case .matrix:
            // Nine or sixteen numbers don't fit in a row: edited as text.
            TextValueEditor(input: input, actions: actions)
        case .other(let type):
            if type.hasSuffix("shader") || type == "material" {
                // Shaders and materials only come through connections.
                Text("Not connected")
                    .foregroundStyle(.tertiary)
            } else {
                // Arrays and custom types: MaterialX's text, checked on commit.
                TextValueEditor(input: input, actions: actions)
            }
        }
    }
}

// MARK: - Text

/// A text field that changes the document only when the user is done:
/// on Return or when it loses focus. Escape puts back the current value.
///
/// Typing into a field that changed the document on every key would make
/// one undo step per character, and half-typed values ("0.") would be
/// refused.
struct CommitTextField: View {
    /// The value to show, from the document.
    let text: String
    var prompt: String = ""
    /// Called with the new text, if it differs from `text`.
    let onCommit: (String) -> Void

    /// What the field shows while the user types.
    @State private var draft: String = ""

    /// SWIFT: `@FocusState` is state that SwiftUI keeps in step with the
    /// keyboard focus: true while this field has it. `.focused($isFocused)`
    /// connects the two.
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $draft)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) {
                if !isFocused {
                    commit()
                }
            }
            // The document changed (this edit, an undo, another field).
            .onChange(of: text, initial: true) {
                draft = text
            }
            // SWIFT: `.onExitCommand` runs on Escape (macOS's "cancel").
            .onExitCommand {
                draft = text
            }
    }

    /// Reports the draft if it changed. The field shows the document's value
    /// again straight away: the new value if the edit is accepted (via
    /// `onChange(of: text)`), the old one if it is refused.
    private func commit() {
        let newText: String = draft
        draft = text
        if newText != text {
            onCommit(newText)
        }
    }
}

/// A plain text field for strings, matrices and arrays.
struct TextValueEditor: View {
    let input: MXPort
    let actions: InputActions

    var body: some View {
        CommitTextField(text: input.value ?? "", onCommit: actions.commit)
            .font(.system(.body, design: .monospaced))
    }
}

// MARK: - Numbers

/// A float or integer: a slider when the nodedef gives a range, and a
/// number field.
struct ScalarEditor: View {
    let input: MXPort
    let actions: InputActions

    /// The current value as a number; 0 when there is none.
    private var number: Double {
        MXValueText.numbers(input.value ?? "")?.first ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            if let range = input.ui.sliderRange() {
                slider(in: range)
            }
            NumberField(text: input.value ?? "", type: input.valueType, onCommit: actions.commit)
                .frame(width: 70)
        }
    }

    /// A slider over `range`, one undo step per drag.
    ///
    /// SWIFT: `Binding(get:set:)` makes a binding out of two closures,
    /// instead of pointing at stored state: reading it reads the document,
    /// writing it edits the document. The slider can't tell the difference.
    @ViewBuilder
    private func slider(in range: ClosedRange<Double>) -> some View {
        let value = Binding<Double>(
            get: { number },
            set: { newValue in
                actions.scrub(MXValueText.text([newValue], as: input.valueType))
            }
        )
        // SWIFT: `onEditingChanged` is called with true when the drag
        // starts and false when it ends.
        let editingChanged: (Bool) -> Void = { isEditing in
            if !isEditing {
                actions.endScrub()
            }
        }
        if input.valueType == .integer {
            Slider(value: value, in: range, step: 1, onEditingChanged: editingChanged)
        } else if let step = input.ui.step {
            Slider(value: value, in: range, step: step, onEditingChanged: editingChanged)
        } else {
            Slider(value: value, in: range, onEditingChanged: editingChanged)
        }
    }
}

/// A text field that accepts only the right count of numbers for `type`
/// ("0.5"; "1, 0.5, 0"), and beeps otherwise.
struct NumberField: View {
    let text: String
    let type: MXValueType
    let onCommit: (String) -> Void

    var body: some View {
        CommitTextField(text: text) { newText in
            guard let numbers = MXValueText.numbers(newText), numbers.count == type.componentCount else {
                NSSound.beep()
                return
            }
            // Rewritten in MaterialX's form: "1,2" becomes "1.0, 2.0".
            onCommit(MXValueText.text(numbers, as: type))
        }
        .font(.system(.body, design: .monospaced))
        .multilineTextAlignment(.trailing)
    }
}

/// A vector2/3/4: one number field per component.
struct VectorEditor: View {
    let input: MXPort
    let actions: InputActions

    var body: some View {
        let count: Int = input.valueType.componentCount ?? 0
        let numbers: [Double] = MXValueText.numbers(input.value ?? "") ?? Array(repeating: 0, count: count)
        HStack(spacing: 4) {
            // SWIFT: `id: \.self` identifies each field by its index.
            ForEach(0..<count, id: \.self) { index in
                CommitTextField(text: index < numbers.count ? MXValueText.text([numbers[index]], as: .float) : "") { newText in
                    guard let number = Double(newText.trimmingCharacters(in: .whitespaces)), index < numbers.count else {
                        NSSound.beep()
                        return
                    }
                    // SWIFT: `var changed = numbers` copies the array (a
                    // value type); changing the copy leaves `numbers` alone.
                    var changed: [Double] = numbers
                    changed[index] = number
                    actions.commit(MXValueText.text(changed, as: input.valueType))
                }
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - Choices

/// A boolean: a checkbox.
struct BooleanEditor: View {
    let input: MXPort
    let actions: InputActions

    var body: some View {
        let isOn = Binding<Bool>(
            get: { MXValueText.boolean(input.value ?? "") ?? false },
            set: { actions.commit(MXValueText.text($0)) }
        )
        Toggle("", isOn: isOn)
            .labelsHidden()
    }
}

/// An input with `enum` choices: a menu of their names.
struct EnumEditor: View {
    let input: MXPort
    let actions: InputActions

    var body: some View {
        let selection = Binding<String>(
            get: { input.value ?? "" },
            set: { actions.commit($0) }
        )
        Picker("", selection: selection) {
            // SWIFT: `ForEach(_:id:)` over values that aren't Identifiable:
            // `id: \.value` names the property that tells them apart.
            ForEach(input.ui.enumOptions, id: \.value) { option in
                Text(option.name).tag(option.value)
            }
        }
        .labelsHidden()
    }
}

// MARK: - Colours

/// A color3 or color4: a colour well, the colour space, and the numbers.
///
/// MaterialX stores colours as numbers in a colour space (`colorspace`,
/// or the document's, usually lin_rec709: linear, Rec. 709 primaries). The
/// colour well shows them converted by OCIO (M3a), so the swatch is right
/// whatever the space; picked colours are converted back before they are
/// stored.
struct ColorEditor: View {
    let input: MXPort
    let componentCount: Int
    let actions: InputActions

    var body: some View {
        let space: ColorSpaceMapping = ColorSpaceMapping(materialX: input.activeColorSpace)
        let numbers: [Double] = MXValueText.numbers(input.value ?? "") ?? Array(repeating: 0, count: componentCount)
        // SWIFT: A binding of a Core Graphics colour (`CGColor`, a C type
        // that Swift manages with ARC like an object). The colour panel
        // reports changes continuously while the user drags in it.
        let color = Binding<CGColor>(
            get: { space.cgColor(numbers) },
            set: { newColor in
                guard let components = space.components(of: newColor, count: componentCount) else {
                    return
                }
                actions.scrub(MXValueText.text(components, as: input.valueType))
            }
        )
        HStack(spacing: 6) {
            ColorPicker("", selection: color, supportsOpacity: componentCount == 4)
                .labelsHidden()
            Text(space.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(space.help)
            NumberField(text: input.value ?? "", type: input.valueType, onCommit: actions.commit)
        }
    }
}

/// How a MaterialX colour space is shown in a colour well.
///
/// The well always works in Core Graphics' extended linear sRGB, which is
/// lin_rec709 (Rec. 709 primaries, linear) with components outside 0–1
/// allowed, as MaterialX values often have (HDR emission, out-of-gamut
/// colours). OCIO converts between it and the input's space.
struct ColorSpaceMapping {
    /// The colour well's space.
    let space: CGColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    /// What the inspector shows next to the well, such as "lin_rec709".
    let label: String
    /// The label's tooltip.
    let help: String
    /// From the input's space to the well's; nil when nothing to do.
    private let toWell: ColorConverter?
    /// From the well's space back to the input's.
    private let fromWell: ColorConverter?

    /// The OCIO name of the well's space (an alias in the studio config).
    static let wellSpaceName: String = "lin_rec709"

    /// Maps a MaterialX colour space name; nil means the document's working
    /// space, taken to be lin_rec709 as MaterialX does.
    init(materialX name: String?) {
        let spaceName: String = name ?? Self.wellSpaceName
        // SWIFT: `try?` turns a thrown error into nil. Without colour
        // management (OCIO failed to load), or for a space the config
        // doesn't know, the numbers are shown as if lin_rec709, and the
        // label says so.
        guard let configuration = try? ColorConfiguration.studio.get(),
              let colorSpace = configuration.colorSpace(named: spaceName),
              let toWell = try? configuration.converter(from: spaceName, to: Self.wellSpaceName),
              let fromWell = try? configuration.converter(from: Self.wellSpaceName, to: spaceName) else {
            label = "\(spaceName) ?"
            help = "\(spaceName) is not a colour space of the colour config; shown as if lin_rec709"
            toWell = nil
            fromWell = nil
            return
        }
        label = spaceName
        let whose: String = name == nil ? "The document's working colour space" : "The input's colour space"
        help = "\(whose): \(colorSpace.name) (\(configuration.name))"
        self.toWell = toWell.isIdentity ? nil : toWell
        self.fromWell = fromWell.isIdentity ? nil : fromWell
    }

    /// A colour from MaterialX numbers in the input's space (alpha 1 for a
    /// color3).
    func cgColor(_ numbers: [Double]) -> CGColor {
        var rgb = SIMD3<Double>(numbers.count > 0 ? numbers[0] : 0,
                                numbers.count > 1 ? numbers[1] : 0,
                                numbers.count > 2 ? numbers[2] : 0)
        if let toWell {
            rgb = toWell.convert(rgb)
        }
        let alpha: Double = numbers.count > 3 ? numbers[3] : 1
        // SWIFT: `CGColor(colorSpace:components:)` takes a C array of
        // CGFloat; Swift passes the array's storage as an
        // `UnsafePointer<CGFloat>` for the duration of the call only.
        let components: [CGFloat] = [rgb.x, rgb.y, rgb.z, alpha].map { CGFloat($0) }
        return CGColor(colorSpace: space, components: components) ?? CGColor(gray: 0, alpha: 1)
    }

    /// The first `count` components of `color` in the input's space, or
    /// nil if it can't be converted.
    func components(of color: CGColor, count: Int) -> [Double]? {
        // The colour panel may hand back any colour space; convert to the
        // well's first.
        guard let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4 else {
            return nil
        }
        var rgb = SIMD3<Double>(Double(components[0]), Double(components[1]), Double(components[2]))
        if let fromWell {
            rgb = fromWell.convert(rgb)
        }
        let all: [Double] = [rgb.x, rgb.y, rgb.z, Double(components[3])]
        return Array(all.prefix(count))
    }
}

// MARK: - Files

/// A filename: the path as text, and a button to choose a file.
struct FileEditor: View {
    let input: MXPort
    let actions: InputActions
    let baseFolder: URL?

    var body: some View {
        HStack(spacing: 4) {
            CommitTextField(text: input.value ?? "", prompt: "No file", onCommit: actions.commit)
                .help(input.fileURL?.path(percentEncoded: false) ?? "")
            Button("Choose…", action: choose)
        }
    }

    /// Asks for a file. One inside the document's folder is stored relative
    /// to it, as MaterialX documents usually do, so the folder can move.
    private func choose() {
        // SWIFT: `NSOpenPanel` is AppKit's Open dialog. `runModal()` blocks
        // until the user answers, which is simpler than a sheet here.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = input.fileURL?.deletingLastPathComponent() ?? baseFolder
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        actions.commit(Self.storedPath(for: url, relativeTo: baseFolder))
    }

    /// `url` relative to `folder` if it is inside it ("textures/wood.png"),
    /// otherwise its absolute path.
    static func storedPath(for url: URL, relativeTo folder: URL?) -> String {
        let path: String = url.standardizedFileURL.path(percentEncoded: false)
        guard let folder else {
            return path
        }
        var folderPath: String = folder.standardizedFileURL.path(percentEncoded: false)
        if !folderPath.hasSuffix("/") {
            folderPath += "/"
        }
        if path.hasPrefix(folderPath) {
            // SWIFT: `dropFirst(n)` gives the rest of the string after n
            // characters, as a Substring; `String(...)` copies it.
            return String(path.dropFirst(folderPath.count))
        }
        return path
    }
}
