import SwiftUI

/// The main window: patterns on the left, the field in the middle, settings on the right.
struct ContentView: View {
    @Bindable var model: SimulationModel
    let context: MetalContext
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        NavigationSplitView {
            PatternSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            FieldView(model: model, context: context)
                .frame(minWidth: 360, minHeight: 360)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StatusBar(model: model)
                }
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
        }
        .navigationTitle("Life × Physarum")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message))
        }
        .focusedSceneValue(\.showInspector, $showInspector)
        #if DEBUG
        .task { DebugSnapshot.runIfRequested(model) }
        #endif
    }

    private var subtitle: String {
        let state = model.isRecording ? "Recording" : model.settings.playing ? "Running" : "Paused"
        let tool = model.tool.pattern.map { "\($0.name) \(model.quarterTurns * 90)°" } ?? "Paint Cells"
        return "\(state) · \(tool)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(model.settings.playing ? "Pause" : "Play",
                   systemImage: model.settings.playing ? "pause.fill" : "play.fill",
                   action: model.togglePlaying)
                .help(model.settings.playing ? "Pause Life (Space)" : "Run Life (Space)")
            Button("Step", systemImage: "forward.frame.fill", action: model.step)
                .help("Advance Life by one generation (→)")
        }
        ToolbarItemGroup(placement: .navigation) {
            Button("Random Fill", systemImage: "die.face.5", action: model.randomFill)
                .help("Fill the board randomly at the Fill Density")
            Button("Clear Board", systemImage: "eraser", action: model.clearBoard)
                .help("Kill every Life cell")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Show", selection: $model.settings.foodView) {
                Label("Trail", systemImage: "scribble.variable").tag(false)
                Label("Food", systemImage: "leaf").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Show the trail or the food map (T)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.toggleRecordingWithPanel() }
            } label: {
                Label(model.isRecording ? "Stop Recording" : "Record Movie",
                      systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(model.isRecording ? .red : nil)
            .help(model.isRecording ? "Stop and save the movie (⇧⌘R)" : "Record the mix to an MP4 movie (⇧⌘R)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .help(showInspector ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
        }
    }
}

extension FocusedValues {
    @Entry var showInspector: Binding<Bool>?
}
