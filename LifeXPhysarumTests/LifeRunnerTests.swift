import Dispatch
import Testing
@testable import LifeXPhysarum

@Suite struct LifeRunnerTests {
    let spawn = SpawnSettings(actorsPerBirth: 4, cellSize: 32, minSpeed: 1, life: 100)

    /// Collects updates delivered to the main actor until `count` have arrived.
    @MainActor final class Collector {
        var updates: [LifeRunner.Update] = []
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func receive(_ update: LifeRunner.Update) {
            updates.append(update)
            if let waiter, updates.count >= waiter.count {
                self.waiter = nil
                waiter.continuation.resume()
            }
        }

        func wait(for count: Int) async {
            if updates.count >= count { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }
    }

    @Test func ticksOffTheMainThreadAndDeliversSpawnsAndFood() async {
        let collector = Collector()
        let runner = LifeRunner(size: 64, seed: 1) { collector.receive($0) }
        runner.edit { $0.place(Pattern.named("blinker")!, x: 10, y: 10, quarterTurns: 0) }
        runner.tick(spawn: spawn, maxActors: 1000)
        await collector.wait(for: 2)
        let tick = collector.updates[1]
        #expect(tick.isTick)
        #expect(tick.actors.count == 2 * 4) // a blinker has 2 births per generation
        #expect(tick.seeds.count == 2)
        #expect(tick.organismCount == 1)
        #expect(collector.updates.map(\.sequence) == [1, 2])
        #expect(tick.texels.count == 64 * 64 * 4)
    }

    @Test func skipsTicksWhileOneIsStillRunning() async {
        let collector = Collector()
        let runner = LifeRunner(size: 16, seed: 1) { collector.receive($0) }
        let gate = DispatchSemaphore(value: 0)
        runner.edit { _ in gate.wait() } // holds Life's queue, like a slow tick
        #expect(runner.tick(spawn: spawn, maxActors: 1000))
        #expect(!runner.tick(spawn: spawn, maxActors: 1000))
        #expect(!runner.tick(spawn: spawn, maxActors: 1000))
        gate.signal()
        runner.waitUntilIdle()
        await collector.wait(for: 2)
        #expect(collector.updates.filter(\.isTick).count == 1)
        #expect(runner.tick(spawn: spawn, maxActors: 1000))
    }

    @Test func toggleReturnsTheNewStateSynchronously() async {
        let collector = Collector()
        let runner = LifeRunner(size: 16, seed: 1) { collector.receive($0) }
        #expect(runner.toggle(Cell(x: 3, y: 3)) == true)
        #expect(runner.toggle(Cell(x: 3, y: 3)) == false)
        await collector.wait(for: 2)
        #expect(collector.updates.map(\.organismCount) == [1, 0])
    }

    @Test func newColorsRedrawTheBoardAndColorTheNextTicksSpawns() async {
        let collector = Collector()
        let runner = LifeRunner(size: 16, seed: 1) { collector.receive($0) }
        runner.edit { $0.place(Pattern.named("blinker")!, x: 5, y: 5, quarterTurns: 0) }
        let white: SIMD3<Float> = [1, 1, 1]
        runner.setColors([white])
        await collector.wait(for: 2)
        let redrawn = collector.updates[1]
        #expect(!redrawn.isTick)
        let o = (5 * 16 + 6) * 4 // the blinker's middle cell
        #expect(Array(redrawn.texels[o..<o + 4]) == [255, 255, 255, 255])
        let tick = runner.tickNow(spawn: spawn, maxActors: 1000)
        #expect(tick.actors.allSatisfy { $0.seed == SIMD4(white, 1) })
        #expect(tick.seeds.allSatisfy { $0.color == SIMD4(white, 1) })
    }

    @Test func tickNowFinishesBeforeReturningAndResizeStartsANewEpoch() async {
        let collector = Collector()
        let runner = LifeRunner(size: 16, seed: 1) { collector.receive($0) }
        runner.edit { $0.place(Pattern.named("blinker")!, x: 5, y: 5, quarterTurns: 0) }
        let update = runner.tickNow(spawn: spawn, maxActors: 1000)
        #expect(update.actors.count == 8 && update.epoch == 0)
        runner.resize(32)
        await collector.wait(for: 2)
        #expect(collector.updates.last?.epoch == 1)
        #expect(collector.updates.last?.gridSize == 32)
        #expect(collector.updates.last?.organismCount == 0)
    }
}
