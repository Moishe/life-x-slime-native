import AppKit
import UniformTypeIdentifiers

/// Open and save panels, shown as sheets on the main window.
enum FilePanels {
    static func save(title: String, name: String, types: [UTType]) async -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        return await present(panel)
    }

    static func open(title: String, types: [UTType]) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return await present(panel)
    }

    private static func present(_ panel: NSSavePanel) async -> URL? {
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
}

extension SimulationModel {
    func saveSettingsWithPanel() async {
        guard let url = await FilePanels.save(title: "Save Settings", name: "life-x-physarum-settings.json", types: [.json]) else { return }
        do {
            try settingsFileData().write(to: url, options: .atomic)
            markSaved(url)
        } catch {
            notice = Notice(title: "Couldn’t save the settings", message: error.localizedDescription)
        }
    }

    func openSettingsWithPanel() async {
        guard let url = await FilePanels.open(title: "Open Settings", types: [.json]) else { return }
        do {
            loadSettings(from: try Data(contentsOf: url), name: url.lastPathComponent)
        } catch {
            notice = Notice(title: "Couldn’t open “\(url.lastPathComponent)”", message: error.localizedDescription)
        }
    }

    /// Asks for a folder name and saves life.png, physarum.png and mix.png images into it.
    func exportImagesWithPanel() async {
        let base = snapshotBaseName(.now)
        guard let url = await FilePanels.save(title: "Export Images", name: base, types: [.folder]) else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            notice = Notice(title: "Couldn’t create the folder", message: error.localizedDescription)
            return
        }
        await exportImages(to: url.appending(path: url.lastPathComponent))
    }

    /// Asks for an audio file and where to save the movie, then renders it
    /// (or, while one is rendering, stops it).
    func renderMovieWithPanel() async {
        if renderProgress != nil {
            cancelRender()
            return
        }
        guard let audio = await FilePanels.open(title: "Render Movie from Audio File", types: [.audio]),
              let url = await FilePanels.save(title: "Save Movie", name: audio.deletingPathExtension().lastPathComponent + ".mp4",
                                              types: [.mpeg4Movie])
        else { return }
        do {
            try await renderMovie(audio: audio, to: url)
        } catch is CancellationError {
        } catch {
            notice = Notice(title: "Couldn’t render “\(audio.lastPathComponent)”", message: error.localizedDescription)
        }
    }

    func toggleRecordingWithPanel() async {
        if isRecording {
            await stopRecording()
            return
        }
        guard let url = await FilePanels.save(title: "Record Movie", name: movieFilename(.now), types: [.mpeg4Movie]) else { return }
        startRecording(to: url)
    }
}
