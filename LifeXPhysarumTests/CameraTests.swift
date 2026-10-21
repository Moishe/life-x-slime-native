import CoreVideo
import Testing
@testable import LifeXPhysarum

@Suite struct MotionDetectorTests {
    /// A size × size frame of one color, with optional per-cell overrides.
    func frame(_ size: Int, _ fill: SIMD3<UInt8>, _ cells: [Int: SIMD3<UInt8>] = [:]) -> CameraFrame {
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<size * size {
            let c = cells[i] ?? fill
            rgba[i * 4] = c.x; rgba[i * 4 + 1] = c.y; rgba[i * 4 + 2] = c.z
        }
        return CameraFrame(size: size, rgba: rgba)
    }

    let dark = SIMD3<UInt8>(20, 20, 20)
    let green = SIMD3<UInt8>(60, 170, 60) // a dull green; its hue at full saturation is pure green

    @Test func theFirstFrameOnlySetsTheBaseline() {
        let detector = MotionDetector(threshold: 0.1)
        let result = detector.process(frame(4, green))
        #expect(result.births.isEmpty && result.deaths.isEmpty && result.movingCells == 0)
    }

    @Test func aCellThatChangesIsABirthInItsHueAtFullSaturation() throws {
        let detector = MotionDetector(threshold: 0.1)
        _ = detector.process(frame(4, dark))
        let result = detector.process(frame(4, dark, [6: green])) // cell (2, 1)
        let birth = try #require(result.births.first)
        #expect(result.births.count == 1 && result.movingCells == 1)
        #expect(birth.x == 2 && birth.y == 1)
        #expect(abs(birth.color.x) < 0.01 && abs(birth.color.y - 1) < 0.01 && abs(birth.color.z) < 0.01)
    }

    @Test func trueColorKeepsThePixelsOwnColor() throws {
        let detector = MotionDetector(threshold: 0.1)
        detector.colors = .trueColor
        _ = detector.process(frame(4, dark))
        let birth = try #require(detector.process(frame(4, dark, [6: green])).births.first)
        #expect(birth.color == SIMD3<Float>(60, 170, 60) / 255)
    }

    @Test func changesBelowTheThresholdAreIgnored() {
        let detector = MotionDetector(threshold: 0.1)
        _ = detector.process(frame(4, dark))
        let result = detector.process(frame(4, dark, [6: SIMD3(30, 30, 30)]))
        #expect(result.births.isEmpty && result.movingCells == 0)
    }

    @Test func aCellThatStopsMovingDiesOnceInItsBirthColor() {
        let detector = MotionDetector(threshold: 0.1)
        _ = detector.process(frame(4, dark))
        let moved = detector.process(frame(4, dark, [6: green]))
        let stopped = detector.process(frame(4, dark, [6: green]))
        #expect(stopped.births.isEmpty)
        #expect(stopped.deaths == moved.births)
        #expect(detector.process(frame(4, dark, [6: green])).deaths.isEmpty)
    }

    @Test func aNewSizeStartsANewBaseline() {
        let detector = MotionDetector(threshold: 0.1)
        _ = detector.process(frame(4, dark))
        let result = detector.process(frame(8, green))
        #expect(result.births.isEmpty && result.deaths.isEmpty)
    }
}

@Suite struct CameraFrameTests {
    /// A BGRA pixel buffer `width` wide and 2 high, colored column by column.
    func buffer(_ columns: [SIMD3<UInt8>]) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, columns.count, 2, kCVPixelFormatType_32BGRA, nil, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<2 {
            for (x, c) in columns.enumerated() {
                let p = base + y * rowBytes + x * 4
                p[0] = c.z; p[1] = c.y; p[2] = c.x; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    let red = SIMD3<UInt8>(255, 0, 0), blue = SIMD3<UInt8>(0, 0, 255), green = SIMD3<UInt8>(0, 255, 0)

    func pixel(_ f: CameraFrame, _ x: Int, _ y: Int) -> SIMD3<UInt8> {
        let i = (y * f.size + x) * 4
        return SIMD3(f.rgba[i], f.rgba[i + 1], f.rgba[i + 2])
    }

    @Test func cropsTheCenteredSquareIntoRGBA() throws {
        let f = try #require(cameraFrame(from: buffer([green, green, red, blue, green, green]), gridSize: 2, mirrored: false))
        #expect(f.size == 2 && f.rgba.count == 16)
        #expect(pixel(f, 0, 0) == red && pixel(f, 1, 0) == blue && pixel(f, 0, 1) == red)
    }

    @Test func mirroringFlipsLeftAndRight() throws {
        let f = try #require(cameraFrame(from: buffer([green, green, red, blue, green, green]), gridSize: 2, mirrored: true))
        #expect(pixel(f, 0, 0) == blue && pixel(f, 1, 0) == red)
    }
}

@Suite struct CameraProcessorTests {
    let spawn = SpawnSettings(actorsPerBirth: 3, cellSize: 32, minSpeed: 1, life: 100)

    func frames() -> (still: CameraFrame, moved: CameraFrame) {
        let still = CameraFrame(size: 4, rgba: [UInt8](repeating: 20, count: 64))
        var moved = still.rgba
        moved[5 * 4] = 250; moved[5 * 4 + 1] = 60; moved[5 * 4 + 2] = 60 // cell (1, 1) turns red
        return (still, CameraFrame(size: 4, rgba: moved))
    }

    @Test func turnsMotionIntoActorsAndFoodAndPassesTheImageOn() {
        let processor = CameraProcessor(seed: 1)
        let config = CameraConfig(gridSize: 4, mirrored: true, threshold: 0.1, colors: .vivid, spawn: spawn, maxActors: 1000, seeding: true)
        let (still, moved) = frames()
        _ = processor.process(still, config)
        let update = processor.process(moved, config)
        #expect(update.actors.count == 3 && update.movingCells == 1)
        #expect(update.actors.allSatisfy { $0.pos.x >= 32 && $0.pos.x < 64 && $0.pos.y >= 32 && $0.pos.y < 64 })
        #expect(update.texels == moved.rgba && update.gridSize == 4)
        #expect(processor.process(moved, config).seeds.count == 1)
    }

    @Test func whilePausedTracksMotionButSpawnsNothing() {
        let processor = CameraProcessor(seed: 1)
        var config = CameraConfig(gridSize: 4, mirrored: true, threshold: 0.1, colors: .vivid, spawn: spawn, maxActors: 1000, seeding: false)
        let (still, moved) = frames()
        _ = processor.process(still, config)
        let paused = processor.process(moved, config)
        #expect(paused.actors.isEmpty && paused.seeds.isEmpty && paused.movingCells == 1)
        config.seeding = true
        // The paused motion is already in the baseline, so resuming doesn't replay it.
        #expect(processor.process(moved, config).actors.isEmpty)
    }
}
