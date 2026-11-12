import Accelerate

/// Guesses the tempo of what's playing. Each short window of sound is compared
/// with the one before; the summed rises across the spectrum (spectral flux)
/// spike on every note and drum hit. The tempo is the beat period at which that
/// onset curve best lines up with itself over the last several seconds,
/// leaning toward ~120 BPM so that half and double tempo don't win by accident.
nonisolated final class TempoDetector {
    static let windowSize = 1024
    static let hopSize = 256
    /// Seconds of onsets each estimate looks at.
    static let history = 8.0
    static let minBPM = 60.0
    static let maxBPM = 200.0
    /// Seconds of sound between estimates.
    static let estimateInterval = 1.0
    /// Multiples of a beat whose correlations add up to its score, and their weights:
    /// half a beat (the eighth notes most music has), then 1 to 4 beats. The half
    /// beat weighs little because offbeats are weaker than beats, and the tempo
    /// at half speed has the real beat as its half beat. (Tuned on 87 Apple Loops.)
    static let multiples = [0.5, 1, 2, 3, 4]
    static let multipleWeights: [Float] = [0.25, 1, 0.5, 0.33, 0.25]

    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let zeros: [Float]
    private var sampleRate = 0.0
    // Samples not yet used by a full hop, and the window that ends with them.
    private var pending: [Float] = []
    private var frame: [Float]
    private var lastSpectrum: [Float] = []
    private var onsets: [Float] = []
    private var hopsSinceEstimate = 0
    private var estimates: [Double] = []

    /// The settled tempo, once the last few estimates agree. Nil until then, or after silence.
    private(set) var tempo: Double?

    init() {
        let n = Self.windowSize
        dft = try! vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        zeros = [Float](repeating: 0, count: n)
        frame = [Float](repeating: 0, count: n)
    }

    /// Onset-curve values per second.
    var onsetRate: Double { sampleRate / Double(Self.hopSize) }

    /// Takes in the samples that followed the last ones. Returns the settled tempo.
    @discardableResult
    func add(_ samples: [Float], sampleRate: Double) -> Double? {
        if sampleRate != self.sampleRate { reset(sampleRate: sampleRate) }
        pending.append(contentsOf: samples)
        let hop = Self.hopSize
        var used = 0
        while pending.count - used >= hop {
            frame.removeFirst(hop)
            frame.append(contentsOf: pending[used..<used + hop])
            used += hop
            addOnset()
        }
        pending.removeFirst(used)
        return tempo
    }

    func reset(sampleRate: Double = 0) {
        self.sampleRate = sampleRate
        pending = []
        frame = [Float](repeating: 0, count: Self.windowSize)
        lastSpectrum = []
        onsets = []
        hopsSinceEstimate = 0
        estimates = []
        tempo = nil
    }

    private func addOnset() {
        let (re, im) = dft.transform(real: vDSP.multiply(frame, window), imaginary: zeros)
        let half = Self.windowSize / 2
        // Log-compressed magnitudes, so quiet notes count as well as loud ones.
        let spectrum = (0..<half).map { k -> Float in
            let magnitude = (re[k] * re[k] + im[k] * im[k]).squareRoot()
            return log1p(1000 * magnitude)
        }
        var flux: Float = 0
        if !lastSpectrum.isEmpty {
            for k in 0..<half { flux += max(0, spectrum[k] - lastSpectrum[k]) }
        }
        lastSpectrum = spectrum
        onsets.append(flux)
        let keep = Int(Self.history * onsetRate)
        if onsets.count > keep { onsets.removeFirst(onsets.count - keep) }

        hopsSinceEstimate += 1
        if hopsSinceEstimate >= Int(Self.estimateInterval * onsetRate) {
            hopsSinceEstimate = 0
            settle(estimate())
        }
    }

    /// The tempo the onsets suggest now, or nil if there's too little to go on.
    func estimate() -> Double? {
        let rate = onsetRate
        let minLag = Int((60 * rate / Self.maxBPM).rounded(.down)), maxLag = Int((60 * rate / Self.minBPM).rounded(.up))
        // Two beats at the slowest tempo, at least.
        guard onsets.count > maxLag * 2 else { return nil }
        // Rise above the local average: the curve's peaks, without its drift.
        let span = max(1, Int(0.1 * rate))
        let rises = onsets.indices.map { i in
            let window = onsets[max(0, i - span)...min(onsets.count - 1, i + span)]
            return max(0, onsets[i] - window.reduce(0, +) / Float(window.count))
        }
        // Widen each peak over ~20 ms, so a beat period between two whole lags still lines up with both.
        let peaks = smoothed(rises, radius: max(1, Int(0.01 * rate)))
        let energy = vDSP.dot(peaks, peaks)
        guard energy > 0 else { return nil }
        // Correlations at every lag up to a bar of the slowest tempo.
        let longest = min(peaks.count - 1, maxLag * Int(Self.multiples.max()!) + 1)
        let correlation = (0...longest).map { lag in
            vDSP.dot(Array(peaks[lag...]), Array(peaks[..<(peaks.count - lag)])) / Float(peaks.count - lag)
        }
        let scores = (minLag...maxLag + 1).map { lag -> (lag: Int, raw: Float, score: Float) in
            let raw = correlation[lag]
            // A real beat lines up again 2, 3 and 4 beats on, and usually halfway; a dotted or triplet pulse mostly doesn't.
            let comb = zip(Self.multiples, Self.multipleWeights).reduce(Float(0)) { sum, m in
                let at = Int((Double(lag) * m.0).rounded())
                return sum + m.1 * (at <= longest ? correlation[at] : 0)
            }
            let bpm = 60 * rate / Double(lag)
            // A log-normal preference one octave wide around 120 BPM.
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120), 2)))
            return (lag, raw, comb * prior)
        }
        guard let best = scores.dropLast().max(by: { $0.score < $1.score }),
              best.raw > 0.05 * energy / Float(peaks.count) else { return nil }
        // Refine between lags with a parabola through the neighbors.
        let i = best.lag - minLag
        let a = i > 0 ? scores[i - 1].raw : best.raw, c = scores[i + 1].raw
        let denominator = a - 2 * best.raw + c
        let offset = denominator < 0 ? Double(max(-0.5, min(0.5, 0.5 * (a - c) / denominator))) : 0
        return 60 * rate / (Double(best.lag) + offset)
    }

    /// `values` averaged with a triangular window `radius` values either side.
    private func smoothed(_ values: [Float], radius: Int) -> [Float] {
        values.indices.map { i in
            var sum: Float = 0, weights: Float = 0
            for j in max(0, i - radius)...min(values.count - 1, i + radius) {
                let w = Float(radius + 1 - abs(j - i))
                sum += values[j] * w
                weights += w
            }
            return sum / weights
        }
    }

    /// Settles on a tempo when the last three estimates agree within 3%; drops it after silence.
    private func settle(_ estimate: Double?) {
        guard let estimate else {
            estimates = []
            tempo = nil
            return
        }
        estimates = (estimates + [estimate]).suffix(3)
        let sorted = estimates.sorted()
        guard sorted.count == 3, sorted[2] / sorted[0] < 1.03 else { return }
        tempo = sorted[1]
    }
}
