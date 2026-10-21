/// What the camera pipeline needs from the interface, read once per frame.
nonisolated struct CameraConfig: Sendable {
    var gridSize: Int
    var mirrored: Bool
    var threshold: Float
    var colors: CameraColors
    var spawn: SpawnSettings
    var maxActors: Int
    /// False while paused: motion is still tracked, but spawns nothing.
    var seeding: Bool
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
    private let rng: Rng

    init(seed: Int) {
        rng = mulberry32(seed)
    }

    func process(_ frame: CameraFrame, _ config: CameraConfig) -> CameraUpdate {
        detector.threshold = config.threshold
        detector.colors = config.colors
        let motion = detector.process(frame)
        var update = CameraUpdate(gridSize: frame.size, texels: frame.rgba, movingCells: motion.movingCells)
        if config.seeding {
            update.actors = birthsToActors(motion.births, config.spawn, rng: rng, maxActors: config.maxActors)
            update.seeds = deathsToFoodSeeds(motion.deaths)
        }
        return update
    }
}
