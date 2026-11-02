// BottomPanel.swift
//
// The panel under the canvas (PLAN.md §4.1, region 6), with tabs:
//   XML      the document's XML, the canvas selection highlighted;
//            editable, applied with ⌘↩ (M4e, XMLTextView.swift)
//   Issues   MaterialX's validation and Margolaria's checks; clicking one
//            shows its node on the canvas
// "Generated Shader" and "Console" come in later milestones.
//
// Introduces (SWIFT): `List` with a selection of a non-`Identifiable` type
// via `id:`, `.contextMenu`, `@ViewBuilder` computed properties,
// `NSPasteboard`.

import AppKit
import MXKit
import SwiftUI

/// The bottom panel's tabs.
enum BottomTab: String, CaseIterable, Identifiable {
    case xml = "XML"
    case issues = "Issues"

    var id: String { rawValue }
}

struct BottomPanel: View {
    let document: MaterialXDocument
    @Binding var tab: BottomTab
    /// The XML tab's edits, kept by the window across tab switches.
    let xmlDraft: XMLDraft
    /// The element selected on the canvas, highlighted in the XML.
    let selectedPath: String?
    /// Called when the user picks an issue, to show its element.
    let onSelectIssue: (MXIssue) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Panel", selection: $tab) {
                    ForEach(BottomTab.allCases) { tab in
                        Text(title(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            // Fill the rest of the panel, whatever the tab shows. The XML
            // view fills by itself, but the "No Issues" placeholder only
            // takes the height it needs, and the VStack would then centre
            // everything, moving the tabs down.
            //
            // SWIFT: `maxWidth: .infinity` lets a view grow to all the
            // space offered; content smaller than that is centred inside.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The tab's content.
    ///
    /// SWIFT: `@ViewBuilder` on a computed property lets it return different
    /// views from a `switch`, like `body`.
    @ViewBuilder
    private var content: some View {
        switch tab {
        case .xml:
            XMLTab(document: document, draft: xmlDraft, highlightedPath: selectedPath)
        case .issues:
            IssuesList(issues: document.issues, libraryLoaded: document.libraryLoaded, onSelect: onSelectIssue)
        }
    }

    /// "Issues (3)" when there are any.
    private func title(for tab: BottomTab) -> String {
        if tab == .issues, !document.issues.isEmpty {
            return "Issues (\(document.issues.count))"
        }
        // A dot while the text has edits not applied, as on a document.
        if tab == .xml, xmlDraft.edits != nil {
            return "XML •"
        }
        return tab.rawValue
    }
}

/// The list of issues.
struct IssuesList: View {
    let issues: [MXIssue]
    let libraryLoaded: Bool
    let onSelect: (MXIssue) -> Void

    /// The selected row, by position (issues have no identity of their own;
    /// two can be identical).
    @State private var selection: Int? = nil

    var body: some View {
        if !libraryLoaded {
            ContentUnavailableView("Not Validated", systemImage: "questionmark.circle",
                                   description: Text("The MaterialX data libraries could not be loaded."))
        } else if issues.isEmpty {
            ContentUnavailableView("No Issues", systemImage: "checkmark.circle",
                                   description: Text("MaterialX's validation and Margolaria's checks found nothing."))
        } else {
            // SWIFT: `List(_:id:selection:)` over the indices: `id: \.self`
            // uses each index as the row's identity, and the selection
            // binding receives it.
            List(issues.indices, id: \.self, selection: $selection) { index in
                IssueRow(issue: issues[index])
                    // Right-click menu.
                    // SWIFT: `.contextMenu { }` adds a menu shown on
                    // right-click (or Control-click).
                    .contextMenu {
                        Button("Copy Message") {
                            copy("\(issues[index].elementPath): \(issues[index].message)")
                        }
                        Button("Copy Element Path") {
                            copy(issues[index].elementPath)
                        }
                    }
            }
            .onChange(of: selection) {
                if let selection, issues.indices.contains(selection) {
                    onSelect(issues[selection])
                }
            }
        }
    }

    private func copy(_ text: String) {
        // SWIFT: AppKit's pasteboard; `clearContents` must come first.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One issue: severity icon, element path, message, who found it.
private struct IssueRow: View {
    let issue: MXIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(issue.elementPath.isEmpty ? "document" : issue.elementPath)
                        .font(.system(.caption, design: .monospaced))
                    Text(issue.source == .materialX ? "MaterialX validation" : "Margolaria")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
