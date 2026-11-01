// MXGraph.swift
//
// The graph structure of a document, as plain Swift values: the nodes of one
// level (the document root or one nodegraph), their inputs and outputs, and
// how they connect. The graph canvas (M1b) draws from these; nothing here
// can change the document.
//
// These are snapshots: reading a graph copies what MaterialX holds at that
// moment. When M2 adds editing, each edit produces a new snapshot.
//
// Introduces (SWIFT): failable initializers (`init?`), assigning `self` in
// an enum's initializer, the `if let x` shorthand, `_` in patterns,
// an `extension` shared within the module, `.map` over a C++ vector, `CGPoint`/`CGFloat`;
// `filter` on a dictionary (M4b).

import CoreGraphics
import Foundation
import MXBridge

/// Where an input (or output) gets its value from, when it is connected.
///
/// MaterialX writes a connection as attributes on the input: `nodename`,
/// `nodegraph`, `output` and `interfacename`. The cases below are the
/// combinations that mean something.
///
/// SWIFT: Associated values with labels. `.node("grain", output: nil)` reads
/// like a function call, and `case .node(let name, let output)` takes it apart
/// again in a `switch`.
public enum MXConnection: Hashable, Sendable {
    /// `nodename="grain"`, optionally with `output="out"` for a node with
    /// several outputs.
    case node(String, output: String?)
    /// `nodegraph="NG_copper"` with `output="roughness_out"` (or only one output).
    case nodeGraph(String, output: String?)
    /// `interfacename="amount"`: inside a nodegraph, the graph's own input.
    case interface(String)
    /// `output="out"` on its own: a top-level `<output>` element.
    case output(String)

    /// Reads the connection attributes of a port, or returns nil when the
    /// port isn't connected.
    ///
    /// SWIFT: `init?` is a *failable initializer*: it may return nil instead
    /// of a value, so `MXConnection(port)` has the type `MXConnection?`. It's
    /// the Swift form of an ObjC `-init` that returns nil.
    init?(_ port: mxbridge.PortInfo) {
        let nodeName: String = port.nodeName.swiftString
        let nodeGraphName: String = port.nodeGraphName.swiftString
        let outputName: String? = port.outputName.swiftString.nonEmpty
        let interfaceName: String = port.interfaceName.swiftString

        if !interfaceName.isEmpty {
            self = .interface(interfaceName)
        } else if !nodeName.isEmpty {
            self = .node(nodeName, output: outputName)
        } else if !nodeGraphName.isEmpty {
            self = .nodeGraph(nodeGraphName, output: outputName)
        } else if let outputName {
            // SWIFT: `if let outputName` is short for
            // `if let outputName = outputName`: unwrap into a constant of
            // the same name.
            self = .output(outputName)
        } else {
            // SWIFT: In a failable initializer, `return nil` means "no value".
            return nil
        }
    }

    /// The name of the node or nodegraph this connection comes from, if it
    /// comes from one.
    public var sourceNodeName: String? {
        switch self {
        case .node(let name, _), .nodeGraph(let name, _):
            return name
        case .interface, .output:
            return nil
        }
    }

    /// Which output of the source is used, if the file says.
    public var sourceOutputName: String? {
        switch self {
        case .node(_, let output), .nodeGraph(_, let output):
            return output
        case .interface, .output:
            return nil
        }
    }
}

/// One input or output of a node, nodegraph or graph.
public struct MXPort: Hashable, Sendable {
    /// The port's name, such as "base_color" or "out".
    public let name: String
    /// The MaterialX type, such as "float", "color3" or "surfaceshader".
    public let type: String
    /// The value as written in the file, such as "0.8, 0.8, 0.8"; for inputs
    /// the document doesn't set, the nodedef's default. Nil if there is none
    /// (outputs, connected inputs without a value).
    public let value: String?
    /// True when the document sets this input; false when the node uses the
    /// nodedef's default. The canvas shows authored inputs first.
    public let isAuthored: Bool
    /// What the port is connected to, or nil.
    public let connection: MXConnection?
    /// The `colorspace` attribute, such as "srgb_texture", if set.
    public let colorSpace: String?
    /// For "filename" inputs: the file it refers to, with `fileprefix`
    /// applied and resolved against the folder of the file the input came
    /// from. Nil for other types, or when the document wasn't read from a file.
    public let fileURL: URL?
    /// The nodedef's `uifolder`, such as "Specular", for grouping inputs.
    public let uiFolder: String?
    /// True for inputs that can only be set, never connected.
    public let isUniform: Bool
    /// The nodedef's default value, such as "0.8, 0.8, 0.8", whether or not
    /// the document sets the input. Nil without a nodedef or a default.
    public let defaultValue: String?
    /// The colour space the value is in: the port's own `colorspace`, an
    /// ancestor's, or the nodedef's. Nil means the document's working
    /// space (lin_rec709 unless the document says otherwise).
    public let activeColorSpace: String?
    /// The colour space the value would be in without the port's own
    /// `colorspace`: its owner's or an ancestor's. Nil means the document's
    /// working space. The inspector's colour space menu calls it "Default".
    public let inheritedColorSpace: String?
    /// How the inspector shows the input: label, ranges, choices, help.
    public let ui: MXPortUI
    /// The metadata as written, by attribute (M4b's inspector edits a
    /// nodegraph input's): the port's own, else its nodedef's.
    public let metadata: [MXInputMetadata: String]
    /// The `xpos`/`ypos` saved on a nodegraph's own input or output, which
    /// the canvas draws as a small node; nil if none (and for node inputs).
    public let position: CGPoint?

    /// The kind of value, which decides the inspector's widget.
    public var valueType: MXValueType {
        MXValueType(type)
    }

    /// Converts the bridge's C++ struct.
    init(_ port: mxbridge.PortInfo) {
        name = port.name.swiftString
        type = port.type.swiftString
        value = port.value.swiftString.nonEmpty
        isAuthored = port.isAuthored
        connection = MXConnection(port)
        colorSpace = port.colorSpace.swiftString.nonEmpty
        fileURL = Self.resolveFile(port.resolvedFilename.swiftString, from: port.sourceUri.swiftString)
        uiFolder = port.uiFolder.swiftString.nonEmpty
        isUniform = port.isUniform
        defaultValue = port.defaultValue.swiftString.nonEmpty
        activeColorSpace = port.activeColorSpace.swiftString.nonEmpty
        inheritedColorSpace = port.inheritedColorSpace.swiftString.nonEmpty
        ui = MXPortUI(port)
        metadata = Self.metadata(of: port)
        position = port.hasPosition ? CGPoint(x: CGFloat(port.xpos), y: CGFloat(port.ypos)) : nil
    }

    /// The metadata attributes `port` has, as text.
    ///
    /// SWIFT: A dictionary literal with enum keys; `filter` on a dictionary
    /// keeps the (key, value) pairs for which the closure is true, and
    /// gives a dictionary back.
    private static func metadata(of port: mxbridge.PortInfo) -> [MXInputMetadata: String] {
        let all: [MXInputMetadata: String] = [
            .uiName: port.uiName.swiftString,
            .uiFolder: port.uiFolder.swiftString,
            .uiMin: port.uiMin.swiftString,
            .uiMax: port.uiMax.swiftString,
            .uiSoftMin: port.uiSoftMin.swiftString,
            .uiSoftMax: port.uiSoftMax.swiftString,
            .uiStep: port.uiStep.swiftString,
            .enumNames: port.enumNames.map { $0.swiftString }.joined(separator: ", "),
            .enumValues: port.enumValues.map { $0.swiftString }.joined(separator: ", "),
            .doc: port.doc.swiftString,
            .uiAdvanced: port.isAdvanced ? "true" : "",
        ]
        return all.filter { !$0.value.isEmpty }
    }

    /// Turns a filename value into a file URL: absolute paths as they are,
    /// relative ones against the folder of `sourceFile`.
    ///
    /// SWIFT: `static` because it doesn't use any instance; it can be called
    /// before `self` is fully initialised, which is why `init` can use it.
    private static func resolveFile(_ filename: String, from sourceFile: String) -> URL? {
        if filename.isEmpty {
            return nil
        }
        if filename.hasPrefix("/") {
            return URL(filePath: filename)
        }
        if sourceFile.isEmpty {
            // Read from a string: there is no folder to be relative to.
            return nil
        }
        // SWIFT: `deletingLastPathComponent()` goes from a file to its
        // folder, like `dirname`. `appending(path:)` then adds the relative
        // path, and `standardized` resolves any "../" in it.
        let folder: URL = URL(filePath: sourceFile).deletingLastPathComponent()
        return folder.appending(path: filename).standardized
    }
}

/// One node of a graph. A nodegraph shown inside its parent graph is also an
/// MXNode, with ``isNodeGraph`` set.
public struct MXNode: Identifiable, Hashable, Sendable {
    /// The node's name, unique within its graph.
    public let name: String
    /// The node's category, such as "open_pbr_surface" or "image", or
    /// "nodegraph".
    public let category: String
    /// The output type, such as "color3", "surfaceshader" or "multioutput".
    public let type: String
    /// The path from the document root, such as "NG_copper/grain".
    public let path: String
    /// The nodedef this node uses (or a nodegraph implements), such as
    /// "ND_image_color3". Nil if not found: an unknown node, or a document
    /// without a data library.
    public let nodeDefName: String?
    /// The nodedef's `nodegroup`, such as "pbr", "texture2d" or "math". Nil
    /// without a nodedef. The canvas colours node headers by it.
    public let nodeGroup: String?
    /// What the node does: its nodedef's `doc`, or a nodegraph's own. Nil
    /// if there is none.
    public let documentation: String?
    /// True for a nodegraph shown as a node.
    public let isNodeGraph: Bool
    /// True if the node came from an `xi:include`d file: read-only, because
    /// saving writes the include back as a reference.
    public let isIncluded: Bool
    /// The `xpos`/`ypos` position saved in the file, if any. MaterialX's
    /// Graph Editor writes these; none of MaterialX's own examples have them.
    public let position: CGPoint?
    /// All inputs: the nodedef's in order, then any extra ones the document
    /// sets. For a nodegraph, its interface inputs.
    public let inputs: [MXPort]
    /// The outputs: from the nodedef, or a nodegraph's `<output>` elements.
    public let outputs: [MXPort]

    /// Required by `Identifiable`: the path is unique in the document.
    public var id: String { path }

    /// Converts the bridge's C++ struct.
    init(_ node: mxbridge.NodeInfo) {
        name = node.name.swiftString
        category = node.category.swiftString
        type = node.type.swiftString
        path = node.path.swiftString
        nodeDefName = node.nodeDefName.swiftString.nonEmpty
        nodeGroup = node.nodeGroup.swiftString.nonEmpty
        documentation = node.doc.swiftString.nonEmpty
        isNodeGraph = node.isNodeGraph
        isIncluded = node.isIncluded
        // SWIFT: The ternary operator works as in C. `CGFloat(...)` converts
        // the C++ `float` (Swift `Float`, 32 bits) to Core Graphics' 64-bit
        // floating-point type; Swift never converts numbers implicitly.
        position = node.hasPosition ? CGPoint(x: CGFloat(node.xpos), y: CGFloat(node.ypos)) : nil
        inputs = node.inputs.map { MXPort($0) }
        outputs = node.outputs.map { MXPort($0) }
    }
}

/// One level of a document's graph: the document root, or one nodegraph.
public struct MXGraph: Hashable, Sendable {
    /// "" for the document root; otherwise the nodegraph's path.
    public let path: String
    /// The nodes of this level, in file order, nodegraphs included.
    public let nodes: [MXNode]
    /// A nodegraph's interface inputs. Empty at the document root.
    public let interfaceInputs: [MXPort]
    /// The `<output>` elements of this level, with what they connect to.
    public let outputs: [MXPort]

    /// The node called `name`, or nil.
    public func node(named name: String) -> MXNode? {
        nodes.first(where: { $0.name == name })
    }

    /// Converts the bridge's C++ struct.
    init(_ graph: mxbridge.GraphInfo) {
        path = graph.path.swiftString
        nodes = graph.nodes.map { MXNode($0) }
        interfaceInputs = graph.interfaceInputs.map { MXPort($0) }
        outputs = graph.outputs.map { MXPort($0) }
    }
}

// SWIFT: An `extension` without an access level gives its members the
// default, `internal`: visible throughout MXKit (MXValue.swift uses it too),
// but not to the app. A small helper, not worth exposing.
extension String {
    /// The string itself, or nil when it's empty. MaterialX uses "" for
    /// "not set"; Swift has optionals for that.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
