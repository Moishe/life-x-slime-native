import AVFoundation

/// A whole audio file (MP3, WAV, AIFF, M4A…) decoded to left and right samples,
/// for rendering a movie from it.
nonisolated struct AudioFileSamples: Sendable {
    enum Failure: LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty: "The file has no audio in it."
            }
        }
    }

    /// A mono file has the same in both channels; one with more than two
    /// channels has its even channels averaged into the left and its odd into the right.
    let samples: StereoSamples
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
        func average(_ indices: [Int]) -> [Float] {
            var sum = [Float](repeating: 0, count: count)
            for c in indices {
                let channel = UnsafeBufferPointer(start: channels[c], count: count)
                for i in 0..<count { sum[i] += channel[i] }
            }
            if indices.count > 1 {
                let scale = 1 / Float(indices.count)
                for i in 0..<count { sum[i] *= scale }
            }
            return sum
        }
        let left = average(Array(stride(from: 0, to: channelCount, by: 2)))
        let right = channelCount > 1 ? average(Array(stride(from: 1, to: channelCount, by: 2))) : left
        self.init(samples: StereoSamples(left: left, right: right), sampleRate: format.sampleRate)
    }

    init(samples: StereoSamples, sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Movie frames at `movieFPS` that cover the whole file.
    var frameCount: Int { Int((duration * Double(movieFPS)).rounded(.up)) }

    /// What frame `frame` hears, as the live input would hand it over: up to `length`
    /// samples of each channel ending half a window past the frame's time (so the window is centered
    /// on it), zero-padded before the start, and how many of them are new since the
    /// frame before.
    func window(forFrame frame: Int, length: Int) -> (samples: StereoSamples, fresh: Int) {
        func end(_ frame: Int) -> Int {
            min(samples.count, Int((Double(frame) / Double(movieFPS) * sampleRate).rounded()) + length / 2)
        }
        let to = end(frame), from = to - length
        let start = max(0, from)
        func window(_ channel: [Float]) -> [Float] {
            var window = [Float](repeating: 0, count: length)
            if start < to {
                window.replaceSubrange((start - from)..<length, with: channel[start..<to])
            }
            return window
        }
        return (StereoSamples(left: window(samples.left), right: window(samples.right)), frame == 0 ? to : to - end(frame - 1))
    }
}
