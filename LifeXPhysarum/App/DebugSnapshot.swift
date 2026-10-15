#if DEBUG
import AppKit

/// Development aid: with LXP_DEBUG_SNAPSHOT set, sets up a scene, then saves
/// the window and the field as PNGs into the app container's tmp directory.
/// LXP_DEBUG_SNAPSHOT is a comma-separated list of steps: "fill", "glider",
/// "food", "big", "inspector-closed", "wait=<seconds>".
enum DebugSnapshot {
    static func runIfRequested(_ model: SimulationModel) {
        guard let script = ProcessInfo.processInfo.environment["LXP_DEBUG_SNAPSHOT"] else { return }
        Task { @MainActor in
            var wait = 3.0
            for step in script.split(separator: ",").map(String.init) {
                switch step {
                case "fill": model.randomFill()
                case "glider": model.click(Cell(x: 10, y: 10))
                case "food": model.settings.foodView = true
                case "big": model.setLifeSize(256); model.randomFill()
                case "huge": model.setLifeSize(1024); model.randomFill()
                case let s where s.hasPrefix("tool="):
                    if let p = Pattern.named(String(s.dropFirst(5))) { model.tool = .pattern(p); model.setHover(Cell(x: 30, y: 30)) }
                case let s where s.hasPrefix("wait="): wait = Double(s.dropFirst(5)) ?? wait
                default: break
                }
            }
            try? await Task.sleep(for: .seconds(wait))
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            let r = model.readouts
            let summary = "fps=\(Int(r.fps)) steps=\(Int(r.physStepsPerSec)) alive=\(r.alive) organisms=\(r.organisms) life=\(Int(r.lifeInsertsPerSec)) children=\(Int(r.childInsertsPerSec))\n"
            try? summary.write(to: directory.appending(path: "readouts.txt"), atomically: true, encoding: .utf8)
            if let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView?.superview {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "window.png"))
                }
            }
            await model.exportImages(to: directory.appending(path: "debug"))
        }
    }
}
#endif
