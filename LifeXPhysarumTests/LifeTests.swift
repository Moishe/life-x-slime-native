import Testing
@testable import LifeXPhysarum

func cellSet(_ cells: [Cell]) -> Set<Cell> { Set(cells) }
func cells(_ list: [(Int, Int)]) -> [Cell] { list.map { Cell(x: $0.0, y: $0.1) } }

/// Deterministic test RNG that returns the given values in order, repeating.
func sequence(_ values: [Double]) -> Rng {
    var i = 0
    return {
        defer { i += 1 }
        return values[i % values.count]
    }
}

func pattern(_ id: String) -> Pattern { Pattern.named(id)! }

@Suite struct LifeEngineTests {
    func engine(_ w: Int, _ h: Int, _ live: [(Int, Int)]) -> LifeEngine {
        let e = LifeEngine(width: w, height: h)
        for (x, y) in live { e.set(x, y, true) }
        return e
    }

    @Test func defaultsTo128AndStartsEmpty() {
        let e = LifeEngine()
        #expect(e.width == 128 && e.height == 128)
        #expect(e.population() == 0)
    }

    @Test func treatsCellsBeyondTheEdgeAsDead() {
        // A blinker lying along the left edge: the vertical phase would need x = -1.
        let e = engine(10, 10, [(0, 4), (0, 5), (0, 6)])
        _ = e.tick()
        #expect(cellSet(e.liveCells()) == cellSet(cells([(0, 5), (1, 5)])))
    }

    @Test func isBounded() {
        let e = LifeEngine(width: 10, height: 10)
        #expect(!e.get(-1, 0))
        #expect(!e.get(0, 10))
        e.set(-1, 0, true)
        e.set(10, 5, true)
        #expect(e.population() == 0)
    }

    @Test func keepsABlockStable() {
        let e = engine(10, 10, [(4, 4), (5, 4), (4, 5), (5, 5)])
        let r = e.tick()
        #expect(r.births.isEmpty && r.deaths.isEmpty)
        #expect(e.population() == 4)
    }

    @Test func oscillatesABlinkerWithPeriod2() {
        let e = engine(10, 10, [(3, 5), (4, 5), (5, 5)])
        let r1 = e.tick()
        #expect(e.liveCells() == cells([(4, 4), (4, 5), (4, 6)]))
        #expect(r1.births.count == 2 && r1.deaths.count == 2)
        _ = e.tick()
        #expect(e.liveCells() == cells([(3, 5), (4, 5), (5, 5)]))
    }

    @Test func movesAGliderDownRightEvery4Generations() {
        let e = engine(20, 20, [(2, 1), (3, 2), (1, 3), (2, 3), (3, 3)])
        for _ in 0..<4 { _ = e.tick() }
        #expect(cellSet(e.liveCells()) == cellSet(cells([(3, 2), (4, 3), (2, 4), (3, 4), (4, 4)])))
    }

    @Test func clearEmptiesTheBoard() {
        let e = engine(10, 10, [(1, 1), (2, 2)])
        e.clear()
        #expect(e.population() == 0)
    }
}

@Suite struct PatternTests {
    @Test func containsTheFullCuratedPalette() {
        #expect(Pattern.all.map(\.id).sorted() == [
            "acorn", "beacon", "beehive", "blinker", "block", "glider",
            "gosperGun", "loaf", "lwss", "pentadecathlon", "pond",
            "pulsar", "rPentomino", "toad",
        ].sorted())
    }

    @Test func hasCorrectCellCounts() {
        #expect(pattern("block").cells.count == 4)
        #expect(pattern("pulsar").cells.count == 48)
        #expect(pattern("gosperGun").cells.count == 36)
        #expect(pattern("rPentomino").cells.count == 5)
        #expect(pattern("acorn").cells.count == 7)
        #expect(pattern("lwss").cells.count == 9)
    }

    @Test func parsesRowsIntoCells() {
        #expect(cellSet(cellsFromRows(["#.", ".#"])) == cellSet(cells([(0, 0), (1, 1)])))
    }

    @Test func rotatesABlinkerToVertical() {
        #expect(cellSet(rotateCells(cellsFromRows(["###"]), quarterTurns: 1)) == cellSet(cells([(0, 0), (0, 1), (0, 2)])))
    }

    @Test func returnsToTheOriginalShapeAfter4Rotations() {
        let glider = pattern("glider").cells
        #expect(cellSet(rotateCells(glider, quarterTurns: 4)) == cellSet(glider))
    }

    @Test(arguments: ["block", "beehive", "loaf", "pond"])
    func stillLifesAreStable(id: String) {
        let e = LifeEngine(width: 20, height: 20)
        placePattern(e, pattern(id), x: 5, y: 5)
        let before = cellSet(e.liveCells())
        _ = e.tick()
        #expect(cellSet(e.liveCells()) == before)
    }

    @Test(arguments: [("blinker", 2), ("toad", 2), ("beacon", 2), ("pulsar", 3), ("pentadecathlon", 15)])
    func oscillatorsReturnAfterTheirPeriod(id: String, period: Int) {
        let e = LifeEngine(width: 40, height: 40)
        placePattern(e, pattern(id), x: 12, y: 12)
        let before = cellSet(e.liveCells())
        for _ in 0..<period { _ = e.tick() }
        #expect(cellSet(e.liveCells()) == before)
    }

    @Test func gosperGunEmitsItsFirstGliderByGeneration30() {
        let e = LifeEngine(width: 96, height: 96)
        placePattern(e, pattern("gosperGun"), x: 5, y: 5)
        for _ in 0..<30 { _ = e.tick() }
        // The gun (36 cells) has period 30 and has released one 5-cell glider.
        #expect(e.population() == 41)
    }
}

@Suite struct GroupCellsTests {
    @Test func noGroupsForAnEmptyBoard() {
        #expect(groupCells([]).isEmpty)
    }

    @Test func groupsAdjacentCells() {
        let groups = groupCells(cells([(5, 5), (6, 5), (5, 6), (6, 6)]))
        #expect(groups.count == 1)
        #expect(groups[0].count == 4)
    }

    @Test func allowsAOneCellGap() {
        #expect(groupCells(cells([(0, 0), (2, 2)])).count == 1)
    }

    @Test func separatesCellsAtChebyshevDistance3() {
        #expect(groupCells(cells([(0, 0), (3, 3)])).count == 2)
    }

    @Test func separatesTwoDistantBlocks() {
        let groups = groupCells(cells([(2, 2), (3, 2), (2, 3), (3, 3), (20, 20), (21, 20), (20, 21), (21, 21)]))
        #expect(groups.map(\.count) == [4, 4])
    }

    @Test func chainsGaps() {
        #expect(groupCells(cells([(0, 0), (2, 0), (4, 0)])).count == 1)
    }
}

@Suite struct ClusterTrackerTests {
    let blinkerH = cells([(10, 10), (11, 10), (12, 10)])
    let blinkerV = cells([(11, 9), (11, 10), (11, 11)])

    @Test func reportsANewClusterAsBornWithMetrics() {
        let t = ClusterTracker(width: 96, height: 96)
        let ev = t.update(blinkerH)
        #expect(ev.born.count == 1 && ev.updated.isEmpty && ev.died.isEmpty)
        let m = ev.born[0]
        #expect(m.cellCount == 3)
        #expect(m.centroid == Point(x: 11, y: 10))
        #expect(m.aspect == 3)
        #expect(m.delta == 0)
        #expect(m.velocity == 0)
    }

    @Test func keepsABlinkerAsTheSameClusterAcrossPhases() {
        let t = ClusterTracker(width: 96, height: 96)
        let id = t.update(blinkerH).born[0].id
        let ev = t.update(blinkerV)
        #expect(ev.born.isEmpty && ev.died.isEmpty)
        #expect(ev.updated.count == 1)
        let m = ev.updated[0]
        #expect(m.id == id)
        #expect(m.delta == 0)
        #expect(m.velocity == 0)
        #expect(abs(m.aspect - 1.0 / 3) < 1e-9)
    }

    @Test func tracksTwoSeparateClustersIndependently() {
        let t = ClusterTracker(width: 96, height: 96)
        let ev = t.update(cells([(2, 2), (3, 2), (2, 3), (3, 3), (40, 40), (41, 40), (40, 41), (41, 41)]))
        #expect(ev.born.count == 2)
        #expect(Set(ev.born.map(\.id)).count == 2)
    }

    @Test func reportsDeathWhenAClusterDisappears() {
        let t = ClusterTracker(width: 96, height: 96)
        let id = t.update(blinkerH).born[0].id
        let ev = t.update([])
        #expect(ev.died == [id])
        #expect(ev.born.isEmpty && ev.updated.isEmpty)
    }

    @Test func mergeKeepsTheIdWithLargerOverlap() {
        let t = ClusterTracker(width: 96, height: 96)
        let small = [(10, 10), (11, 10), (10, 11), (11, 11)]
        let big = [(20, 10), (21, 10), (22, 10), (20, 11), (21, 11), (22, 11)]
        let ev1 = t.update(cells(small + big))
        #expect(ev1.born.count == 2)
        let bigId = ev1.born.first { $0.cellCount == 6 }!.id
        let smallId = ev1.born.first { $0.cellCount == 4 }!.id
        let ev2 = t.update(cells(small + big + [(13, 10), (15, 10), (17, 10), (18, 10)]))
        #expect(ev2.updated.count == 1)
        #expect(ev2.updated[0].id == bigId)
        #expect(ev2.died == [smallId])
    }

    @Test func splitLetsTheLargestFragmentKeepTheId() {
        let t = ClusterTracker(width: 96, height: 96)
        let frag4 = [(10, 10), (11, 10), (10, 11), (11, 11)]
        let frag6 = [(16, 10), (17, 10), (18, 10), (16, 11), (17, 11), (18, 11)]
        let ev1 = t.update(cells(frag4 + [(13, 10), (14, 10)] + frag6))
        #expect(ev1.born.count == 1)
        let id = ev1.born[0].id
        let ev2 = t.update(cells(frag4 + frag6))
        #expect(ev2.updated.count == 1)
        #expect(ev2.updated[0].id == id)
        #expect(ev2.updated[0].cellCount == 6)
        #expect(ev2.born.count == 1)
        #expect(ev2.born[0].cellCount == 4)
        #expect(ev2.died.isEmpty)
    }

    @Test func equalOverlapMergeTakesTheLowerPrevId() {
        let t = ClusterTracker(width: 96, height: 96)
        let a = [(10, 10), (11, 10)]
        let b = [(20, 10), (21, 10)]
        let ev1 = t.update(cells(a + b))
        let idA = ev1.born.first { $0.centroid.x == 10.5 }!.id
        let idB = ev1.born.first { $0.centroid.x == 20.5 }!.id
        // Same clusters with b listed first, so prev is rebuilt with the higher id first.
        #expect(t.update(cells(b + a)).updated.count == 2)
        let ev3 = t.update(cells([(10, 10), (11, 10), (13, 10), (15, 10), (17, 10), (19, 10), (20, 10), (21, 10)]))
        #expect(ev3.updated.count == 1)
        #expect(ev3.updated[0].id == min(idA, idB))
        #expect(ev3.died == [max(idA, idB)])
    }

    @Test func tracksAMoverViaVelocity() {
        let t = ClusterTracker(width: 96, height: 96)
        let id = t.update(blinkerH).born[0].id
        let ev = t.update(cells([(11, 10), (12, 10), (13, 10)]))
        #expect(ev.updated[0].id == id)
        #expect(abs(ev.updated[0].velocity - 1) < 1e-9)
    }

    @Test func tracksABusy512BoardQuickly() {
        let engine = LifeEngine(width: 512, height: 512)
        let rng = mulberry32(1)
        for y in 0..<512 {
            for x in 0..<512 where rng() < 0.2 { engine.set(x, y, true) }
        }
        let t = ClusterTracker(width: 512, height: 512)
        _ = t.update(engine.liveCells())
        _ = engine.tick()
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = t.update(engine.liveCells()) }
        // Generous: debug builds are unoptimized.
        #expect(elapsed < .seconds(2))
    }
}

@Suite struct PaletteTests {
    @Test func has8FullySaturatedColorsAt45DegreeSteps() {
        #expect(palette.count == 8)
        for (i, rgb) in palette.enumerated() {
            let hsv = rgb2hsv(rgb)
            #expect(abs(hsv.x * 360 - paletteHuesDegrees[i]) < 1e-3)
            #expect(abs(hsv.y - 1) < 1e-5)
            #expect(abs(hsv.z - 1) < 1e-5)
        }
    }

    @Test func givesANewOrganismARandomPaletteIndex() {
        let tracker = ClusterTracker(width: 128, height: 128)
        let p = OrganismPalette(rng: sequence([0.5]))
        let ev = tracker.update(cells([(10, 10), (11, 10), (12, 10)]))
        p.apply(ev)
        #expect(p.index(of: ev.born[0].id) == 4)
    }

    @Test func keepsAColorWhileTheIdSurvives() {
        let tracker = ClusterTracker(width: 128, height: 128)
        let p = OrganismPalette(rng: sequence([0.1, 0.9]))
        let ev1 = tracker.update(cells([(10, 10), (11, 10), (12, 10)]))
        p.apply(ev1)
        let ev2 = tracker.update(cells([(11, 9), (11, 10), (11, 11)]))
        p.apply(ev2)
        #expect(ev2.updated[0].id == ev1.born[0].id)
        #expect(p.index(of: ev1.born[0].id) == 0)
    }

    @Test func forgetsOrganismsThatDied() {
        let tracker = ClusterTracker(width: 128, height: 128)
        let p = OrganismPalette(rng: sequence([0.3]))
        let ev1 = tracker.update(cells([(10, 10), (11, 10), (12, 10)]))
        p.apply(ev1)
        p.apply(tracker.update([]))
        #expect(p.index(of: ev1.born[0].id) == nil)
    }

    @Test func onASplitTheLargestFragmentKeepsTheColor() {
        let tracker = ClusterTracker(width: 128, height: 128)
        let p = OrganismPalette(rng: sequence([0.1, 0.9]))
        let frag4 = [(10, 10), (11, 10), (10, 11), (11, 11)]
        let frag6 = [(16, 10), (17, 10), (18, 10), (16, 11), (17, 11), (18, 11)]
        p.apply(tracker.update(cells(frag4 + [(13, 10), (14, 10)] + frag6)))
        let ev2 = tracker.update(cells(frag4 + frag6))
        p.apply(ev2)
        #expect(p.index(of: ev2.updated[0].id) == 0)
        #expect(p.index(of: ev2.born[0].id) == 7)
    }

    @Test func onAMergeTheSurvivingIdKeepsItsColor() {
        let tracker = ClusterTracker(width: 128, height: 128)
        let p = OrganismPalette(rng: sequence([0.1, 0.6]))
        let small = [(10, 10), (11, 10), (10, 11), (11, 11)]
        let big = [(20, 10), (21, 10), (22, 10), (20, 11), (21, 11), (22, 11)]
        let ev1 = tracker.update(cells(small + big))
        p.apply(ev1)
        let bigId = ev1.born.first { $0.cellCount == 6 }!.id
        let bigColor = p.index(of: bigId)
        let ev2 = tracker.update(cells(small + big + [(13, 10), (15, 10), (17, 10), (18, 10)]))
        p.apply(ev2)
        #expect(ev2.updated[0].id == bigId)
        #expect(p.index(of: bigId) == bigColor)
    }

    @Test func isDeterministicForASeed() {
        func run() -> [Int?] {
            let tracker = ClusterTracker(width: 128, height: 128)
            let p = OrganismPalette(rng: mulberry32(5))
            let ev = tracker.update(cells([(2, 2), (3, 2), (40, 40), (41, 40), (80, 80), (81, 80)]))
            p.apply(ev)
            return ev.born.map { p.index(of: $0.id) }
        }
        #expect(run() == run())
    }
}

@Suite struct LifeWorldTests {
    @Test func colorsBirthsByTheirOrganismAndDeathsByTheOrganismTheyLeft() {
        let world = LifeWorld(width: 128, height: 128, rng: sequence([0.3]))
        world.place(pattern("blinker"), x: 60, y: 64, quarterTurns: 0)
        let result = world.tick()
        #expect(result.births.count == 2)
        #expect(result.deaths.count == 2)
        for c in result.births + result.deaths { #expect(c.paletteIndex == 2) }
    }

    @Test func attributesALoneCellDeathToItsPreviousOrganism() {
        let world = LifeWorld(width: 128, height: 128, rng: sequence([0.7]))
        world.toggle(5, 5)
        let result = world.tick()
        #expect(result.deaths == [ColoredCell(x: 5, y: 5, paletteIndex: 5)])
        #expect(result.births.isEmpty)
        #expect(world.organismCount == 0)
    }

    @Test func keepsSeparateOrganismsInSeparateStableColors() {
        let world = LifeWorld(width: 128, height: 128, rng: sequence([0.0, 0.99]))
        world.place(pattern("block"), x: 10, y: 10, quarterTurns: 0)
        world.place(pattern("block"), x: 100, y: 100, quarterTurns: 0)
        _ = world.tick()
        let byPosition = Dictionary(uniqueKeysWithValues: world.liveCells().map { (Cell(x: $0.x, y: $0.y), $0.paletteIndex) })
        #expect(byPosition[Cell(x: 10, y: 10)] == 0)
        #expect(byPosition[Cell(x: 100, y: 100)] == 7)
        #expect(world.organismCount == 2)
    }

    @Test func editsRetrackImmediatelyWithoutBirthsOrDeaths() {
        let world = LifeWorld(width: 128, height: 128, rng: sequence([0.5]))
        world.toggle(3, 3)
        #expect(world.organismCount == 1)
        #expect(world.liveCells() == [ColoredCell(x: 3, y: 3, paletteIndex: 4)])
        world.clear()
        #expect(world.organismCount == 0)
        #expect(world.latestEvents.died.count == 1)
    }

    @Test func placesAPatternHangingOffTheEdgeWithoutWrapping() {
        let world = LifeWorld(width: 128, height: 128, rng: sequence([0.5]))
        world.place(pattern("glider"), x: 126, y: 126, quarterTurns: 0)
        // Only the glider's top-right cell (127, 126) lands on the board.
        #expect(world.liveCells() == [ColoredCell(x: 127, y: 126, paletteIndex: 4)])
    }

    @Test func randomFillRespectsDensity0And1() {
        let world = LifeWorld(width: 16, height: 16, rng: sequence([0.25, 0.75]))
        world.randomFill(density: 0)
        #expect(world.liveCells().isEmpty)
        world.randomFill(density: 1)
        #expect(world.liveCells().count == 256)
    }

    @Test func exposesTheLatestTrackerEventsAfterATick() {
        let world = LifeWorld(width: 128, height: 128, rng: sequence([0.5]))
        world.place(pattern("blinker"), x: 60, y: 64, quarterTurns: 0)
        let result = world.tick()
        #expect(result.events.updated.count == 1)
        #expect(world.latestEvents.updated.map(\.id) == result.events.updated.map(\.id))
    }

    @Test func setCellPaintsWithoutToggling() {
        let world = LifeWorld(width: 16, height: 16, rng: sequence([0.5]))
        world.setCell(2, 2, alive: true)
        world.setCell(2, 2, alive: true)
        #expect(world.liveCells().count == 1)
        world.setCell(2, 2, alive: false)
        #expect(world.liveCells().isEmpty)
    }
}
