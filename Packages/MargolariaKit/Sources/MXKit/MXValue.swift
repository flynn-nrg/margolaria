// MXValue.swift
//
// MaterialX values as the inspector (M2b) needs them: what kind of value a
// type holds (which picks the widget), how an input should be presented
// (label, ranges, choices, help text, from the nodedef), and converting
// between MaterialX's value text ("0.8, 0.2, 0.1") and numbers.
//
// MaterialX stores every value as text in the file, and MXKit keeps it that
// way: edits pass text to `setValue(_:ofInput:on:)`, which checks it. These
// helpers only turn text into numbers for sliders and colour wells, and
// back.
//
// Introduces (SWIFT): enums with an `init` that classifies a String, a
// case-less enum as a namespace, `ClosedRange`, `zip`, `Double` vs `Float`
// and formatting numbers with `String(_:)`, extending a generic type
// (`Array`) and its `Element`.

import Foundation
import MXBridge

/// The kind of value a MaterialX type holds, as far as editing goes.
///
/// SWIFT: Associated values carry the size of vectors and matrices, so
/// `.vector(3)` and `.vector(2)` are different values of the same case.
/// Compare a C union with a tag, but the compiler checks the tag for you.
public enum MXValueType: Hashable, Sendable {
    case float
    case integer
    case boolean
    /// `color3` or `color4`: 3 or 4 components.
    case color(Int)
    /// `vector2`, `vector3` or `vector4`.
    case vector(Int)
    /// `matrix33` or `matrix44`: the number of rows (and columns).
    case matrix(Int)
    case string
    /// A file path, usually a texture, relative to the document's folder.
    case filename
    /// Anything else: arrays, shader types (`surfaceshader`, which are only
    /// ever connected), custom types. Edited as text, if at all.
    case other(String)

    /// Classifies a MaterialX type name, such as "color3".
    public init(_ typeName: String) {
        // SWIFT: `switch` on a String matches exact values. Assigning
        // `self` in an initializer works for enums (see MXConnection).
        switch typeName {
        case "float":
            self = .float
        case "integer":
            self = .integer
        case "boolean":
            self = .boolean
        case "color3":
            self = .color(3)
        case "color4":
            self = .color(4)
        case "vector2":
            self = .vector(2)
        case "vector3":
            self = .vector(3)
        case "vector4":
            self = .vector(4)
        case "matrix33":
            self = .matrix(3)
        case "matrix44":
            self = .matrix(4)
        case "string":
            self = .string
        case "filename":
            self = .filename
        default:
            self = .other(typeName)
        }
    }

    /// How many numbers a value of this type is made of: 1 for a float or
    /// integer, 3 for a color3, 16 for a matrix44. Nil for types that aren't
    /// numbers (booleans, strings, files, others).
    public var componentCount: Int? {
        switch self {
        case .float, .integer:
            return 1
        case .color(let count), .vector(let count):
            return count
        case .matrix(let rows):
            return rows * rows
        case .boolean, .string, .filename, .other:
            return nil
        }
    }
}

/// One choice of an enum input: the name shown, and the value stored.
public struct MXEnumOption: Hashable, Sendable {
    /// What the menu shows, such as "BLEND".
    public let name: String
    /// What the input's value is set to, such as "2". The same as `name`
    /// for string enums, which have no `enumvalues`.
    public let value: String
}

/// How an input asks to be presented: the nodedef's `ui*` attributes,
/// `enum`, `doc` and units, already parsed. Every field is optional: most
/// inputs set only a few.
public struct MXPortUI: Hashable, Sendable {
    /// `uiname`: the label to show, such as "Base Color". Nil to use the name.
    public let name: String?
    /// `uimin`/`uimax`: the hard limits, one number per component.
    public let minimum: [Double]?
    public let maximum: [Double]?
    /// `uisoftmin`/`uisoftmax`: the usual range, for sliders.
    public let softMinimum: [Double]?
    public let softMaximum: [Double]?
    /// `uistep`: the slider's increment.
    public let step: Double?
    /// `enum`/`enumvalues`: the allowed values. Empty when any value goes.
    public let enumOptions: [MXEnumOption]
    /// `doc`: a sentence about the input, for its tooltip.
    public let documentation: String?
    /// `uiadvanced="true"`: an input most users can leave alone.
    public let isAdvanced: Bool
    /// `defaultgeomprop`: the geometric property ("UV0", "Nworld", ...) an
    /// unconnected input reads instead of a value.
    public let defaultGeomProp: String?
    /// `unit` and `unittype`, such as "meter" and "distance".
    public let unit: String?
    public let unitType: String?

    /// The range a slider for component `component` should cover: the soft
    /// range if there is one, else the hard limits. Nil when either end is
    /// missing, or the ends are equal or the wrong way round.
    ///
    /// SWIFT: `ClosedRange<Double>` is a range including both ends, written
    /// `0...1`. SwiftUI's `Slider` takes one.
    public func sliderRange(component: Int = 0) -> ClosedRange<Double>? {
        // SWIFT: `?.` (optional chaining) gives nil if the array is nil;
        // `??` then tries the next one. `element(at:)` is defined below.
        let lower: Double? = softMinimum?.element(at: component) ?? minimum?.element(at: component)
        let upper: Double? = softMaximum?.element(at: component) ?? maximum?.element(at: component)
        guard let lower, let upper, lower < upper else {
            return nil
        }
        return lower...upper
    }

    /// Converts the metadata fields of the bridge's PortInfo.
    init(_ port: mxbridge.PortInfo) {
        name = port.uiName.swiftString.nonEmpty
        minimum = MXValueText.numbers(port.uiMin.swiftString)
        maximum = MXValueText.numbers(port.uiMax.swiftString)
        softMinimum = MXValueText.numbers(port.uiSoftMin.swiftString)
        softMaximum = MXValueText.numbers(port.uiSoftMax.swiftString)
        step = MXValueText.numbers(port.uiStep.swiftString)?.first
        documentation = port.doc.swiftString.nonEmpty
        isAdvanced = port.isAdvanced
        defaultGeomProp = port.defaultGeomProp.swiftString.nonEmpty
        unit = port.unit.swiftString.nonEmpty
        unitType = port.unitType.swiftString.nonEmpty

        // SWIFT: Mapping a C++ std::vector<std::string> gives a Swift
        // [String]: the vector is a Swift collection (see MXGraph.swift).
        let names: [String] = port.enumNames.map { $0.swiftString }
        let values: [String] = port.enumValues.map { $0.swiftString }
        if values.count == names.count {
            // SWIFT: `zip` pairs up two sequences element by element, like
            // Python's zip; the closure gets each pair as a tuple.
            enumOptions = zip(names, values).map { MXEnumOption(name: $0.0, value: $0.1) }
        } else {
            // No `enumvalues` (a string enum), or a malformed list: the
            // names are the values.
            enumOptions = names.map { MXEnumOption(name: $0, value: $0) }
        }
    }
}

/// Converting between MaterialX's value text and numbers.
///
/// MaterialX writes a value of a numeric type as its numbers separated by
/// commas ("0.8, 0.2, 0.1" for a color3, "1" for an integer), booleans as
/// "true" or "false".
///
/// SWIFT: An enum with no cases is a namespace: it can't be instantiated,
/// only hold `static` members. Swift's stand-in for a C++ namespace.
public enum MXValueText {
    /// The numbers in `text`, or nil if it is empty or any part isn't a
    /// number. "0.8, 0.2, 0.1" → [0.8, 0.2, 0.1].
    ///
    /// SWIFT: `Double` is a 64-bit float (C `double`), `Float` 32 bits.
    /// SwiftUI's sliders work in Double, so the inspector does too;
    /// MaterialX stores 32-bit floats, and ``text(_:as:)`` rounds to them.
    public static func numbers(_ text: String) -> [Double]? {
        if text.isEmpty {
            return nil
        }
        var numbers: [Double] = []
        for part in text.split(separator: ",") {
            // SWIFT: `trimmingCharacters(in:)` strips spaces at both ends.
            // `Double(_:)` parsing a String is failable: nil if it isn't a
            // number, so `guard let` rejects the whole text.
            guard let number = Double(part.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            numbers.append(number)
        }
        return numbers
    }

    /// MaterialX text for `numbers` as a value of `type`: integers without
    /// a decimal point, floats with as few digits as round-trip a 32-bit
    /// float ("0.8", not "0.800000011920929").
    public static func text(_ numbers: [Double], as type: MXValueType) -> String {
        let parts: [String] = numbers.map { (number: Double) -> String in
            if type == .integer {
                // SWIFT: `.rounded()` rounds to the nearest whole number;
                // `Int(_:)` then converts (it would truncate otherwise).
                return String(Int(number.rounded()))
            }
            // SWIFT: `String(Float(x))` prints the shortest text that reads
            // back as the same Float. Converting to Float first drops the
            // digits a 32-bit float can't hold.
            return String(Float(number))
        }
        return parts.joined(separator: ", ")
    }

    /// The boolean in `text` ("true" or "false"), or nil.
    public static func boolean(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces) {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    /// MaterialX text for a boolean.
    public static func text(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

// SWIFT: `Array` is generic (`Array<Element>`); an extension of it applies
// to arrays of any element type, and `Element` names that type inside.
// Like adding a member template to std::vector, which C++ can't do.
private extension Array {
    /// The element at `index`, or the last one if the array is shorter (a
    /// single `uimin` for all components), or nil if it is empty.
    func element(at index: Int) -> Element? {
        index < count ? self[index] : last
    }
}
