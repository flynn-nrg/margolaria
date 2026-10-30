// ColorPickerPopover.swift
//
// The inspector's colour picker (M3e), shown by clicking a colour input's
// well. It replaces the macOS colour panel, which picks only in its own
// spaces, can't go above 1, and stored colours outside the input's gamut
// without a word (PLAN.md §8.2).
//
// A colour field (saturation across, value up, in the current hue) and a
// hue strip are the main way to pick; the sliders under them, whose tracks
// show the colour along them, and number fields are for exact values.
//
// The colour is picked in a space chosen from a menu (ColorKit's
// PickSpace: the input's own numbers, linear Rec.709, ACEScg, sRGB or
// Display P3; remembered between picks) and stored in the input's space,
// converted by OCIO (ColorKit's ColorPicking). Sliders in RGB or HSV, number
// fields (linear values can go above 1: emission, HDR), a hex code for the
// encoded spaces, and the screen eyedropper. A pick outside the input's
// gamut is kept, with a warning and a button that clips it.
//
// Every slider drag is one undo step (the inspector's `scrub`/`endScrub`);
// typed numbers, hex codes, the eyedropper and Clip are one step each.
//
// Introduces (SWIFT): `NSColorSampler` (the screen eyedropper), `TextField`
// with a number `format:`, `@State` initialised from a parameter in `init`
// (`State(initialValue:)`), `KeyPath` subscripts with `WritableKeyPath`, a
// custom control from shapes and a `DragGesture`, `.presentationBackground`.

import AppKit
import ColorKit
import MXKit
import SwiftUI

/// The picker for one colour input.
struct ColorPickerPopover: View {
    let input: MXPort
    /// 3 for a color3, 4 for a color4.
    let componentCount: Int
    let actions: InputActions

    /// The pick space chosen last, by MaterialX name; "" for the input's
    /// own space. Shared by every picker, kept between launches.
    @AppStorage("colorPickSpace") private var pickSpaceName: String = ""
    /// RGB or HSV sliders.
    @AppStorage("colorPickMode") private var mode: Mode = .rgb

    /// The colour as picked (in the pick space), while the popover is open.
    /// Kept here rather than read back from the stored text each time: the
    /// stored text is rounded, and the hue of a grey isn't stored at all,
    /// so dragging saturation to 0 and back would lose it.
    @State private var picked: SIMD3<Double> = .zero
    /// The same colour as hue, saturation and value.
    @State private var hsv: SIMD3<Double> = .zero
    /// The value this popover last wrote, to tell an outside change (undo,
    /// another field) from its own.
    @State private var written: String? = nil
    /// The value when the popover opened, shown beside the new one.
    @State private var original: String

    enum Mode: String {
        case rgb, hsv
    }

    /// SWIFT: `State(initialValue:)` sets a `@State` property's first
    /// value from an argument. Assigning `original = ...` wouldn't work: in
    /// `init`, a `@State` property is its wrapper, written `_original`.
    init(input: MXPort, componentCount: Int, actions: InputActions) {
        self.input = input
        self.componentCount = componentCount
        self.actions = actions
        _original = State(initialValue: input.value ?? "")
    }

    // MARK: Spaces

    /// The input's space: its `colorspace`, or the document's working
    /// space, which MaterialX takes to be lin_rec709.
    private var inputSpace: String {
        input.activeColorSpace ?? "lin_rec709"
    }

    /// The menu's spaces: the input's own first, then the others it isn't.
    private var spaces: [PickSpace] {
        [PickSpace.input(inputSpace)] + PickSpace.offered.filter { $0.name != inputSpace }
    }

    /// The chosen space; the input's own if none is, or if the one chosen
    /// is the input's space anyway.
    private var pickSpace: PickSpace {
        spaces.dropFirst().first(where: { $0.name == pickSpaceName }) ?? spaces[0]
    }

    /// The conversions, or nil without colour management: the picker then
    /// works on the stored numbers as they are.
    private var picking: ColorPicking? {
        try? ColorPicking(input: inputSpace, pick: pickSpace.name)
    }

    // MARK: Values

    /// The stored numbers (RGB, and alpha for a color4).
    private var stored: [Double] {
        MXValueText.numbers(input.value ?? "") ?? Array(repeating: 0, count: componentCount)
    }

    private static func rgb(_ numbers: [Double]) -> SIMD3<Double> {
        SIMD3(numbers.count > 0 ? numbers[0] : 0, numbers.count > 1 ? numbers[1] : 0,
              numbers.count > 2 ? numbers[2] : 0)
    }

    /// The stored colour as the pick space shows it.
    private var storedPicked: SIMD3<Double> {
        let rgb: SIMD3<Double> = Self.rgb(stored)
        return picking?.picked(fromInput: rgb) ?? rgb
    }

    /// `picked` in the input's space: what is (or will be) stored.
    private var inputRGB: SIMD3<Double> {
        picking?.input(fromPicked: picked) ?? picked
    }

    /// The text for `rgb` (input space) with the current alpha.
    private func text(for rgb: SIMD3<Double>) -> String {
        var numbers: [Double] = [rgb.x, rgb.y, rgb.z]
        if componentCount == 4 {
            numbers.append(stored.count > 3 ? stored[3] : 1)
        }
        return MXValueText.text(numbers, as: input.valueType)
    }

    // MARK: Writing

    /// Stores `picked` as part of a drag.
    private func scrub() {
        let text: String = text(for: inputRGB)
        written = text
        actions.scrub(text)
    }

    /// Stores `picked` as one step.
    private func commit() {
        let text: String = text(for: inputRGB)
        written = text
        actions.commit(text)
    }

    /// Sets `picked` (and `hsv` from it) and stores it as one step.
    private func commit(picked newValue: SIMD3<Double>) {
        picked = newValue
        hsv = ColorPicking.hsv(fromRGB: newValue)
        commit()
    }

    /// Reads the stored colour into `picked` and `hsv`: on opening, on
    /// another pick space, and when something else changed the value.
    private func reload() {
        picked = storedPicked
        // A grey keeps the hue it had: it has none of its own.
        let fresh: SIMD3<Double> = ColorPicking.hsv(fromRGB: picked)
        hsv = fresh.y == 0 ? SIMD3(hsv.x, 0, fresh.z) : fresh
    }

    // MARK: View

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("Pick in", selection: $pickSpaceName) {
                // SWIFT: `enumerated()` to know which is first: the
                // input's own, stored as "", so that it follows the input
                // whatever its space.
                ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                    Text(space.title).tag(index == 0 ? "" : space.name)
                }
            }
            .help("The space the sliders and numbers are in. The colour is stored in the input's space, \(inputSpace), converted by OCIO.")
            colorField
            Picker("Sliders", selection: $mode) {
                Text("RGB").tag(Mode.rgb)
                Text("HSV").tag(Mode.hsv)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .rgb:
                channel("R", \.x)
                channel("G", \.y)
                channel("B", \.z)
            case .hsv:
                hsvChannel("H", \.x, range: 0...1, scale: 360)
                hsvChannel("S", \.y, range: 0...1, scale: 1)
                hsvChannel("V", \.z, range: 0...(pickSpace.isEncoded ? 1 : max(1, hsv.z)), scale: 1)
            }
            if componentCount == 4 {
                alphaChannel
            }
            if pickSpace.isEncoded {
                hexField
            }
            gamutWarning
        }
        .padding(12)
        .frame(width: 300)
        // SWIFT: `.presentationBackground` sets what is behind a popover's
        // content. macOS's default is a translucent glass, through which
        // the XML and the inspector showed and muddled the colours.
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: pickSpaceName) {
            reload()
        }
        // Undo, a typed value in the inspector, ...: follow it.
        .onChange(of: input.value) {
            if input.value != written {
                reload()
            }
        }
    }

    /// The colour before the popover opened and now, labelled, and the
    /// eyedropper.
    private var header: some View {
        let mapping = ColorSpaceMapping(materialX: input.activeColorSpace)
        return HStack(alignment: .top, spacing: 8) {
            // Clicking the old colour puts it back.
            Button {
                actions.commit(original)
            } label: {
                swatch(mapping.cgColor(MXValueText.numbers(original) ?? stored), caption: "Before")
            }
            .buttonStyle(.plain)
            .help("The colour before: click to put it back")
            swatch(mapping.cgColor(stored), caption: "Now")
            Button {
                sampleScreen(mapping: mapping)
            } label: {
                Image(systemName: "eyedropper")
            }
            .help("Pick a colour from the screen")
        }
    }

    /// The colour field: saturation from left to right, value from bottom
    /// to top, in the current hue, with the hue strip under it. Click or
    /// drag in either to pick. Both are computed in the pick space and
    /// converted as the well is, so they show what each point would store.
    private var colorField: some View {
        let top: Double = pickSpace.isEncoded ? 1 : max(1, hsv.z)
        let field: CGImage? = fieldImage(hue: hsv.x, top: top)
        let hueRange: ClosedRange<Double> = 0...1
        let hue = Binding<Double>(
            get: { hsv.x },
            set: { newValue in
                hsv.x = newValue
                picked = ColorPicking.rgb(fromHSV: hsv)
                scrub()
            })
        return VStack(spacing: 6) {
            ColorField(image: field, saturation: hsv.y, value: hsv.z / top, onEditingChanged: endDrag) { s, v in
                hsv.y = s
                hsv.z = v * top
                picked = ColorPicking.rgb(fromHSV: hsv)
                scrub()
            }
            .frame(height: 150)
            ColorTrack(value: hue, range: hueRange, colors: Self.stops(in: hueRange) { level in
                screenColor(ofPicked: ColorPicking.rgb(fromHSV: SIMD3(level, 1, min(top, 1))))
            }, onEditingChanged: endDrag)
            .help("Hue")
        }
    }

    /// The field's picture: 48 × 32 points of saturation and value at
    /// `hue`, value up to `top`, as linear Rec.709 floats (Core Graphics'
    /// extended linear sRGB) so the screen shows each as the well would.
    /// SwiftUI scales it up smoothly.
    private func fieldImage(hue: Double, top: Double) -> CGImage? {
        let width: Int = 48
        let height: Int = 32
        let mapping = ColorSpaceMapping(materialX: input.activeColorSpace)
        // SWIFT: `[Float](repeating:count:)` then filled in place; four
        // floats (RGBA) per point, top row first.
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for row in 0..<height {
            let value: Double = top * (1 - Double(row) / Double(height - 1))
            for column in 0..<width {
                let saturation: Double = Double(column) / Double(width - 1)
                let pickedRGB: SIMD3<Double> = ColorPicking.rgb(fromHSV: SIMD3(hue, saturation, value))
                let stored: SIMD3<Double> = picking?.input(fromPicked: pickedRGB) ?? pickedRGB
                let linear: SIMD3<Double> = mapping.wellRGB(stored)
                let offset: Int = (row * width + column) * 4
                pixels[offset] = Float(linear.x)
                pixels[offset + 1] = Float(linear.y)
                pixels[offset + 2] = Float(linear.z)
            }
        }
        // SWIFT: A bitmap of 32-bit floats: `floatComponents` in the bitmap
        // info, alpha last and opaque (`noneSkipLast` isn't allowed for
        // floats, so alpha is 1 and premultiplied).
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 32,
                                          bytesPerRow: width * 16, space: mapping.space, bitmapInfo: info.rawValue)
            else {
                return nil
            }
            return context.makeImage()
        }
    }

    /// A colour swatch with a caption under it.
    private func swatch(_ color: CGColor, caption: String) -> some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(cgColor: color))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                .frame(height: 28)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The screen colour of picked values (in the pick space): converted to
    /// the input's space, then as the well shows it.
    private func screenColor(ofPicked values: SIMD3<Double>) -> Color {
        let rgb: SIMD3<Double> = picking?.input(fromPicked: values) ?? values
        return Color(cgColor: ColorSpaceMapping(materialX: input.activeColorSpace).cgColor([rgb.x, rgb.y, rgb.z]))
    }

    /// The colours along a track from `range.lowerBound` to its upper
    /// bound, made by `colour` for each value: the track's gradient.
    private static func stops(in range: ClosedRange<Double>, _ colour: (Double) -> Color) -> [Color] {
        // 12 stops: hue needs that many to show its rainbow; the others
        // are smooth with fewer, and drawing them is cheap.
        (0...11).map { colour(range.lowerBound + (range.upperBound - range.lowerBound) * Double($0) / 11) }
    }

    /// One RGB slider and its number, in the pick space.
    ///
    /// SWIFT: `WritableKeyPath<SIMD3<Double>, Double>` names one component
    /// (`\.x`); `picked[keyPath: component]` reads or writes it.
    private func channel(_ name: String, _ component: WritableKeyPath<SIMD3<Double>, Double>) -> some View {
        // Encoded values are 0 to 1; linear ones can go above (the slider
        // grows to fit, and the number can be typed).
        let upper: Double = pickSpace.isEncoded ? 1 : max(1, picked[keyPath: component])
        let value = Binding<Double>(
            get: { picked[keyPath: component] },
            set: { newValue in
                picked[keyPath: component] = newValue
                hsv = ColorPicking.hsv(fromRGB: picked)
                scrub()
            })
        let range: ClosedRange<Double> = min(0, value.wrappedValue)...upper
        // The track: this component from one end to the other, the others
        // as they are.
        let colors: [Color] = Self.stops(in: range) { level in
            var values: SIMD3<Double> = picked
            values[keyPath: component] = level
            return screenColor(ofPicked: values)
        }
        return row(name, slider: ColorTrack(value: value, range: range, colors: colors, onEditingChanged: endDrag),
                   number: value)
    }

    /// One HSV slider; hue is shown in degrees (`scale` 360).
    private func hsvChannel(_ name: String, _ component: WritableKeyPath<SIMD3<Double>, Double>,
                            range: ClosedRange<Double>, scale: Double) -> some View {
        let value = Binding<Double>(
            get: { hsv[keyPath: component] },
            set: { newValue in
                hsv[keyPath: component] = newValue
                picked = ColorPicking.rgb(fromHSV: hsv)
                scrub()
            })
        let shown = Binding<Double>(get: { value.wrappedValue * scale }, set: { value.wrappedValue = $0 / scale })
        // The track: the rainbow for hue, the ramp for saturation or value.
        let colors: [Color] = Self.stops(in: range) { level in
            var values: SIMD3<Double> = hsv
            values[keyPath: component] = level
            return screenColor(ofPicked: ColorPicking.rgb(fromHSV: values))
        }
        return row(name, slider: ColorTrack(value: value, range: range, colors: colors, onEditingChanged: endDrag),
                   number: shown)
    }

    /// Alpha, stored as it is (it isn't converted).
    private var alphaChannel: some View {
        let value = Binding<Double>(
            get: { stored.count > 3 ? stored[3] : 1 },
            set: { newValue in
                var numbers: [Double] = stored
                while numbers.count < 4 {
                    numbers.append(1)
                }
                numbers[3] = newValue
                let text: String = MXValueText.text(numbers, as: input.valueType)
                written = text
                actions.scrub(text)
            })
        return row("A", slider: Slider(value: value, in: 0...1, onEditingChanged: endDrag), number: value)
    }

    /// A slider with a label and a number field. The number commits on
    /// Return, as one step.
    private func row(_ name: String, slider: some View, number: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.caption.monospaced())
                .frame(width: 12)
            slider
            // SWIFT: `TextField(value:format:)` edits a number: it parses
            // what is typed with the format, and shows the value with it.
            TextField("", value: Binding(get: { number.wrappedValue }, set: { typed in
                number.wrappedValue = typed
                commit()
            }), format: .number.precision(.fractionLength(0...4)))
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
        }
    }

    /// A slider was let go: the next change is a new undo step.
    private func endDrag(_ editing: Bool) {
        if !editing {
            actions.endScrub()
        }
    }

    /// "#RRGGBB", for the encoded spaces.
    private var hexField: some View {
        HStack(spacing: 6) {
            Text("Hex")
                .font(.caption)
                .foregroundStyle(.secondary)
            CommitTextField(text: ColorPicking.hex(picked)) { text in
                guard let rgb = ColorPicking.rgb(hex: text) else {
                    NSSound.beep()
                    return
                }
                commit(picked: rgb)
            }
            .font(.system(.body, design: .monospaced))
            .help("The colour as a hex code, in \(pickSpace.title)")
        }
    }

    /// Shown when the colour is outside the input's gamut, with Clip.
    @ViewBuilder
    private var gamutWarning: some View {
        let rgb: SIMD3<Double> = Self.rgb(stored)
        if ColorPicking.isOutOfGamut(rgb) {
            HStack(spacing: 6) {
                Label("Outside \(inputSpace)'s gamut", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("A component is negative in the input's space. MaterialX allows it, but renderers treat it differently.")
                Spacer()
                Button("Clip") {
                    let text: String = text(for: ColorPicking.clipped(rgb))
                    written = nil
                    actions.commit(text)
                }
                .controlSize(.small)
                .help("Set the negative components to 0, the nearest colour in \(inputSpace)'s gamut")
            }
        }
    }

    /// Picks a colour on the screen. macOS gives it in the screen's colour
    /// space; Core Graphics converts it to linear Rec.709 and OCIO from
    /// there to the input's space (ColorSpaceMapping).
    ///
    /// SWIFT: `NSColorSampler` shows the system's magnifier; the closure
    /// is called once, with the colour, or nil if the user pressed Escape.
    /// AppKit calls it on the main thread, but its type doesn't say so
    /// (it is a plain `@Sendable` closure), so `MainActor.assumeIsolated`
    /// tells the compiler, and traps if it were ever called elsewhere (as
    /// in MaterialXDocument's `read`).
    private func sampleScreen(mapping: ColorSpaceMapping) {
        NSColorSampler().show { color in
            MainActor.assumeIsolated {
                guard let color, let numbers = mapping.components(of: color.cgColor, count: 3) else {
                    return
                }
                let text: String = text(for: Self.rgb(numbers))
                written = nil
                actions.commit(text)
            }
        }
    }
}

/// A slider whose track shows the colour along it (M3e): a colour picker's
/// sliders, where SwiftUI's own would be plain blue.
///
/// SWIFT: A custom control from shapes and a gesture. `GeometryReader`
/// gives the width to map the pointer to a value; `DragGesture` with
/// `minimumDistance: 0` also takes a click (a drag of no length).
struct ColorTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// The track's colours, left to right.
    let colors: [Color]
    /// Called with true when a drag starts and false when it ends, like
    /// Slider's: one undo step per drag.
    let onEditingChanged: (Bool) -> Void

    @State private var dragging: Bool = false

    private static let thumb: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let travel: CGFloat = max(1, geometry.size.width - Self.thumb)
            let span: Double = max(range.upperBound - range.lowerBound, 1e-9)
            let fraction: Double = min(max((value - range.lowerBound) / span, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.separator))
                    .frame(height: 10)
                    .padding(.horizontal, Self.thumb / 2 - 2)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35)))
                    .shadow(radius: 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: CGFloat(fraction) * travel)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        onEditingChanged(true)
                    }
                    let position: Double = Double((drag.location.x - Self.thumb / 2) / travel)
                    value = range.lowerBound + min(max(position, 0), 1) * span
                }
                .onEnded { _ in
                    dragging = false
                    onEditingChanged(false)
                })
        }
        .frame(height: 18)
    }
}

/// The colour field (M3e): a picture of the colours to pick from, and a
/// ring where the current one is. Click or drag to pick: `onPick` gets the
/// point as saturation (0 at the left) and value (0 at the bottom), 0 to 1.
struct ColorField: View {
    let image: CGImage?
    let saturation: Double
    /// The value as a fraction of the field's top.
    let value: Double
    let onEditingChanged: (Bool) -> Void
    let onPick: (Double, Double) -> Void

    @State private var dragging: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let size: CGSize = geometry.size
            ZStack(alignment: .topLeading) {
                if let image {
                    // SWIFT: `Image(decorative:scale:)` shows a CGImage;
                    // `.interpolation(.medium)` smooths it as it is scaled
                    // up from 48 × 32.
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                } else {
                    Rectangle().fill(.quaternary)
                }
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(min(max(saturation, 0), 1)) * size.width - 6,
                            y: CGFloat(1 - min(max(value, 0), 1)) * size.height - 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        onEditingChanged(true)
                    }
                    let s: Double = Double(drag.location.x / max(size.width, 1))
                    let v: Double = 1 - Double(drag.location.y / max(size.height, 1))
                    onPick(min(max(s, 0), 1), min(max(v, 0), 1))
                }
                .onEnded { _ in
                    dragging = false
                    onEditingChanged(false)
                })
        }
    }
}
