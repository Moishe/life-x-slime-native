nonisolated struct SpawnSettings: Sendable {
    var actorsPerBirth: Int
    var cellSize: Float
    var minSpeed: Float
    var life: UInt32
}

/// A cell that releases actors (a birth) or leaves food (a death), in its color.
/// Life's cells take their organism's palette color; the camera's, the scene's.
nonisolated struct SeedCell: Equatable {
    var x: Int
    var y: Int
    var color: SIMD3<Float>
}

extension ColoredCell {
    nonisolated func seedCell(_ colors: [SIMD3<Float>]) -> SeedCell {
        SeedCell(x: x, y: y, color: colorFor(colors, slot: paletteIndex))
    }
}

nonisolated func birthsToActors(_ births: [ColoredCell], colors: [SIMD3<Float>], _ settings: SpawnSettings,
                                rng: Rng, maxActors: Int) -> [Actor] {
    birthsToActors(births.map { $0.seedCell(colors) }, settings, rng: rng, maxActors: maxActors)
}

nonisolated func deathsToFoodSeeds(_ deaths: [ColoredCell], colors: [SIMD3<Float>]) -> [FoodSeed] {
    deathsToFoodSeeds(deaths.map { $0.seedCell(colors) })
}

/// Turns Life births into Physarum actors placed randomly inside each newborn
/// cell's block, in random birth order. Returns at most `maxActors`.
///
/// Births arrive in row order, and on a big board more are born than can be
/// spawned: this keeps `maxActors`, and the per-step cap and the queue trim
/// further. Shuffling first makes every such cut a uniform sample of the board
/// rather than its bottom rows. (The web version keeps the last births, so its
/// big boards only grow actors along one edge.)
nonisolated func birthsToActors(_ births: [SeedCell], _ settings: SpawnSettings, rng: Rng, maxActors: Int) -> [Actor] {
    guard settings.actorsPerBirth > 0, maxActors > 0 else { return [] }
    let keep = (maxActors + settings.actorsPerBirth - 1) / settings.actorsPerBirth
    var births = births
    for i in stride(from: births.count - 1, to: 0, by: -1) {
        births.swapAt(i, Int(rng() * Double(i + 1)))
    }
    var actors: [Actor] = []
    actors.reserveCapacity(min(births.count, keep) * settings.actorsPerBirth)
    for b in births.prefix(keep) {
        let color = SIMD4(b.color, 1)
        for _ in 0..<settings.actorsPerBirth {
            let x = (Float(b.x) + Float(rng())) * settings.cellSize
            let y = (Float(b.y) + Float(rng())) * settings.cellSize
            actors.append(Actor(
                pos: SIMD2(x, y),
                dir: Float(rng() * 2 * .pi),
                speed: settings.minSpeed,
                seed: color,
                color: color,
                age: 0,
                life: settings.life,
                alive: 1,
                rng: randomNonZeroU32(rng)
            ))
        }
    }
    return Array(actors.prefix(maxActors))
}

nonisolated func deathsToFoodSeeds(_ deaths: [SeedCell]) -> [FoodSeed] {
    deaths.map { d in
        FoodSeed(color: SIMD4(d.color, 1), cell: SIMD2(UInt32(d.x), UInt32(d.y)), pad: .zero)
    }
}

nonisolated enum SpawnMode: String, CaseIterable, Identifiable {
    case burst, trickle

    var id: Self { self }
}

/// Queues spawned actors between Life ticks and hands them to Physarum steps,
/// either all at once (burst) or spread evenly until the next tick (trickle).
nonisolated final class SpawnScheduler {
    var mode: SpawnMode = .burst
    var maxQueued: Int
    // The queue is queue[head...]; taken actors are dropped from the front lazily.
    private var queue: [Actor] = []
    private var head = 0
    private var stepsLeft = 1

    init(maxQueued: Int) {
        self.maxQueued = maxQueued
    }

    var pending: Int { queue.count - head }

    func enqueue(_ actors: [Actor], stepsUntilNextTick: Int) {
        compact()
        queue.append(contentsOf: actors)
        if queue.count > maxQueued { queue.removeFirst(queue.count - maxQueued) }
        stepsLeft = max(1, stepsUntilNextTick)
    }

    func takeForStep(limit: Int) -> ArraySlice<Actor> {
        let wanted = mode == .burst ? pending : (pending + stepsLeft - 1) / stepsLeft
        stepsLeft = max(1, stepsLeft - 1)
        let n = min(wanted, limit)
        defer { head += n }
        return queue[head..<head + n]
    }

    func clear() {
        queue = []
        head = 0
        stepsLeft = 1
    }

    private func compact() {
        guard head > 0 else { return }
        queue.removeFirst(head)
        head = 0
    }
}
