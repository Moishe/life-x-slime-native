import SwiftUI

/// The placement tools: paint cells, or stamp one of the library's patterns.
struct PatternSidebar: View {
    @Bindable var model: SimulationModel

    var body: some View {
        List(selection: Binding<Tool?>(get: { model.tool }, set: { if let tool = $0 { model.tool = tool } })) {
            Section("Tools") {
                Label("Paint Cells", systemImage: "paintbrush.pointed")
                    .help("Click to toggle a cell; drag to paint")
                    .tag(Tool.paint)
            }
            ForEach(PatternCategory.allCases) { category in
                Section {
                    ForEach(Pattern.all.filter { $0.category == category }) { pattern in
                        PatternRow(pattern: pattern)
                            .tag(Tool.pattern(pattern))
                    }
                } header: {
                    Text(category.title)
                        .help(category.subtitle)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            RotationControl(model: model)
        }
    }
}

private struct PatternRow: View {
    let pattern: Pattern

    var body: some View {
        Label {
            Text(pattern.name)
        } icon: {
            PatternThumbnail(pattern: pattern)
        }
        .help("\(pattern.name): \(pattern.width) × \(pattern.height), \(pattern.cells.count) cells. Click the field to place it; press R to rotate")
    }
}

/// The pattern's cells, scaled to fit an icon.
struct PatternThumbnail: View {
    let pattern: Pattern
    var quarterTurns = 0

    var body: some View {
        Canvas { context, size in
            let cells = rotateCells(pattern.cells, quarterTurns: quarterTurns)
            let width = (cells.map(\.x).max() ?? 0) + 1
            let height = (cells.map(\.y).max() ?? 0) + 1
            let cellSize = min(size.width / CGFloat(width), size.height / CGFloat(height))
            let origin = CGPoint(x: (size.width - cellSize * CGFloat(width)) / 2,
                                 y: (size.height - cellSize * CGFloat(height)) / 2)
            var path = Path()
            for c in cells {
                path.addRect(CGRect(x: origin.x + CGFloat(c.x) * cellSize, y: origin.y + CGFloat(c.y) * cellSize,
                                    width: cellSize, height: cellSize).insetBy(dx: cellSize * 0.08, dy: cellSize * 0.08))
            }
            context.fill(path, with: .foreground)
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// Shows the current rotation and turns the pattern 90° clockwise.
private struct RotationControl: View {
    let model: SimulationModel

    var body: some View {
        HStack {
            if let pattern = model.tool.pattern {
                PatternThumbnail(pattern: pattern, quarterTurns: model.quarterTurns)
                    .foregroundStyle(.secondary)
            }
            Text("Rotation \(model.quarterTurns * 90)°")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Rotate", systemImage: "rotate.right", action: model.rotate)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Rotate the pattern 90° clockwise (R)")
                .disabled(model.tool.pattern == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
