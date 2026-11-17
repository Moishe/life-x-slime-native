import Foundation

/// How sound is drawn on the grid. Every lit cell releases actors.
nonisolated enum AudioStyle: String, Codable, CaseIterable, Sendable {
    /// An oscilloscope trace across the field: time left to right, the signal up and down.
    case waveform
    /// The same trace wrapped around a circle: the signal pushes it in and out.
    case ring
    /// A curve of loudness by pitch: low notes on the left, louder higher up.
    case spectrum
    /// Pitch as distance from the center, swept around like radar (or whole rings,
    /// unswept), the left and right channels half a turn apart.
    case radial
}

/// What picks a lit cell's color from the audio palette: the Life palette at
/// `audioColorCount` colors, one per note of the chromatic scale, C first.
nonisolated enum AudioColors: String, Codable, CaseIterable, Sendable {
    /// How loud it is there: quiet takes the palette's first colors, loud its last.
    case loudness
    /// Its note, in any octave: the band's own, or, for the traces, the sound's loudest.
    case pitch
}

/// What sets a band's distance from the center in the radial view.
nonisolated enum AudioDistance: String, Codable, CaseIterable, Sendable {
    /// Its pitch: low notes in the middle, high at the edge.
    case pitch
    /// Its level: quiet in the middle, loud at the edge.
    case loudness
}

/// Colors in the audio palette: one per note, C to B.
nonisolated let audioColorCount = 12

/// One moment of sound, ready to draw.
nonisolated struct AudioFrame {
    /// The newest samples, mono and gain-scaled, oldest first. Traces show the
    /// last `traceLength`; the samples before give room to find a trigger.
    var samples: [Float]
    var traceLength: Int
    /// Band levels (0–1), low to high, one per column (spectrum) or per unit of
    /// radius (radial). Radial: the left channel's.
    var bands: [Float]
    /// Each band's note (0 = C … 11 = B): the one sounding loudest in it.
    var bandNotes: [Int]
    /// Radial: the right channel's band levels and notes, drawn half a turn from
    /// the left's. Nil draws `bands` for both.
    var rightBands: [Float]? = nil
    var rightBandNotes: [Int]? = nil
    /// The loudest note in the sound, nil when there's none.
    var note: Int?
}

/// What to draw and how.
nonisolated struct AudioDrawing {
    var style: AudioStyle
    var colors: AudioColors
    var palette: [SIMD3<Float>]
    /// Level (0–1) below which nothing lights: a trace's peak, or a band's level.
    var threshold: Float
    /// Spectrum and radial: bands light only within this much (on the 0–1 level
    /// scale) of the loudest band, so what stands out is drawn, not everything over the threshold.
    var range: Float = 1
    /// Radial: what sets each band's distance from the center.
    var distance = AudioDistance.pitch
    /// Radial: the outermost radius, as a fraction of half the grid.
    var radiusScale = 1.0
    /// Radial: the sweep's angle last frame and now, in radians: the left channel's
    /// arm, with the right's half a turn on. Equal means whole rings, the left
    /// channel on the left half and the right on the right.
    var sweepFrom: Double = 0
    var sweepTo: Double = 0
}

/// A size × size grid of lit cells and their colors, top-left origin. Sparse: a
/// frame lights a few hundred cells of up to a million, so only those are stored.
nonisolated struct AudioCanvas {
    let size: Int
    private var colors: [Int: SIMD3<Float>] = [:]
    /// The lit cells' indices (y × size + x), in the order they were first lit.
    private(set) var litIndices: [Int] = []

    init(size: Int) {
        self.size = size
    }

    var litCount: Int { litIndices.count }

    subscript(x: Int, y: Int) -> SIMD3<Float>? { colors[y * size + x] }

    /// The color of the cell at `index` (y × size + x), if it's lit.
    subscript(index index: Int) -> SIMD3<Float>? { colors[index] }

    mutating func plot(_ x: Int, _ y: Int, _ color: SIMD3<Float>) {
        guard x >= 0, y >= 0, x < size, y < size else { return }
        let i = y * size + x
        if colors.updateValue(color, forKey: i) == nil { litIndices.append(i) }
    }

    /// Lights the cells on a straight line from one point to another (in cells),
    /// leaving out the cell at `a` unless the line has no length. A trace drawn
    /// point to point thus leaves each point in its own color.
    mutating func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ color: SIMD3<Float>) {
        let steps = max(1, Int(ceil(max(abs(b.x - a.x), abs(b.y - a.y)))))
        let start = Int(a.x.rounded(.down)) == Int(b.x.rounded(.down)) && Int(a.y.rounded(.down)) == Int(b.y.rounded(.down)) ? 0 : 1
        for i in start...steps {
            let p = a + (b - a) * (Double(i) / Double(steps))
            plot(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)), color)
        }
    }
}

/// Draws `frame` on a canvas of `size` cells.
nonisolated func drawAudio(_ frame: AudioFrame, _ drawing: AudioDrawing, size: Int) -> AudioCanvas {
    var canvas = AudioCanvas(size: size)
    guard !drawing.palette.isEmpty else { return canvas }
    switch drawing.style {
    case .waveform, .ring: drawTrace(frame, drawing, &canvas)
    case .spectrum: drawSpectrum(frame, drawing, &canvas)
    case .radial: drawRadial(frame, drawing, &canvas)
    }
    return canvas
}

/// Whether a band at `level` lights, with the loudest band at `loudest`.
nonisolated func bandLights(_ level: Float, loudest: Float, _ drawing: AudioDrawing) -> Bool {
    level > drawing.threshold && level >= loudest - drawing.range
}

/// The palette color for a position 0–1 along it.
nonisolated func paletteColor(_ palette: [SIMD3<Float>], _ t: Float) -> SIMD3<Float> {
    palette[min(palette.count - 1, max(0, Int(t * Float(palette.count))))]
}

/// The palette color for a note, 0 (C) to 11 (B). Palettes shorter than 12 colors repeat.
nonisolated func noteColor(_ palette: [SIMD3<Float>], _ note: Int) -> SIMD3<Float> {
    palette[note % palette.count]
}

/// Where a trace starts: the first rising zero crossing before its last
/// `traceLength` samples, as an oscilloscope triggers, so a steady tone stands
/// still instead of drifting. The newest samples if there's none.
nonisolated func traceStart(_ samples: [Float], traceLength: Int) -> Int {
    let latest = max(0, samples.count - traceLength)
    guard latest > 1 else { return latest }
    return (1...latest).first { samples[$0 - 1] <= 0 && samples[$0] > 0 } ?? latest
}

private nonisolated func drawTrace(_ frame: AudioFrame, _ drawing: AudioDrawing, _ canvas: inout AudioCanvas) {
    let length = min(frame.traceLength, frame.samples.count)
    guard length > 1 else { return }
    let start = traceStart(frame.samples, traceLength: length)
    let trace = frame.samples[start..<start + length]
    guard trace.map(abs).max()! > drawing.threshold else { return }
    let size = Double(canvas.size)
    let pitchColor = noteColor(drawing.palette, frame.note ?? 0)
    func color(_ v: Float) -> SIMD3<Float> { drawing.colors == .pitch ? pitchColor : paletteColor(drawing.palette, abs(v)) }
    func sample(_ t: Double) -> Float { min(1, max(-1, trace[start + min(length - 1, Int(t * Double(length)))])) }

    switch drawing.style {
    case .ring:
        // Points close enough together that the line between them never skips a cell's worth of curve.
        let points = max(64, canvas.size * 4)
        let center = SIMD2(size / 2, size / 2), radius = size * 0.28
        func point(_ k: Int) -> (SIMD2<Double>, Float) {
            let v = sample(Double(k % points) / Double(points))
            let angle = 2 * Double.pi * Double(k) / Double(points)
            let r = radius * (1 + 0.6 * Double(v))
            return (center + SIMD2(cos(angle), -sin(angle)) * r, v)
        }
        var (previous, _) = point(0)
        for k in 1...points {
            let (p, v) = point(k)
            canvas.line(previous, p, color(v))
            previous = p
        }
    default:
        let mid = (size - 1) / 2
        func point(_ x: Int) -> (SIMD2<Double>, Float) {
            let v = sample(Double(x) / size)
            return (SIMD2(Double(x) + 0.5, mid + 0.5 - Double(v) * mid * 0.95), v)
        }
        var (previous, _) = point(0)
        for x in 0..<canvas.size {
            let (p, v) = point(x)
            canvas.line(previous, p, color(v))
            previous = p
        }
    }
}

private nonisolated func drawSpectrum(_ frame: AudioFrame, _ drawing: AudioDrawing, _ canvas: inout AudioCanvas) {
    let size = canvas.size, bands = frame.bands
    guard let loudest = bands.max() else { return }
    var previous: SIMD2<Double>?
    for x in 0..<size {
        let b = x * bands.count / size
        let level = bands[b]
        guard bandLights(level, loudest: loudest, drawing) else {
            previous = nil
            continue
        }
        let p = SIMD2(Double(x) + 0.5, (Double(size) - 0.5) - Double(level) * Double(size - 1))
        let color = drawing.colors == .pitch ? noteColor(drawing.palette, frame.bandNotes[b]) : paletteColor(drawing.palette, level)
        canvas.line(previous ?? p, p, color)
        previous = p
    }
}

private nonisolated func drawRadial(_ frame: AudioFrame, _ drawing: AudioDrawing, _ canvas: inout AudioCanvas) {
    let right = (bands: frame.rightBands ?? frame.bands, notes: frame.rightBandNotes ?? frame.bandNotes)
    guard let loudest = (frame.bands + right.bands).max() else { return }
    let center = SIMD2(Double(canvas.size) / 2, Double(canvas.size) / 2)
    let maxRadius = Double(canvas.size) / 2 * drawing.radiusScale
    let whole = drawing.sweepFrom == drawing.sweepTo
    // Whole rings: each channel takes half the circle, the left from 12 o'clock round to 6, the right from 6 to 12.
    let leftFrom = whole ? Double.pi / 2 : drawing.sweepFrom
    let span = whole ? Double.pi : drawing.sweepTo - drawing.sweepFrom
    for (bands, notes, from) in [(frame.bands, frame.bandNotes, leftFrom), (right.bands, right.notes, leftFrom + .pi)] {
        for (b, level) in bands.enumerated() where bandLights(level, loudest: loudest, drawing) {
            let r = switch drawing.distance {
            case .pitch: (Double(b) + 0.5) * maxRadius / Double(bands.count)
            case .loudness: Double(level) * (maxRadius - 0.5)
            }
            let color = drawing.colors == .pitch ? noteColor(drawing.palette, notes[b]) : paletteColor(drawing.palette, level)
            // About one point per cell along the arc.
            let steps = max(1, Int(ceil(abs(span) * r)))
            for i in 0...steps {
                let angle = from + span * Double(i) / Double(steps)
                let p = center + SIMD2(cos(angle), -sin(angle)) * r
                canvas.plot(Int(p.x.rounded(.down)), Int(p.y.rounded(.down)), color)
            }
        }
    }
}
