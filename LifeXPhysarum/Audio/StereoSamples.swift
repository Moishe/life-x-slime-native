/// Left and right channel samples, oldest first, the same length. A mono
/// source has the same samples in both.
nonisolated struct StereoSamples: Sendable, Equatable {
    var left: [Float]
    var right: [Float]

    init(left: [Float], right: [Float]) {
        precondition(left.count == right.count, "channels differ in length")
        self.left = left
        self.right = right
    }

    init(mono: [Float]) {
        self.init(left: mono, right: mono)
    }

    var count: Int { left.count }

    /// The channels averaged.
    var mono: [Float] { zip(left, right).map { ($0 + $1) / 2 } }

    /// The newest `count` samples of each channel.
    func suffix(_ count: Int) -> StereoSamples {
        StereoSamples(left: Array(left.suffix(count)), right: Array(right.suffix(count)))
    }
}
