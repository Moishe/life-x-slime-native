import Dispatch

/// Runs the Life world on its own serial queue, so ticking and tracking a big
/// board never holds up drawing. Every change to the world goes through the
/// queue; each one sends an `Update` back to the main actor, in order.
nonisolated final class LifeRunner: @unchecked Sendable {
    struct Update: Sendable {
        /// Which board this came from; updates from a replaced board are stale.
        var epoch: Int
        /// Increases with every update; an older board image than one already shown is stale.
        var sequence: Int
        var gridSize: Int
        var texels: [UInt8]
        var organismCount: Int
        /// From a tick: actors to spawn and food to seed.
        var actors: [Actor] = []
        var seeds: [FoodSeed] = []
        var isTick = false
    }

    private let queue = DispatchQueue(label: "Life", qos: .userInteractive)
    private let deliver: @MainActor (Update) -> Void
    // Confined to `queue`.
    private var world: LifeWorld
    private var epoch = 0
    private var sequence = 0
    private let random: ReseedableRng

    init(size: Int, seed: Int, deliver: @escaping @MainActor (Update) -> Void) {
        random = ReseedableRng(seed: seed)
        world = LifeWorld(width: size, height: size, rng: random.next)
        self.deliver = deliver
    }

    /// One generation, its births turned into actors with `spawn`.
    func tick(spawn: SpawnSettings, maxActors: Int) {
        queue.async { self.send(self.runTick(spawn: spawn, maxActors: maxActors)) }
    }

    /// One generation, finished before returning (for movie recording, where
    /// spawns must land on the step they belong to).
    func tickNow(spawn: SpawnSettings, maxActors: Int) -> Update {
        queue.sync { runTick(spawn: spawn, maxActors: maxActors) }
    }

    /// Changes the board. The change happens after anything already queued.
    func edit(_ change: @escaping @Sendable (LifeWorld) -> Void) {
        queue.async {
            change(self.world)
            self.send(self.snapshot())
        }
    }

    /// Toggles a cell and returns its new state, waiting for queued work.
    func toggle(_ cell: Cell) -> Bool {
        let (alive, update) = queue.sync {
            world.toggle(cell.x, cell.y)
            return (world.engine.get(cell.x, cell.y), snapshot())
        }
        send(update)
        return alive
    }

    /// Replaces the board with an empty one of a new size.
    func resize(_ size: Int) {
        queue.async {
            self.epoch += 1
            self.world = LifeWorld(width: size, height: size, rng: self.random.next)
            self.send(self.snapshot())
        }
    }

    /// Restarts the random sequence (organism colors, random fill, actor RNG seeds).
    func reseed(_ seed: Int) {
        queue.async { self.random.reseed(seed) }
    }

    /// Waits for everything queued so far; for tests.
    func waitUntilIdle() {
        queue.sync {}
    }

    private func runTick(spawn: SpawnSettings, maxActors: Int) -> Update {
        let result = world.tick()
        var update = snapshot()
        update.actors = birthsToActors(result.births, spawn, rng: random.next, maxActors: maxActors)
        update.seeds = deathsToFoodSeeds(result.deaths)
        update.isTick = true
        return update
    }

    private func snapshot() -> Update {
        sequence += 1
        return Update(epoch: epoch, sequence: sequence, gridSize: world.width, texels: lifeTexels(world.liveCells(), gridSize: world.width),
               organismCount: world.organismCount)
    }

    private func send(_ update: Update) {
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(update) } }
    }
}
