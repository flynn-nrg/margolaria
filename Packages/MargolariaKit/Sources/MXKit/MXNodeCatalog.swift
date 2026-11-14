// MXNodeCatalog.swift
//
// The node library (M2e): every node a document can add, from the data
// libraries and the document's own nodedefs. MaterialX defines one nodedef
// per type variant (`ND_add_float`, `ND_add_color3`, `ND_add_color3FA`,
// ...); the catalog lists each node once, as an MXNodeKind holding its
// variants, so the sidebar shows "add" rather than twenty entries.
//
// For each kind it picks the variant a new node starts as (colour first,
// then float, ...), names the variants for the inspector's Type menu
// ("color3", "color3 (in2: float)"), and searches by name. For a wire
// dropped on empty canvas, it picks the variant that can take the wire,
// and the port it goes to (`ND_multiply_float`'s in1 for a float wire).
//
// Introduces (SWIFT): `Dictionary(grouping:by:)`, comparing tuples in
// `sorted`/`min(by:)`, `firstIndex(of:)` as a rank, `lazy` sequences,
// `allSatisfy`.

import Foundation
import MXBridge

/// One input or output of a nodedef.
public struct MXNodeDefinitionPort: Hashable, Sendable {
    public let name: String
    /// The MaterialX type: "float", "color3", ...
    public let type: String
    /// `uniform="true"`: takes a value or a graph input, not a node's output.
    public let isUniform: Bool

    init(_ port: mxbridge.NodeDefPort) {
        name = port.name.swiftString
        type = port.type.swiftString
        isUniform = port.isUniform
    }

    public init(name: String, type: String, isUniform: Bool = false) {
        self.name = name
        self.type = type
        self.isUniform = isUniform
    }
}

/// One nodedef: one type variant of a node.
public struct MXNodeDefinition: Hashable, Sendable, Identifiable {
    /// The nodedef's name, such as "ND_multiply_color3FA".
    public let name: String
    /// The node's category, such as "multiply".
    public let node: String
    /// The output type, or "multioutput".
    public let type: String
    /// `nodegroup`: "math", "texture2d", ...
    public let group: String?
    /// `doc`: what the node does.
    public let documentation: String?
    /// True for a nodedef in the document rather than the data libraries.
    public let isFromDocument: Bool
    public let inputs: [MXNodeDefinitionPort]
    public let outputs: [MXNodeDefinitionPort]
    /// The library file defining it, for a nodedef the document doesn't
    /// have yet (M7c): adding a node of it includes the file first. Nil for
    /// the document's own and the data libraries'.
    public let libraryFile: URL?

    public var id: String { name }

    init(_ nodeDef: mxbridge.NodeDefSummary) {
        name = nodeDef.name.swiftString
        node = nodeDef.node.swiftString
        type = nodeDef.type.swiftString
        group = nodeDef.nodeGroup.swiftString.nonEmpty
        documentation = nodeDef.doc.swiftString.nonEmpty
        isFromDocument = nodeDef.isFromDocument
        inputs = nodeDef.inputs.map { MXNodeDefinitionPort($0) }
        outputs = nodeDef.outputs.map { MXNodeDefinitionPort($0) }
        libraryFile = nil
    }

    /// For tests and previews.
    public init(name: String, node: String, type: String, group: String? = nil, documentation: String? = nil,
                isFromDocument: Bool = false, inputs: [MXNodeDefinitionPort] = [],
                outputs: [MXNodeDefinitionPort] = [], libraryFile: URL? = nil) {
        self.name = name
        self.node = node
        self.type = type
        self.group = group
        self.documentation = documentation
        self.isFromDocument = isFromDocument
        self.inputs = inputs
        self.outputs = outputs
        self.libraryFile = libraryFile
    }

    /// The same definition, as found in the library file at `url` rather
    /// than in a document (M7c).
    func inLibraryFile(_ url: URL) -> MXNodeDefinition {
        MXNodeDefinition(name: name, node: node, type: type, group: group, documentation: documentation,
                         isFromDocument: false, inputs: inputs, outputs: outputs, libraryFile: url)
    }
}

/// A node as the library lists it: its category and every type variant.
public struct MXNodeKind: Hashable, Sendable, Identifiable {
    /// The category: "multiply", "image", "open_pbr_surface", ...
    public let node: String
    /// The default variant's `nodegroup` (or the first variant's that has
    /// one). Variants can differ: multiply is "math", but its BSDF
    /// variants are "pbr".
    public let group: String?
    /// The default variant's description, or the first variant's that has one.
    public let documentation: String?
    /// True if the document defines any of its variants.
    public let isFromDocument: Bool
    /// The library file its default variant is in, for a kind the document
    /// doesn't have yet (M7c); nil otherwise.
    public var libraryFile: URL? { defaultVariant.libraryFile }
    /// Every variant, in library order.
    public let variants: [MXNodeDefinition]
    /// The variant a new node starts as.
    public let defaultVariant: MXNodeDefinition

    public var id: String { node }

    /// Output types in the order a new node prefers them: colour first, as
    /// most graphs are about colour, then the other common value types,
    /// then shaders. A type not listed comes after all of these.
    static let preferredTypes: [String] = [
        "color3", "float", "vector3", "vector2", "color4", "vector4", "integer", "boolean",
        "surfaceshader", "BSDF", "EDF", "VDF", "displacementshader", "volumeshader", "material",
    ]

    init(node: String, variants: [MXNodeDefinition]) {
        self.node = node
        self.variants = variants
        // SWIFT: `min(by:)` with a comparison of tuples: Swift compares
        // tuples element by element, like std::tuple's operator<. So: the
        // preferred type first; among equals, the shortest name, which is
        // the plain variant (ND_multiply_color3 before ND_multiply_color3FA,
        // ND_mix_color3 before ND_mix_color3_color3).
        defaultVariant = variants.min { a, b in
            (Self.rank(of: a.type), a.name.count) < (Self.rank(of: b.type), b.name.count)
        }!  // SWIFT: `!` unwraps; the catalog never makes a kind without variants.
        // SWIFT: `lazy` makes `compactMap` produce values on demand, so
        // `.first` stops at the first one instead of mapping every variant.
        // `\.group` is a key path used as a function: `{ $0.group }`.
        group = defaultVariant.group ?? variants.lazy.compactMap(\.group).first
        documentation = defaultVariant.documentation ?? variants.lazy.compactMap(\.documentation).first
        isFromDocument = variants.contains(where: \.isFromDocument)
    }

    /// Where `type` is in ``preferredTypes``; after all of them if absent.
    ///
    /// SWIFT: `firstIndex(of:)` returns the index or nil; `??` supplies the
    /// value for nil.
    static func rank(of type: String) -> Int {
        preferredTypes.firstIndex(of: type) ?? preferredTypes.count
    }

    /// A short name telling `variant` apart from the others, for the Type
    /// menu: the output type ("color3"), followed, where several variants
    /// share it, by the inputs whose types differ between them
    /// ("color3 (in2: float)"). Multi-output variants are named by their
    /// inputs alone ("in: vector3"). Falls back to the nodedef's name.
    public func label(for variant: MXNodeDefinition) -> String {
        let base: String = variant.type == "multioutput" ? "" : variant.type
        let siblings: [MXNodeDefinition] = variants.filter { $0.type == variant.type }
        if siblings.count == 1 && !base.isEmpty {
            return base
        }
        // The inputs, by name, whose type isn't the same in every sibling
        // (or that some siblings lack).
        let varying: [MXNodeDefinitionPort] = variant.inputs.filter { input in
            !siblings.allSatisfy { sibling in
                sibling.inputs.contains(where: { $0.name == input.name && $0.type == input.type })
            }
        }
        let suffix: String = varying.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        switch (base.isEmpty, suffix.isEmpty) {
        case (_, true):
            // Nothing to tell it apart by but its name.
            return variant.name
        case (true, false):
            return suffix
        case (false, false):
            return "\(base) (\(suffix))"
        }
    }

    /// The variant called `name`, if it is one of this kind's.
    public func variant(named name: String) -> MXNodeDefinition? {
        variants.first(where: { $0.name == name })
    }
}

/// What a new node needs to connect to a wire dropped on empty canvas.
public enum MXConnectionNeed: Hashable, Sendable {
    /// An input of this type, for a wire from an output.
    case input(String)
    /// An output of this type, for a wire into an input.
    case output(String)
}

/// A node to add, as the node search lists it: the variant to add, and,
/// for a wire, the port the wire goes to.
public struct MXNodeMatch: Hashable, Sendable, Identifiable {
    public let kind: MXNodeKind
    public let variant: MXNodeDefinition
    /// The new node's input (or output) the wire connects to; nil when
    /// there is no wire.
    public let port: String?

    public var id: String { kind.node }

    public init(kind: MXNodeKind, variant: MXNodeDefinition, port: String? = nil) {
        self.kind = kind
        self.variant = variant
        self.port = port
    }
}

extension MXNodeKind {
    /// The variant and port that can take a wire with `need`, or nil if no
    /// variant can.
    ///
    /// For a wire from an output (`.input(type)`): variants with an input
    /// of that type that isn't `uniform`, preferring those whose output is
    /// the same type (a float wire into multiply makes `ND_multiply_float`,
    /// not `ND_multiply_color3FA`'s float in2), then the usual order. For a
    /// wire into an input (`.output(type)`): variants with an output of
    /// that type, preferring the preferred types for their first input
    /// (`ND_convert_float_color3` for a colour), then the plainest name.
    /// The port is the first one of the type: in1 before in2.
    public func match(for need: MXConnectionNeed) -> MXNodeMatch? {
        // SWIFT: A tuple array of (variant, port, sort key) for the
        // candidates; `min(by:)` compares the keys, which are tuples too.
        let candidates: [(variant: MXNodeDefinition, port: String, key: (Int, Int, Int))]
        switch need {
        case .input(let type):
            candidates = variants.compactMap { variant in
                guard let input = variant.inputs.first(where: { $0.type == type && !$0.isUniform }) else {
                    return nil
                }
                return (variant, input.name, (variant.type == type ? 0 : 1, Self.rank(of: variant.type), variant.name.count))
            }
        case .output(let type):
            candidates = variants.compactMap { variant in
                guard let output = variant.outputs.first(where: { $0.type == type }) else {
                    return nil
                }
                let firstInput: String = variant.inputs.first?.type ?? ""
                return (variant, output.name, (variant.type == type ? 0 : 1, Self.rank(of: firstInput), variant.name.count))
            }
        }
        guard let best = candidates.min(by: { $0.key < $1.key }) else {
            return nil
        }
        return MXNodeMatch(kind: self, variant: best.variant, port: best.port)
    }
}

/// A group of kinds as the library shows it: one `nodegroup`.
public struct MXNodeGroup: Hashable, Sendable, Identifiable {
    /// The `nodegroup` value, or "other" for kinds without one.
    public let name: String
    /// A heading for the list: "Texture 2D", "Math", ...
    public let title: String
    /// Sorted by name.
    public let kinds: [MXNodeKind]

    public var id: String { name }
}

/// Every node that can be added to one document, grouped and searchable.
public struct MXNodeCatalog: Sendable {
    /// Every kind, sorted by name.
    public let kinds: [MXNodeKind]

    /// The kinds by `nodegroup`, in ``groupOrder``; nodes the document
    /// itself defines come first, in a group called "document", then those
    /// of library files, in "library" (M7c).
    public let groups: [MXNodeGroup]

    /// The groups' order: the ones used to build materials first (PLAN
    /// §4.1 calls the library "grouped by nodegroup"; the order is ours).
    /// Groups not listed follow, alphabetically.
    static let groupOrder: [String] = [
        "document", "library", "pbr", "texture2d", "texture3d", "procedural2d", "procedural3d", "procedural",
        "geometric", "math", "adjustment", "compositing", "conditional", "channel", "convolution2d",
        "colortransform", "organization", "shader", "material", "light", "npr", "translation",
        "application",
    ]

    /// Headings for the groups whose names don't read well capitalised.
    static let groupTitles: [String: String] = [
        "document": "In This Document", "library": "In Library Files", "pbr": "PBR", "texture2d": "Texture 2D", "texture3d": "Texture 3D",
        "procedural2d": "Procedural 2D", "procedural3d": "Procedural 3D", "convolution2d": "Convolution 2D",
        "colortransform": "Colour Transform", "npr": "NPR",
    ]

    /// Builds the catalog from nodedefs, in the order given (document
    /// first, as ``MXDocument/nodeDefinitions`` lists them), and the
    /// definitions in `libraryFiles` that aren't among them (M7c): those
    /// the document can use once it includes their file. A nodedef in two
    /// files is listed from the first.
    public init(definitions: [MXNodeDefinition], libraryFiles: [MXLibraryFile] = []) {
        var known = Set(definitions.map(\.name))
        var all: [MXNodeDefinition] = definitions
        for file in libraryFiles {
            // SWIFT: `insert(_:).inserted` is false for a name already in
            // the set: added only the first time it is seen.
            for definition in file.definitions where known.insert(definition.name).inserted {
                all.append(definition.inLibraryFile(file.url))
            }
        }
        // SWIFT: `Dictionary(grouping:by:)` makes a dictionary from a key
        // to the array of elements with that key, keeping their order.
        let byNode: [String: [MXNodeDefinition]] = Dictionary(grouping: all, by: \.node)
        kinds = byNode.map { MXNodeKind(node: $0.key, variants: $0.value) }.sorted { $0.node < $1.node }

        let byGroup: [String: [MXNodeKind]] = Dictionary(grouping: kinds) { kind in
            kind.isFromDocument ? "document" : kind.libraryFile != nil ? "library" : (kind.group ?? "other")
        }
        groups = byGroup.map { name, kinds in
            MXNodeGroup(name: name, title: Self.groupTitles[name] ?? name.capitalized, kinds: kinds)
        }
        .sorted { a, b in
            let rankA: Int = Self.groupOrder.firstIndex(of: a.name) ?? Self.groupOrder.count
            let rankB: Int = Self.groupOrder.firstIndex(of: b.name) ?? Self.groupOrder.count
            return (rankA, a.name) < (rankB, b.name)
        }
    }

    /// The catalog for `document`: its own nodedefs and its data library's,
    /// and those of `libraryFiles` it doesn't have yet (M7c).
    public init(document: MXDocument, libraryFiles: [MXLibraryFile] = []) {
        self.init(definitions: document.nodeDefinitions, libraryFiles: libraryFiles)
    }

    /// The kind whose category is `node`, if there is one.
    public func kind(named node: String) -> MXNodeKind? {
        // SWIFT: A binary search would be faster on the sorted array, but
        // with ~300 kinds a linear one takes microseconds.
        kinds.first(where: { $0.node == node })
    }

    /// The nodedef called `name` (a variant of one of the kinds), if any.
    public func definition(named name: String) -> MXNodeDefinition? {
        // SWIFT: `lazy` again: `flatMap` would otherwise build an array of
        // all ~800 variants before `first` looked at any.
        kinds.lazy.flatMap(\.variants).first(where: { $0.name == name })
    }

    /// The kinds matching `text`, best first. Matching ignores case and
    /// underscores' role as separators: "surf" and "pbr surf" both find
    /// "open_pbr_surface". Ranks: the exact name, then names starting with
    /// the text, then names with a word (after "_") starting with it, then
    /// names containing it; within a rank, shorter names first (the basic
    /// node before its relatives: open_pbr_surface before
    /// open_pbr_surface_to_standard_surface). Every word of a
    /// multi-word query must match. An empty query matches everything.
    public func search(_ text: String) -> [MXNodeKind] {
        let words: [String] = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init)
        guard !words.isEmpty else {
            return kinds
        }
        // SWIFT: `compactMap` keeps the non-nil results; the closure
        // returns nil for kinds that don't match.
        let ranked: [(rank: Int, kind: MXNodeKind)] = kinds.compactMap { kind in
            let name: String = kind.node.lowercased()
            let parts: [Substring] = name.split(separator: "_")
            var worst: Int = 0
            for word in words {
                let rank: Int
                if name == word {
                    rank = 0
                } else if name.hasPrefix(word) {
                    rank = 1
                } else if parts.contains(where: { $0.hasPrefix(word) }) {
                    rank = 2
                } else if name.contains(word) {
                    rank = 3
                } else {
                    return nil
                }
                // A multi-word query ranks by its weakest word.
                worst = max(worst, rank)
            }
            return (worst, kind)
        }
        return ranked.sorted { a, b in
            (a.rank, a.kind.node.count, a.kind.node) < (b.rank, b.kind.node.count, b.kind.node)
        }
        .map(\.kind)
    }
}

extension MXNodeCatalog {
    /// The node search's results for `text`: each matching kind as the
    /// variant to add. With `need` (a wire dropped on empty canvas), only
    /// the kinds that can take the wire, with the variant and port that do.
    public func search(_ text: String, for need: MXConnectionNeed?) -> [MXNodeMatch] {
        let kinds: [MXNodeKind] = search(text)
        // SWIFT: `if let` on the optional parameter picks the branch.
        if let need {
            return kinds.compactMap { $0.match(for: need) }
        }
        return kinds.map { MXNodeMatch(kind: $0, variant: $0.defaultVariant) }
    }
}

extension MXDocument {
    /// Every nodedef a node can be added from: the document's own, then
    /// the data library's (once ``setDataLibrary(_:)`` has been called).
    public var nodeDefinitions: [MXNodeDefinition] {
        handle.nodeDefinitions().map { MXNodeDefinition($0) }
    }
}
