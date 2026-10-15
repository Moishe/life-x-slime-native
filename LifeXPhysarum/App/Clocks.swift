/// Converts frame time into a whole number of fixed-rate steps. After a long
/// stall it runs at most `maxStepsPerAdvance` steps and drops the rest instead
/// of trying to catch up.
struct FixedStepClock {
    var hz: Double
    let maxStepsPerAdvance: Int
    private var accumulatorMs = 0.0

    init(hz: Double, maxStepsPerAdvance: Int) {
        self.hz = hz
        self.maxStepsPerAdvance = maxStepsPerAdvance
    }

    mutating func advance(_ dtMs: Double) -> Int {
        accumulatorMs += dtMs
        let periodMs = 1000 / hz
        let steps = Int((accumulatorMs / periodMs).rounded(.down))
        if steps > maxStepsPerAdvance {
            accumulatorMs = 0
            return maxStepsPerAdvance
        }
        accumulatorMs -= Double(steps) * periodMs
        return steps
    }

    mutating func reset() {
        accumulatorMs = 0
    }
}

/// Counts fixed steps and reports when a tick is due. Drives Life from
/// Physarum steps (rather than the wall clock) while recording a movie.
struct StepTicker {
    private var steps = 0

    mutating func step(stepsPerTick: Int) -> Bool {
        steps += 1
        guard steps >= stepsPerTick else { return false }
        steps = 0
        return true
    }

    mutating func reset() {
        steps = 0
    }
}

/// Counts events and reports them as a per-second rate between samples.
struct RateMeter {
    private var count = 0
    private var lastSampleMs: Double?

    mutating func add(_ n: Int = 1) {
        if n > 0 { count += n }
    }

    mutating func sample(nowMs: Double) -> Double {
        let elapsed = lastSampleMs.map { nowMs - $0 } ?? 0
        let rate = elapsed > 0 ? Double(count) * 1000 / elapsed : 0
        count = 0
        lastSampleMs = nowMs
        return rate
    }
}
