import Foundation
import Metal
import Testing
@testable import LifeXPhysarum

private let W = 64

/// Deterministic baseline: no randomness in turning, no reproduction, no food.
/// Sensor geometry is pinned (3 slices, 1 radian, distance 10) because the
/// sensing tests place pixels at those sensor positions.
private func baseParams(_ configure: (inout PhysarumParams) -> Void = { _ in }) -> PhysarumParams {
    var p = PhysarumParams()
    p.directionRandomization = 0
    p.spawnProbability = 0
    p.foodSensitivity = 0
    p.foodExhaustion = 0
    p.minSpeed = 0
    p.maxSpeed = 0
    p.alwaysSpawnFromParent = -1
    p.lookSlices = 3
    p.lookRadians = 1
    p.lookDistance = 10
    configure(&p)
    return p
}

private struct AgentResult {
    var actors: [Actor]
    var children: [Actor]
    var counters: CounterValues
}

private func runAgent(
    _ actors: [Actor], trail: [UInt8]? = nil, food: [UInt8]? = nil, maxChildren: Int = 8,
    _ configure: (inout PhysarumParams) -> Void = { _ in }
) -> AgentResult {
    let passes = PhysarumPasses(context: gpu)
    let params = SimParams(baseParams(configure), SimFrame(
        width: W, height: W, step: 0, poolSize: actors.count, maxChildren: maxChildren, spawnCount: 0))
    let actorBuffer = makeBuffer(actors)
    let children = makeBuffer([Actor](), minimumCount: maxChildren)
    let counterBuffer = countersBuffer()
    let trailTexture = texture(W, trail ?? solidTexels(W, W, [0, 0, 0, 0]))
    let foodTexture = texture(W, food ?? solidTexels(W, W, [0, 0, 0, 0]))
    run {
        passes.encodeAgents($0, params: params, actors: actorBuffer, children: children,
                            counters: counterBuffer, trail: trailTexture, food: foodTexture)
    }
    return AgentResult(
        actors: read(actorBuffer, as: Actor.self, count: actors.count),
        children: read(children, as: Actor.self, count: maxChildren),
        counters: counters(counterBuffer))
}

private func isClose(_ a: Float, _ b: Float, _ tolerance: Float = 1e-3) -> Bool { abs(a - b) <= tolerance }

/// An rng seed whose first draw selects a parent slot other than 0.
private func seedPickingOtherParent(_ pool: Int) -> UInt32 {
    var seed: UInt32 = 1
    while Int(nthRand(seed, 0) * Float(pool)) % pool == 0 { seed += 1 }
    return seed
}

@Suite(.serialized) struct AgentMovementTests {
    @Test func movesAlongItsDirectionAndAgesByOne() {
        let r = runAgent([actor(x: 10, y: 10, speed: 1)]) { $0.directionMomentum = 1; $0.maxSpeed = 1 }
        #expect(isClose(r.actors[0].pos.x, 11) && isClose(r.actors[0].pos.y, 10))
        #expect(isClose(r.actors[0].dir, 0, 1e-5))
        #expect(r.actors[0].age == 1)
        #expect(r.counters.aliveCount == 1)
    }

    @Test func wrapsAcrossTheEdgeWhenWrapBoundsIsOn() {
        let r = runAgent([actor(x: 63.5, y: 10.5, speed: 1)]) { $0.directionMomentum = 1; $0.maxSpeed = 1; $0.wrapBounds = true }
        #expect(isClose(r.actors[0].pos.x, 0.5))
        #expect(r.actors[0].alive == 1)
    }

    @Test func diesLeavingTheFieldWhenWrapBoundsAndRespawnAreOff() {
        let r = runAgent([actor(x: 63.5, y: 10.5, speed: 1)]) { $0.directionMomentum = 1; $0.maxSpeed = 1; $0.wrapBounds = false }
        #expect(r.actors[0].alive == 0)
        #expect(r.counters.aliveCount == 0)
    }

    @Test func ignoresSlotsThatAreNotAlive() {
        let r = runAgent([actor(x: 5, alive: false)])
        #expect(r.actors[0].pos.x == 5)
        #expect(r.counters.aliveCount == 0)
    }

    @Test func countsAliveActorsAcrossManySimdGroups() {
        let actors = (0..<1000).map { i in actor(alive: i % 3 != 0) }
        let r = runAgent(actors)
        #expect(r.counters.aliveCount == 666)
    }
}

@Suite(.serialized) struct AgentRespawnTests {
    @Test func diesOfOldAgeOnlyOnceAgeExceedsLife() {
        let r = runAgent([actor(age: 5, life: 5), actor(age: 6, life: 5)])
        #expect(r.actors[0].alive == 1)
        #expect(r.actors[0].age == 6)
        #expect(r.actors[1].alive == 0)
    }

    @Test func respawnsAtARandomPositionWithItsOwnColor() {
        let rng: UInt32 = 4242
        let r = runAgent([actor(x: 10, y: 10, speed: 2, age: 9, life: 5, rng: rng)]) {
            $0.alwaysSpawnFromParent = 0; $0.spawnRandomOffset = 0; $0.minSpeed = 0.3; $0.maxSpeed = 5
        }
        let a = r.actors[0]
        #expect(a.alive == 1 && a.age == 1)
        // Reset to minSpeed, then nudged by at most 0.01.
        #expect(a.speed >= 0.3 && a.speed <= 0.31)
        // Position draws are x then y.
        #expect(isClose(a.pos.x, nthRand(rng, 0) * Float(W)))
        #expect(isClose(a.pos.y, nthRand(rng, 1) * Float(W)))
        #expect(a.seed.x == 1 && a.seed.y == 0 && a.seed.z == 0)
    }

    @Test func givesARespawnedActorAFreshLifeFromParams() {
        let r = runAgent([actor(age: 9, life: 5)]) { $0.alwaysSpawnFromParent = 0; $0.spawnRandomOffset = 0; $0.life = 777 }
        #expect(r.actors[0].alive == 1 && r.actors[0].age == 1 && r.actors[0].life == 777)
    }

    @Test func respawnsFromALivingParentAdoptingItsPositionDirectionAndColor() {
        let pool = 64
        let green: SIMD4<Float> = [0, 1, 0, 1]
        let actors = [actor(x: 5, y: 5, age: 9, life: 5, rng: seedPickingOtherParent(pool))]
            + (1..<pool).map { _ in actor(x: 50, y: 50, dir: 1, seed: green, color: green) }
        let r = runAgent(actors) { $0.alwaysSpawnFromParent = 1; $0.spawnRandomOffset = 0; $0.directionMomentum = 1 }
        #expect(r.actors[0].alive == 1)
        #expect(isClose(r.actors[0].pos.x, 50) && isClose(r.actors[0].pos.y, 50))
        #expect(isClose(r.actors[0].dir, 1, 1e-4))
        #expect(isClose(r.actors[0].seed.y, 1, 1e-4) && isClose(r.actors[0].seed.x, 0, 1e-4))
    }

    @Test func offsetsAParentRespawnPerpendicularByTheSpawnOffset() {
        let pool = 64
        let actors = [actor(x: 5, y: 5, age: 9, life: 5, rng: seedPickingOtherParent(pool))]
            + (1..<pool).map { _ in actor(x: 50, y: 50, dir: 0) }
        let r = runAgent(actors) { $0.alwaysSpawnFromParent = 1; $0.spawnRandomOffset = 2; $0.directionMomentum = 1 }
        #expect(isClose(r.actors[0].pos.x, 50))
        #expect(isClose(abs(r.actors[0].pos.y - 50), 2))
    }

    @Test func fallsBackToARandomPositionWhenTheChosenParentIsDead() {
        let pool = 64
        let green: SIMD4<Float> = [0, 1, 0, 1]
        let actors = [actor(x: 5, y: 5, age: 9, life: 5, rng: seedPickingOtherParent(pool))]
            + (1..<pool).map { _ in actor(x: 50, y: 50, seed: green, color: green, alive: false) }
        let r = runAgent(actors) { $0.alwaysSpawnFromParent = 1; $0.spawnRandomOffset = 0 }
        let a = r.actors[0]
        #expect(a.alive == 1 && a.age == 1)
        #expect(a.seed.x == 1 && a.seed.y == 0 && a.seed.z == 0)
        #expect(a.pos.x >= 0 && a.pos.x < Float(W) && a.pos.y >= 0 && a.pos.y < Float(W))
    }

    @Test func diesOfExhaustionOnlyWhenFoodAlphaReachesTheThreshold() {
        var food = solidTexels(W, W, [0, 0, 0, 0])
        setPixel(&food, W, 10, 10, [255, 0, 0, 255])
        setPixel(&food, W, 20, 20, [255, 0, 0, 128])
        let r = runAgent([actor(x: 10.5, y: 10.5), actor(x: 20.5, y: 20.5)], food: food) { $0.foodExhaustion = 1 }
        #expect(r.actors[0].alive == 0)
        #expect(r.actors[1].alive == 1)
    }

    @Test func neverDiesOfExhaustionWhenTheThresholdIs0() {
        let r = runAgent([actor(x: 10.5, y: 10.5)], food: solidTexels(W, W, [255, 0, 0, 255])) { $0.foodExhaustion = 0 }
        #expect(r.actors[0].alive == 1)
    }
}

@Suite(.serialized) struct AgentSensingTests {
    func sensorPixel(_ angle: Double) -> (Int, Int) {
        (Int((32 + 10 * cos(angle)).rounded(.down)), Int((32 + 10 * sin(angle)).rounded(.down)))
    }

    @Test func turnsTowardTrailMatchingItsSeedHue() {
        var trail = solidTexels(W, W, [0, 0, 0, 255])
        let (px, py) = sensorPixel(2.0 / 3)
        setPixel(&trail, W, px, py, [255, 0, 0, 255])
        let r = runAgent([actor()], trail: trail) { $0.directionMomentum = 0 }
        #expect(isClose(r.actors[0].dir, 2.0 / 3, 1e-4))
    }

    @Test func prefersFoodOfItsOwnHue() {
        var food = solidTexels(W, W, [0, 0, 0, 0])
        let (rx, ry) = sensorPixel(-1.0 / 3)
        let (gx, gy) = sensorPixel(1.0 / 3)
        setPixel(&food, W, rx, ry, [255, 0, 0, 255])
        setPixel(&food, W, gx, gy, [0, 255, 0, 255])
        let r = runAgent([actor()], food: food) { $0.directionMomentum = 0; $0.foodSensitivity = 1 }
        #expect(isClose(r.actors[0].dir, -1.0 / 3, 1e-4))
    }

    @Test func keepsItsHeadingWhenNothingDistinguishesTheSensors() {
        let r = runAgent([actor(dir: 0.5)]) { $0.directionMomentum = 0 }
        #expect(isClose(r.actors[0].dir, 0.5, 1e-5))
    }

    @Test func blendsTheTrailUnderItTowardItsOwnColorByIntensity() {
        let r = runAgent([actor()], trail: solidTexels(W, W, [0, 0, 255, 255])) { $0.intensity = 0.5; $0.directionMomentum = 1 }
        let expected = hsvMix([0, 0, 1], [1, 0, 0], 0.5)
        let c = r.actors[0].color
        #expect(isClose(c.x, expected.x, 0.01) && isClose(c.y, expected.y, 0.01) && isClose(c.z, expected.z, 0.01))
        #expect(isClose(c.w, 0.5, 1e-5))
    }
}

@Suite(.serialized) struct AgentReproductionTests {
    @Test func queuesOneChildPerAliveActorAtProbability1() {
        let parents = [10, 20, 30, 40].map { actor(x: Float($0)) }
        let r = runAgent(parents) {
            $0.spawnProbability = 1; $0.spawnRandomOffset = 0; $0.directionVariance = 0
            $0.speedVariance = 0; $0.directionMomentum = 1; $0.life = 777
        }
        #expect(r.counters.childCount == 4)
        let born = r.children.filter { $0.alive == 1 }
        #expect(born.count == 4)
        #expect(Set(born.map { Int($0.pos.x.rounded()) }) == [10, 20, 30, 40])
        for c in born {
            #expect(c.age == 0 && c.life == 777)
            #expect(isClose(c.dir, 0, 1e-5))
            #expect(c.seed.x == 1 && c.seed.y == 0 && c.seed.z == 0)
            #expect(c.rng != 0)
        }
    }

    @Test func queuesNoChildrenAtProbability0() {
        #expect(runAgent([actor(), actor()]).counters.childCount == 0)
    }

    @Test func writesNoMoreThanMaxChildren() {
        let r = runAgent([actor(), actor(), actor(), actor()], maxChildren: 2) { $0.spawnProbability = 1 }
        #expect(r.counters.childCount == 4)
        #expect(r.children.count == 2 && r.children.allSatisfy { $0.alive == 1 })
    }
}

@Suite(.serialized) struct InjectTests {
    func inject(poolSize: Int, head: UInt32, spawnXs: [Float], childXs: [Float], childCount: UInt32, maxChildren: Int)
        -> (actors: [Actor], counters: CounterValues)
    {
        let passes = PhysarumPasses(context: gpu)
        let params = SimParams(PhysarumParams(), SimFrame(
            width: 64, height: 64, step: 0, poolSize: poolSize, maxChildren: maxChildren, spawnCount: spawnXs.count))
        let actors = makeBuffer([Actor](), minimumCount: poolSize)
        let spawns = makeBuffer(spawnXs.map { actor(x: $0) })
        let children = makeBuffer(childXs.map { actor(x: $0) }, minimumCount: maxChildren)
        let counterBuffer = countersBuffer(CounterValues(head: head, childCount: childCount))
        run { passes.encodeInject($0, params: params, actors: actors, spawns: spawns, children: children, counters: counterBuffer) }
        return (read(actors, as: Actor.self, count: poolSize), counters(counterBuffer))
    }

    @Test func writesSpawnsAndChildrenAtTheRingHeadWrappingAround() {
        let r = inject(poolSize: 8, head: 6, spawnXs: [100, 101, 102, 103], childXs: [200, 201], childCount: 2, maxChildren: 2)
        // Intra-step order is not deterministic: check which slots changed, not their order.
        let written = [6, 7, 0, 1, 2, 3]
        #expect(Set(written.map { r.actors[$0].pos.x }) == [100, 101, 102, 103, 200, 201])
        for i in written { #expect(r.actors[i].alive == 1) }
        for i in [4, 5] { #expect(r.actors[i].alive == 0) }
        #expect(r.counters.head == 12)
        #expect(r.counters.childrenInserted == 2)
    }

    @Test func ignoresChildrenBeyondMaxChildren() {
        let r = inject(poolSize: 8, head: 0, spawnXs: [], childXs: [200, 201], childCount: 5, maxChildren: 2)
        #expect(r.actors.filter { $0.alive == 1 }.count == 2)
        #expect(r.counters.head == 2 && r.counters.childrenInserted == 2)
    }

    @Test func insertsNothingWhenNothingIsQueued() {
        let r = inject(poolSize: 8, head: 3, spawnXs: [], childXs: [], childCount: 0, maxChildren: 2)
        #expect(r.actors.allSatisfy { $0.alive == 0 })
        #expect(r.counters.head == 3)
    }
}

@Suite(.serialized) struct DiffuseTests {
    func diffuse(_ input: [UInt8], decrement: Float, blurMultiplier: Float) -> RGBAImage {
        let passes = PhysarumPasses(context: gpu)
        let source = texture(W, input)
        let target = texture(W)
        run { passes.encodeDiffuse($0, fade: FadeParams(decrement: decrement, blurMultiplier: blurMultiplier, pad0: 0, pad1: 0),
                                   source: source, target: target) }
        return readTexture(target)
    }

    @Test func onlyFadesWhenBlurMultiplierIs0() {
        var input = solidTexels(W, W, [0, 0, 0, 255])
        setPixel(&input, W, 5, 5, [128, 64, 0, 255])
        let out = diffuse(input, decrement: 0.01, blurMultiplier: 0)
        #expect(near(out.pixel(5, 5), [125, 61, 0, 255]))
        #expect(near(out.pixel(6, 5), [0, 0, 0, 255]))
    }

    @Test func blurs3x3WithAWeightedCenterThenFades() {
        var input = solidTexels(W, W, [0, 0, 0, 255])
        setPixel(&input, W, 10, 10, [255, 0, 0, 255])
        let out = diffuse(input, decrement: 0.01, blurMultiplier: 1)
        // center: (1 + 1) / 10 - 0.01 = 0.19 -> 48; neighbour: 1/10 - 0.01 = 0.09 -> 23
        #expect(near(out.pixel(10, 10), [48, 0, 0, 255]))
        #expect(near(out.pixel(11, 11), [23, 0, 0, 255]))
        #expect(near(out.pixel(12, 10), [0, 0, 0, 255]))
    }

    @Test func treatsPixelsOutsideTheTextureAsZero() {
        let out = diffuse(solidTexels(W, W, [255, 255, 255, 255]), decrement: 0, blurMultiplier: 1)
        // The corner sees 4 of 9 neighbours plus the weighted center: (4 + 1) / 10 = 0.5
        #expect(near(out.pixel(0, 0), [128, 128, 128, 255]))
        #expect(near(out.pixel(30, 30), [255, 255, 255, 255]))
    }
}

@Suite(.serialized) struct FoodTests {
    func seed(_ seeds: [FoodSeed]) -> RGBAImage {
        let passes = PhysarumPasses(context: gpu)
        let target = texture(W, solidTexels(W, W, [0, 0, 0, 0]))
        let buffer = makeBuffer(seeds)
        run { passes.encodeFood($0, target: target, seeds: buffer, seedCount: seeds.count,
                                foodParams: FoodParams(cellSize: 16, foodPerDeath: 0.5, width: Float(W), height: Float(W)), fade: nil) }
        return readTexture(target)
    }

    func foodSeed(_ x: UInt32, _ y: UInt32, _ rgb: SIMD3<Float>) -> FoodSeed {
        FoodSeed(color: SIMD4(rgb, 1), cell: [x, y], pad: .zero)
    }

    @Test func addsColorTimesFoodPerDeathOverExactlyTheCellBlock() {
        let out = seed([foodSeed(1, 2, [1, 0, 0])])
        #expect(near(out.pixel(16, 32), [128, 0, 0, 128]))
        #expect(near(out.pixel(31, 47), [128, 0, 0, 128]))
        for (x, y) in [(15, 32), (32, 32), (16, 31), (16, 48)] { #expect(out.pixel(x, y) == [0, 0, 0, 0]) }
    }

    @Test func accumulatesAdditively() {
        let out = seed([foodSeed(0, 0, [0, 1, 0]), foodSeed(0, 0, [0, 1, 0])])
        #expect(near(out.pixel(3, 3), [0, 255, 0, 255]))
    }

    @Test func fadeSubtractsTheDecrementFromEveryChannel() {
        let passes = PhysarumPasses(context: gpu)
        let target = texture(W, solidTexels(W, W, [100, 50, 0, 200]))
        let empty = makeBuffer([FoodSeed](), minimumCount: 1)
        run { passes.encodeFood($0, target: target, seeds: empty, seedCount: 0, foodParams: FoodParams(),
                                fade: FadeParams(decrement: 0.02, blurMultiplier: 0, pad0: 0, pad1: 0)) }
        #expect(near(readTexture(target).pixel(7, 7), [95, 45, 0, 195]))
    }
}

@Suite(.serialized) struct DepositTests {
    @Test func colorsExactlyThePixelFloorPosOfEachAliveActor() {
        let passes = PhysarumPasses(context: gpu)
        let actors = [actor(x: 5.7, y: 9.2, color: [0, 1, 0, 1]), actor(x: 40.1, y: 3.9, color: [0, 0, 1, 1], alive: false)]
        let params = SimParams(PhysarumParams(), SimFrame(width: W, height: W, step: 0, poolSize: actors.count, maxChildren: 0, spawnCount: 0))
        let buffer = makeBuffer(actors)
        let target = texture(W, solidTexels(W, W, [10, 10, 10, 255]))
        run { passes.encodeDeposit($0, params: params, actors: buffer, target: target) }
        let out = readTexture(target)
        #expect(out.pixel(5, 9) == [0, 255, 0, 255])
        #expect(out.pixel(5, 54) == [10, 10, 10, 255]) // would be hit if y were not flipped
        #expect(out.pixel(40, 3) == [10, 10, 10, 255]) // the dead actor drew nothing
        #expect(stride(from: 1, to: out.pixels.count, by: 4).filter { out.pixels[$0] == 255 }.count == 1)
    }
}
