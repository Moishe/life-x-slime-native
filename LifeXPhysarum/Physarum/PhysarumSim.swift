import Metal
import Synchronization

struct CounterValues: Equatable, Sendable {
    var head: UInt32 = 0
    var childCount: UInt32 = 0
    var aliveCount: UInt32 = 0
    var childrenInserted: UInt32 = 0
}

/// Owns the Physarum GPU state and runs one step at a time.
///
/// Pass order per step, as in Particles: diffuse/fade the trail, seed and fade
/// the food, move/sense/turn the actors, insert Life spawns and children into
/// the ring, deposit every actor into the trail, then fold the step's actor
/// pile into the height field.
final class PhysarumSim {
    enum StepError: Error, Equatable {
        case tooManySpawns(max: Int)
        case tooManyFoodSeeds(max: Int)
    }

    static let maxSpawnsPerStepCap = 65536
    /// Steps that may be queued on the GPU before `step` waits for one to finish.
    private static let framesInFlight = 3

    var params = PhysarumParams()
    /// How much each step's (blurred) actor count raises the height field, and
    /// what fraction of the height fades per step.
    var heightGain = 0.0
    var heightDecay = 0.0
    let width: Int
    let height: Int
    private(set) var poolSize = 0
    private(set) var cellSize = 0

    private let context: MetalContext
    private let passes: PhysarumPasses

    private var trailA: MTLTexture
    private var trailB: MTLTexture
    let foodTexture: MTLTexture

    private var actors: MTLBuffer!
    private var children: MTLBuffer!
    private let counters: MTLBuffer
    /// Actors per field pixel in the current step, for crowdingLimit.
    private let density: MTLBuffer
    /// Actors per field pixel in the current step, counted by the deposit pass.
    private let pile: MTLBuffer
    /// Pile height per field pixel (one Float each, row-major), in [0, 1].
    let heightField: MTLBuffer

    /// Per-frame-in-flight upload and readback buffers, reused round-robin.
    private struct Frame {
        var spawns: MTLBuffer
        var seeds: MTLBuffer
        let readback: MTLBuffer
    }
    private var frames: [Frame]
    private let inFlight = DispatchSemaphore(value: framesInFlight)
    private var stepIndex = 0
    private let latest = LatestCounters()

    init(context: MetalContext, width: Int, height: Int, poolSize: Int, cellSize: Int) {
        self.context = context
        self.width = width
        self.height = height
        passes = PhysarumPasses(context: context)

        trailA = context.makeFieldTexture(width: width, height: height, label: "trail A")
        trailB = context.makeFieldTexture(width: width, height: height, label: "trail B")
        foodTexture = context.makeFieldTexture(width: width, height: height, label: "food")
        counters = context.makeBuffer(length: MemoryLayout<Counters>.stride, label: "counters")
        density = context.makeBuffer(length: width * height * MemoryLayout<UInt32>.stride, label: "density")
        pile = context.makeBuffer(length: width * height * MemoryLayout<UInt32>.stride, label: "pile")
        heightField = context.makeBuffer(length: width * height * MemoryLayout<Float>.stride, label: "height")
        frames = (0..<Self.framesInFlight).map { i in
            Frame(
                spawns: context.makeBuffer(length: 0, label: "spawns \(i)"),
                seeds: context.makeBuffer(length: 0, label: "food seeds \(i)"),
                readback: context.makeBuffer(length: MemoryLayout<Counters>.stride, label: "counters readback \(i)")
            )
        }

        clearTrail()
        allocatePool(poolSize)
        setCellSize(cellSize)
    }

    /// The latest trail.
    var trail: MTLTexture { trailA }

    var maxChildren: Int { poolSize / 8 }

    /// Life spawns per step are capped so a step never inserts more than poolSize actors.
    var maxSpawnsPerStep: Int { min(poolSize - maxChildren, Self.maxSpawnsPerStepCap) }

    /// One food seed per Life cell, so a tick's deaths always fit in one step.
    var maxFoodSeedsPerStep: Int { (width / cellSize) * (height / cellSize) }

    /// Counters as of the most recently completed step (never blocks).
    var latestCounters: CounterValues { latest.value }

    func step<Spawns: Collection<Actor>>(spawns: Spawns, seeds: [FoodSeed]) throws(StepError) {
        guard spawns.count <= maxSpawnsPerStep else { throw .tooManySpawns(max: maxSpawnsPerStep) }
        guard seeds.count <= maxFoodSeedsPerStep else { throw .tooManyFoodSeeds(max: maxFoodSeedsPerStep) }
        let p = params

        inFlight.wait()
        let slot = stepIndex % Self.framesInFlight
        upload(spawns, into: &frames[slot].spawns, label: "spawns \(slot)")
        upload(seeds, into: &frames[slot].seeds, label: "food seeds \(slot)")
        let frame = frames[slot]

        let simParams = SimParams(p, SimFrame(
            width: width, height: height, step: stepIndex, poolSize: poolSize,
            maxChildren: maxChildren, spawnCount: spawns.count))
        let commandBuffer = context.queue.makeCommandBuffer()!
        commandBuffer.label = "physarum step"

        // Reset childCount and aliveCount; head and childrenInserted persist.
        let reset = commandBuffer.makeBlitCommandEncoder()!
        reset.fill(buffer: counters, range: 4..<12, value: 0)
        if p.crowdingLimit > 0 { reset.fill(buffer: density, range: 0..<density.length, value: 0) }
        reset.fill(buffer: pile, range: 0..<pile.length, value: 0)
        reset.endEncoding()

        // Blur and fade each have their own interval; one pass does whichever are due.
        let blur = stepIndex % max(1, p.blurInterval) == 0
        let fadeTrail = stepIndex % max(1, p.fadeInterval) == 0
        let diffuse = blur || fadeTrail
        if diffuse {
            let fade = FadeParams(decrement: fadeTrail ? Float(p.fadeDecrement) : 0,
                                  blurMultiplier: blur ? Float(p.blurMultiplier) : 0, pad0: 0, pad1: 0)
            passes.encodeDiffuse(commandBuffer, fade: fade, source: trailA, target: trailB)
        }
        let current = diffuse ? trailB : trailA

        let fadeFood = stepIndex % max(1, p.foodFadeInterval) == 0
        passes.encodeFood(
            commandBuffer, target: foodTexture, seeds: frame.seeds, seedCount: seeds.count,
            foodParams: FoodParams(cellSize: Float(cellSize), foodPerDeath: Float(p.foodPerDeath),
                                   width: Float(width), height: Float(height)),
            fade: fadeFood ? FadeParams(decrement: Float(p.foodFadeDecrement), blurMultiplier: 0, pad0: 0, pad1: 0) : nil)

        passes.encodeAgents(commandBuffer, params: simParams, actors: actors, children: children,
                            counters: counters, density: density, trail: current, food: foodTexture)
        passes.encodeInject(commandBuffer, params: simParams, actors: actors, spawns: frame.spawns,
                            children: children, counters: counters)
        passes.encodeDeposit(commandBuffer, params: simParams, actors: actors, target: current, pile: pile)
        passes.encodeHeight(commandBuffer, params: HeightParams(gain: Float(heightGain), decay: Float(heightDecay),
                                                                width: UInt32(width), height: UInt32(height)),
                            pile: pile, height: heightField)

        let copy = commandBuffer.makeBlitCommandEncoder()!
        copy.copy(from: counters, sourceOffset: 0, to: frame.readback, destinationOffset: 0, size: MemoryLayout<Counters>.stride)
        copy.endEncoding()

        // The readback buffer is only touched by this step's GPU work and then this handler.
        let readback = UncheckedSendable(frame.readback)
        let latest = latest
        let inFlight = inFlight
        commandBuffer.addCompletedHandler { _ in
            latest.store(readback.value)
            inFlight.signal()
        }
        commandBuffer.commit()

        if diffuse { swap(&trailA, &trailB) }
        stepIndex += 1
    }

    /// Follows a Life board size change: the food map is laid out in the old
    /// cell blocks, so it is cleared.
    func setCellSize(_ cellSize: Int) {
        self.cellSize = cellSize
        clearFood()
    }

    /// Reallocates the actor pool. Every actor and counter starts at zero.
    func setPoolSize(_ poolSize: Int) {
        allocatePool(poolSize)
    }

    func clearActors() {
        let commandBuffer = context.queue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.fill(buffer: actors, range: 0..<actors.length, value: 0)
        blit.fill(buffer: children, range: 0..<children.length, value: 0)
        blit.fill(buffer: counters, range: 0..<counters.length, value: 0)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { [latest] _ in latest.reset() }
        commandBuffer.commit()
    }

    /// Also flattens the height field, which is as much a record of the trail as the texture.
    func clearTrail() {
        clear([trailA, trailB], to: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
        let commandBuffer = context.queue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.fill(buffer: heightField, range: 0..<heightField.length, value: 0)
        blit.endEncoding()
        commandBuffer.commit()
    }

    func clearFood() {
        clear([foodTexture], to: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
    }

    /// Reads the counters after every submitted step has finished. Blocks; for tests.
    @discardableResult
    func readCounters() -> CounterValues {
        context.waitUntilIdle()
        return counters.contents().load(as: Counters.self).values
    }

    private func allocatePool(_ poolSize: Int) {
        precondition(poolSize >= 16 && poolSize.nonzeroBitCount == 1, "poolSize must be a power of two >= 16, got \(poolSize)")
        self.poolSize = poolSize
        actors = context.makeBuffer(length: poolSize * actorBytes, label: "actors")
        children = context.makeBuffer(length: maxChildren * actorBytes, label: "children")
        // Steps already queued hold their own references to the old buffers and
        // keep using the old counters until they finish, so wait for them first.
        context.waitUntilIdle()
        counters.contents().initializeMemory(as: UInt8.self, repeating: 0, count: counters.length)
        latest.reset()
    }

    private func upload<C: Collection>(_ items: C, into buffer: inout MTLBuffer, label: String) {
        let bytes = items.count * MemoryLayout<C.Element>.stride
        if bytes > buffer.length {
            buffer = context.makeBuffer(length: bytes, label: label)
        }
        guard !items.isEmpty else { return }
        let pointer = buffer.contents().bindMemory(to: C.Element.self, capacity: items.count)
        _ = UnsafeMutableBufferPointer(start: pointer, count: items.count).initialize(from: items)
    }

    private func clear(_ textures: [MTLTexture], to color: MTLClearColor) {
        let commandBuffer = context.queue.makeCommandBuffer()!
        for texture in textures {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = color
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
        }
        commandBuffer.commit()
    }
}

/// Carries a value into a completion handler whose access is ordered by the GPU.
nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The most recent step's counters, written from Metal's completion thread.
nonisolated private final class LatestCounters: Sendable {
    private let storage = Mutex(CounterValues())

    var value: CounterValues { storage.withLock { $0 } }

    func store(_ buffer: MTLBuffer) {
        let values = buffer.contents().load(as: Counters.self).values
        storage.withLock { $0 = values }
    }

    func reset() {
        storage.withLock { $0 = CounterValues() }
    }
}

extension Counters {
    nonisolated var values: CounterValues {
        CounterValues(head: head, childCount: childCount, aliveCount: aliveCount, childrenInserted: childrenInserted)
    }
}
