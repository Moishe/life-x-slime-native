import CoreAudio
import Foundation
import Testing
@testable import LifeXPhysarum

/// `count` samples of a sine at `hz`, peaking at `amplitude`.
func sine(_ hz: Double, amplitude: Float = 1, count: Int = SpectrumAnalyzer.fftSize, sampleRate: Double = 48_000) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
}

let rainbow4: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 1, 1)]

@Suite struct SpectrumAnalyzerTests {
    let analyzer = SpectrumAnalyzer()

    @Test func aFullScaleSineOnABinHasAmplitudeOne() {
        let bin = 86, hz = Double(bin) * 48_000 / Double(SpectrumAnalyzer.fftSize)
        let amps = analyzer.amplitudes(sine(hz))
        #expect(amps.indices.max { amps[$0] < amps[$1] } == bin)
        #expect(abs(amps[bin] - 1) < 0.01)
    }

    @Test func levelsSpanTheDynamicRange() {
        #expect(analyzer.level(amplitude: 1) == 1)
        #expect(analyzer.level(amplitude: 0.001) == 0) // −60 dB
        #expect(abs(analyzer.level(amplitude: 0.0316) - 0.5) < 0.01) // −30 dB
        #expect(analyzer.level(amplitude: 0) == 0)
    }

    @Test func aToneLightsTheBandAtItsPitch() {
        let bands = analyzer.bands(sine(1000), count: 64, sampleRate: 48_000)
        let loudest = bands.indices.max { bands[$0] < bands[$1] }!
        let expected = Int(64 * log(1000 / 30.0) / log(16_000 / 30.0))
        #expect(abs(loudest - expected) <= 1)
        #expect(bands[loudest] > 0.9)
        #expect(bands[0] < 0.3 && bands[63] < 0.3)
    }

    @Test func silenceIsLevelZero() {
        let bands = analyzer.bands([Float](repeating: 0, count: 4096), count: 32, sampleRate: 48_000)
        #expect(bands.allSatisfy { $0 == 0 })
    }

    @Test func frequenciesMapToTheirNearestNote() {
        #expect(noteIndex(frequency: 440) == 9) // A4
        #expect(noteIndex(frequency: 261.63) == 0) // C4
        #expect(noteIndex(frequency: 277.18) == 1) // C♯4
        #expect(noteIndex(frequency: 493.88) == 11) // B4
        // Any octave, and a little out of tune.
        #expect(noteIndex(frequency: 55) == 9 && noteIndex(frequency: 7040) == 9)
        #expect(noteIndex(frequency: 445) == 9 && noteIndex(frequency: 32.7) == 0)
    }

    @Test func aTonesChromaPeaksAtItsNote() {
        let amps = analyzer.amplitudes(sine(392)) // G4
        #expect(dominantNote(analyzer.chroma(amplitudes: amps, sampleRate: 48_000)) == 7)
    }

    @Test func aChordsLoudestNoteWins() {
        // C major, with C loudest.
        let chord = zip(zip(sine(261.63, amplitude: 0.5), sine(329.63, amplitude: 0.25)), sine(392, amplitude: 0.25)).map { $0.0 + $0.1 + $1 }
        let chroma = analyzer.chroma(amplitudes: analyzer.amplitudes(chord), sampleRate: 48_000)
        #expect(dominantNote(chroma) == 0)
        #expect(chroma[4] > chroma[2] && chroma[7] > chroma[9]) // E and G, not their neighbors
    }

    @Test func silenceHasNoNote() {
        let silence = [Float](repeating: 0, count: 4096)
        #expect(dominantNote(analyzer.chroma(amplitudes: analyzer.amplitudes(silence), sampleRate: 48_000)) == nil)
    }
}

@Suite struct AudioDrawingTests {
    func frame(_ samples: [Float], bands: [Float] = [], bandNotes: [Int]? = nil, note: Int? = nil) -> AudioFrame {
        AudioFrame(samples: samples, traceLength: samples.count / 2, bands: bands,
                   bandNotes: bandNotes ?? bands.indices.map { $0 % 12 }, note: note)
    }

    let scale: [SIMD3<Float>] = (0..<12).map { SIMD3(Float($0) / 11, 0, 0) }

    func drawing(_ style: AudioStyle, colors: AudioColors = .loudness, threshold: Float = 0.1) -> AudioDrawing {
        AudioDrawing(style: style, colors: colors, palette: rainbow4, threshold: threshold)
    }

    @Test func traceStartIsTheFirstRisingZeroCrossing() {
        let samples: [Float] = [0.5, 0.2, -0.3, -0.1, 0.4, 0.6, 0.2, -0.2, 0.1]
        #expect(traceStart(samples, traceLength: 4) == 4)
        // None in reach: the newest samples.
        #expect(traceStart([1, 1, 1, 1, 1, 1], traceLength: 3) == 3)
    }

    @Test func aWaveformLightsEveryColumnContinuously() {
        let canvas = drawAudio(frame(sine(200, amplitude: 0.8, count: 2400)), drawing(.waveform), size: 32)
        for x in 0..<32 {
            #expect((0..<32).contains { canvas[x, $0] != nil }, "column \(x)")
        }
        // Neighboring columns' lit runs touch, so the trace has no gaps.
        func rows(_ x: Int) -> [Int] { (0..<32).filter { canvas[x, $0] != nil } }
        for x in 1..<32 {
            #expect(rows(x).contains { r in rows(x - 1).contains { abs($0 - r) <= 1 } })
        }
        // It swings well above and below the middle.
        #expect(canvas.cells.indices.contains { canvas.cells[$0] != nil && $0 / 32 < 6 })
        #expect(canvas.cells.indices.contains { canvas.cells[$0] != nil && $0 / 32 > 25 })
    }

    @Test func aTraceUnderTheThresholdDrawsNothing() {
        let canvas = drawAudio(frame(sine(200, amplitude: 0.05, count: 2400)), drawing(.waveform), size: 32)
        #expect(canvas.litCount == 0)
        let ring = drawAudio(frame(sine(200, amplitude: 0.05, count: 2400)), drawing(.ring), size: 32)
        #expect(ring.litCount == 0)
    }

    @Test func pitchColorsATraceByItsLoudestNote() {
        var d = drawing(.waveform, colors: .pitch)
        d.palette = scale
        let canvas = drawAudio(frame(sine(200, amplitude: 0.8, count: 2400), note: 7), d, size: 16)
        #expect(canvas.litCount > 0 && canvas.cells.compactMap { $0 }.allSatisfy { $0 == scale[7] })
    }

    @Test func aRingCirclesTheCenter() {
        let canvas = drawAudio(frame(sine(200, amplitude: 0.5, count: 2400)), drawing(.ring), size: 64)
        // Lit cells on every side of the center, and none at it.
        #expect(canvas[32, 32] == nil)
        #expect((0..<32).contains { canvas[$0, 32] != nil } && (32..<64).contains { canvas[$0, 32] != nil })
        #expect((0..<32).contains { canvas[32, $0] != nil } && (32..<64).contains { canvas[32, $0] != nil })
    }

    @Test func theSpectrumPutsLoudBandsHigher() throws {
        var bands = [Float](repeating: 0, count: 16)
        bands[3] = 1
        bands[12] = 0.5
        let canvas = drawAudio(frame([], bands: bands), drawing(.spectrum), size: 16)
        #expect(canvas[3, 0] == rainbow4[3])
        let y = try #require((0..<16).first { canvas[12, $0] != nil })
        #expect(abs(y - 8) <= 1)
        #expect(canvas[12, y] == rainbow4[2])
        // Quiet bands light nothing.
        #expect((0..<16).allSatisfy { canvas[0, $0] == nil })
    }

    @Test func pitchColorsEachBandByItsNote() {
        var d = drawing(.spectrum, colors: .pitch)
        d.palette = scale
        let notes = [3, 3, 9, 0, 11, 5, 5, 5, 2, 2, 7, 7, 1, 1, 4, 10]
        let canvas = drawAudio(frame([], bands: [Float](repeating: 0.5, count: 16), bandNotes: notes), d, size: 16)
        let y = (0..<16).first { canvas[0, $0] != nil }!
        for x in 0..<16 { #expect(canvas[x, y] == scale[notes[x]], "column \(x)") }
    }

    @Test func pitchColorsRadialRingsByTheirNote() {
        var d = drawing(.radial, colors: .pitch)
        d.palette = scale
        var bands = [Float](repeating: 0, count: 16)
        bands[10] = 0.8
        let canvas = drawAudio(frame([], bands: bands), d, size: 32)
        #expect(canvas[26, 16] == scale[10])
    }

    @Test func unsweptRadialBandsAreWholeRings() {
        var bands = [Float](repeating: 0, count: 16)
        bands[10] = 0.8
        let canvas = drawAudio(frame([], bands: bands), drawing(.radial), size: 32)
        // Band 10 of 16 sits at radius 10.5 of 16 cells.
        for (x, y) in [(26, 16), (5, 16), (16, 5), (16, 26)] {
            #expect(canvas[x, y] != nil, "(\(x), \(y))")
        }
        #expect(canvas[16, 16] == nil)
    }

    @Test func radiusScaleShrinksTheRadialDrawing() {
        var bands = [Float](repeating: 0, count: 16)
        bands[15] = 0.8 // the outermost band
        var d = drawing(.radial)
        d.radiusScale = 0.5
        let canvas = drawAudio(frame([], bands: bands), d, size: 32)
        // Band 15 of 16 sits at radius 15.5 of 8 cells: 7.75.
        #expect(canvas[23, 16] != nil && canvas[16, 8] != nil)
        #expect((0..<32).allSatisfy { canvas[$0, 2] == nil && canvas[$0, 29] == nil })
    }

    @Test func onlyBandsWithinTheRangeOfTheLoudestLight() {
        var bands = [Float](repeating: 0.5, count: 16)
        bands[3] = 0.9
        bands[12] = 0.7
        var d = drawing(.spectrum)
        d.range = 0.25
        let canvas = drawAudio(frame([], bands: bands), d, size: 16)
        let litColumns = (0..<16).filter { x in (0..<16).contains { canvas[x, $0] != nil } }
        #expect(litColumns == [3, 12])
        d.style = .radial
        #expect(drawAudio(frame([], bands: bands), d, size: 32).cells.compactMap { $0 }.count
                < drawAudio(frame([], bands: bands), drawing(.radial), size: 32).cells.compactMap { $0 }.count / 4)
    }

    @Test func loudnessDistanceDrawsLoudBandsFurtherOut() {
        var bands = [Float](repeating: 0, count: 16)
        bands[2] = 1
        bands[12] = 0.5
        var d = drawing(.radial, colors: .pitch)
        d.palette = scale
        d.distance = .loudness
        let notes = (0..<16).map { $0 % 12 }
        let canvas = drawAudio(frame([], bands: bands, bandNotes: notes), d, size: 32)
        // The loud low band at the edge, the quieter high one halfway, each in its note's color.
        #expect(canvas[31, 16] == scale[2])
        #expect(canvas[23, 16] == scale[0])
        #expect(canvas[16, 16] == nil)
    }

    @Test func aSweepLightsOnlyItsArc() {
        var bands = [Float](repeating: 0, count: 16)
        bands[10] = 0.8
        var d = drawing(.radial)
        d.sweepFrom = 0
        d.sweepTo = 0.3
        let canvas = drawAudio(frame([], bands: bands), d, size: 32)
        #expect(canvas[26, 16] != nil) // angle 0: to the right
        #expect(canvas[5, 16] == nil && canvas[16, 5] == nil)
        #expect(canvas.litCount < 8)
    }
}

@Suite struct AudioProcessorTests {
    func config(_ style: AudioStyle = .waveform, seeding: Bool = true, autoGain: Bool = false) -> AudioConfig {
        AudioConfig(gridSize: 16, style: style, colors: .loudness, palette: rainbow4, threshold: 0.1, gainDB: 0, autoGain: autoGain,
                    sweepBPM: 0, spawn: SpawnSettings(actorsPerBirth: 2, cellSize: 4, minSpeed: 1, life: 100),
                    maxActors: 100_000, seeding: seeding)
    }

    let silence = [Float](repeating: 0, count: 4096)

    @Test func litCellsReleaseActorsEveryFrame() {
        let processor = AudioProcessor(seed: 1)
        let first = processor.process(sine(400, amplitude: 0.8), sampleRate: 48_000, dt: 1 / 30, config())
        let second = processor.process(sine(400, amplitude: 0.8), sampleRate: 48_000, dt: 1 / 30, config())
        #expect(first.litCells >= 16)
        #expect(first.actors.count == first.litCells * 2)
        #expect(second.litCells == first.litCells)
        #expect(second.seeds.isEmpty)
    }

    @Test func cellsThatGoDarkLeaveFoodOnce() {
        let processor = AudioProcessor(seed: 1)
        let lit = processor.process(sine(400, amplitude: 0.8), sampleRate: 48_000, dt: 1 / 30, config())
        let dark = processor.process(silence, sampleRate: 48_000, dt: 1 / 30, config())
        #expect(dark.litCells == 0 && dark.actors.isEmpty)
        #expect(dark.seeds.count == lit.litCells)
        #expect(processor.process(silence, sampleRate: 48_000, dt: 1 / 30, config()).seeds.isEmpty)
    }

    @Test func theDrawingFadesBehindItself() {
        let processor = AudioProcessor(seed: 1)
        let lit = processor.process(sine(400, amplitude: 0.8), sampleRate: 48_000, dt: 1 / 30, config())
        let dark = processor.process(silence, sampleRate: 48_000, dt: 1 / 30, config())
        let i = stride(from: 3, to: lit.texels.count, by: 4).first { lit.texels[$0] == 255 }!
        #expect(dark.texels[i] == UInt8((255 * AudioProcessor.afterglow).rounded()))
        #expect(dark.texels[i - 3...i - 1] == lit.texels[i - 3...i - 1])
    }

    @Test func pausedSoundIsDrawnButSpawnsNothing() {
        let processor = AudioProcessor(seed: 1)
        let update = processor.process(sine(400, amplitude: 0.8), sampleRate: 48_000, dt: 1 / 30, config(seeding: false))
        #expect(update.litCells > 0 && update.actors.isEmpty)
    }

    @Test func autoGainLiftsQuietSoundOverTheThreshold() {
        let quiet = sine(400, amplitude: 0.05)
        #expect(AudioProcessor(seed: 1).process(quiet, sampleRate: 48_000, dt: 1 / 30, config()).litCells == 0)
        let update = AudioProcessor(seed: 1).process(quiet, sampleRate: 48_000, dt: 1 / 30, config(autoGain: true))
        #expect(update.litCells >= 16)
        #expect(abs(update.inputLevel - 0.05) < 0.001)
    }

    @Test func autoGainDoesntMagnifyTheNoiseFloor() {
        let hiss = sine(400, amplitude: 0.0005)
        #expect(AudioProcessor(seed: 1).process(hiss, sampleRate: 48_000, dt: 1 / 30, config(autoGain: true)).litCells == 0)
    }

    @Test func theSweepKeepsItsDrawingUntilItComesRound() throws {
        var c = config(.radial)
        c.sweepBPM = 60
        let processor = AudioProcessor(seed: 1)
        // A quarter turn a second: the first quarter second draws a sixteenth of the way round, at angle 0 (the right).
        let drawn = processor.process(sine(1000), sampleRate: 48_000, dt: 0.25, c)
        let alpha = { (u: AudioUpdate, x: Int, y: Int) in u.texels[(y * 16 + x) * 4 + 3] }
        let x = try #require((8..<16).first { alpha(drawn, $0, 8) == 255 })
        // A quarter turn later, silent, it's still there, dimmed by a quarter turn's fade.
        var later = drawn
        for _ in 0..<4 { later = processor.process(silence, sampleRate: 48_000, dt: 0.25, c) }
        let expected = 255 * pow(AudioProcessor.sweepFade, 1.0 / 4)
        #expect(abs(Double(alpha(later, x, 8)) - expected) < 4)
        // Once the sweep comes round again, it's cleared.
        for _ in 0..<12 { later = processor.process(silence, sampleRate: 48_000, dt: 0.25, c) }
        #expect(alpha(later, x, 8) == 0)
    }

    @Test func theSweepSpawnsEvenlyOverTheDisc() {
        var c = config(.radial)
        c.gridSize = 32
        c.sweepBPM = 60
        c.rangeDB = 60
        let processor = AudioProcessor(seed: 1)
        let rng = mulberry32(7)
        // Noise lights every band; a turn takes 4 s at 60 BPM, 120 frames.
        var inner = 0, outer = 0
        for _ in 0..<120 {
            let noise = (0..<4096).map { _ in Float(rng() - 0.5) }
            for a in processor.process(noise, sampleRate: 48_000, dt: 1 / 30, c).actors {
                let d = a.pos / 4 - 16, r = (d * d).sum().squareRoot()
                if r < 6 { inner += 1 } else if r >= 9, r < 15 { outer += 1 }
            }
        }
        // Actors per unit area, inner disc against the outer ring.
        let ratio = (Double(inner) / (36 * .pi)) / (Double(outer) / ((225 - 81) * .pi))
        #expect(inner > 0 && ratio > 0.6 && ratio < 1.6, "inner \(inner), outer \(outer), ratio \(ratio)")
    }

    @Test func theRadialSweepTurnsWithTime() {
        var c = config(.radial)
        c.sweepBPM = 60
        let processor = AudioProcessor(seed: 1)
        // A bar of 4 beats per turn at 60 BPM is a quarter turn a second; in a quarter second, a sixteenth of the way round.
        let update = processor.process(sine(1000), sampleRate: 48_000, dt: 0.25, c)
        let whole = AudioProcessor(seed: 1).process(sine(1000), sampleRate: 48_000, dt: 0.25, config(.radial))
        #expect(update.litCells > 0 && update.litCells < whole.litCells / 4)
    }
}

@Suite struct SampleRingTests {
    @Test func latestWrapsAround() {
        var ring = SampleRing(capacity: 4)
        ring.append([1, 2, 3, 4, 5, 6] as [Float])
        #expect(ring.latest(4) == [3, 4, 5, 6])
        #expect(ring.latest(2) == [5, 6])
        #expect(ring.latest(10) == [3, 4, 5, 6])
    }

    /// Mixes `buffers` (each a list of interleaved frames with `channels` channels) through a ring.
    func mono(_ buffers: [(channels: Int, samples: [Float])]) -> [Float] {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        let data = buffers.map { b in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: b.samples.count)
            p.initialize(from: b.samples, count: b.samples.count)
            return p
        }
        defer {
            data.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (i, b) in buffers.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: UInt32(b.channels), mDataByteSize: UInt32(b.samples.count * 4), mData: data[i])
        }
        var ring = SampleRing(capacity: 3)
        ring.appendMono(list)
        return ring.latest(3)
    }

    @Test func interleavedChannelsMixToMono() {
        #expect(mono([(2, [1, 0, 0, 1, 0.5, -0.5])]) == [0.5, 0.5, 0])
    }

    @Test func separateChannelsMixToMono() {
        #expect(mono([(1, [1, 0, 0.5]), (1, [0, 1, -0.5])]) == [0.5, 0.5, 0])
    }

    @Test func aSavedSweepSpeedBecomesATempo() throws {
        let saved = try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"sweepSpeed":0.5}"#.utf8))
        #expect(saved.sweepBPM == 120)
        let encoded = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(AudioSettings.self, from: encoded) == saved)
    }

    @Test func audioSettingsFromBeforeAFieldExistedKeepTheDefault() throws {
        let saved = try JSONDecoder().decode(AudioSettings.self, from: Data(#"{"style":"radial"}"#.utf8))
        var expected = AudioSettings()
        expected.style = .radial
        #expect(saved == expected)
    }
}

@Suite struct TempoDetectorTests {
    /// `seconds` of a drum pattern at `bpm`: a kick on every beat and a hi-hat between, over quiet noise.
    func drums(bpm: Double, seconds: Double = 12, sampleRate: Double = 48_000) -> [Float] {
        let rng = mulberry32(7)
        let beat = 60 / bpm
        return (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            let sinceBeat = t.truncatingRemainder(dividingBy: beat)
            let sinceHat = (t + beat / 2).truncatingRemainder(dividingBy: beat)
            let noise = Float(rng() * 2 - 1)
            let kick = Float(sin(2 * .pi * 55 * sinceBeat) * exp(-sinceBeat * 18))
            let hat = noise * Float(exp(-sinceHat * 60)) * 0.3
            return 0.6 * kick + hat + noise * 0.002
        }
    }

    /// Feeds `samples` in 30-a-second chunks, as AudioSource does. Returns the settled tempo.
    func detect(_ samples: [Float], sampleRate: Double = 48_000) -> Double? {
        let detector = TempoDetector()
        let chunk = Int(sampleRate / 30)
        for start in stride(from: 0, to: samples.count, by: chunk) {
            detector.add(Array(samples[start..<min(samples.count, start + chunk)]), sampleRate: sampleRate)
        }
        return detector.tempo
    }

    @Test(arguments: [90.0, 120, 128, 150])
    func findsTheTempoOfADrumPattern(bpm: Double) throws {
        let tempo = try #require(detect(drums(bpm: bpm)))
        #expect(abs(tempo - bpm) < 1.5, "\(tempo)")
    }

    @Test func worksAtOtherSampleRates() throws {
        let tempo = try #require(detect(drums(bpm: 110, sampleRate: 44_100), sampleRate: 44_100))
        #expect(abs(tempo - 110) < 1.5, "\(tempo)")
    }

    @Test func silenceHasNoTempo() {
        #expect(detect([Float](repeating: 0, count: 48_000 * 10)) == nil)
    }

    @Test func itNeedsSeveralSecondsToSettle() {
        #expect(detect(drums(bpm: 120, seconds: 2)) == nil)
    }

    @Test func followsATempoChange() throws {
        let tempo = try #require(detect(drums(bpm: 100, seconds: 10) + drums(bpm: 140, seconds: 14)))
        #expect(abs(tempo - 140) < 1.5, "\(tempo)")
    }

    @Test func theProcessorReportsTheTempo() throws {
        let processor = AudioProcessor(seed: 1)
        let samples = drums(bpm: 120), chunk = 1600
        var update: AudioUpdate?
        var c = AudioConfig(gridSize: 16, palette: rainbow4, spawn: SpawnSettings(actorsPerBirth: 1, cellSize: 4, minSpeed: 1, life: 100),
                            maxActors: 1000, seeding: false)
        c.style = .radial
        for end in stride(from: chunk, through: samples.count, by: chunk) {
            update = processor.process(Array(samples[max(0, end - 4096)..<end]), fresh: chunk, sampleRate: 48_000, dt: 1 / 30, c)
        }
        let tempo = try #require(update?.tempo)
        #expect(abs(tempo - 120) < 1.5)
    }
}

@Suite struct AudioPitchColorTests {
    @Test func theProcessorColorsATraceByTheNotePlaying() throws {
        let scale: [SIMD3<Float>] = (0..<12).map { SIMD3(Float($0) / 11, 0.5, 0) }
        var c = AudioConfig(gridSize: 32, style: .waveform, colors: .pitch, palette: scale,
                            spawn: SpawnSettings(actorsPerBirth: 1, cellSize: 4, minSpeed: 1, life: 100), maxActors: 10_000, seeding: true)
        c.autoGain = false
        let update = AudioProcessor(seed: 1).process(sine(440, amplitude: 0.8), sampleRate: 48_000, dt: 1 / 30, c)
        let colors = Set(update.actors.map { $0.color })
        #expect(colors == [SIMD4(scale[9], 1)]) // A
    }

    @Test func aBandTakesTheNoteSoundingInIt() throws {
        let scale: [SIMD3<Float>] = (0..<12).map { SIMD3(Float($0) / 11, 0.5, 0) }
        var c = AudioConfig(gridSize: 64, style: .spectrum, colors: .pitch, palette: scale,
                            spawn: SpawnSettings(actorsPerBirth: 1, cellSize: 4, minSpeed: 1, life: 100), maxActors: 100_000, seeding: true)
        c.autoGain = false
        let update = AudioProcessor(seed: 1).process(sine(440, amplitude: 0.8), sampleRate: 48_000, dt: 1 / 30, c)
        // At 64 bands over 9 octaves a band is wider than a semitone, yet every note colors its band as itself.
        let analyzer = SpectrumAnalyzer()
        var centeredElsewhere = 0
        for note in 0..<12 {
            let hz = 440 * pow(2, Double(note - 9) / 12) // C4 to B4
            let (levels, notes) = analyzer.bands(amplitudes: analyzer.amplitudes(sine(hz, amplitude: 0.8)), count: 64, sampleRate: 48_000)
            let loudest = levels.indices.max { levels[$0] < levels[$1] }!
            #expect(notes[loudest] == note, "note \(noteNames[note])")
            if noteIndex(frequency: SpectrumAnalyzer.bandEdge(Double(loudest) + 0.5, count: 64, sampleRate: 48_000)) != note { centeredElsewhere += 1 }
        }
        #expect(centeredElsewhere > 0)
        #expect(update.actors.contains { $0.color == SIMD4(scale[9], 1) })
    }
}
