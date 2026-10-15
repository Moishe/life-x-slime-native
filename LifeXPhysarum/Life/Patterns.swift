// The pattern library, ported from life-ambient's engine/patterns.ts.

enum PatternCategory: String, CaseIterable, Identifiable {
    case drone, pulse, voyager, fountain, wildcard

    var id: Self { self }

    var title: String {
        switch self {
        case .drone: "Drones"
        case .pulse: "Pulses"
        case .voyager: "Voyagers"
        case .fountain: "Fountains"
        case .wildcard: "Wildcards"
        }
    }

    var subtitle: String {
        switch self {
        case .drone: "Still lifes"
        case .pulse: "Oscillators"
        case .voyager: "Spaceships"
        case .fountain: "Guns"
        case .wildcard: "Methuselahs"
        }
    }
}

struct Pattern: Identifiable, Hashable {
    let id: String
    let name: String
    let category: PatternCategory
    let cells: [Cell]
    let width: Int
    let height: Int

    init(_ id: String, _ name: String, _ category: PatternCategory, _ rows: [String]) {
        self.id = id
        self.name = name
        self.category = category
        cells = cellsFromRows(rows)
        width = rows.map(\.count).max() ?? 0
        height = rows.count
    }

    static let all: [Pattern] = [
        Pattern("block", "Block", .drone, ["##", "##"]),
        Pattern("beehive", "Beehive", .drone, [".##.", "#..#", ".##."]),
        Pattern("loaf", "Loaf", .drone, [".##.", "#..#", ".#.#", "..#."]),
        Pattern("pond", "Pond", .drone, [".##.", "#..#", "#..#", ".##."]),
        Pattern("blinker", "Blinker", .pulse, ["###"]),
        Pattern("toad", "Toad", .pulse, [".###", "###."]),
        Pattern("beacon", "Beacon", .pulse, ["##..", "##..", "..##", "..##"]),
        Pattern("pulsar", "Pulsar", .pulse, [
            "..###...###..",
            ".............",
            "#....#.#....#",
            "#....#.#....#",
            "#....#.#....#",
            "..###...###..",
            ".............",
            "..###...###..",
            "#....#.#....#",
            "#....#.#....#",
            "#....#.#....#",
            ".............",
            "..###...###..",
        ]),
        Pattern("pentadecathlon", "Pentadecathlon", .pulse, [
            "..#....#..",
            "##.####.##",
            "..#....#..",
        ]),
        Pattern("glider", "Glider", .voyager, [".#.", "..#", "###"]),
        Pattern("lwss", "Lightweight Spaceship", .voyager, [
            "#..#.",
            "....#",
            "#...#",
            ".####",
        ]),
        Pattern("gosperGun", "Gosper Glider Gun", .fountain, [
            "........................#...........",
            "......................#.#...........",
            "............##......##............##",
            "...........#...#....##............##",
            "##........#.....#...##..............",
            "##........#...#.##....#.#...........",
            "..........#.....#.......#...........",
            "...........#...#....................",
            "............##......................",
        ]),
        Pattern("rPentomino", "R-Pentomino", .wildcard, [".##", "##.", ".#."]),
        Pattern("acorn", "Acorn", .wildcard, [".#.....", "...#...", "##..###"]),
    ]

    static func named(_ id: String) -> Pattern? {
        all.first { $0.id == id }
    }
}

func cellsFromRows(_ rows: [String]) -> [Cell] {
    var cells: [Cell] = []
    for (y, row) in rows.enumerated() {
        for (x, ch) in row.enumerated() where ch == "#" { cells.append(Cell(x: x, y: y)) }
    }
    return cells
}

/// Rotates cells by quarter turns clockwise, keeping them anchored at the top left.
func rotateCells(_ cells: [Cell], quarterTurns: Int) -> [Cell] {
    var out = cells
    let turns = ((quarterTurns % 4) + 4) % 4
    for _ in 0..<turns {
        let maxY = out.map(\.y).max() ?? 0
        out = out.map { Cell(x: maxY - $0.y, y: $0.x) }
    }
    return out
}

func placePattern(_ engine: LifeEngine, _ pattern: Pattern, x ox: Int, y oy: Int, quarterTurns: Int = 0) {
    for c in rotateCells(pattern.cells, quarterTurns: quarterTurns) {
        engine.set(ox + c.x, oy + c.y, true)
    }
}
