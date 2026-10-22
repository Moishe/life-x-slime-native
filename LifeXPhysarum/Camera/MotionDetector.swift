import simd

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
    /// The nearest color in the Life palette, so the camera wears the palette's colors.
    case palette
}

/// What in the camera image releases actors.
nonisolated enum CameraTrigger: String, Codable, CaseIterable, Sendable {
    /// Cells whose image changed since the last frame.
    case motion
    /// Cells on an edge in the current frame, every frame, still or not.
    case edges
}

/// A frame's births and deaths, from a MotionDetector or an EdgeDetector.
nonisolated struct MotionResult {
    /// Cells that are moving (or on an edge); each releases actors.
    var births: [SeedCell] = []
    /// Cells that were moving (or on an edge) and have stopped; each leaves food.
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
    /// The colors `.palette` picks from.
    var palette: [SIMD3<Float>] = []
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
                let color = cellColor(frame.rgba, i, colors, palette)
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

    /// Forgets the last frame, so the next one only sets the baseline.
    func reset() {
        size = 0
    }
}

/// Finds edges in each camera image: cells where brightness changes sharply
/// across them, by more than `threshold` (0–1, a Sobel gradient scaled so a
/// black-to-white step is 1). Unlike motion, an edge is born again every frame
/// it's there, so a still scene keeps spawning; it dies, leaving food in its last
/// color, when it moves away or fades.
nonisolated final class EdgeDetector {
    var threshold: Float
    var colors = CameraColors.vivid
    /// The colors `.palette` picks from.
    var palette: [SIMD3<Float>] = []
    private var size = 0
    // Each edge cell's color in the last frame; nil where there's no edge.
    private var edges: [SIMD3<Float>?] = []

    init(threshold: Float) {
        self.threshold = threshold
    }

    func process(_ frame: CameraFrame) -> MotionResult {
        let size = frame.size, n = size * size
        if size != self.size {
            self.size = size
            edges = Array(repeating: nil, count: n)
        }
        let luma = (0..<n).map { lumaOf(frame.rgba, $0) }
        // Samples clamp at the border, so the frame's own edges aren't edges.
        func l(_ x: Int, _ y: Int) -> Float { luma[min(max(y, 0), size - 1) * size + min(max(x, 0), size - 1)] }
        var result = MotionResult()
        for y in 0..<size {
            for x in 0..<size {
                let gx = l(x + 1, y - 1) + 2 * l(x + 1, y) + l(x + 1, y + 1) - l(x - 1, y - 1) - 2 * l(x - 1, y) - l(x - 1, y + 1)
                let gy = l(x - 1, y + 1) + 2 * l(x, y + 1) + l(x + 1, y + 1) - l(x - 1, y - 1) - 2 * l(x, y - 1) - l(x + 1, y - 1)
                let i = y * size + x
                if (gx * gx + gy * gy).squareRoot() / 4 > threshold {
                    let color = cellColor(frame.rgba, i, colors, palette)
                    result.births.append(SeedCell(x: x, y: y, color: color))
                    edges[i] = color
                } else if let color = edges[i] {
                    result.deaths.append(SeedCell(x: x, y: y, color: color))
                    edges[i] = nil
                }
            }
        }
        result.movingCells = result.births.count
        return result
    }

    /// Forgets the last frame's edges, so none of them die.
    func reset() {
        size = 0
    }
}

private nonisolated func lumaOf(_ rgba: [UInt8], _ i: Int) -> Float {
    (0.2126 * Float(rgba[i * 4]) + 0.7152 * Float(rgba[i * 4 + 1]) + 0.0722 * Float(rgba[i * 4 + 2])) / 255
}

/// A cell's color for its actors: its hue at full strength (vivid), as is, or
/// the palette color nearest it.
private nonisolated func cellColor(_ rgba: [UInt8], _ i: Int, _ colors: CameraColors,
                                   _ palette: [SIMD3<Float>]) -> SIMD3<Float> {
    let rgb = SIMD3(Float(rgba[i * 4]), Float(rgba[i * 4 + 1]), Float(rgba[i * 4 + 2])) / 255
    switch colors {
    case .vivid: return hsv2rgb(SIMD3(rgb2hsv(rgb).x, 1, 1))
    case .trueColor: return rgb
    case .palette: return palette.min { simd_distance_squared($0, rgb) < simd_distance_squared($1, rgb) } ?? rgb
    }
}
