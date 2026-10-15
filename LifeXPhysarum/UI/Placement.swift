import CoreGraphics

/// What a click on the field does.
enum Tool: Hashable {
    case paint
    case pattern(Pattern)

    var pattern: Pattern? {
        if case .pattern(let p) = self { p } else { nil }
    }
}

/// The square, centered region of a view the field is drawn into.
func fieldRect(in bounds: CGSize) -> CGRect {
    let side = min(bounds.width, bounds.height)
    return CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
}

/// The Life cell under a point (top-left origin), or nil outside the field.
func cell(at point: CGPoint, in field: CGRect, gridSize: Int) -> Cell? {
    let fx = (point.x - field.minX) / field.width
    let fy = (point.y - field.minY) / field.height
    guard fx >= 0, fy >= 0, fx < 1, fy < 1 else { return nil }
    return Cell(x: Int(fx * Double(gridSize)), y: Int(fy * Double(gridSize)))
}

/// Cells the tool would affect if clicked at `anchor`, clipped to the board.
/// Paint mode affects just the cell under the cursor.
func ghostCells(_ pattern: Pattern?, quarterTurns: Int, anchor: Cell, gridSize: Int) -> [Cell] {
    let cells = pattern.map { p in
        rotateCells(p.cells, quarterTurns: quarterTurns).map { Cell(x: anchor.x + $0.x, y: anchor.y + $0.y) }
    } ?? [anchor]
    return cells.filter { $0.x >= 0 && $0.y >= 0 && $0.x < gridSize && $0.y < gridSize }
}

/// Translucent blue, as in life-ambient's placement preview.
let ghostRGBA: [UInt8] = [90, 170, 255, 120]

/// One RGBA texel per Life cell: palette color where alive, transparent elsewhere.
func lifeTexels(_ cells: [ColoredCell], gridSize: Int) -> [UInt8] {
    var texels = [UInt8](repeating: 0, count: gridSize * gridSize * 4)
    for c in cells {
        let rgb = palette[c.paletteIndex]
        let o = (c.y * gridSize + c.x) * 4
        texels[o] = UInt8((rgb.x * 255).rounded())
        texels[o + 1] = UInt8((rgb.y * 255).rounded())
        texels[o + 2] = UInt8((rgb.z * 255).rounded())
        texels[o + 3] = 255
    }
    return texels
}

func ghostTexels(_ cells: [Cell], gridSize: Int) -> [UInt8] {
    var texels = [UInt8](repeating: 0, count: gridSize * gridSize * 4)
    for c in cells {
        let o = (c.y * gridSize + c.x) * 4
        texels.replaceSubrange(o..<o + 4, with: ghostRGBA)
    }
    return texels
}
