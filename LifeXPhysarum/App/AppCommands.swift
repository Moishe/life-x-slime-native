import SwiftUI

/// Menu bar items. Single-key shortcuts (Space, →, R, T) are handled by the
/// field view so they never steal keys from the inspector's text fields.
struct AppCommands: Commands {
    let model: SimulationModel?
    @FocusedValue(\.showInspector) private var showInspector

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Settings…") { run { await $0.openSettingsWithPanel() } }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
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
                Divider()
                Button("Random Fill") { model?.randomFill() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Clear Board") { model?.clearBoard() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Divider()
                Button("Rotate Pattern") { model?.rotate() }
                    .keyboardShortcut("r")
                    .disabled(model?.tool.pattern == nil)
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

    private func run(_ action: @escaping (SimulationModel) async -> Void) {
        guard let model else { return }
        Task { await action(model) }
    }
}
