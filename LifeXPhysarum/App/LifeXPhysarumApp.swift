import SwiftUI

@main
struct LifeXPhysarumApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = LifeXPhysarumApp.isTesting ? nil : SimulationModel()

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
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            AppCommands(model: model)
        }
    }

    /// Unit tests run inside the app; don't start a simulation alongside them.
    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
