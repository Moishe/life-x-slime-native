import CoreGraphics
import Metal
import Testing
@testable import LifeXPhysarum

private let W = 64

/// Quiet, deterministic settings: actors stand still, never die, never
/// reproduce, deposit exactly their own color, and the trail neither blurs nor fades.
private func makeSim(poolSize: Int = 256) -> PhysarumSim {
    let sim = PhysarumSim(context: gpu, width: W, height: W, poolSize: poolSize, cellSize: 16)
    sim.params.minSpeed = 0
    sim.params.maxSpeed = 0
    sim.params.spawnProbability = 0
    sim.params.alwaysSpawnFromParent = -1
    sim.params.foodExhaustion = 0
    sim.params.fadeDecrement = 0
    sim.params.foodFadeDecrement = 0
    sim.params.blurMultiplier = 0
    sim.params.intensity = 1
    sim.params.life = 1_000_000
    return sim
}

private func spawnsAt(_ n: Int) -> [Actor] {
    (0..<n).map { i in actor(x: Float(i % W) + 0.5, y: Float(i / W) + 0.5) }
}

private func redSeed(_ x: UInt32, _ y: UInt32) -> FoodSeed {
    FoodSeed(color: [1, 0, 0, 1], cell: [x, y], pad: .zero)
}

@Suite(.serialized) struct PhysarumSimTests {
    @Test func injectsSpawnsSoTheyAreAliveOnTheNextStep() throws {
        let sim = makeSim()
        try sim.step(spawns: spawnsAt(10), seeds: [])
        try sim.step(spawns: [], seeds: [])
        let c = sim.readCounters()
        #expect(c.aliveCount == 10 && c.head == 10)
        #expect(sim.latestCounters == c)
    }

    @Test func countsCrowdingAfreshEachStep() throws {
        let sim = makeSim()
        sim.params.spawnProbability = 1
        sim.params.spawnRandomOffset = 0
        sim.params.crowdingLimit = 2
        try sim.step(spawns: (0..<4).map { _ in actor(x: 5.5, y: 5.5) }, seeds: [])
        try sim.step(spawns: [], seeds: [])
        try sim.step(spawns: [], seeds: [])
        // Two children per step from the crowd on one pixel, not two in all.
        #expect(sim.readCounters().childrenInserted == 4)
    }

    @Test func depositsANewActorIntoTheTrail() throws {
        let sim = makeSim()
        try sim.step(spawns: [actor(x: 5.5, y: 7.5, seed: [0, 1, 0, 1], color: [0, 1, 0, 1])], seeds: [])
        sim.readCounters()
        #expect(readTexture(sim.trail).pixel(5, 7) == [0, 255, 0, 255])
    }

    @Test func neverHoldsMoreThanPoolSizeActorsAsTheRingWraps() throws {
        let sim = makeSim(poolSize: 256)
        #expect(sim.maxSpawnsPerStep == 224)
        try sim.step(spawns: spawnsAt(200), seeds: [])
        try sim.step(spawns: spawnsAt(200), seeds: [])
        try sim.step(spawns: [], seeds: [])
        let c = sim.readCounters()
        #expect(c.aliveCount == 256 && c.head == 400)
    }

    @Test func rejectsMoreSpawnsThanAStepCanHold() {
        let sim = makeSim(poolSize: 256)
        #expect(throws: PhysarumSim.StepError.tooManySpawns(max: 224)) {
            try sim.step(spawns: spawnsAt(225), seeds: [])
        }
    }

    @Test func countsReproducedChildrenAsInserted() throws {
        let sim = makeSim()
        sim.params.spawnProbability = 1
        try sim.step(spawns: spawnsAt(10), seeds: [])
        try sim.step(spawns: [], seeds: [])
        #expect(sim.readCounters().childrenInserted == 10)
    }

    @Test func appliesDeathFoodSeedsToTheFoodTexture() throws {
        let sim = makeSim()
        try sim.step(spawns: [], seeds: [redSeed(1, 2)])
        sim.readCounters()
        let p = readTexture(sim.foodTexture).pixel(20, 36)
        #expect(near(p, [128, 0, 0, 128]))
    }

    @Test func setCellSizeMakesFoodCoverTheSmallerBlockAndRaisesTheSeedLimit() throws {
        let sim = makeSim()
        #expect(sim.maxFoodSeedsPerStep == 16)
        sim.setCellSize(4)
        #expect(sim.maxFoodSeedsPerStep == 256)
        try sim.step(spawns: [], seeds: [redSeed(1, 2)])
        sim.readCounters()
        let out = readTexture(sim.foodTexture)
        #expect(near(out.pixel(4, 8), [128, 0, 0, 128]))
        #expect(near(out.pixel(7, 11), [128, 0, 0, 128]))
        #expect(out.pixel(8, 8) == [0, 0, 0, 0])
        #expect(out.pixel(4, 12) == [0, 0, 0, 0])
        let all = (0..<256).map { FoodSeed(color: [0, 1, 0, 1], cell: [UInt32($0 % 16), UInt32($0 / 16)], pad: .zero) }
        #expect(throws: Never.self) { try sim.step(spawns: [], seeds: all) }
    }

    @Test func setCellSizeClearsTheFoodMap() throws {
        let sim = makeSim()
        try sim.step(spawns: [], seeds: [redSeed(0, 0)])
        sim.setCellSize(8)
        sim.readCounters()
        #expect(readTexture(sim.foodTexture).pixel(3, 3) == [0, 0, 0, 0])
    }

    @Test func setPoolSizeClearsActorsAndResetsEveryCounter() throws {
        let sim = makeSim(poolSize: 256)
        sim.params.spawnProbability = 1
        try sim.step(spawns: spawnsAt(10), seeds: [])
        try sim.step(spawns: [], seeds: [])
        sim.setPoolSize(512)
        #expect(sim.latestCounters == CounterValues())
        try sim.step(spawns: [], seeds: [])
        #expect(sim.readCounters() == CounterValues())
        #expect(sim.poolSize == 512)
    }

    @Test func clearActorsEmptiesThePool() throws {
        let sim = makeSim()
        try sim.step(spawns: spawnsAt(10), seeds: [])
        sim.clearActors()
        try sim.step(spawns: [], seeds: [])
        #expect(sim.readCounters().aliveCount == 0)
    }

    @Test func clearTrailAndClearFoodBlankTheirTextures() throws {
        let sim = makeSim()
        try sim.step(spawns: [actor(x: 5.5, y: 7.5, color: [0, 1, 0, 1])], seeds: [redSeed(0, 0)])
        sim.clearTrail()
        sim.clearFood()
        sim.readCounters()
        #expect(readTexture(sim.trail).pixel(5, 7) == [0, 0, 0, 255])
        #expect(readTexture(sim.foodTexture).pixel(3, 3) == [0, 0, 0, 0])
    }

    @Test func blursOnlyEveryBlurIntervalStepsIndependentlyOfFading() throws {
        let sim = makeSim()
        sim.params.blurInterval = 2
        sim.params.blurMultiplier = 1
        sim.params.fadeDecrement = 0
        var trail = solidTexels(W, W, [0, 0, 0, 255])
        setPixel(&trail, W, 20, 20, [255, 255, 255, 255])
        write(sim.trail, trail)
        var centers: [Int] = []
        for _ in 0..<3 {
            try sim.step(spawns: [], seeds: [])
            sim.readCounters()
            centers.append(Int(readTexture(sim.trail).pixel(20, 20)[0]))
        }
        // (255 + 255) / 10 after step 0; unchanged on step 1; blurred again on step 2.
        #expect(abs(centers[0] - 51) <= 1)
        #expect(centers[1] == centers[0])
        #expect(centers[2] < centers[1])
    }

    @Test func fadesTheTrailOnlyEveryFadeIntervalSteps() throws {
        let sim = makeSim()
        sim.params.fadeInterval = 2
        sim.params.fadeDecrement = 0.1
        // A pixel away from the actor, so only fading (never deposit) can change it.
        var trail = solidTexels(W, W, [0, 0, 0, 255])
        setPixel(&trail, W, 20, 20, [255, 255, 255, 255])
        write(sim.trail, trail)

        let green = actor(x: 5.5, y: 7.5, seed: [0, 1, 0, 1], color: [0, 1, 0, 1])
        let faded = [230, 230, 204, 204]
        for step in 0..<4 {
            try sim.step(spawns: step == 0 ? [green] : [], seeds: [])
            sim.readCounters()
            let out = readTexture(sim.trail)
            #expect(out.pixel(5, 7) == [0, 255, 0, 255], "actor pixel after step \(step)")
            #expect(abs(Int(out.pixel(20, 20)[0]) - faded[step]) <= 2, "other pixel after step \(step)")
        }
    }

    @Test func fadesFoodOnlyEveryFoodFadeIntervalSteps() throws {
        let sim = makeSim()
        sim.params.foodFadeInterval = 2
        sim.params.foodFadeDecrement = 0.1
        func alpha() -> Int {
            sim.readCounters()
            return Int(readTexture(sim.foodTexture).pixel(20, 36)[3])
        }
        try sim.step(spawns: [], seeds: [redSeed(1, 2)]) // step 0: seeded, then faded
        let afterFirstFade = alpha()
        #expect(afterFirstFade > 60)
        try sim.step(spawns: [], seeds: []) // step 1: no fade
        #expect(alpha() == afterFirstFade)
        try sim.step(spawns: [], seeds: []) // step 2: fade
        let afterSecondFade = alpha()
        #expect(abs(afterFirstFade - afterSecondFade - 26) <= 2)
        try sim.step(spawns: [], seeds: []) // step 3: no fade
        #expect(alpha() == afterSecondFade)
    }

    @Test func runsAFullSizeFieldWithAMillionActors() throws {
        let sim = PhysarumSim(context: gpu, width: fieldSize, height: fieldSize, poolSize: defaultPoolSize, cellSize: 32)
        let spawns = (0..<sim.maxSpawnsPerStep).map { i in
            actor(x: Float(i % fieldSize) + 0.5, y: Float(i / fieldSize) + 0.5, speed: 1)
        }
        for _ in 0..<20 { try sim.step(spawns: spawns, seeds: []) }
        let c = sim.readCounters()
        #expect(c.head == UInt32(20 * sim.maxSpawnsPerStep) + c.childrenInserted)
        #expect(c.aliveCount > 0)
    }
}

@Suite(.serialized) struct PhysarumSimHeightTests {
    /// The height under field pixel (x, y) once every queued step has finished.
    func heightAt(_ sim: PhysarumSim, _ x: Int, _ y: Int) -> Float {
        sim.readCounters()
        return read(sim.heightField, as: Float.self, count: W * W)[y * W + x]
    }

    @Test func risesUnderAnActorByTheBlurredCountTimesTheGain() throws {
        let sim = makeSim()
        sim.heightGain = 0.9
        sim.heightDecay = 0
        try sim.step(spawns: [actor(x: 5.5, y: 7.5)], seeds: [])
        #expect(abs(heightAt(sim, 5, 7) - 0.1) < 1e-5)
        #expect(abs(heightAt(sim, 6, 8) - 0.1) < 1e-5)
        #expect(heightAt(sim, 9, 9) == 0)
    }

    @Test func decaysEachStep() throws {
        let sim = makeSim()
        sim.heightGain = 0.9
        sim.heightDecay = 0
        try sim.step(spawns: [actor(x: 5.5, y: 7.5)], seeds: [])
        sim.heightGain = 0
        sim.heightDecay = 0.5
        try sim.step(spawns: [], seeds: [])
        #expect(abs(heightAt(sim, 5, 7) - 0.05) < 1e-5)
    }

    @Test func isFlattenedByClearTrail() throws {
        let sim = makeSim()
        sim.heightGain = 0.9
        try sim.step(spawns: [actor(x: 5.5, y: 7.5)], seeds: [])
        sim.clearTrail()
        #expect(heightAt(sim, 5, 7) == 0)
    }
}

@Suite(.serialized) struct CompositorReliefTests {
    /// A solid grey field over `heights`, lit from the +x side at a low angle.
    func shaded(_ heights: [Float], relief: Double = 1) -> RGBAImage {
        let compositor = Compositor(context: gpu, gridSize: 2)
        let field = texture(W, solidTexels(W, W, [128, 128, 128, 255]))
        compositor.setHeight(makeBuffer(heights), fieldWidth: W, fieldHeight: W)
        compositor.relief = ReliefSettings(relief: relief, reliefHeight: 8, lightAngle: 0, lightElevation: 0.5)
        let target = texture(W)
        run { compositor.encode(into: $0, target: target, field: field, physarumOpacity: 1, lifeOpacity: 0, ghostOpacity: 0) }
        return readTexture(target)
    }

    /// A ridge: height rises with x up to column 32, then falls.
    var ridge: [Float] {
        (0..<W * W).map { i in Float(i % W < 32 ? i % W : 63 - i % W) / 32 }
    }

    @Test func leavesAFlatFieldUnchanged() {
        let out = shaded([Float](repeating: 0.5, count: W * W))
        #expect(out.pixel(10, 10) == [128, 128, 128, 255])
        #expect(out.pixel(50, 40) == [128, 128, 128, 255])
    }

    @Test func darkensSlopesFacingAwayFromTheLightAndBrightensThoseFacingIt() {
        let out = shaded(ridge)
        let rising = out.pixel(16, 20)  // faces -x, away from the light
        let falling = out.pixel(48, 20) // faces +x, toward the light
        #expect(rising[0] < 100)
        #expect(falling[0] > 150)
        #expect(rising[0] == rising[1] && rising[1] == rising[2]) // grey stays grey
    }

    @Test func ignoresTheHeightFieldWhenReliefIsZero() {
        #expect(shaded(ridge, relief: 0).pixel(16, 20) == [128, 128, 128, 255])
    }

    @Test func startsFlatBeforeAHeightFieldIsSet() {
        let compositor = Compositor(context: gpu, gridSize: 2)
        compositor.relief = ReliefSettings(relief: 1, reliefHeight: 8, lightAngle: 0, lightElevation: 0.5)
        let target = texture(W)
        run { compositor.encode(into: $0, target: target, field: texture(W, solidTexels(W, W, [128, 128, 128, 255])),
                                physarumOpacity: 1, lifeOpacity: 0, ghostOpacity: 0) }
        #expect(readTexture(target).pixel(10, 10) == [128, 128, 128, 255])
    }
}

@Suite(.serialized) struct CompositorTests {
    func field(_ rgba: [UInt8]) -> MTLTexture { texture(64, solidTexels(64, 64, rgba)) }

    @Test func turnsTheFieldCounterclockwiseLeavingTheCornersItLeavesBlank() {
        let compositor = Compositor(context: gpu, gridSize: 2)
        var life = [UInt8](repeating: 0, count: 16)
        life.replaceSubrange(4..<8, with: [0, 255, 0, 255]) // cell (1, 0), top right
        compositor.setLife(life)
        let grey = field([128, 128, 128, 255])
        func render(_ rotation: Double) -> RGBAImage {
            let target = texture(64)
            run { compositor.encode(into: $0, target: target, field: grey, physarumOpacity: 1, lifeOpacity: 1,
                                    ghostOpacity: 0, rotation: rotation) }
            return readTexture(target)
        }
        let quarter = render(.pi / 2)
        #expect(quarter.pixel(16, 16) == [0, 255, 0, 255]) // top right turned to top left
        #expect(quarter.pixel(48, 16) == [128, 128, 128, 255])
        let eighth = render(.pi / 4)
        #expect(eighth.pixel(1, 1) == [0, 0, 0, 255]) // off the field: the background
        #expect(eighth.pixel(32, 40) == [128, 128, 128, 255])
    }

    func render(_ compositor: Compositor, field: MTLTexture, format: MTLPixelFormat = .rgba8Unorm,
                _ physarum: Double, _ life: Double, _ ghost: Double) -> RGBAImage {
        let target = texture(64, format: format)
        run { compositor.encode(into: $0, target: target, field: field, physarumOpacity: physarum, lifeOpacity: life, ghostOpacity: ghost) }
        return readTexture(target)
    }

    @Test func drawsTheFieldThenLifeCellsThenTheGhost() {
        let compositor = Compositor(context: gpu, gridSize: 2)
        let red = field([255, 0, 0, 255])
        var life = [UInt8](repeating: 0, count: 16)
        life.replaceSubrange(0..<4, with: [0, 255, 0, 255]) // cell (0, 0)
        compositor.setLife(life)
        var ghost = [UInt8](repeating: 0, count: 16)
        ghost.replaceSubrange(12..<16, with: [0, 0, 255, 255]) // cell (1, 1), fully opaque
        compositor.setGhost(ghost)

        var out = render(compositor, field: red, 1, 1, 1)
        #expect(out.pixel(10, 10) == [0, 255, 0, 255])
        #expect(out.pixel(40, 10) == [255, 0, 0, 255])
        #expect(out.pixel(40, 40) == [0, 0, 255, 255])

        out = render(compositor, field: red, 0.5, 0, 1)
        #expect(near(out.pixel(10, 10), [128, 0, 0, 255]))
    }

    @Test func drawsLifeCellsAtTheNewGridSize() {
        let compositor = Compositor(context: gpu, gridSize: 2)
        compositor.setGridSize(4)
        var life = [UInt8](repeating: 0, count: 64)
        life.replaceSubrange(12..<16, with: [0, 255, 0, 255]) // cell (3, 0): pixels x 48..63, y 0..15
        compositor.setLife(life)
        let out = render(compositor, field: field([0, 0, 0, 0]), 1, 1, 1)
        #expect(out.pixel(50, 5) == [0, 255, 0, 255])
        #expect(out.pixel(40, 5) == [0, 0, 0, 255])
        #expect(out.pixel(50, 20) == [0, 0, 0, 255])
    }

    @Test func leavesTheGhostOutAtOpacity0AndRendersIntoOtherFormats() {
        let compositor = Compositor(context: gpu, gridSize: 2)
        let red = field([255, 0, 0, 255])
        var ghost = [UInt8](repeating: 0, count: 16)
        ghost.replaceSubrange(0..<4, with: [0, 0, 255, 255])
        compositor.setGhost(ghost)
        #expect(render(compositor, field: red, 1, 1, 0).pixel(10, 10) == [255, 0, 0, 255])
        #expect(render(compositor, field: red, 1, 1, 1).pixel(10, 10) == [0, 0, 255, 255])
        // bgra8Unorm stores blue first, so the blue ghost reads back as [255, 0, 0].
        #expect(render(compositor, field: red, format: .bgra8Unorm, 1, 1, 1).pixel(10, 10) == [255, 0, 0, 255])
    }

    @Test func capturesLayersWithoutTheGhost() async {
        let compositor = Compositor(context: gpu, gridSize: 2)
        let red = field([255, 0, 0, 255])
        var life = [UInt8](repeating: 0, count: 16)
        life.replaceSubrange(0..<4, with: [0, 255, 0, 255])
        compositor.setLife(life)
        var ghost = [UInt8](repeating: 0, count: 16)
        ghost.replaceSubrange(12..<16, with: [0, 0, 255, 255])
        compositor.setGhost(ghost)

        let images = await compositor.capture(field: red, layers: [(0, 1), (1, 0)], size: 128, context: gpu)
        #expect(images[0].pixels.count == 128 * 128 * 4)
        #expect(images[0].pixel(10, 10) == [0, 255, 0, 255])
        #expect(images[0].pixel(100, 10) == [0, 0, 0, 255])
        #expect(images[0].pixel(100, 100) == [0, 0, 0, 255]) // no ghost
        #expect(images[1].pixel(10, 10) == [255, 0, 0, 255])
        #expect(images[1].pixel(100, 100) == [255, 0, 0, 255])
        #expect(images[1].cgImage?.width == 128)
    }
}
