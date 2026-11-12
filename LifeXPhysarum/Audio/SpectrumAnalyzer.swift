import Accelerate

/// Measures how loud each frequency band is in a window of samples, with
/// bands spaced evenly in pitch (log frequency), as ears hear them.
nonisolated final class SpectrumAnalyzer {
    /// Samples per transform: about 85 ms at 48 kHz, fine enough to tell bass notes apart.
    static let fftSize = 4096
    /// The lowest and highest frequencies the bands cover, in Hz.
    static let lowFrequency = 30.0
    static let highFrequency = 16_000.0
    /// Levels span this many decibels below full scale, mapped to 0–1.
    static let dynamicRange: Float = 60

    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let zeros: [Float]

    init() {
        let n = Self.fftSize
        // Only fails for unsupported sizes, and 4096 is supported.
        dft = try! vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        zeros = [Float](repeating: 0, count: n)
    }

    /// Each bin's amplitude (a full-scale sine is 1) from 0 Hz up to Nyquist,
    /// for the newest `fftSize` samples (zero-padded at the start if fewer).
    func amplitudes(_ samples: [Float]) -> [Float] {
        let n = Self.fftSize
        var input = [Float](repeating: 0, count: n)
        let tail = samples.suffix(n)
        input.replaceSubrange((n - tail.count)..<n, with: tail)
        vDSP.multiply(input, window, result: &input)
        let (re, im) = dft.transform(real: input, imaginary: zeros)
        // A Hann window's sum is n/2, and a sine splits between ± frequencies: amplitude is |X| · 4/n.
        let half = n / 2
        var magnitudes = [Float](repeating: 0, count: half)
        re.withUnsafeBufferPointer { r in
            im.withUnsafeBufferPointer { i in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: r.baseAddress!),
                                            imagp: UnsafeMutablePointer(mutating: i.baseAddress!))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        return vDSP.multiply(4 / Float(n), magnitudes)
    }

    /// `count` band levels from low to high, each 0 (silent, or more than
    /// `dynamicRange` dB down) to 1 (a full-scale sine). A band takes its
    /// loudest bin; bands narrower than a bin read the spectrum at their center.
    func bands(_ samples: [Float], count: Int, sampleRate: Double) -> [Float] {
        bands(amplitudes: amplitudes(samples), count: count, sampleRate: sampleRate).levels
    }

    /// `bands` from amplitudes already measured, with each band's note (0 = C
    /// … 11 = B): its loudest bin's, so a band wider than a semitone takes the
    /// note actually sounding in it, or its center's if it's narrower than a bin.
    func bands(amplitudes amps: [Float], count: Int, sampleRate: Double) -> (levels: [Float], notes: [Int]) {
        let binHz = sampleRate / Double(Self.fftSize)
        var levels: [Float] = [], notes: [Int] = []
        levels.reserveCapacity(count)
        notes.reserveCapacity(count)
        for b in 0..<count {
            let lo = Self.bandEdge(Double(b), count: count, sampleRate: sampleRate) / binHz
            let hi = Self.bandEdge(Double(b + 1), count: count, sampleRate: sampleRate) / binHz
            let first = Int(lo.rounded(.up)), last = min(Int(hi.rounded(.down)), amps.count - 1)
            if first <= last {
                let loudest = (first...last).max { amps[$0] < amps[$1] }!
                levels.append(level(amplitude: amps[loudest]))
                notes.append(noteIndex(frequency: max(1, Double(loudest)) * binHz))
            } else {
                let center = min((lo * hi).squareRoot(), Double(amps.count - 1))
                let k = Int(center), f = Float(center - Double(k))
                levels.append(level(amplitude: amps[k] + (amps[min(k + 1, amps.count - 1)] - amps[k]) * f))
                notes.append(noteIndex(frequency: center * binHz))
            }
        }
        return (levels, notes)
    }

    /// Where band `b` of `count` starts (or, for b + 0.5, its center), in Hz.
    static func bandEdge(_ b: Double, count: Int, sampleRate: Double) -> Double {
        let high = min(highFrequency, sampleRate / 2)
        return lowFrequency * pow(high / lowFrequency, b / Double(count))
    }

    /// How much of the sound is each of the 12 notes, C to B, in any octave:
    /// the power of every bin from `chromaLow` to `chromaHigh` Hz, added to its nearest note.
    /// Bins below that are wider than a semitone; above it, mostly overtones and noise.
    func chroma(amplitudes amps: [Float], sampleRate: Double) -> [Float] {
        let binHz = sampleRate / Double(Self.fftSize)
        var chroma = [Float](repeating: 0, count: 12)
        let first = Int((Self.chromaLow / binHz).rounded(.up)), last = min(amps.count - 1, Int(Self.chromaHigh / binHz))
        guard first <= last else { return chroma }
        for k in first...last {
            chroma[noteIndex(frequency: Double(k) * binHz)] += amps[k] * amps[k]
        }
        return chroma
    }

    static let chromaLow = 100.0
    static let chromaHigh = 5000.0

    /// An amplitude on the 0–1 level scale.
    func level(amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        return min(1, max(0, 1 + 20 * log10(amplitude) / Self.dynamicRange))
    }
}

/// The note nearest `frequency`, as 0 (C) to 11 (B) in any octave, with A at 440 Hz.
nonisolated func noteIndex(frequency: Double) -> Int {
    // Semitones from A4, which is note 9.
    let semitones = Int((12 * log2(frequency / 440)).rounded())
    return ((semitones + 9) % 12 + 12) % 12
}

/// The loudest of the 12 notes in `chroma`, or nil if there's no sound.
nonisolated func dominantNote(_ chroma: [Float]) -> Int? {
    guard let loudest = chroma.indices.max(by: { chroma[$0] < chroma[$1] }), chroma[loudest] > 0 else { return nil }
    return loudest
}

/// Note names, C to B, for showing a 12-color palette as a scale.
nonisolated let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
