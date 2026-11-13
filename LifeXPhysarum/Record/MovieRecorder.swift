import AVFoundation
import CoreVideo
import Metal
import Synchronization

struct MovieConfig: Equatable {
    enum Codec: Equatable {
        case h264, hevc
    }

    var codec: Codec
    var size: Int
    var bitrate: Int

    /// In order of preference: H.264 plays everywhere, HEVC keeps full size.
    static let candidates: [MovieConfig] = [
        MovieConfig(codec: .h264, size: 2048, bitrate: 20_000_000),
        MovieConfig(codec: .hevc, size: 2048, bitrate: 20_000_000),
        MovieConfig(codec: .h264, size: 1024, bitrate: 8_000_000),
    ]

    /// The first candidate `canEncode` accepts, or nil if none.
    static func choose(_ canEncode: (MovieConfig) -> Bool) -> MovieConfig? {
        candidates.first(where: canEncode)
    }

    /// A note for the user when the movie won't be full-size H.264.
    var notice: String? {
        var notes: [String] = []
        if codec != .h264 { notes.append("Recording as HEVC: this Mac can't encode 2048×2048 H.264.") }
        if size != 2048 { notes.append("Recording at \(size)×\(size): this Mac can't encode 2048×2048 video.") }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }

    var outputSettings: [String: Any] {
        [
            AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: movieFPS,
                AVVideoMaxKeyFrameIntervalKey: movieFPS * 2,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }
}

/// Records composited frames into an MP4 on disk, one frame per `addFrame`
/// call at `movieFPS`. Frames are rendered straight into the encoder's pixel
/// buffers by Metal and handed to AVFoundation once the GPU has drawn them.
/// A soundtrack, if given, is copied in as AAC alongside, starting with the first frame.
final class MovieRecorder {
    enum Failure: LocalizedError {
        case cannotEncode
        case cannotStart(Error?)
        case writer(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotEncode: "This Mac cannot encode video at 1024×1024 or larger."
            case .cannotStart(let error): "Could not start the movie: \(error?.localizedDescription ?? "unknown error")"
            case .writer(let error): "The movie encoder failed: \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }

    /// Frames handed to the GPU or encoder but not yet appended. Above this the
    /// caller should hold off on new frames (see `isBusy`) instead of dropping any.
    private static let maxPendingFrames = 3

    let config: MovieConfig
    let url: URL
    private(set) var frameCount = 0
    private let context: MetalContext
    private let output: Output
    private let textureCache: CVMetalTextureCache
    private let soundtrack: Soundtrack?

    /// The writer, its input and adaptor. Frames are appended only on `queue`.
    nonisolated private final class Output: @unchecked Sendable {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let queue = DispatchQueue(label: "movie writer")
        let pending = Mutex(0)

        init(writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        }

        func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
            // The caller holds off while the input isn't ready, so this wait is rare and short.
            while !input.isReadyForMoreMediaData && writer.status == .writing { usleep(1000) }
            if writer.status == .writing { adaptor.append(pixelBuffer, withPresentationTime: time) }
        }
    }

    /// An audio file's track, with its asset (which the track holds only weakly).
    nonisolated struct SoundtrackSource: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack

        init(url: URL) async throws {
            asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AudioFileSamples.Failure.empty }
            self.track = track
        }
    }

    init(url: URL, context: MetalContext, soundtrack source: SoundtrackSource? = nil) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        guard let config = MovieConfig.choose({ writer.canApply(outputSettings: $0.outputSettings, forMediaType: .video) }) else {
            throw Failure.cannotEncode
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: config.outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.size,
            kCVPixelBufferHeightKey as String: config.size,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { throw Failure.cannotStart(writer.error) }
        writer.add(input)
        let soundtrack = try source.map { try Soundtrack(source: $0, writer: writer) }
        guard writer.startWriting() else { throw Failure.cannotStart(writer.error) }
        writer.startSession(atSourceTime: .zero)
        try soundtrack?.start()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, context.device, nil, &cache)
        guard let cache else { throw Failure.cannotStart(nil) }

        self.url = url
        self.config = config
        self.context = context
        output = Output(writer: writer, input: input, adaptor: adaptor)
        textureCache = cache
        self.soundtrack = soundtrack
    }

    /// True while the encoder is behind; callers should wait before adding frames.
    var isBusy: Bool {
        output.pending.withLock { $0 } >= Self.maxPendingFrames || !output.input.isReadyForMoreMediaData
    }

    /// Renders the next frame with `draw` (into a BGRA texture of the movie's
    /// size) and appends it to the movie.
    func addFrame(_ draw: (MTLCommandBuffer, MTLTexture) -> Void) throws {
        let writer = output.writer
        if writer.status == .failed { throw Failure.writer(writer.error) }
        guard let pool = output.adaptor.pixelBufferPool else { throw Failure.writer(writer.error) }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        var cvTexture: CVMetalTexture?
        if let pixelBuffer {
            CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, pixelBuffer, nil, .bgra8Unorm, config.size, config.size, 0, &cvTexture)
        }
        guard let pixelBuffer, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw Failure.writer(nil)
        }

        let commandBuffer = context.queue.makeCommandBuffer()!
        commandBuffer.label = "movie frame"
        draw(commandBuffer, texture)

        let time = CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(movieFPS))
        frameCount += 1
        output.pending.withLock { $0 += 1 }
        // The CVMetalTexture must outlive the GPU's use of its texture.
        let frame = UncheckedSendable((pixelBuffer, cvTexture))
        let output = output
        commandBuffer.addCompletedHandler { _ in
            output.queue.async {
                output.append(frame.value.0, at: time)
                output.pending.withLock { $0 -= 1 }
            }
        }
        commandBuffer.commit()
    }

    /// Waits for queued frames and finishes the file.
    func finish() async throws {
        context.waitUntilIdle()
        let output = output
        await withCheckedContinuation { continuation in output.queue.async { continuation.resume() } }
        output.input.markAsFinished()
        // After the video's marked finished: the writer interleaves the tracks, so it
        // may hold the soundtrack back until it knows no more frames are coming.
        if let soundtrack { await soundtrack.finished() }
        await withCheckedContinuation { continuation in
            output.writer.finishWriting { continuation.resume() }
        }
        if output.writer.status != .completed { throw Failure.writer(output.writer.error) }
    }

    /// Abandons the recording and deletes the partial file.
    func cancel() {
        soundtrack?.cancel()
        output.writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    /// Copies an audio track into the movie as AAC, as fast as the writer takes it, on its own queue.
    nonisolated private final class Soundtrack: @unchecked Sendable {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let input: AVAssetWriterInput
        private let queue = DispatchQueue(label: "movie soundtrack")
        private let done = DispatchGroup()
        // Confined to `queue`.
        private var isDone = false

        static let sampleRate = 48_000
        static let channels = 2

        init(source: SoundtrackSource, writer: AVAssetWriter) throws {
            reader = try AVAssetReader(asset: source.asset)
            output = AVAssetReaderTrackOutput(track: source.track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: Self.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw Failure.cannotStart(reader.error) }
            reader.add(output)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: Self.channels,
                AVEncoderBitRateKey: 256_000,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.cannotStart(writer.error) }
            writer.add(input)
        }

        /// Starts copying; call once the writer has started.
        func start() throws {
            guard reader.startReading() else { throw Failure.cannotStart(reader.error) }
            done.enter()
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while !isDone && input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                        finish()
                        return
                    }
                }
            }
        }

        /// Waits until the whole track has been handed to the writer.
        func finished() async {
            await withCheckedContinuation { continuation in done.notify(queue: queue) { continuation.resume() } }
        }

        func cancel() {
            queue.async { [self] in
                reader.cancelReading()
                finish()
            }
        }

        // On `queue`.
        private func finish() {
            guard !isDone else { return }
            isDone = true
            input.markAsFinished()
            done.leave()
        }
    }
}
