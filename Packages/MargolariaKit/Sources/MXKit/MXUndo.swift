// MXUndo.swift
//
// Undo steps made of whole-document copies (PLAN.md §8.1): each step keeps
// the document as it was before, and undoing puts that copy back. The app
// registers one step per edit (MaterialXDocument.edit); a Python script
// can make several (M6b: `with margolaria.edit("Name"):`), registered here
// in one go, so the tests can check what Undo and Redo give.
//
// Introduces (SWIFT): nothing new.

import Foundation

/// One undo step: its name, as the Edit menu shows it ("Undo Run
/// brick.py"), and the document as it was after it.
public struct MXUndoStep {
    public let name: String
    public let after: MXDocument

    public init(name: String, after: MXDocument) {
        self.name = name
        self.after = after
    }
}

/// Registering undo steps on an UndoManager.
///
/// SWIFT: `@MainActor`, as UndoManager is used on the main thread, where
/// the documents are edited.
@MainActor
public enum MXUndo {
    /// Registers one step called `name` on `undoManager`: Undo puts
    /// `snapshot` back into `document` (the same object, `restore(from:)`),
    /// and registers the Redo that puts back what it replaced. `changed`
    /// is called after each Undo and Redo, to show the document again.
    ///
    /// SWIFT: `registerUndo(withTarget:handler:)` stores a closure that the
    /// undo manager calls on Undo, passing the target (`document`) back in.
    /// The undo manager holds the target weakly, so the closure uses the
    /// parameter, not a captured `document`. Registering during an undo is
    /// how redo works: the undo manager records that registration as the
    /// redo step.
    public static func register(on undoManager: UndoManager, restoring snapshot: MXDocument,
                                in document: MXDocument, named name: String,
                                changed: @escaping (MXDocument) -> Void) {
        undoManager.registerUndo(withTarget: document) { document in
            let current: MXDocument = document.copy()
            document.restore(from: snapshot)
            register(on: undoManager, restoring: current, in: document, named: name, changed: changed)
            changed(document)
        }
        undoManager.setActionName(name)
    }

    /// Registers `steps` as as many undo steps, in order: undoing the last
    /// puts back the one before's `after`, and the first's `before`.
    /// `document` must be the last step's `after` now. Nothing is
    /// registered for no steps.
    ///
    /// Each step is a group of its own, so Edit > Undo takes them back one
    /// at a time. AppKit groups everything registered while handling one
    /// event (one key press, one menu choice) into one step by itself
    /// (`groupsByEvent`); that is turned off here, while the groups are
    /// made. If a group is already open, the steps join it, as one.
    public static func register(_ steps: [MXUndoStep], on undoManager: UndoManager, startingFrom before: MXDocument,
                                in document: MXDocument, changed: @escaping (MXDocument) -> Void) {
        let grouping: Bool = undoManager.groupingLevel == 0
        let groupsByEvent: Bool = undoManager.groupsByEvent
        if grouping {
            undoManager.groupsByEvent = false
        }
        // SWIFT: `defer` runs its block when the scope ends, however it
        // ends (here, after the loop), like Go's `defer` or a C++
        // destructor: the setting is put back whatever happens in between.
        defer {
            undoManager.groupsByEvent = groupsByEvent
        }
        var previous: MXDocument = before
        for step in steps {
            if grouping {
                undoManager.beginUndoGrouping()
            }
            register(on: undoManager, restoring: previous, in: document, named: step.name, changed: changed)
            if grouping {
                undoManager.endUndoGrouping()
            }
            previous = step.after
        }
    }
}
