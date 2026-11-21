// AcknowledgementsWindow.swift
//
// Help > Acknowledgements: the full licence texts of the third-party software
// inside the app. The About panel's credits (Credits.html) name each project
// and its licence; the licences themselves ask for their texts to ship with
// the app, and this window shows them.
//
// The texts are one file per project in the app's Licenses folder, gathered
// by scripts/fetch-licenses.sh from App/Licenses. The window lists whatever
// is there, so a licence added by the script needs no change here.
//
// One window for the app, made the first time and kept, as the Settings
// window is (SettingsWindow.swift, which says more about the pattern).
//
// Introduces (SWIFT): `NavigationSplitView`,
// `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)`.

import AppKit
import SwiftUI

/// One licence text: a file of the Licenses folder.
///
/// SWIFT: `Identifiable` gives each one the ID the list's selection uses;
/// the file name is unique within the folder, so it serves.
struct LicenseText: Identifiable, Hashable {
    /// The project, as the list shows it: the file's name without ".txt".
    let name: String
    /// The text, read when the folder is.
    let text: String

    var id: String { name }

    /// Every licence in the app's Licenses folder, by name as Finder sorts
    /// them; empty if the folder is missing.
    static func all() -> [LicenseText] {
        guard let folder = Bundle.main.url(forResource: "Licenses", withExtension: nil),
              // SWIFT: `contentsOfDirectory(at:includingPropertiesForKeys:)`
              // lists a folder's files as URLs, like `readdir`; the keys
              // would ask for file attributes to be fetched with them.
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "txt" }
            .compactMap { file in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                    return nil
                }
                return LicenseText(name: file.deletingPathExtension().lastPathComponent, text: text)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The Acknowledgements window's controller: one for the app.
@MainActor
final class AcknowledgementsWindowController: NSWindowController {
    /// The one Acknowledgements window, once made.
    private static var shared: AcknowledgementsWindowController?

    /// Shows the Acknowledgements window, made the first time.
    static func show() {
        let controller: AcknowledgementsWindowController = shared ?? AcknowledgementsWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: AcknowledgementsView()))
        window.title = "Acknowledgements"
        // Resizable, unlike Settings: the texts are long and wide.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 820, height: 600))
        window.setFrameAutosaveName("MargolariaAcknowledgements")
        super.init(window: window)
        if !window.setFrameUsingName("MargolariaAcknowledgements") {
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("AcknowledgementsWindowController isn't made from a nib")
    }
}

/// The Acknowledgements window's content: the projects on the left, the
/// chosen one's licence on the right.
struct AcknowledgementsView: View {
    /// Read once, when the view is made: the files don't change while the
    /// app runs.
    @State private var licenses: [LicenseText] = LicenseText.all()
    /// The project shown; the first until one is chosen.
    @State private var selection: LicenseText.ID?

    var body: some View {
        // SWIFT: `NavigationSplitView` is the sidebar-and-detail layout of
        // Mail or Notes: the first closure is the sidebar, the second what
        // the sidebar's selection shows. It draws the Mac's sidebar style
        // and lets the sidebar be resized or hidden.
        NavigationSplitView {
            List(licenses, selection: $selection) { license in
                Text(license.name)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
        } detail: {
            if let license = shown {
                ScrollView {
                    Text(license.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                // A new scroll view, at the top, for each project.
                .id(license.id)
            } else {
                Text("The licence texts are missing from the app.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        // The first project chosen when the window opens, so the list
        // shows which one the text is.
        .onAppear {
            selection = selection ?? licenses.first?.id
        }
    }

    /// The licence shown: the one chosen, or the first.
    private var shown: LicenseText? {
        licenses.first { $0.id == selection } ?? licenses.first
    }
}
