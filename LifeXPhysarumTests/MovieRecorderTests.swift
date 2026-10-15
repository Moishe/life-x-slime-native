import AVFoundation
import Foundation
import Metal
import Testing
@testable import LifeXPhysarum

@Suite(.serialized) struct MovieRecorderTests {
    @Test func prefersFullSizeH264AndExplainsFallbacks() {
        #expect(MovieConfig.choose { _ in true } == MovieConfig(codec: .h264, size: 2048, bitrate: 20_000_000))
        #expect(MovieConfig.choose { $0.codec == .hevc }?.size == 2048)
        #expect(MovieConfig.choose { $0.size == 1024 } == MovieConfig(codec: .h264, size: 1024, bitrate: 8_000_000))
        #expect(MovieConfig.choose { _ in false } == nil)
        #expect(MovieConfig(codec: .h264, size: 2048, bitrate: 0).notice == nil)
        #expect(MovieConfig(codec: .h264, size: 1024, bitrate: 0).notice == "Recording at 1024×1024: this Mac can't encode 2048×2048 video.")
    }

    @Test func recordsComposedFramesIntoAPlayableMP4() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recorder-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let compositor = Compositor(context: gpu, gridSize: 64)
        let field = texture(64, solidTexels(64, 64, [255, 0, 0, 255]))
        let recorder = try MovieRecorder(url: url, context: gpu)
        for _ in 0..<45 {
            while recorder.isBusy { try await Task.sleep(for: .milliseconds(2)) }
            try recorder.addFrame { commandBuffer, target in
                compositor.encode(into: commandBuffer, target: target, field: field,
                                  physarumOpacity: 1, lifeOpacity: 0, ghostOpacity: 0)
            }
        }
        #expect(recorder.frameCount == 45)
        try await recorder.finish()

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 1.5) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: recorder.config.size, height: recorder.config.size))

        // The frames are the red field.
        let generator = AVAssetImageGenerator(asset: asset)
        let image = try await generator.image(at: CMTime(value: 1, timescale: 2)).image
        let data = try #require(image.dataProvider?.data as Data?)
        let bytesPerPixel = image.bitsPerPixel / 8
        let o = (image.height / 2) * image.bytesPerRow + (image.width / 2) * bytesPerPixel
        let isBGRA = image.bitmapInfo.contains(.byteOrder32Little)
        let (r, g, b) = isBGRA ? (data[o + 2], data[o + 1], data[o]) : (data[o], data[o + 1], data[o + 2])
        #expect(r > 200 && g < 60 && b < 60, "center pixel r=\(r) g=\(g) b=\(b)")
    }
}
