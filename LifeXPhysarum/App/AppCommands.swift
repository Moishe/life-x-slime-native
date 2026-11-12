import SwiftUI

/// Menu bar items. Single-key shortcuts (Space, →, R, T, X, C) are handled by the
/// field view so they never steal keys from the inspector's text fields.
struct AppCommands: Commands {
    let model: SimulationModel?
    @FocusedValue(\.showInspector) private var showInspector
    @FocusedValue(\.showSidebar) private var showSidebar
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(showSidebar?.wrappedValue == false ? "Show Sidebar" : "Hide Sidebar") {
                showSidebar?.wrappedValue.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(showSidebar == nil)
        }
        CommandGroup(replacing: .help) {
            // ⌘? is the system's Help search, which finds this item.
            Button("Life × Physarum Help") { openWindow(id: "help") }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Settings…") { run { await $0.openSettingsWithPanel() } }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .saveItem) { // after, not replacing: that would remove Close (⌘W)
            Button("Save Settings…") { run { await $0.saveSettingsWithPanel() } }
                .keyboardShortcut("s")
            Divider()
            Button("Export Images…") { run { await $0.exportImagesWithPanel() } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button(model?.isRecording == true ? "Stop Recording" : "Record Movie…") {
                run { await $0.toggleRecordingWithPanel() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Simulation") {
            Group {
                Button(model?.settings.playing == false ? "Play" : "Pause") { model?.togglePlaying() }
                    .keyboardShortcut("p")
                Button("Step Generation") { model?.step() }
                    .keyboardShortcut(.return)
                    .disabled(model?.source != .life)
                Divider()
                Toggle("Seed from Life", isOn: sourceBinding(.life))
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Toggle("Seed from Camera", isOn: sourceBinding(.camera))
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Toggle("Seed from Audio", isOn: sourceBinding(.audio))
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Group {
                    Button("Random Fill") { model?.randomFill() }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                    Button("Clear Board") { model?.clearBoard() }
                        .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    Divider()
                    Button("Rotate Pattern") { model?.rotate() }
                        .keyboardShortcut("r")
                        .disabled(model?.tool.pattern == nil)
                }
                .disabled(model?.source != .life)
                Divider()
                Button("Clear Trail") { model?.clearTrail() }
                Button("Clear Food") { model?.clearFood() }
                Button("Clear Actors") { model?.clearActors() }
                Divider()
                Button("Reset Physarum Parameters") { model?.resetPhysarumParameters() }
            }
            .disabled(model == nil)
        }

        CommandGroup(before: .toolbar) {
            Button("Show Trail") { model?.settings.foodView = false }
                .keyboardShortcut("1")
            Button("Show Food") { model?.settings.foodView = true }
                .keyboardShortcut("2")
            Divider()
            Button(showInspector?.wrappedValue == true ? "Hide Inspector" : "Show Inspector") {
                showInspector?.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(showInspector == nil)
            Divider()
        }
    }

    /// On when `source` is the current one; turning it on switches to it.
    private func sourceBinding(_ source: SeedSource) -> Binding<Bool> {
        Binding(get: { model?.source == source }, set: { on in
            if on, let model { Task { await model.setSource(source) } }
        })
    }

    private func run(_ action: @escaping (SimulationModel) async -> Void) {
        guard let model else { return }
        Task { await action(model) }
    }
}
