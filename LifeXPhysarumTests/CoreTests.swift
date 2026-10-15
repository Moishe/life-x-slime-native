import CoreGraphics
import Foundation
import Testing
@testable import LifeXPhysarum

func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.z - b.z) <= tolerance
}

@Suite struct ColorMathTests {
    let noLock = HueLock(lockToHsvAngles: 0, hsvAngleOffset: 0, hsvSaturationMultiplier: 1, hsvValueMultiplier: 1)

    @Test func convertsPrimaries() {
        #expect(close(rgb2hsv([1, 0, 0]), [0, 1, 1]))
        #expect(close(rgb2hsv([0, 1, 0]), [1.0 / 3, 1, 1]))
        #expect(close(rgb2hsv([0, 0, 1]), [2.0 / 3, 1, 1]))
    }

    @Test func mapsBlackAndGreyToHue0Saturation0() {
        #expect(close(rgb2hsv([0, 0, 0]), [0, 0, 0]))
        #expect(close(rgb2hsv([0.5, 0.5, 0.5]), [0, 0, 0.5]))
    }

    @Test(arguments: [SIMD3<Float>(0.2, 0.4, 0.6), [0.9, 0.1, 0.3], [0.5, 0.5, 0.1]])
    func roundTrips(rgb: SIMD3<Float>) {
        #expect(close(hsv2rgb(rgb2hsv(rgb)), rgb, 1e-4))
    }

    @Test func distanceUsesCircularHueDifference() {
        #expect(abs(hsvDistance([0.95, 1, 1], [0.05, 1, 1]) - 0.1) < 1e-6)
        #expect(abs(hsvDistance([0, 1, 1], [0, 0, 0]) - 2.0.squareRoot().float) < 1e-6)
    }

    @Test func mixWrapsForwardAndBackwardAcrossRed() {
        #expect(abs(rgb2hsv(hsvMix(hsv2rgb([0.9, 1, 1]), hsv2rgb([0.1, 1, 1]), 0.25)).x - 0.95) < 1e-4)
        #expect(abs(rgb2hsv(hsvMix(hsv2rgb([0.1, 1, 1]), hsv2rgb([0.9, 1, 1]), 0.25)).x - 0.05) < 1e-4)
    }

    @Test func mixInterpolatesDirectlyWhenNoWrapIsShorter() {
        #expect(abs(rgb2hsv(hsvMix(hsv2rgb([0.2, 1, 1]), hsv2rgb([0.4, 1, 1]), 0.5)).x - 0.3) < 1e-4)
        #expect(close(hsvMix([0, 0, 1], [1, 0, 0], 1), [1, 0, 0], 1e-4))
    }

    @Test func dominantColorIsOffWhenLockIs0() {
        #expect(dominantColor([0.2, 0.4, 0.6], noLock) == [0.2, 0.4, 0.6])
    }

    @Test func dominantColorQuantizesHueWithoutFolding() {
        var lock = noLock
        lock.lockToHsvAngles = 4
        #expect(abs(rgb2hsv(dominantColor(hsv2rgb([0.3, 1, 1]), lock)).x - 0.25) < 1e-4)
        #expect(abs(rgb2hsv(dominantColor(hsv2rgb([0.7, 1, 1]), lock)).x - 0.75) < 1e-4)
        lock.hsvAngleOffset = 1
        #expect(abs(rgb2hsv(dominantColor(hsv2rgb([0.3, 1, 1]), lock)).x - 0.25) < 1e-4)
    }

    @Test func dominantColorScalesAndClampsSaturationAndValue() {
        let lock = HueLock(lockToHsvAngles: 4, hsvAngleOffset: 0, hsvSaturationMultiplier: 0.5, hsvValueMultiplier: 2)
        #expect(close(rgb2hsv(dominantColor(hsv2rgb([0.25, 1, 0.4]), lock)), [0.25, 0.5, 0.8], 1e-4))
    }
}

private extension Double {
    var float: Float { Float(self) }
}

@Suite struct RngTests {
    @Test func mulberry32IsDeterministicAndMatchesTheWebVersion() {
        let a = mulberry32(42)
        let b = mulberry32(42)
        for _ in 0..<5 { #expect(a() == b()) }
        // First outputs of mulberry32(1) in JavaScript.
        let r = mulberry32(1)
        #expect(r() == 0.6270739405881613)
        #expect(r() == 0.002735721180215478)
    }

    @Test func differsAcrossSeeds() {
        #expect(mulberry32(1)() != mulberry32(2)())
    }

    @Test func returnsValuesInTheUnitInterval() {
        let r = mulberry32(7)
        for _ in 0..<10000 {
            let v = r()
            #expect(v >= 0 && v < 1)
        }
    }

    @Test func randomNonZeroU32IsOdd() {
        let r = mulberry32(3)
        for _ in 0..<1000 { #expect(randomNonZeroU32(r) % 2 == 1) }
    }
}

@Suite struct ClockTests {
    @Test func emitsOneStepPerPeriodCarryingTheRemainder() {
        var c = FixedStepClock(hz: 10, maxStepsPerAdvance: 4)
        #expect(c.advance(250) == 2)
        #expect(c.advance(40) == 0)
        #expect(c.advance(10) == 1)
    }

    @Test func capsCatchUpAfterALongPause() {
        var c = FixedStepClock(hz: 30, maxStepsPerAdvance: 4)
        #expect(c.advance(10_000) == 4)
        #expect(c.advance(0) == 0)
    }

    @Test func followsAChangedRate() {
        var c = FixedStepClock(hz: 1, maxStepsPerAdvance: 1)
        c.hz = 2
        #expect(c.advance(500) == 1)
    }

    @Test func resetDiscardsAccumulatedTime() {
        var c = FixedStepClock(hz: 10, maxStepsPerAdvance: 4)
        _ = c.advance(90)
        c.reset()
        #expect(c.advance(20) == 0)
    }

    @Test func stepTickerTicksEveryStepsPerTickSteps() {
        var t = StepTicker()
        let ticks = (0..<9).map { _ in t.step(stepsPerTick: 4) }
        #expect(ticks == [false, false, false, true, false, false, false, true, false])
        var one = StepTicker()
        #expect([one.step(stepsPerTick: 1), one.step(stepsPerTick: 1)] == [true, true])
        t.reset()
        #expect((0..<3).map { _ in t.step(stepsPerTick: 3) } == [false, false, true])
    }

    @Test func rateMeterReportsEventsPerSecond() {
        var m = RateMeter()
        #expect(m.sample(nowMs: 1000) == 0)
        m.add(5)
        m.add()
        #expect(m.sample(nowMs: 1500) == 12)
        #expect(m.sample(nowMs: 2500) == 0)
        m.add(-100)
        m.add(3)
        #expect(m.sample(nowMs: 3500) == 3)
    }
}

@Suite struct LayoutTests {
    @Test func actorIs64BytesAtTheShaderOffsets() {
        #expect(MemoryLayout<Actor>.stride == 64)
        #expect(MemoryLayout<Actor>.offset(of: \.pos) == 0)
        #expect(MemoryLayout<Actor>.offset(of: \.dir) == 8)
        #expect(MemoryLayout<Actor>.offset(of: \.speed) == 12)
        #expect(MemoryLayout<Actor>.offset(of: \.seed) == 16)
        #expect(MemoryLayout<Actor>.offset(of: \.color) == 32)
        #expect(MemoryLayout<Actor>.offset(of: \.age) == 48)
        #expect(MemoryLayout<Actor>.offset(of: \.rng) == 60)
        #expect(MemoryLayout<SimParams>.stride == 112)
        #expect(MemoryLayout<FoodSeed>.stride == 32)
        #expect(MemoryLayout<Counters>.stride == 16)
    }

    @Test func simParamsCarriesEveryField() {
        var p = PhysarumParams()
        p.alwaysSpawnFromParent = -1
        p.wrapBounds = false
        p.lookSlices = 3
        p.lockToHsvAngles = 6
        let s = SimParams(p, SimFrame(width: 2048, height: 1024, step: 77, poolSize: 256, maxChildren: 32, spawnCount: 5))
        #expect(s.width == 2048 && s.height == 1024)
        #expect(s.lookSlices == 3 && s.lockToHsvAngles == 6)
        #expect(s.alwaysSpawnFromParent == -1)
        #expect(s.wrapBounds == 0)
        #expect(s.life == 20000)
        #expect(s.lookRadians == Float(1.31))
        #expect([s.step, s.poolSize, s.maxChildren, s.spawnCount] == [77, 256, 32, 5])
    }

    @Test func offersPoolSizesUpToTheBufferLimit() {
        let mib = 1024 * 1024
        #expect(supportedPoolSizes(maxBufferLength: 128 * mib) == (14...21).map { 1 << $0 })
        #expect(supportedPoolSizes(maxBufferLength: 4096 * mib).last == 1 << 22)
    }
}

@Suite struct SettingsTests {
    @Test func hasTheSpecSizesAndDefaults() {
        #expect(fieldSize == 2048)
        #expect(lifeSizes == [64, 128, 256, 512, 1024])
        #expect(lifeSizes.map { cellSize(forLifeSize: $0) } == [32, 16, 8, 4, 2])
        let s = AppSettings()
        #expect(s.playing && !s.foodView)
        #expect(s.lifeHz == 7.5 && s.randomDensity == 0.2 && s.actorsPerBirth == 129)
        #expect(s.spawnMode == .trickle && s.lifeOpacity == 0.05 && s.physarumOpacity == 1)
        #expect(s.poolSize == 1_048_576 && s.lifeSize == 64)
    }
}

@Suite struct SpawnerTests {
    let settings = SpawnSettings(actorsPerBirth: 16, cellSize: 16, minSpeed: 0.3, life: 20000)

    func fakeActors(_ n: Int, tag: Float = 0) -> [Actor] {
        (0..<n).map { i in
            Actor(pos: [tag, Float(i)], dir: 0, speed: 0, seed: [1, 0, 0, 1], color: [1, 0, 0, 1], age: 0, life: 1, alive: 1, rng: 1)
        }
    }

    @Test func spawnsActorsPerBirthInsideEachNewbornCellBlock() {
        let actors = birthsToActors([ColoredCell(x: 3, y: 5, paletteIndex: 2)], settings, rng: mulberry32(1), maxActors: 1000)
        #expect(actors.count == 16)
        for a in actors {
            #expect(a.pos.x >= 48 && a.pos.x < 64)
            #expect(a.pos.y >= 80 && a.pos.y < 96)
            #expect(a.dir >= 0 && a.dir < 2 * .pi)
            #expect(a.speed == 0.3)
            #expect(a.age == 0 && a.life == 20000 && a.alive == 1)
            #expect(a.rng % 2 == 1)
            #expect(a.seed == SIMD4(palette[2], 1))
            #expect(a.color == SIMD4(palette[2], 1))
        }
    }

    @Test func producesBirthsTimesActorsPerBirth() {
        let births = (0..<3).map { ColoredCell(x: $0, y: 0, paletteIndex: $0) }
        #expect(birthsToActors(births, settings, rng: mulberry32(1), maxActors: 1000).count == 48)
    }

    @Test func keepsOnlyTheNewestMaxActors() {
        let births = (0..<100).map { ColoredCell(x: $0, y: 0, paletteIndex: 0) }
        let actors = birthsToActors(births, settings, rng: mulberry32(1), maxActors: 40)
        #expect(actors.count == 40)
        #expect(actors.contains { $0.pos.x >= 99 * 16 })
        #expect(!actors.contains { $0.pos.x < 16 })
    }

    @Test func spawnsNothingWhenActorsPerBirthIs0() {
        var s = settings
        s.actorsPerBirth = 0
        #expect(birthsToActors([ColoredCell(x: 0, y: 0, paletteIndex: 0)], s, rng: mulberry32(1), maxActors: 100).isEmpty)
    }

    @Test func makesOneFoodSeedPerDeathInTheOrganismColor() {
        let seeds = deathsToFoodSeeds([ColoredCell(x: 4, y: 7, paletteIndex: 5)])
        #expect(seeds.count == 1)
        #expect(seeds[0].cell == [4, 7])
        #expect(seeds[0].color == SIMD4(palette[5], 1))
    }

    @Test func burstHandsEverythingToTheNextStep() {
        let s = SpawnScheduler(maxQueued: 1000)
        s.enqueue(fakeActors(50), stepsUntilNextTick: 30)
        #expect(s.takeForStep(limit: .max).count == 50)
        #expect(s.takeForStep(limit: .max).count == 0)
    }

    @Test func burstSpillsOverStepsWhenAStepLimitIsHit() {
        let s = SpawnScheduler(maxQueued: 1000)
        s.enqueue(fakeActors(100), stepsUntilNextTick: 30)
        #expect((0..<3).map { _ in s.takeForStep(limit: 40).count } == [40, 40, 20])
    }

    @Test func trickleSpreadsEvenlyUntilTheNextTick() {
        let s = SpawnScheduler(maxQueued: 1000)
        s.mode = .trickle
        s.enqueue(fakeActors(31), stepsUntilNextTick: 30)
        let counts = (0..<30).map { _ in s.takeForStep(limit: .max).count }
        #expect(counts.reduce(0, +) == 31)
        #expect(counts.max() == 2 && counts.min() == 1)
    }

    @Test func trickleKeepsLeftoversWhenTheNextTickArrivesEarly() {
        let s = SpawnScheduler(maxQueued: 1000)
        s.mode = .trickle
        s.enqueue(fakeActors(30, tag: 1), stepsUntilNextTick: 30)
        for _ in 0..<10 { _ = s.takeForStep(limit: .max) }
        s.enqueue(fakeActors(30, tag: 2), stepsUntilNextTick: 30)
        let total = (0..<30).map { _ in s.takeForStep(limit: .max).count }.reduce(0, +)
        #expect(total == 50)
        #expect(s.pending == 0)
    }

    @Test func dropsTheOldestQueuedActorsBeyondMaxQueued() {
        let s = SpawnScheduler(maxQueued: 10)
        s.enqueue(fakeActors(8, tag: 1), stepsUntilNextTick: 30)
        s.enqueue(fakeActors(8, tag: 2), stepsUntilNextTick: 30)
        let taken = s.takeForStep(limit: .max)
        #expect(taken.count == 10)
        #expect(taken.filter { $0.pos.x == 1 }.count == 2)
        #expect(taken.filter { $0.pos.x == 2 }.count == 8)
    }

    @Test func clearEmptiesTheQueue() {
        let s = SpawnScheduler(maxQueued: 100)
        s.enqueue(fakeActors(5), stepsUntilNextTick: 30)
        s.clear()
        #expect(s.pending == 0)
    }
}

@Suite struct PlacementTests {
    let field = CGRect(x: 200, y: 50, width: 640, height: 640) // 5 points per cell at 128

    @Test func mapsAPointOnAScaledOffsetFieldToItsCell() {
        #expect(cell(at: CGPoint(x: 200, y: 50), in: field, gridSize: 128) == Cell(x: 0, y: 0))
        #expect(cell(at: CGPoint(x: 252, y: 154), in: field, gridSize: 128) == Cell(x: 10, y: 20))
        #expect(cell(at: CGPoint(x: 839.9, y: 689.9), in: field, gridSize: 128) == Cell(x: 127, y: 127))
    }

    @Test func returnsNilOutsideTheField() {
        #expect(cell(at: CGPoint(x: 199, y: 60), in: field, gridSize: 128) == nil)
        #expect(cell(at: CGPoint(x: 840, y: 60), in: field, gridSize: 128) == nil)
        #expect(cell(at: CGPoint(x: 300, y: 690), in: field, gridSize: 128) == nil)
    }

    @Test func fitsASquareFieldCenteredInTheView() {
        #expect(fieldRect(in: CGSize(width: 1000, height: 600)) == CGRect(x: 200, y: 0, width: 600, height: 600))
        #expect(fieldRect(in: CGSize(width: 300, height: 500)) == CGRect(x: 0, y: 100, width: 300, height: 300))
    }

    @Test func ghostOffsetsTheRotatedPatternByTheAnchor() {
        let ghost = ghostCells(pattern("glider"), quarterTurns: 0, anchor: Cell(x: 10, y: 10), gridSize: 128)
        #expect(Set(ghost) == Set(cells([(11, 10), (12, 11), (10, 12), (11, 12), (12, 12)])))
    }

    @Test func ghostClipsCellsThatFallOffTheBoard() {
        #expect(ghostCells(pattern("glider"), quarterTurns: 0, anchor: Cell(x: 126, y: 126), gridSize: 128) == [Cell(x: 127, y: 126)])
    }

    @Test func ghostShowsTheSingleCellUnderTheCursorInPaintMode() {
        #expect(ghostCells(nil, quarterTurns: 0, anchor: Cell(x: 3, y: 4), gridSize: 128) == [Cell(x: 3, y: 4)])
    }

    @Test func lifeTexelsWriteEachLiveCellOpaqueInItsPaletteColor() {
        let t = lifeTexels([ColoredCell(x: 1, y: 2, paletteIndex: 3)], gridSize: 4)
        #expect(t.count == 64)
        let o = (2 * 4 + 1) * 4
        let rgb = palette[3]
        #expect(Array(t[o..<o + 4]) == [UInt8((rgb.x * 255).rounded()), UInt8((rgb.y * 255).rounded()), UInt8((rgb.z * 255).rounded()), 255])
        #expect(Array(t[0..<4]) == [0, 0, 0, 0])
    }

    @Test func ghostTexelsWriteTheGhostColor() {
        let t = ghostTexels([Cell(x: 0, y: 1)], gridSize: 2)
        #expect(Array(t[8..<12]) == ghostRGBA)
        #expect(Array(t[0..<4]) == [0, 0, 0, 0])
    }
}

@Suite struct ExportNameTests {
    let when = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 7, minute: 5, second: 9))!

    @Test func namesSnapshotsWithASharedLocalTimestamp() {
        let base = snapshotBaseName(when)
        #expect(base == "life-x-physarum-2026-10-03-07-05-09")
        #expect(SnapshotPart.allCases.map { snapshotFilename(base: base, part: $0) } == [
            "life-x-physarum-2026-10-03-07-05-09-life.png",
            "life-x-physarum-2026-10-03-07-05-09-physarum.png",
            "life-x-physarum-2026-10-03-07-05-09-mix.png",
        ])
        #expect(movieFilename(when) == "life-x-physarum-2026-10-03-07-05-09.mp4")
    }

    @Test func recordingStatusShowsMovieTimeAndFrames() {
        #expect(recordingStatus(frames: nil) == nil)
        #expect(recordingStatus(frames: 0) == "0.0 s (0 frames)")
        #expect(recordingStatus(frames: 45) == "1.5 s (45 frames)")
    }
}
