// MXLibraryFiles.swift
//
// Libraries of node definitions (M4c2, PLAN.md §8.5). A definition made in
// a document (M4c1) is saved to a file of its own: its `<nodedef>` and the
// `<nodegraph>` implementing it. The Library panel lists the definitions
// in the user library folder (~/Documents/Margolaria/Libraries) and in the
// document's folder; using one adds
// an `xi:include` of its file to the document, then the node. Saving keeps
// the include as an include (M2a), so MaterialXView, the Graph Editor and
// USD find the definition through the same file, as long as they can
// reach it.
//
// Introduces (SWIFT): `FileManager.url(for:in:appropriateFor:create:)`,
// `pathComponents` and `starts(with:)` for paths, `compactMap` with `try?`.

import Foundation
import MXBridge

/// One library file and the definitions in it.
public struct MXLibraryFile: Hashable, Sendable, Identifiable {
    /// The file.
    public let url: URL
    /// The node definitions it holds, as the Library lists them.
    public let definitions: [MXNodeDefinition]

    public var id: URL { url }

    /// The file's name without ".mtlx", as the Library shows it.
    public var name: String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// A folder of library files, as the Library tab lists it.
public struct MXLibraryFolder: Hashable, Sendable {
    /// "My Library" or "This Document's Folder".
    public let title: String
    public let files: [MXLibraryFile]
}

/// Where Margolaria keeps the user's files: `~/Documents/Margolaria`, with
/// `Libraries` (definitions saved with Save to Library) and `Materials`
/// (where saving a new document starts). In Documents rather than
/// Application Support: they are the user's work, to find in Finder, back
/// up and share.
public enum MXLibraryFolders {
    /// `~/Documents/Margolaria/<name>`, created if missing. Nil if the
    /// system won't give a Documents folder.
    ///
    /// SWIFT: `url(for:in:appropriateFor:create:)` is Foundation's way to
    /// find the standard folders, like `NSSearchPathForDirectoriesInDomains`
    /// in Objective-C.
    private static func folder(_ name: String) -> URL? {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true) else {
            return nil
        }
        let folder: URL = documents.appending(path: "Margolaria/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The user library folder, `~/Documents/Margolaria/Libraries`.
    public static var user: URL? {
        guard let folder = folder("Libraries") else {
            return nil
        }
        moveOldLibraries(to: folder)
        return folder
    }

    /// Where saving a new document starts: `~/Documents/Margolaria/Materials`.
    public static var materials: URL? {
        folder("Materials")
    }

    /// Moves library files from where the first M4c2 build kept them
    /// (`~/Library/Application Support/Margolaria/Libraries`) to `folder`,
    /// once: files whose name is taken there are left where they are.
    private static func moveOldLibraries(to folder: URL) {
        let fileManager: FileManager = .default
        guard let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: false) else {
            return
        }
        let old: URL = support.appending(path: "Margolaria/Libraries", directoryHint: .isDirectory)
        let files: [URL] = (try? fileManager.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mtlx" {
            try? fileManager.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
        }
        if ((try? fileManager.contentsOfDirectory(atPath: old.path(percentEncoded: false))) ?? ["?"]).isEmpty {
            try? fileManager.removeItem(at: old)
        }
    }

    /// The library folders a document can use nodes from, with their files
    /// (M4c2; shared by the Library tab and the node searches since M7c):
    /// "My Library", and the folder of `document` (the document's file,
    /// left out of the list) unless it is My Library.
    public static func libraries(for document: URL?) -> [MXLibraryFolder] {
        var found: [MXLibraryFolder] = []
        if let user {
            found.append(MXLibraryFolder(title: "My Library", files: files(in: user)))
        }
        if let folder = document?.deletingLastPathComponent(), folder.standardizedFileURL != user?.standardizedFileURL {
            found.append(MXLibraryFolder(title: "This Document's Folder", files: files(in: folder, except: document)))
        }
        return found
    }

    /// The library files directly in `folder` (not in folders inside it)
    /// that define at least one node, sorted by name. `except` is left out:
    /// the document itself, when listing its own folder.
    ///
    /// SWIFT: `compactMap` with `try?` skips the files that fail to read:
    /// a broken file in the folder doesn't hide the others.
    public static func files(in folder: URL, except: URL? = nil) -> [MXLibraryFile] {
        let urls: [URL] = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let library: MXLibrary? = try? MXLibrary.bundled.get()
        return urls.filter { $0.pathExtension == "mtlx" && $0.standardizedFileURL != except?.standardizedFileURL }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let document = try? MXDocument.read(from: url) else {
                    return nil
                }
                if let library {
                    document.setDataLibrary(library)
                }
                let definitions: [MXNodeDefinition] = document.nodeDefinitions.filter(\.isFromDocument)
                return definitions.isEmpty ? nil : MXLibraryFile(url: url, definitions: definitions)
            }
    }
}

extension MXDocument {
    /// The definition the nodegraph at `graph` implements, and the graph,
    /// as the text of a library file. Refused if the graph uses nodes of
    /// another definition made in this document.
    public func libraryText(forDefinitionAt graph: String) throws -> String {
        var xml = std.string()
        try perform { error in
            handle.writeNodeDefinition(std.string(graph), &xml, &error)
        }
        return xml.swiftString
    }

    /// Includes the library `file` in the document (`xi:include`): its
    /// definitions can then be used, and are read-only here. The include
    /// is written relative to `folder` (the document's) when the file is
    /// inside it, and by absolute path otherwise. Returns the file's
    /// nodedef names. Nothing changes if it is already included.
    @discardableResult
    public func include(library file: URL, from folder: URL?) throws -> [String] {
        let href: String = Self.href(for: file, from: folder)
        var names = mxbridge.StringVector()
        try perform { error in
            handle.includeLibrary(std.string(file.path(percentEncoded: false)), std.string(href), &names, &error)
        }
        return names.map { $0.swiftString }
    }

    /// `file`'s path relative to `folder` if it is inside it ("lib/tiles.mtlx"),
    /// else its absolute path.
    ///
    /// SWIFT: `pathComponents` splits a URL's path into its parts ("/",
    /// "Users", ...); `starts(with:)` checks one array begins with another.
    static func href(for file: URL, from folder: URL?) -> String {
        let fileParts: [String] = file.standardizedFileURL.pathComponents
        guard let folderParts = folder?.standardizedFileURL.pathComponents,
              fileParts.count > folderParts.count, fileParts.starts(with: folderParts) else {
            return file.standardizedFileURL.path(percentEncoded: false)
        }
        return fileParts.dropFirst(folderParts.count).joined(separator: "/")
    }
}
