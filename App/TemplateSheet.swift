// TemplateSheet.swift
//
// The sheet a new document shows first (File > New, M2e): pick what it
// starts from, an OpenPBR or Standard Surface material ready to edit, or
// an empty document. Return takes the highlighted choice; Escape starts
// empty. "Open…" is for when an existing file was wanted after all (the
// app opens a new document at launch): the new one closes, and the Open
// dialog appears.
//
// Introduces (SWIFT): `.keyboardShortcut(.defaultAction)` and
// `.cancelAction`, `.buttonStyle(.plain)` with a custom selected look.

import MXKit
import SwiftUI

struct TemplateSheet: View {
    /// Called with the template chosen.
    let onChoose: (MXDocumentTemplate) -> Void
    /// Called for "Open…".
    let onOpen: () -> Void

    @State private var selection: MXDocumentTemplate = .openPBR

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Document")
                .font(.title2)
                .bold()
            VStack(spacing: 8) {
                ForEach(MXDocumentTemplate.allCases) { template in
                    // SWIFT: `.buttonStyle(.plain)` drops the standard
                    // button look, so the row draws its own (a highlighted
                    // background when selected).
                    Button {
                        selection = template
                    } label: {
                        row(template)
                    }
                    .buttonStyle(.plain)
                    // A double-click also chooses (the first click selected).
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        onChoose(template)
                    })
                }
            }
            HStack {
                Button("Open…") {
                    onOpen()
                }
                .help("Open an existing MaterialX file instead")
                Spacer()
                Button("Empty Document") {
                    onChoose(.empty)
                }
                // SWIFT: `.cancelAction` makes Escape press this button,
                // `.defaultAction` Return (and draws it as the default).
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onChoose(selection)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// One choice: an icon, its title and what it is.
    private func row(_ template: MXDocumentTemplate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: template == .empty ? "doc" : "circle.lefthalf.filled")
                .font(.title)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title)
                    .font(.headline)
                Text(template.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(selection == template ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08),
                    in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }
}
