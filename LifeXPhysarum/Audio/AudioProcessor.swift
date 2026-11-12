import Foundation

/// What the audio pipeline needs from the interface, read once per frame.
nonisolated struct AudioConfig: Sendable {
    var gridSize: Int
    var style = AudioStyle.waveform
    var colors = AudioColors.pitch
    /// The Life palette at `audioColorCount` colors, which lit cells take their colors from.
    var palette: [SIMD3<Float>] = []
    var threshold: Float = 0.1
    /// Spectrum and radial: bands light only within this many decibels of the loudest.
    var rangeDB: Float = SpectrumAnalyzer.dynamicRange
    /// Gain in decibels, applied after automatic gain if that's on.
    var gainDB: Float = 0
    var autoGain = true
    /// Radial sweep tempo: the sweep turns once per bar of `beatsPerTurn` beats. 0 draws whole rings.
    var sweepBPM: Double = 60
    var spawn: SpawnSettings
    var maxActors: Int
    /// False while paused: sound is still drawn, but spawns nothing.
    var seeding: Bool
}

/// One processed moment of sound, for the main actor.
nonisolated struct AudioUpdate: Sendable {
    var gridSize: Int
    /// The drawing, fading behind as it moves, shown in place of the Life layer.
    var texels: [UInt8]
    var actors: [Actor] = []
    var seeds: [FoodSeed] = []
    var litCells = 0
    /// The input's level before gain, 0–1, for the meter.
    var inputLevel: Float = 0
    /// The detected tempo, once it has settled.
    var tempo: Double?
}

/// Turns windows of samples into actors and food, as CameraProcessor does for
/// frames: every lit cell releases actors, and a cell that goes dark leaves
/// food in its last color. Not thread-safe: the audio queue owns it.
nonisolated final class AudioProcessor {
    /// How much of the last drawing's brightness each frame keeps, so movement leaves a short afterglow.
    static let afterglow: Float = 0.8
    /// Bands fall at most to this fraction of their last level each frame, so the spectrum doesn't flicker.
    static let bandRelease: Float = 0.85
    /// Automatic gain's peak follower falls by this each frame (about 4.6 s to halve at 30 frames a second).
    static let peakRelease: Float = 0.995
    /// Automatic gain stops boosting below this peak (−40 dBFS), so it doesn't magnify the noise floor.
    static let quietestPeak: Float = 0.01
    /// Beats in one turn of the radial sweep: a bar of 4/4, so the sweep comes round once a bar.
    static let beatsPerTurn = 4.0
    /// How much of its brightness the radial sweep's drawing keeps after a turn:
    /// it stays until the sweep comes round again, dimming as it ages.
    static let sweepFade = 0.3

    private let analyzer = SpectrumAnalyzer()
    private let tempoDetector = TempoDetector()
    private let rng: Rng
    private var size = 0
    private var lit: [SIMD3<Float>?] = []
    private var glow: [Float] = []
    /// Each cell's angle around the center, as the radial sweep measures it (0–2π).
    private var cellAngles: [Double] = []
    private var bands: [Float] = []
    private var bandNotes: [Int] = []
    private var peak: Float = 0
    private var angle = 0.0

    init(seed: Int) {
        rng = mulberry32(seed)
    }

    /// Processes the newest `samples` (mono), `dt` seconds after the last call;
    /// the last `fresh` of them arrived since then. Nil `fresh` means all of them.
    func process(_ samples: [Float], fresh: Int? = nil, sampleRate: Double, dt: Double, _ config: AudioConfig) -> AudioUpdate {
        let tempo = tempoDetector.add(Array(samples.suffix(fresh ?? samples.count)), sampleRate: sampleRate)
        let size = config.gridSize, n = size * size
        if size != self.size {
            self.size = size
            lit = Array(repeating: nil, count: n)
            glow = [Float](repeating: 0, count: n * 4)
            let c = Double(size) / 2
            cellAngles = (0..<n).map { i in
                let a = atan2(c - (Double(i / size) + 0.5), Double(i % size) + 0.5 - c)
                return a < 0 ? a + 2 * .pi : a
            }
            bands = []
        }

        let inputLevel = samples.suffix(SpectrumAnalyzer.fftSize).map(abs).max() ?? 0
        peak = max(inputLevel, peak * Self.peakRelease)
        var gain = pow(10, config.gainDB / 20)
        // Automatic gain brings the recent peak to 0.9, just inside the field.
        if config.autoGain { gain *= 0.9 / max(peak, Self.quietestPeak) }
        let scaled = samples.map { $0 * gain }

        let bandCount = config.style == .radial ? size / 2 : size
        let amplitudes = analyzer.amplitudes(scaled)
        let (fresh, freshNotes) = analyzer.bands(amplitudes: amplitudes, count: bandCount, sampleRate: sampleRate)
        if bands.count != bandCount { bands = fresh; bandNotes = freshNotes }
        // A band holding its level as it falls keeps its note too, until something louder sounds in it.
        for b in 0..<bandCount where fresh[b] >= bands[b] * Self.bandRelease { bandNotes[b] = freshNotes[b] }
        bands = zip(fresh, bands).map { max($0, $1 * Self.bandRelease) }

        let lastAngle = angle
        let turnsPerSecond = config.sweepBPM / 60 / Self.beatsPerTurn
        if config.style == .radial, turnsPerSecond > 0 {
            angle = (angle + 2 * .pi * turnsPerSecond * dt).truncatingRemainder(dividingBy: 2 * .pi)
        }
        // About 25 ms of trace: a few cycles of a bass note, one or two of a low voice.
        let traceLength = max(2, Int(sampleRate * 0.025))
        let frame = AudioFrame(samples: Array(scaled.suffix(traceLength * 2)), traceLength: traceLength,
                               bands: bands, bandNotes: bandNotes,
                               note: dominantNote(analyzer.chroma(amplitudes: amplitudes, sampleRate: sampleRate)))
        // The sweep is drawn from where it was to where it is, so fast sweeps leave no gaps.
        let sweepTo = angle < lastAngle ? angle + 2 * .pi : angle
        let drawing = AudioDrawing(style: config.style, colors: config.colors, palette: config.palette, threshold: config.threshold,
                                   range: config.rangeDB / SpectrumAnalyzer.dynamicRange,
                                   sweepFrom: lastAngle, sweepTo: turnsPerSecond > 0 ? sweepTo : lastAngle)
        let canvas = drawAudio(frame, drawing, size: size)

        // A sweep keeps its drawing until it comes round, clearing the wedge it passes over;
        // everything else (alpha: the composite blends the color in by it) leaves a short afterglow.
        let sweeping = config.style == .radial && turnsPerSecond > 0
        let swept = sweepTo - lastAngle
        let fade = sweeping ? Float(pow(Self.sweepFade, swept / (2 * .pi))) : Self.afterglow
        var births: [SeedCell] = [], deaths: [SeedCell] = []
        for i in 0..<n {
            if sweeping, (cellAngles[i] - lastAngle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi) < swept {
                glow[i * 4 + 3] = 0
            } else {
                glow[i * 4 + 3] *= fade
            }
            if let color = canvas.cells[i] {
                births.append(SeedCell(x: i % size, y: i / size, color: color))
                glow[i * 4] = color.x; glow[i * 4 + 1] = color.y; glow[i * 4 + 2] = color.z; glow[i * 4 + 3] = 1
            } else if let color = lit[i] {
                deaths.append(SeedCell(x: i % size, y: i / size, color: color))
            }
        }
        lit = canvas.cells

        var update = AudioUpdate(gridSize: size, texels: glow.map { UInt8(min(255, max(0, $0 * 255)).rounded()) },
                                 litCells: births.count, inputLevel: inputLevel, tempo: tempo)
        if config.seeding {
            update.actors = birthsToActors(births, config.spawn, rng: rng, maxActors: config.maxActors)
            update.seeds = deathsToFoodSeeds(deaths)
        }
        return update
    }
}
