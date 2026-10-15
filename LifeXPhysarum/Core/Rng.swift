/// A source of random doubles in [0, 1).
typealias Rng = () -> Double

/// mulberry32: a small seedable PRNG. Bit-for-bit the same sequence as the web
/// version, so a seed gives the same organism colors in both.
nonisolated func mulberry32(_ seed: Int) -> Rng {
    var a = UInt32(truncatingIfNeeded: seed)
    return {
        a &+= 0x6d2b_79f5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}

/// A random UInt32 that is never 0, for seeding the GPU's per-actor xorshift32.
nonisolated func randomNonZeroU32(_ rng: Rng) -> UInt32 {
    UInt32(rng() * 4_294_967_296) | 1
}

/// A seeded RNG that can be restarted with a new seed. Hand out `next` as an
/// `Rng`; holders keep drawing from the current seed's sequence.
nonisolated final class ReseedableRng {
    private var source: Rng

    init(seed: Int) {
        source = mulberry32(seed)
    }

    func reseed(_ seed: Int) {
        source = mulberry32(seed)
    }

    func next() -> Double {
        source()
    }
}
