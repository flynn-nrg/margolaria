// MXIssue.swift
//
// Problems found in a document, for the Issues panel: MaterialX's own
// validation (MXDocument.validationIssues) and Margolaria's extra checks
// (MXLint, below). Each issue names the element it is about, so the UI can
// jump to it.
//
// Introduces (SWIFT): nested types (an enum inside a struct), enums without
// associated values used as labels, `FileManager`, `contains` on a String,
// `+` on arrays.

import Foundation

/// One problem in a document.
public struct MXIssue: Hashable, Sendable {
    /// How serious a problem is.
    ///
    /// SWIFT: A type declared inside another is a *nested type*; outside, it
    /// is written `MXIssue.Severity`. Like a C++ nested class, it only
    /// affects the name; it has no access to an MXIssue instance.
    public enum Severity: Hashable, Sendable {
        /// The document is wrong: MaterialX won't accept it, or a renderer
        /// will fail.
        case error
        /// Probably not what the author meant, but the document still works,
        /// for example with a missing texture replaced by a default.
        case warning
    }

    /// Who found the problem.
    public enum Source: Hashable, Sendable {
        /// MaterialX's `Document::validate()`.
        case materialX
        /// Margolaria's own checks (``MXLint``).
        case margolaria
    }

    /// The path of the element the problem is about, such as
    /// "NG_copper/grain/amplitude", or "" for the document as a whole.
    public let elementPath: String
    /// What is wrong, in one line.
    public let message: String
    public let severity: Severity
    public let source: Source

    public init(elementPath: String, message: String, severity: Severity, source: Source) {
        self.elementPath = elementPath
        self.message = message
        self.severity = severity
        self.source = source
    }
}

/// Margolaria's own checks, for problems MaterialX's validation doesn't
/// report: nodes without a nodedef, and missing files. More rules come later (PLAN.md §4.1: colour spaces on vector data,
/// and others); each one is a small function called from `check`.
///
/// SWIFT: An enum with no cases can't be instantiated, so it works as a
/// namespace for static functions, like a C++ namespace.
public enum MXLint {
    /// Runs every rule over `document` and returns what they found.
    public static func check(_ document: MXDocument) -> [MXIssue] {
        var issues: [MXIssue] = []
        // The document root first, then every nodegraph.
        var graphPaths: [String] = [""]
        for nodeGraph in document.nodeGraphs {
            graphPaths.append(nodeGraph.path)
        }
        for path in graphPaths {
            // SWIFT: `try?` turns a thrown error into nil. A graph that can't
            // be read has nothing to check; the path came from the document,
            // so this isn't expected to happen.
            guard let graph = try? document.graph(at: path) else {
                continue
            }
            if document.hasDataLibrary {
                issues += unknownNodes(in: graph)
            }
            issues += missingFiles(in: graph)
        }
        return issues
    }

    /// Rule: every node must have a nodedef.
    ///
    /// MaterialX's validation only checks a node against its nodedef when it
    /// finds one, so a misspelled category (`<mutliply>`) or a node from a
    /// library we don't have passes silently. Renderers then fail on it.
    static func unknownNodes(in graph: MXGraph) -> [MXIssue] {
        var issues: [MXIssue] = []
        for node in graph.nodes where !node.isNodeGraph && node.nodeDefName == nil {
            issues.append(MXIssue(elementPath: node.path,
                                  message: "No nodedef for \(node.category) with type \(node.type): unknown node, or inputs that match no variant",
                                  severity: .error,
                                  source: .margolaria))
        }
        return issues
    }

    /// Rule: every "filename" input must point at a file that exists.
    ///
    /// Renderers replace a missing texture with a default colour, so this is
    /// a warning: the material renders, just not as intended. Filenames with
    /// tokens such as `<UDIM>` name several files and are skipped for now.
    static func missingFiles(in graph: MXGraph) -> [MXIssue] {
        var issues: [MXIssue] = []
        for node in graph.nodes {
            for input in node.inputs where input.type == "filename" {
                // SWIFT: A `where` clause on a for loop skips the elements
                // for which it is false, like `continue` at the top.
                guard let url = input.fileURL, let value = input.value, !value.contains("<") else {
                    continue
                }
                if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    issues.append(MXIssue(elementPath: node.path + "/" + input.name,
                                          message: "File not found: \(value) (looked in \(url.deletingLastPathComponent().path(percentEncoded: false)))",
                                          severity: .warning,
                                          source: .margolaria))
                }
            }
        }
        return issues
    }
}
