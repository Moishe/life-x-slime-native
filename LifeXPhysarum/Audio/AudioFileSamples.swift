import AVFoundation

/// A whole audio file (MP3, WAV, AIFF, M4A…) decoded to mono samples, for
/// rendering a movie from it.
nonisolated struct AudioFileSamples: Sendable {
    enum Failure: LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty: "The file has no audio in it."
            }
        }
    }

    /// Mono: the channels averaged.
    let samples: [Float]
    let sampleRate: Double

    var duration: Double { Double(samples.count) / sampleRate }

    /// Decodes `url`, which can take a moment for a long file.
    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat // deinterleaved Float32
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw Failure.empty }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { throw Failure.empty }
        let count = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            let channel = UnsafeBufferPointer(start: channels[c], count: count)
            for i in 0..<count { mono[i] += channel[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<count { mono[i] *= scale }
        }
        self.init(samples: mono, sampleRate: format.sampleRate)
    }

    init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Movie frames at `movieFPS` that cover the whole file.
    var frameCount: Int { Int((duration * Double(movieFPS)).rounded(.up)) }

    /// What frame `frame` hears, as the live input would hand it over: up to `length`
    /// samples ending half a window past the frame's time (so the window is centered
    /// on it), zero-padded before the start, and how many of them are new since the
    /// frame before.
    func window(forFrame frame: Int, length: Int) -> (samples: [Float], fresh: Int) {
        func end(_ frame: Int) -> Int {
            min(samples.count, Int((Double(frame) / Double(movieFPS) * sampleRate).rounded()) + length / 2)
        }
        let to = end(frame), from = to - length
        var window = [Float](repeating: 0, count: length)
        let start = max(0, from)
        if start < to {
            window.replaceSubrange((start - from)..<length, with: samples[start..<to])
        }
        return (window, frame == 0 ? to : to - end(frame - 1))
    }
}
