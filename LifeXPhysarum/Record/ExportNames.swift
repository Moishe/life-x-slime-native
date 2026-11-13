import Foundation

/// Local-time stamp used in exported file names, e.g. 2026-10-03-19-30-12.
func exportTimestamp(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(format: "%04d-%02d-%02d-%02d-%02d-%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
}

enum SnapshotPart: String, CaseIterable {
    case life, physarum, mix
}

/// The base name for one export; parts are saved as "<base>-<part>.png".
func snapshotBaseName(_ date: Date) -> String {
    "life-x-physarum-\(exportTimestamp(date))"
}

func snapshotFilename(base: String, part: SnapshotPart) -> String {
    "\(base)-\(part.rawValue).png"
}

func movieFilename(_ date: Date) -> String {
    "life-x-physarum-\(exportTimestamp(date)).mp4"
}

nonisolated let movieFPS = 30

/// The status bar's recording readout: nil when not recording.
func recordingStatus(frames: Int?) -> String? {
    guard let frames else { return nil }
    return String(format: "%.1f s (%d frames)", Double(frames) / Double(movieFPS), frames)
}

/// The status bar's render readout: movie time done of the whole, and the share.
func renderStatus(_ progress: RenderProgress) -> String {
    func time(_ frames: Int) -> String {
        let seconds = frames / movieFPS
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    guard progress.total > 0 else { return "Reading the audio file…" }
    return "Rendering \(time(progress.done)) of \(time(progress.total)) (\(Int(progress.fraction * 100))%)"
}
