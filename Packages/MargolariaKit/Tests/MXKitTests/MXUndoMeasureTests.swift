// MXUndoMeasureTests.swift
//
// M7d: what undo's snapshots (PLAN.md §8.1: a whole copy of the document
// before each edit) cost on documents much larger than MaterialX's
// examples, the largest of which is 32 KB. Not a check, beyond a loose
// bound: the numbers are recorded in PLAN.md, to decide whether undo needs
// something cheaper than copies.
//
// The documents are made up: materials each reading a nodegraph of a
// chain of nodes, about 10 and 100 times the largest example.
//
// Introduces (SWIFT): `task_info` (a Mach call, from C) with
// `withUnsafeMutablePointer` and `withMemoryRebound`.

import Darwin
import Foundation
import Testing
@testable import MXKit

@Suite("Undo snapshots on large documents (M7d)")
struct MXUndoMeasureTests {
    /// A document of `materials` materials, each a standard surface whose
    /// base colour comes from a nodegraph chaining `chain` multiplies.
    static func largeDocument(materials: Int, chain: Int) -> String {
        var xml: String = #"<?xml version="1.0"?>"# + "\n" + #"<materialx version="1.39">"# + "\n"
        for m in 0..<materials {
            xml += #"  <nodegraph name="NG_\#(m)">"# + "\n"
            xml += #"    <constant name="c0" type="color3"><input name="value" type="color3" value="0.8, 0.5, 0.2" /></constant>"# + "\n"
            for n in 1...chain {
                xml += #"    <multiply name="c\#(n)" type="color3" xpos="\#(n)" ypos="1">"# + "\n"
                xml += #"      <input name="in1" type="color3" nodename="c\#(n - 1)" />"# + "\n"
                xml += #"      <input name="in2" type="color3" value="0.99, 0.98, 0.97" />"# + "\n"
                xml += "    </multiply>\n"
            }
            xml += #"    <output name="out" type="color3" nodename="c\#(chain)" />"# + "\n"
            xml += "  </nodegraph>\n"
            xml += #"  <standard_surface name="SR_\#(m)" type="surfaceshader">"# + "\n"
            xml += #"    <input name="base_color" type="color3" nodegraph="NG_\#(m)" output="out" />"# + "\n"
            xml += "  </standard_surface>\n"
            xml += #"  <surfacematerial name="M_\#(m)" type="material">"# + "\n"
            xml += #"    <input name="surfaceshader" type="surfaceshader" nodename="SR_\#(m)" />"# + "\n"
            xml += "  </surfacematerial>\n"
        }
        return xml + "</materialx>\n"
    }

    /// The memory the process uses, in bytes, as Activity Monitor's
    /// Memory column counts it (the "physical footprint").
    ///
    /// SWIFT: `task_info` is a C function of the Mach kernel, which fills
    /// in a struct through a pointer. `withUnsafeMutablePointer(to:)`
    /// lends a pointer to a Swift variable for the closure's duration
    /// (like `&info` in C), and `withMemoryRebound` views it as the
    /// `integer_t` array the function's signature asks for: C's cast.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integers in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), integers, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// The median of `runs` timings of `body`, in milliseconds.
    static func milliseconds(runs: Int = 9, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<runs {
            let elapsed: Duration = try clock.measure(body)
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        return times.sorted()[runs / 2]
    }

    @Test("Statistics: a snapshot, a restore and an edit, on documents 10 and 100 times the largest example",
          arguments: [(materials: 75, chain: 20), (materials: 750, chain: 20)])
    func measure(_ size: (materials: Int, chain: Int)) throws {
        let xml: String = Self.largeDocument(materials: size.materials, chain: size.chain)
        let document = try MXDocument(xml: xml)
        document.setDataLibrary(try MXLibrary.bundled.get())
        let nodes: Int = size.materials * (size.chain + 3)

        // What the app does around each edit: a snapshot first
        // (MaterialXDocument.edit), and Undo puts one back.
        let snapshot: Double = Self.milliseconds { _ = document.copy() }
        let copy: MXDocument = document.copy()
        let restore: Double = Self.milliseconds { document.restore(from: copy) }
        // For scale: an edit itself, and writing the text (saving, and the
        // XML tab, after each edit).
        let edit: Double = try Self.milliseconds {
            try document.setValue("0.5, 0.5, 0.5", ofInput: "in2", on: "NG_0/c1")
        }
        let write: Double = try Self.milliseconds { _ = try document.xmlString() }

        // The memory 100 undo steps hold: one copy each.
        let before: Int = Self.footprint()
        let steps: [MXDocument] = (0..<100).map { _ in document.copy() }
        let perStep: Double = Double(Self.footprint() - before) / Double(steps.count)

        print(String(format: "Undo snapshots: %d KB of XML, %d nodes: snapshot %.2f ms, restore %.2f ms, "
                     + "edit %.2f ms, write %.2f ms; %.0f KB per step held",
                     xml.utf8.count / 1024, nodes, snapshot, restore, edit, write, perStep / 1024))
        // A loose bound, so a slowdown by orders of magnitude shows: well
        // under a frame for the larger document on an M-series Mac.
        #expect(snapshot < 100 && restore < 100, "snapshot \(snapshot) ms, restore \(restore) ms")
    }
}
