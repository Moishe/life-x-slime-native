// Palette hues: 8 fully saturated, full-value colors 45° apart.
nonisolated let paletteHuesDegrees: [Float] = [0, 45, 90, 135, 180, 225, 270, 315]
nonisolated let palette: [SIMD3<Float>] = paletteHuesDegrees.map { hsv2rgb(SIMD3($0 / 360, 1, 1)) }

/// Remembers which palette color each tracked organism wears. A color lasts as
/// long as the organism's id: splits give new ids (new colors), merges keep one.
nonisolated final class OrganismPalette {
    private var colors: [Int: Int] = [:]
    private let rng: Rng

    init(rng: @escaping Rng) {
        self.rng = rng
    }

    func apply(_ events: ClusterEvents) {
        for id in events.died { colors[id] = nil }
        for m in events.born { colors[m.id] = Int(rng() * Double(palette.count)) }
    }

    func index(of organismId: Int) -> Int? {
        colors[organismId]
    }
}

nonisolated struct ColoredCell: Equatable {
    var x: Int
    var y: Int
    var paletteIndex: Int
}

nonisolated struct WorldTick {
    var births: [ColoredCell]
    var deaths: [ColoredCell]
    var events: ClusterEvents
}

/// The Life board plus organism tracking and coloring. This is the single
/// place other modules (rendering, the Physarum bridge, future MIDI) read
/// organism state from.
nonisolated final class LifeWorld {
    let width: Int
    let height: Int
    let engine: LifeEngine
    private let tracker: ClusterTracker
    private let organismPalette: OrganismPalette
    private let rng: Rng
    // Organism id of each cell (0 = none), as of the latest tracker update.
    private var owner: [Int32]
    private(set) var latestEvents = ClusterEvents()

    init(width: Int, height: Int, rng: @escaping Rng) {
        self.width = width
        self.height = height
        self.rng = rng
        engine = LifeEngine(width: width, height: height)
        tracker = ClusterTracker(width: width, height: height)
        organismPalette = OrganismPalette(rng: rng)
        owner = [Int32](repeating: 0, count: width * height)
    }

    func tick() -> WorldTick {
        let result = engine.tick()
        // Deaths take the color of the organism the cell belonged to before this tick.
        let deaths = result.deaths.map(colored)
        retrack()
        return WorldTick(births: result.births.map(colored), deaths: deaths, events: latestEvents)
    }

    func toggle(_ x: Int, _ y: Int) {
        engine.set(x, y, !engine.get(x, y))
        retrack()
    }

    func setCell(_ x: Int, _ y: Int, alive: Bool) {
        setCells([Cell(x: x, y: y)], alive: alive)
    }

    /// Sets several cells, tracking organisms once.
    func setCells(_ cells: [Cell], alive: Bool) {
        let changed = cells.filter { engine.get($0.x, $0.y) != alive }
        guard !changed.isEmpty else { return }
        for c in changed { engine.set(c.x, c.y, alive) }
        retrack()
    }

    func place(_ pattern: Pattern, x: Int, y: Int, quarterTurns: Int) {
        placePattern(engine, pattern, x: x, y: y, quarterTurns: quarterTurns)
        retrack()
    }

    func clear() {
        engine.clear()
        retrack()
    }

    func randomFill(density: Double) {
        engine.clear()
        for y in 0..<height {
            for x in 0..<width where rng() < density { engine.set(x, y, true) }
        }
        retrack()
    }

    func liveCells() -> [ColoredCell] {
        engine.liveCells().map(colored)
    }

    var organismCount: Int {
        latestEvents.born.count + latestEvents.updated.count
    }

    private func colored(_ c: Cell) -> ColoredCell {
        let id = Int(owner[c.y * width + c.x])
        let index = id == 0 ? nil : organismPalette.index(of: id)
        return ColoredCell(x: c.x, y: c.y, paletteIndex: index ?? 0)
    }

    private func retrack() {
        for m in latestEvents.born + latestEvents.updated {
            for c in m.cells { owner[c.y * width + c.x] = 0 }
        }
        latestEvents = tracker.update(engine.liveCells())
        organismPalette.apply(latestEvents)
        for m in latestEvents.born + latestEvents.updated {
            for c in m.cells { owner[c.y * width + c.x] = Int32(m.id) }
        }
    }
}
