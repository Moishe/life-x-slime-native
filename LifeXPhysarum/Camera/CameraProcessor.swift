/// What the camera pipeline needs from the interface, read once per frame.
nonisolated struct CameraConfig: Sendable {
    var gridSize: Int
    var mirrored: Bool
    /// The motion threshold.
    var threshold: Float
    var colors: CameraColors
    /// The Life palette, for `.palette` colors.
    var palette: [SIMD3<Float>] = []
    var spawn: SpawnSettings
    var maxActors: Int
    /// False while paused: motion is still tracked, but spawns nothing.
    var seeding: Bool
    var trigger = CameraTrigger.motion
    var edgeThreshold: Float = 0.2
}

/// One processed camera frame, for the main actor.
nonisolated struct CameraUpdate: Sendable {
    var gridSize: Int
    /// The image, shown in place of the Life layer.
    var texels: [UInt8]
    var actors: [Actor] = []
    var seeds: [FoodSeed] = []
    var movingCells = 0
}

/// Turns camera frames into actors and food, like LifeRunner does for Life
/// ticks. Not thread-safe: the camera's queue owns it.
nonisolated final class CameraProcessor {
    private let detector = MotionDetector(threshold: 0.1)
    private let edgeDetector = EdgeDetector(threshold: 0.2)
    private let rng: Rng
    private var trigger = CameraTrigger.motion

    init(seed: Int) {
        rng = mulberry32(seed)
    }

    func process(_ frame: CameraFrame, _ config: CameraConfig) -> CameraUpdate {
        if config.trigger != trigger {
            trigger = config.trigger
            // Frames went to the other detector meanwhile, so each one's last frame is stale.
            detector.reset()
            edgeDetector.reset()
        }
        let motion: MotionResult
        switch config.trigger {
        case .motion:
            detector.threshold = config.threshold
            detector.colors = config.colors
            detector.palette = config.palette
            motion = detector.process(frame)
        case .edges:
            edgeDetector.threshold = config.edgeThreshold
            edgeDetector.colors = config.colors
            edgeDetector.palette = config.palette
            motion = edgeDetector.process(frame)
        }
        var update = CameraUpdate(gridSize: frame.size, texels: frame.rgba, movingCells: motion.movingCells)
        if config.seeding {
            update.actors = birthsToActors(motion.births, config.spawn, rng: rng, maxActors: config.maxActors)
            update.seeds = deathsToFoodSeeds(motion.deaths)
        }
        return update
    }
}
