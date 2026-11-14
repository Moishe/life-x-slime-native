import Accelerate
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
    /// Radial: what sets each band's distance from the center.
    var distance = AudioDistance.pitch
    /// Radial: the outermost radius, as a fraction of half the grid.
    var radiusScale = 1.0
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
    /// The radial sweep's angle (radians counterclockwise from 3 o'clock) and
    /// its speed in turns a second; nil while nothing sweeps.
    var sweep: (angle: Double, turnsPerSecond: Double)?
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
    /// The lit cells' indices into `lit`, ascending.
    private var litIndices: [Int] = []
    private var glow: [Float] = []
    /// Scratch for turning `glow` into texels.
    private var texelScratch: [Float] = []
    /// Each cell's angle around the center, as the radial sweep measures it (0–2π).
    private var cellAngles: [Double] = []
    /// The cells grouped by angle, `angleBuckets` groups to a turn: bucket b's cells
    /// are `bucketCells[bucketStarts[b]..<bucketStarts[b + 1]]`. The sweep looks up
    /// the wedge it passes over here, instead of testing every cell each frame.
    private var bucketStarts: [Int] = []
    private var bucketCells: [Int32] = []
    private static let angleBuckets = 1024
    /// Each cell's distance from the center, in cells.
    private var cellRadii: [Double] = []
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
            litIndices = []
            glow = [Float](repeating: 0, count: n * 4)
            texelScratch = [Float](repeating: 0, count: n * 4)
            let c = Double(size) / 2
            let offsets = (0..<n).map { (i: Int) -> SIMD2<Double> in
                let x = Double(i % size) + 0.5, y = Double(i / size) + 0.5
                return SIMD2(x - c, c - y)
            }
            cellAngles = offsets.map { d in
                let a = atan2(d.y, d.x)
                return a < 0 ? a + 2 * .pi : a
            }
            cellRadii = offsets.map { ($0 * $0).sum().squareRoot() }
            (bucketStarts, bucketCells) = Self.bucketByAngle(cellAngles)
            bands = []
        }

        let inputLevel = samples.suffix(SpectrumAnalyzer.fftSize).map(abs).max() ?? 0
        peak = max(inputLevel, peak * Self.peakRelease)
        var gain = pow(10, config.gainDB / 20)
        // Automatic gain brings the recent peak to 0.9, just inside the field.
        if config.autoGain { gain *= 0.9 / max(peak, Self.quietestPeak) }
        let scaled = samples.map { $0 * gain }

        // Radial: one band per cell of radius.
        let bandCount = config.style == .radial ? max(1, Int(Double(size) / 2 * config.radiusScale)) : size
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
                                   range: config.rangeDB / SpectrumAnalyzer.dynamicRange, distance: config.distance, radiusScale: config.radiusScale,
                                   sweepFrom: lastAngle, sweepTo: turnsPerSecond > 0 ? sweepTo : lastAngle)
        let canvas = drawAudio(frame, drawing, size: size)

        // A sweep keeps its drawing until it comes round, clearing the wedge it passes over;
        // everything else (alpha: the composite blends the color in by it) leaves a short afterglow.
        let sweeping = config.style == .radial && turnsPerSecond > 0
        let swept = sweepTo - lastAngle
        let fade = sweeping ? Float(pow(Self.sweepFade, swept / (2 * .pi))) : Self.afterglow
        // At the largest grid that's a million cells a frame, so the per-cell work runs
        // in Accelerate or visits only the cells that matter, quick even unoptimized.
        glow.withUnsafeMutableBufferPointer { glow in
            var fade = fade
            vDSP_vsmul(glow.baseAddress! + 3, 4, &fade, glow.baseAddress! + 3, 4, vDSP_Length(n))
            if sweeping { forEachCell(sweptFrom: lastAngle, by: swept) { glow[$0 * 4 + 3] = 0 } }
        }
        var births: [SeedCell] = [], deaths: [SeedCell] = []
        let nowLit = canvas.litIndices.sorted()
        for i in nowLit {
            let color = canvas.cells[i]!
            births.append(SeedCell(x: i % size, y: i / size, color: color))
            glow[i * 4] = color.x; glow[i * 4 + 1] = color.y; glow[i * 4 + 2] = color.z; glow[i * 4 + 3] = 1
        }
        for i in litIndices where canvas.cells[i] == nil {
            deaths.append(SeedCell(x: i % size, y: i / size, color: lit[i]!))
        }
        lit = canvas.cells
        litIndices = nowLit

        var texels = [UInt8](repeating: 0, count: n * 4)
        var low: Float = 0, high: Float = 1, scale: Float = 255, half: Float = 0.5
        vDSP_vclip(glow, 1, &low, &high, &texelScratch, 1, vDSP_Length(n * 4))
        vDSP_vsmsa(texelScratch, 1, &scale, &half, &texelScratch, 1, vDSP_Length(n * 4))
        vDSP_vfixu8(texelScratch, 1, &texels, 1, vDSP_Length(n * 4)) // truncates, so with the half added it rounds

        var update = AudioUpdate(gridSize: size, texels: texels,
                                 litCells: births.count, inputLevel: inputLevel, tempo: tempo,
                                 sweep: sweeping ? (angle, turnsPerSecond) : nil)
        if config.seeding {
            if sweeping {
                // Near the center a cell spans more angle than a frame's sweep, so it stays lit for
                // several frames: it spawns with the chance the sweep has just reached it (the arc
                // swept at its radius, in cells), so actors spread evenly over the disc.
                births = births.filter { rng() < cellRadii[$0.y * size + $0.x] * swept }
            }
            update.actors = birthsToActors(births, config.spawn, rng: rng, maxActors: config.maxActors)
            update.seeds = deathsToFoodSeeds(deaths)
        }
        return update
    }

    /// Calls `body` with each cell whose angle lies in [from, from + by), turning past 2π.
    private func forEachCell(sweptFrom from: Double, by swept: Double, _ body: (Int) -> Void) {
        let buckets = Self.angleBuckets, perRadian = Double(buckets) / (2 * .pi)
        let first = Int(from * perRadian), last = Int(((from + swept) * perRadian).rounded(.up))
        for b in first..<min(last, first + buckets) {
            let bucket = b % buckets
            for k in bucketStarts[bucket]..<bucketStarts[bucket + 1] {
                let i = Int(bucketCells[k])
                if (cellAngles[i] - from + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi) < swept { body(i) }
            }
        }
    }

    /// Groups cells by angle (a counting sort), for `forEachCell(sweptFrom:by:)`.
    private static func bucketByAngle(_ angles: [Double]) -> (starts: [Int], cells: [Int32]) {
        let perRadian = Double(angleBuckets) / (2 * .pi)
        let bucketOf = angles.map { min(angleBuckets - 1, Int($0 * perRadian)) }
        var starts = [Int](repeating: 0, count: angleBuckets + 1)
        for b in bucketOf { starts[b + 1] += 1 }
        for b in 0..<angleBuckets { starts[b + 1] += starts[b] }
        var next = starts, cells = [Int32](repeating: 0, count: angles.count)
        for (i, b) in bucketOf.enumerated() {
            cells[next[b]] = Int32(i)
            next[b] += 1
        }
        return (starts, cells)
    }
}
