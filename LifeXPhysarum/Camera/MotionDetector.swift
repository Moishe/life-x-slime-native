/// A camera image scaled to the Life grid: size × size RGBA, top-left origin.
nonisolated struct CameraFrame {
    let size: Int
    let rgba: [UInt8]
}

/// How a moving cell's color is taken from the camera.
nonisolated enum CameraColors: String, Codable, CaseIterable, Sendable {
    /// The pixel's hue at full saturation and brightness: vivid, and easy for actors to tell apart.
    case vivid
    /// The pixel's own color: faithful, but dull colors weaken actors' hue sensing.
    case trueColor
}

nonisolated struct MotionResult {
    /// Cells that changed since the last frame; each releases actors.
    var births: [SeedCell] = []
    /// Cells that were changing and have stopped; each leaves food.
    var deaths: [SeedCell] = []
    var movingCells = 0
}

/// Finds where the camera image is changing, frame to frame: the camera's
/// counterpart of Life's births and deaths. A cell is moving when its
/// brightness changed by more than `threshold` (0–1) since the last frame.
/// Its color is the scene's there: by default its hue at full saturation, since
/// actors sense each other by hue and a camera's colors are mostly dull.
nonisolated final class MotionDetector {
    var threshold: Float
    var colors = CameraColors.vivid
    private var size = 0
    private var luma: [Float] = []
    // The color each moving cell was born in; nil where it isn't moving.
    private var moving: [SIMD3<Float>?] = []

    init(threshold: Float) {
        self.threshold = threshold
    }

    func process(_ frame: CameraFrame) -> MotionResult {
        let n = frame.size * frame.size
        guard frame.size == size else {
            size = frame.size
            luma = (0..<n).map { lumaOf(frame.rgba, $0) }
            moving = Array(repeating: nil, count: n)
            return MotionResult()
        }
        var result = MotionResult()
        for i in 0..<n {
            let l = lumaOf(frame.rgba, i)
            let changed = abs(l - luma[i]) > threshold
            luma[i] = l
            if changed {
                let rgb = SIMD3(Float(frame.rgba[i * 4]), Float(frame.rgba[i * 4 + 1]), Float(frame.rgba[i * 4 + 2])) / 255
                let color = colors == .vivid ? hsv2rgb(SIMD3(rgb2hsv(rgb).x, 1, 1)) : rgb
                result.births.append(SeedCell(x: i % size, y: i / size, color: color))
                moving[i] = color
            } else if let color = moving[i] {
                result.deaths.append(SeedCell(x: i % size, y: i / size, color: color))
                moving[i] = nil
            }
        }
        result.movingCells = result.births.count
        return result
    }

    private func lumaOf(_ rgba: [UInt8], _ i: Int) -> Float {
        (0.2126 * Float(rgba[i * 4]) + 0.7152 * Float(rgba[i * 4 + 1]) + 0.0722 * Float(rgba[i * 4 + 2])) / 255
    }
}
