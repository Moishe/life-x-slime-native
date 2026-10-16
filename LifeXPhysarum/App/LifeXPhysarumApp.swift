import SwiftUI

@main
struct LifeXPhysarumApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: SimulationModel? = {
        guard !LifeXPhysarumApp.isTesting, let model = SimulationModel() else { return nil }
        model.persistSettings(in: .standard)
        return model
    }()

    var body: some Scene {
        Window("Life × Physarum", id: "main") {
            Group {
                if let model, let context = MetalContext.shared {
                    ContentView(model: model, context: context)
                } else if Self.isTesting {
                    Text("Running tests")
                } else {
                    ContentUnavailableView(
                        "Metal Isn’t Available",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Life × Physarum needs a Mac with a Metal GPU."))
                }
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            AppCommands(model: model)
        }

        Window("Life × Physarum Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }

    /// Unit tests run inside the app; don't start a simulation alongside them.
    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// SwiftUI ignores defaultSize for this split-view window and opens it at about
    /// 1100×600, so size it on first launch. Later launches restore the saved frame.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UserDefaults.standard.string(forKey: "NSWindow Frame main") == nil else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let screen = window.screen else { return }
            let visible = screen.visibleFrame
            let size = CGSize(width: min(1440, visible.width - 40), height: min(900, visible.height - 40))
            let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            window.setFrame(CGRect(origin: origin, size: size), display: true)
        }
    }
}
