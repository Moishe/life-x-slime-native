struct SpawnSettings {
    var actorsPerBirth: Int
    var cellSize: Float
    var minSpeed: Float
    var life: UInt32
}

/// Turns Life births into Physarum actors placed randomly inside each newborn
/// cell's block. Returns at most `maxActors`; when there are more, the newest
/// births win (older ones would be evicted from the ring anyway).
func birthsToActors(_ births: [ColoredCell], _ settings: SpawnSettings, rng: Rng, maxActors: Int) -> [Actor] {
    guard settings.actorsPerBirth > 0, maxActors > 0 else { return [] }
    let keep = (maxActors + settings.actorsPerBirth - 1) / settings.actorsPerBirth
    var actors: [Actor] = []
    actors.reserveCapacity(min(births.count, keep) * settings.actorsPerBirth)
    for b in births.suffix(keep) {
        let rgb = palette[b.paletteIndex]
        let color = SIMD4(rgb, 1)
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
    return Array(actors.suffix(maxActors))
}

func deathsToFoodSeeds(_ deaths: [ColoredCell]) -> [FoodSeed] {
    deaths.map { d in
        FoodSeed(color: SIMD4(palette[d.paletteIndex], 1), cell: SIMD2(UInt32(d.x), UInt32(d.y)), pad: .zero)
    }
}

enum SpawnMode: String, CaseIterable, Identifiable {
    case burst, trickle

    var id: Self { self }
}

/// Queues spawned actors between Life ticks and hands them to Physarum steps,
/// either all at once (burst) or spread evenly until the next tick (trickle).
final class SpawnScheduler {
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
