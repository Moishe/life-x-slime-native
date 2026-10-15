struct Cell: Hashable {
    var x: Int
    var y: Int
}

struct TickResult {
    var births: [Cell]
    var deaths: [Cell]
}

/// A B3/S23 Life board. Cells beyond the edges are dead (no wrapping).
final class LifeEngine {
    let width: Int
    let height: Int
    private var cells: [UInt8]
    private var next: [UInt8]

    init(width: Int = 128, height: Int = 128) {
        self.width = width
        self.height = height
        cells = Array(repeating: 0, count: width * height)
        next = cells
    }

    func get(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return cells[y * width + x] == 1
    }

    func set(_ x: Int, _ y: Int, _ alive: Bool) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        cells[y * width + x] = alive ? 1 : 0
    }

    func clear() {
        for i in cells.indices { cells[i] = 0 }
    }

    /// Live cells in row-major order.
    func liveCells() -> [Cell] {
        var out: [Cell] = []
        for y in 0..<height {
            for x in 0..<width where cells[y * width + x] == 1 {
                out.append(Cell(x: x, y: y))
            }
        }
        return out
    }

    func population() -> Int {
        cells.reduce(0) { $0 + Int($1) }
    }

    func tick() -> TickResult {
        var births: [Cell] = []
        var deaths: [Cell] = []
        let w = width
        let h = height
        cells.withUnsafeBufferPointer { cur in
            next.withUnsafeMutableBufferPointer { nxt in
                for y in 0..<h {
                    let y0 = max(0, y - 1)
                    let y1 = min(h - 1, y + 1)
                    for x in 0..<w {
                        let x0 = max(0, x - 1)
                        let x1 = min(w - 1, x + 1)
                        var n = 0
                        for ny in y0...y1 {
                            let row = ny * w
                            for nx in x0...x1 { n += Int(cur[row + nx]) }
                        }
                        let i = y * w + x
                        let alive = cur[i] == 1
                        if alive { n -= 1 }
                        let lives = alive ? (n == 2 || n == 3) : n == 3
                        nxt[i] = lives ? 1 : 0
                        if lives && !alive { births.append(Cell(x: x, y: y)) }
                        if !lives && alive { deaths.append(Cell(x: x, y: y)) }
                    }
                }
            }
        }
        swap(&cells, &next)
        return TickResult(births: births, deaths: deaths)
    }
}
