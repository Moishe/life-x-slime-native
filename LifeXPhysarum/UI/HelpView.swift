import SwiftUI

/// The Help menu's window: what the app is, how to use it, and its shortcuts.
struct HelpView: View {
    private let shortcuts: [(String, String)] = [
        ("Play / pause", "Space or ⌘P"),
        ("Step one generation", "→ or ⌘↩"),
        ("Seed from Life / camera", "⌥⌘1 / ⌥⌘2"),
        ("Rotate pattern", "R or ⌘R"),
        ("Show trail / food", "⌘1 / ⌘2, or T to toggle"),
        ("Random fill / clear board", "⇧⌘F / ⇧⌘⌫"),
        ("Open / save settings", "⌘O / ⌘S"),
        ("Export images", "⇧⌘E"),
        ("Record movie / stop", "⇧⌘R"),
        ("Show or hide the inspector", "⌥⌘I"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("A Conway’s Life board whose organisms seed a Physarum (slime mold) simulation. "
                    + "Every Life birth releases actors in its organism’s color; they follow and lay down "
                    + "trails, and the food left where cells die draws them in.")

                section("Using it") {
                    bullet("**Sidebar:** choose Paint Cells (click toggles a cell, drag paints) or a pattern, then click the field to place it.")
                    bullet("**Inspector:** every setting. Hover a control for what it does; right-click to reset it to its default.")
                    bullet("**Status bar:** frame rate, Physarum steps per second, live actors, organisms, and how many actors Life births and reproduction add each second.")
                    bullet("**Camera:** switch the toolbar from Life to Camera, and motion in front of the camera releases actors in the scene’s colors (or, with Colors set to Palette, the nearest colors in the Life palette), leaving food where it stops. Set Spawn From to Edges and the outlines in the image release actors every frame, even when nothing moves. The Camera section also picks the camera, mirrors it and sets the thresholds.")
                    bullet("**Settings files** use the web version’s format. Your settings are also remembered between sessions.")
                    bullet("**Export Images** saves the Life layer, the trail and the mix as 2048 × 2048 PNGs. **Record Movie** saves a 2048 × 2048, 30 fps movie with one frame per Physarum step.")
                }

                section("Keyboard shortcuts") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        ForEach(shortcuts, id: \.0) { action, keys in
                            GridRow {
                                Text(action)
                                Text(keys).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    Text("Space, →, R and T work when the field has focus (click it); Space and R also work in the sidebar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
