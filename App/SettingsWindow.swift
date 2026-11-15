// SettingsWindow.swift
//
// Margolaria > Settings… (⌘,, M7f): the app's settings, kept in the user
// defaults. For now one: the OSL compiler, oslc, with which the Generated
// Shader tab's Export… compiles an OSL shader to .oso. It was chosen in the
// Export Shader panel itself until M7f; the panel now only asks whether to
// compile, and says with which oslc.
//
// One Settings window for the app, made the first time it is asked for and
// kept (closing it only hides it), as Mac apps' settings windows are. The
// app is AppKit at the top (MargolariaApp.swift), so this is an
// NSWindowController showing a SwiftUI view, not SwiftUI's `Settings`
// scene, which only a SwiftUI `App` has.
//
// Introduces (SWIFT): subclassing `NSWindowController`, a mutable
// `static var` made safe by `@MainActor`, `LabeledContent`,
// `.formStyle(.grouped)`, `NSHostingController.sizingOptions`.

import AppKit
import SwiftUI

/// The OSL compiler the exports use (M7f): the one chosen in Settings, or
/// else the first found where Homebrew and other installers put it.
///
/// SWIFT: An enum with no cases, a namespace for these static members.
enum OSLCompiler {
    /// The user defaults key of the chosen path; empty or unset for none
    /// chosen. The same key the Export Shader panel used before M7f, so a
    /// choice made there is kept.
    static let defaultsKey: String = "oslcPath"

    /// Where oslc is looked for when none has been chosen.
    static let usualPlaces: [String] = ["/opt/homebrew/bin/oslc", "/usr/local/bin/oslc"]

    /// The path chosen in Settings, or nil.
    static var chosen: String? {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The first of `usualPlaces` that is a program, or nil.
    static var found: String? {
        usualPlaces.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The oslc to compile with: the one chosen, else the one found; nil
    /// if neither is a program (a chosen one since deleted, say).
    static var url: URL? {
        guard let path = chosen ?? found, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(filePath: path)
    }
}

/// The Settings window's controller: one for the app.
///
/// SWIFT: `NSWindowController` owns a window and shows it (`showWindow`),
/// as in Objective-C. The window keeps its controller's content alive while
/// it is hidden, so closing and opening again shows the same view.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// The one Settings window, once made.
    ///
    /// SWIFT: A `static var` is one variable for the whole type, like a C++
    /// static member. A mutable static is rejected unless something keeps
    /// threads from racing on it: here `@MainActor` on the class, which
    /// makes only main-thread code able to reach it.
    private static var shared: SettingsWindowController?

    /// Shows the Settings window, made the first time.
    static func show() {
        let controller: SettingsWindowController = shared ?? SettingsWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        // SWIFT: `sizingOptions` says what the hosting controller tells
        // AppKit about the SwiftUI view's size: with
        // `.preferredContentSize`, the window takes the view's own size.
        hosting.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        // Hidden, not freed, when closed: the controller keeps it.
        window.isReleasedWhenClosed = false
        // Where it was left, next time and after a relaunch.
        window.setFrameAutosaveName("MargolariaSettings")
        super.init(window: window)
        if !window.setFrameUsingName("MargolariaSettings") {
            window.center()
        }
    }

    /// SWIFT: NSWindowController can be made from a nib, through this
    /// initializer; Swift requires a subclass with its own `init` to say
    /// what it does with that one. Never called here.
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController isn't made from a nib")
    }
}

/// The Settings window's content.
struct SettingsView: View {
    /// The oslc chosen, as a path; empty for "find it" (OSLCompiler).
    @AppStorage(OSLCompiler.defaultsKey) private var oslcPath: String = ""

    var body: some View {
        Form {
            Section {
                // SWIFT: `LabeledContent` puts a label in the Form's left
                // column beside any views, not only beside a control that
                // has its own label (a TextField, a Picker).
                LabeledContent("OSL compiler:") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(shownPath)
                            .foregroundStyle(problem == nil ? .primary : .secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let problem {
                            Text(problem)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        HStack {
                            Button("Choose…", action: choose)
                            Button("Find Automatically") {
                                oslcPath = ""
                            }
                            .disabled(oslcPath.isEmpty)
                        }
                    }
                }
                Text("Export… in the Generated Shader tab compiles OSL shaders to .oso with it. "
                     + "Left to find itself, it looks in /opt/homebrew/bin and /usr/local/bin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Export")
            }
        }
        // SWIFT: `.formStyle(.grouped)`: the Form drawn as System
        // Settings' panes are, sections in rounded boxes.
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The oslc used, as the window shows it.
    private var shownPath: String {
        if !oslcPath.isEmpty {
            return oslcPath
        }
        return OSLCompiler.found.map { "\($0) (found)" } ?? "Not found"
    }

    /// Why the oslc shown can't be used, or nil if it can.
    private var problem: String? {
        if !oslcPath.isEmpty {
            return FileManager.default.isExecutableFile(atPath: oslcPath) ? nil : "This isn't a program there now."
        }
        return OSLCompiler.found == nil ? "Choose oslc to compile OSL shaders when exporting them." : nil
    }

    /// Chooses oslc with an Open panel, run modally (InspectorFields.swift):
    /// there is no document window here to attach it to as a sheet.
    private func choose() {
        let panel = NSOpenPanel()
        panel.message = "Choose oslc, OSL's compiler."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let current: String = oslcPath.isEmpty ? (OSLCompiler.found ?? "/opt/homebrew/bin/oslc") : oslcPath
        panel.directoryURL = URL(filePath: current).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        oslcPath = url.path(percentEncoded: false)
    }
}
