import AVFoundation
import Foundation
import Testing
@testable import LifeXPhysarum

@Suite(.serialized) struct AudioFileRenderTests {
    /// A WAV of a stereo sine at 48 kHz.
    func writeTone(seconds: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 48_000) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func temporary(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "render-test-\(UUID().uuidString).\(ext)")
    }

    @Test func decodesToMonoAndCoversTheFileInFrames() throws {
        let url = temporary("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(seconds: 1.01, to: url)
        let audio = try AudioFileSamples(url: url)
        #expect(audio.sampleRate == 48_000)
        #expect(audio.samples.count == 48_480)
        #expect(abs(audio.samples[12] - 0.5 * sin(2 * .pi * 440 * 12 / 48_000)) < 1e-4)
        #expect(audio.frameCount == 31) // 30.3 frames, rounded up
    }

    @Test func eachFrameHearsAWindowCenteredOnItsTime() {
        let audio = AudioFileSamples(samples: (0..<300).map(Float.init), sampleRate: 300) // 10 samples a frame
        let first = audio.window(forFrame: 0, length: 8)
        #expect(first.samples == [0, 0, 0, 0, 0, 1, 2, 3]) // zero-padded before the start
        #expect(first.fresh == 4)
        let later = audio.window(forFrame: 3, length: 8)
        #expect(later.samples == (26..<34).map(Float.init))
        #expect(later.fresh == 10)
        let last = audio.window(forFrame: 30, length: 8)
        #expect(last.samples == (292..<300).map(Float.init)) // stops at the end
    }

    @Test func rendersAMovieWithTheSoundAsLongAsTheFile() async throws {
        let wav = temporary("wav"), movie = temporary("mp4")
        defer {
            try? FileManager.default.removeItem(at: wav)
            try? FileManager.default.removeItem(at: movie)
        }
        try writeTone(seconds: 2, to: wav)
        let model = try #require(SimulationModel())
        model.audioSettings.style = .radial
        model.audioSettings.sweepAtTop = true
        try await model.renderMovie(audio: wav, to: movie)
        #expect(model.renderProgress == nil && model.source == .life)

        let asset = AVURLAsset(url: movie)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let sound = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let videoDuration = try await video.load(.timeRange).duration.seconds
        let soundDuration = try await sound.load(.timeRange).duration.seconds
        #expect(abs(videoDuration - 2) < 0.05, "video \(videoDuration) s")
        #expect(abs(soundDuration - 2) < 0.05, "sound \(soundDuration) s")
        #expect(try await sound.load(.timeRange).start.seconds < 0.01)
    }
}
