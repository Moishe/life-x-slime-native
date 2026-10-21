import SwiftUI

/// The main window: patterns on the left, the field in the middle, settings on the right.
struct ContentView: View {
    @Bindable var model: SimulationModel
    let context: MetalContext
    @AppStorage("showInspector") private var showInspector = true
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            PatternSidebar(model: model)
                .disabled(model.source == .camera)
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
        .focusedSceneValue(\.showSidebar, Binding(get: { columns != .detailOnly },
                                                   set: { columns = $0 ? .all : .detailOnly }))
        #if DEBUG
        .task { DebugSnapshot.runIfRequested(model) }
        #endif
    }

    private var subtitle: String {
        let state = model.isRecording ? "Recording" : model.settings.playing ? "Running" : "Paused"
        if model.source == .camera { return "\(state) · \(model.activeCamera?.name ?? "Camera")" }
        let tool = model.tool.pattern.map { "\($0.name) \(model.quarterTurns * 90)°" } ?? "Paint Cells"
        return "\(state) · \(tool)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Seed From", selection: Binding(get: { model.source }, set: { source in Task { await model.setSource(source) } })) {
                Label("Life", systemImage: "circle.grid.3x3.fill").accessibilityLabel("Life").tag(SeedSource.life)
                Label("Camera", systemImage: "web.camera").accessibilityLabel("Camera").tag(SeedSource.camera)
            }
            .pickerStyle(.segmented)
            .disabled(model.isStartingCamera)
            .help("Release actors from Life’s births, or from motion in front of the camera (⌥⌘1 / ⌥⌘2)")
        }
        ToolbarItemGroup(placement: .navigation) {
            Button(model.settings.playing ? "Pause" : "Play",
                   systemImage: model.settings.playing ? "pause.fill" : "play.fill",
                   action: model.togglePlaying)
                .help(model.source == .camera
                      ? (model.settings.playing ? "Stop releasing actors from the camera (Space)" : "Release actors from the camera (Space)")
                      : (model.settings.playing ? "Pause Life (Space)" : "Run Life (Space)"))
            Button("Step", systemImage: "forward.frame.fill", action: model.step)
                .help("Advance Life by one generation (→)")
                .disabled(model.source == .camera)
        }
        ToolbarItemGroup(placement: .navigation) {
            Button("Random Fill", systemImage: "die.face.5", action: model.randomFill)
                .help("Fill the board randomly at the Fill Density")
            Button("Clear Board", systemImage: "eraser", action: model.clearBoard)
                .help("Kill every Life cell")
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Show", selection: $model.settings.foodView) {
                Label("Trail", systemImage: "scribble.variable").accessibilityLabel("Trail").tag(false)
                Label("Food", systemImage: "leaf").accessibilityLabel("Food").tag(true)
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
    /// The built-in SidebarCommands mislabels its item for this split view, so the View menu uses this.
    @Entry var showSidebar: Binding<Bool>?
}
