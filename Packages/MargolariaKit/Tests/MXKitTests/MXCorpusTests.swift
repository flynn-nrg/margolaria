// MXCorpusTests.swift
//
// M1's exit criterion: every example in MaterialX's
// resources/Materials/Examples opens (docs/PLAN.md §8). "Opens" here means:
// it reads (includes resolved), validates without errors, every level of
// its graph can be listed, and every connection points at something that
// exists in that level.
//
// The examples are not in the repository. Fetch them once with
// scripts/fetch-materialx-examples.sh; without them, these tests are skipped.
//
// Introduces (SWIFT): parameterized tests (`@Test(arguments:)`), test traits
// (`.enabled(if:)`), `#filePath`, `FileManager.enumerator`, `while let`,
// `Set`, nested functions, `Issue.record`, named tuples.

import Foundation
import Testing
@testable import MXKit

/// The example documents, found relative to this source file.
enum Corpus {
    /// Vendor/MaterialX/resources/Materials/Examples in the repository.
    ///
    /// SWIFT: `#filePath` is a literal the compiler replaces with the path of
    /// this source file, like C's `__FILE__`. From there, the repository root
    /// is five levels up: MXCorpusTests.swift, MXKitTests, Tests,
    /// MargolariaKit, Packages.
    static let examplesFolder: URL = {
        var url = URL(filePath: #filePath)
        for _ in 0..<5 {
            url = url.deletingLastPathComponent()
        }
        return url.appending(path: "Vendor/MaterialX/resources/Materials/Examples")
    }()

    /// Every .mtlx file under ``examplesFolder``, sorted, as paths relative
    /// to it ("OpenPbr/open_pbr_carpaint.mtlx"). Empty if not fetched.
    ///
    /// Relative paths rather than URLs, because each one becomes the name of
    /// a test case in the report.
    static let files: [String] = {
        let root: String = examplesFolder.path(percentEncoded: false)
        // SWIFT: `enumerator(atPath:)` walks a folder recursively, like
        // `find`. It returns nil if the folder doesn't exist; `guard let`
        // turns that into an empty list.
        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            return []
        }
        var files: [String] = []
        // SWIFT: The enumerator is an Objective-C collection of `Any`, so
        // each element is cast to String with `as?`.
        while let path = enumerator.nextObject() as? String {
            if path.hasSuffix(".mtlx") {
                files.append(path)
            }
        }
        return files.sorted()
    }()

    static var isAvailable: Bool { !files.isEmpty }
}

@Suite("MaterialX examples (M1 exit criterion)",
       // SWIFT: A *trait* changes how a test or suite runs. This one skips
       // the whole suite, with the comment as the reason, when the
       // examples haven't been fetched.
       .enabled(if: Corpus.isAvailable, "Run scripts/fetch-materialx-examples.sh to fetch the examples"))
struct MXCorpusTests {
    @Test("The corpus is all there")
    func corpusSize() {
        // MaterialX 1.39.5 has 50; fewer means a broken checkout.
        #expect(Corpus.files.count >= 50)
    }

    /// Prints the size of the graphs in the corpus. Not a check: these
    /// numbers guide the graph canvas (how much auto-layout must handle, how
    /// many inputs a node can show).
    @Test("Statistics")
    func statistics() throws {
        let library = try MXLibrary.bundled.get()
        var graphCount: Int = 0
        var largestGraph: (nodes: Int, name: String) = (0, "")
        var mostInputs: (inputs: Int, authored: Int, name: String) = (0, 0, "")
        var nodeCount: Int = 0
        for file in Corpus.files {
            let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
            document.setDataLibrary(library)
            var graphs: [MXGraph] = [try document.graph()]
            for nodeGraph in document.nodeGraphs {
                graphs.append(try document.graph(at: nodeGraph.path))
            }
            for graph in graphs {
                graphCount += 1
                nodeCount += graph.nodes.count
                if graph.nodes.count > largestGraph.nodes {
                    largestGraph = (graph.nodes.count, "\(file) \(graph.path)")
                }
                for node in graph.nodes where node.inputs.count > mostInputs.inputs {
                    let authored: Int = node.inputs.filter { $0.isAuthored }.count
                    mostInputs = (node.inputs.count, authored, "\(node.category) in \(file)")
                }
            }
        }
        print("""
            Corpus: \(Corpus.files.count) documents, \(graphCount) graph levels, \(nodeCount) nodes.
            Largest level: \(largestGraph.nodes) nodes (\(largestGraph.name)).
            Most inputs: \(mostInputs.inputs), \(mostInputs.authored) of them authored (\(mostInputs.name)).
            """)
    }

    // SWIFT: `arguments:` makes this a *parameterized test*: Swift Testing
    // calls it once per element of `Corpus.files`, and reports each call as
    // its own test case, named after the argument. A failure in one file
    // doesn't stop the others.
    @Test("Opens, validates and lists its graph", arguments: Corpus.files)
    func opens(_ file: String) throws {
        let library = try MXLibrary.bundled.get()
        let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
        document.setDataLibrary(library)

        // No MaterialX validation errors. Each issue is reported on its own,
        // with the element's path, if there are any.
        let issues: [MXIssue] = document.validationIssues()
        for issue in issues {
            Issue.record("\(issue.elementPath): \(issue.message)")
        }

        // The root and every nodegraph can be listed, and hang together.
        let root: MXGraph = try document.graph()
        #expect(!root.nodes.isEmpty, "a document with nothing to show")
        try Self.checkConnections(in: root)
        for nodeGraph in document.nodeGraphs {
            let graph: MXGraph = try document.graph(at: nodeGraph.path)
            try Self.checkConnections(in: graph)
        }
    }

    /// M2's exit criterion: saving loses nothing. Each example is written as
    /// MaterialX would save it, read back, and compared element by element.
    @Test("Writes back losslessly (M2 exit criterion)", arguments: Corpus.files)
    func roundTrip(_ file: String) throws {
        let url: URL = Corpus.examplesFolder.appending(path: file)
        let original = try MXDocument.read(from: url)
        let written: String = try original.xmlString()
        let reread = try MXDocument.parse(xml: written, includesFrom: url.deletingLastPathComponent())
        // SWIFT: `if let` on the optional message: nil means no difference.
        if let difference = original.difference(from: reread) {
            Issue.record("\(file): \(difference)")
        }
    }

    /// How close the written text is to the file, byte for byte. Not a
    /// check (PLAN.md §8 asks for byte-equivalent *or* semantically equal);
    /// the numbers show how much reformatting saving does.
    @Test("Statistics: files written back byte for byte")
    func byteStatistics() throws {
        var identical: Int = 0
        var differing: [String] = []
        for file in Corpus.files {
            let url: URL = Corpus.examplesFolder.appending(path: file)
            let text: String = try String(contentsOf: url, encoding: .utf8)
            let written: String = try MXDocument.read(from: url).xmlString()
            if text == written {
                identical += 1
            } else {
                differing.append(file)
            }
        }
        print("Round trip: \(identical) of \(Corpus.files.count) examples written back byte for byte.")
        print("Differing: \(differing.prefix(8).joined(separator: ", "))\(differing.count > 8 ? ", ..." : "")")
    }

    /// M2b's exit criterion, for MXKit: every input the inspector can edit,
    /// in every example, takes a new value, which then reads back; putting
    /// back the copy taken before (what undo does) restores the document.
    @Test("Every input can be edited and undone (M2b exit criterion)", arguments: Corpus.files)
    func editsEveryInput(_ file: String) throws {
        let library = try MXLibrary.bundled.get()
        let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
        document.setDataLibrary(library)
        let original: MXDocument = document.copy()

        var levels: [MXGraph] = [try document.graph()]
        for nodeGraph in document.nodeGraphs {
            levels.append(try document.graph(at: nodeGraph.path))
        }
        for level in levels {
            // A nodegraph's own inputs are among its inputs as a node, in
            // the level above.
            // A nodegraph that implements a nodedef gets its inputs from the
            // nodedef, and the inspector leaves them alone (M4 edits them).
            var owners: [(path: String, inputs: [MXPort])] = []
            for node in level.nodes where !node.isIncluded && !(node.isNodeGraph && node.nodeDefName != nil) {
                owners.append((node.path, node.inputs))
            }
            for owner in owners {
                // Connected inputs are rewired in M2d, not given values.
                for input in owner.inputs where input.connection == nil {
                    guard let value = Self.changedValue(for: input) else {
                        continue
                    }
                    try document.setValue(value, ofInput: input.name, on: owner.path)
                    let edited: MXPort? = try Self.input(input.name, of: owner.path, in: document)
                    #expect(edited?.value == value, "\(owner.path).\(input.name) (\(input.type)) reads back")
                    #expect(edited?.isAuthored == true)
                }
            }
        }

        document.restore(from: original)
        if let difference = document.difference(from: original) {
            Issue.record("\(file) after undo: \(difference)")
        }
    }

    /// A value different from `input`'s current one, as the inspector would
    /// set it; nil for types the inspector doesn't edit as values (shaders,
    /// arrays, custom types).
    static func changedValue(for input: MXPort) -> String? {
        let type: MXValueType = input.valueType
        switch type {
        case .float, .integer, .color, .vector, .matrix:
            // SWIFT: `!` force-unwraps; safe because these types all have a
            // component count (see MXValueType.componentCount).
            let count: Int = type.componentCount!
            var numbers: [Double] = MXValueText.numbers(input.value ?? "") ?? Array(repeating: 0, count: count)
            numbers[0] += type == .integer ? 1 : 0.25
            return MXValueText.text(numbers, as: type)
        case .boolean:
            return MXValueText.text(!(MXValueText.boolean(input.value ?? "") ?? false))
        case .string:
            // An enum takes another of its values; free text gets a suffix.
            if let other = input.ui.enumOptions.first(where: { $0.value != input.value }) {
                return other.value
            }
            return (input.value ?? "") + "_edited"
        case .filename:
            return "textures/edited.png"
        case .other:
            return nil
        }
    }

    /// The input `name` of the element at `path`, read from the document again.
    static func input(_ name: String, of path: String, in document: MXDocument) throws -> MXPort? {
        switch try document.inspectable(at: path) {
        case .node(let node):
            return node.inputs.first(where: { $0.name == name })
        case .graphInput, .graphOutput, .backdrop, nil:
            // A nodegraph is listed as a node in its parent; `path` here
            // is always a node or a nodegraph.
            return nil
        }
    }

    @Test("Margolaria's own checks find nothing (nodedefs, textures)", arguments: Corpus.files)
    func lintIsClean(_ file: String) throws {
        let library = try MXLibrary.bundled.get()
        let document = try MXDocument.read(from: Corpus.examplesFolder.appending(path: file))
        document.setDataLibrary(library)
        for issue in MXLint.check(document) {
            Issue.record("\(issue.elementPath): \(issue.message)")
        }
    }

    /// Records a failure for every input or output in `graph` that is
    /// connected to something that isn't there.
    static func checkConnections(in graph: MXGraph) throws {
        // SWIFT: `Set(...)` builds a hash set from any sequence, here the
        // names from `.map`. `contains` on a Set is O(1).
        let interfaceNames: Set<String> = Set(graph.interfaceInputs.map { $0.name })
        let outputNames: Set<String> = Set(graph.outputs.map { $0.name })

        // SWIFT: A function inside a function (a *nested function*). It can
        // use the enclosing function's constants, like a closure.
        func check(_ port: MXPort, of owner: String) {
            guard let connection = port.connection else {
                return
            }
            switch connection {
            case .node(let name, let output), .nodeGraph(let name, let output):
                guard let source = graph.node(named: name) else {
                    Issue.record("\(owner).\(port.name) is connected to \(name), which is not in \(graph.path.isEmpty ? "the document" : graph.path)")
                    return
                }
                // When the connection names an output, the source must have it.
                if let output, !source.outputs.contains(where: { $0.name == output }) {
                    Issue.record("\(owner).\(port.name) uses output \(output) of \(name), which has \(source.outputs.map { $0.name })")
                }
            case .interface(let name):
                #expect(interfaceNames.contains(name), "\(owner).\(port.name) uses interface input \(name), which \(graph.path) doesn't have")
            case .output(let name):
                #expect(outputNames.contains(name), "\(owner).\(port.name) uses output \(name), which isn't in this graph")
            }
        }

        for node in graph.nodes {
            for input in node.inputs {
                check(input, of: node.path)
            }
        }
        for output in graph.outputs {
            check(output, of: graph.path.isEmpty ? "output" : graph.path)
        }
    }
}
