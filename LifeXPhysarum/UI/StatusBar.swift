import AppKit
import SwiftUI

/// Live numbers along the bottom of the window.
struct StatusBar: View {
    let model: SimulationModel

    var body: some View {
        let r = model.readouts
        HStack(spacing: 14) {
            if let frames = model.recordingFrames {
                Label {
                    Text(recordingStatus(frames: frames) ?? "")
                } icon: {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                }
                .foregroundStyle(.primary)
                .help("Recording: one movie frame per Physarum step, at 30 fps")
                Divider().frame(height: 12)
            }
            // Drops the insert rates, then the frame rates, when the window is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { rates(r); counts(r); inserts(r) }
                HStack(spacing: 14) { rates(r); counts(r) }
                HStack(spacing: 14) { counts(r) }
            }
            Spacer(minLength: 0)
            if let saved = model.lastSaved {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                } label: {
                    Label("Show \(saved.lastPathComponent) in Finder", systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help("Reveal the last saved file in Finder")
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private func rates(_ r: Readouts) -> some View {
        item("\(Int(r.fps.rounded()))", "fps", help: "Frames drawn per second")
        item("\(Int(r.physStepsPerSec.rounded()))", "steps/s", help: "Physarum steps per second (target 30)")
    }

    @ViewBuilder
    private func counts(_ r: Readouts) -> some View {
        item(r.alive.formatted(), "actors", help: "Physarum actors alive")
        if model.source == .audio {
            item(r.movingCells.formatted(), r.movingCells == 1 ? "lit cell" : "lit cells", help: "Cells the sound lit in the last audio frame")
        } else if model.source == .camera {
            if model.cameraSettings.trigger == .edges {
                item(r.movingCells.formatted(), r.movingCells == 1 ? "edge cell" : "edge cells", help: "Cells on an edge in the last camera frame")
            } else {
                item(r.movingCells.formatted(), r.movingCells == 1 ? "moving cell" : "moving cells", help: "Cells whose image changed in the last camera frame")
            }
        } else {
            item(r.organisms.formatted(), r.organisms == 1 ? "organism" : "organisms", help: "Life organisms (clusters of cells)")
        }
    }

    @ViewBuilder
    private func inserts(_ r: Readouts) -> some View {
        if model.source == .audio {
            item("+\(Int(r.lifeInsertsPerSec.rounded()).formatted())/s", "from audio", help: "Actors spawned by the sound’s lit cells per second")
        } else if model.source == .camera {
            item("+\(Int(r.lifeInsertsPerSec.rounded()).formatted())/s", "from camera", help: "Actors spawned by the camera’s motion or edges per second")
        } else {
            item("+\(Int(r.lifeInsertsPerSec.rounded()).formatted())/s", "from Life", help: "Actors spawned by Life births per second")
        }
        item("+\(Int(r.childInsertsPerSec.rounded()).formatted())/s", "from children", help: "Actors added by reproduction per second")
    }

    private func item(_ value: String, _ label: String, help: String) -> some View {
        HStack(spacing: 4) {
            Text(value).foregroundStyle(.primary)
            Text(label)
        }
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .combine)
    }
}
