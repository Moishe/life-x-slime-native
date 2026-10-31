/// Side of the square Physarum field, in pixels.
let fieldSize = 2048
/// Life board sizes; each divides the field into whole square pixel blocks.
let lifeSizes = [64, 128, 256, 512, 1024]
nonisolated let physarumHz = 30.0

/// Width of one Life cell's block on the Physarum field, in field pixels.
func cellSize(forLifeSize lifeSize: Int) -> Int {
    fieldSize / lifeSize
}

/// Everything in the inspector except the Physarum parameters.
struct AppSettings: Equatable {
    var playing = true
    var lifeHz = 7.5
    var randomDensity = 0.2
    var actorsPerBirth = 129
    var spawnMode: SpawnMode = .trickle
    /// A palette name from `palettes`, as in settings files.
    var palette = "rainbow"
    /// How many of the palette's colors organisms wear (1...maxColors).
    var colorCount = 8
    var lifeOpacity = 0.05
    var physarumOpacity = 1.0
    var foodView = false
    var poolSize = defaultPoolSize
    var lifeSize = 64
    /// Relief shading of the Physarum layer from the pile height field.
    var relief = 0.0
    var reliefHeight = 8.0
    var lightAngle = 0.8
    var lightElevation = 0.7
    var heightGain = 0.1
    var heightDecay = 0.02

    var reliefSettings: ReliefSettings {
        ReliefSettings(relief: relief, reliefHeight: reliefHeight, lightAngle: lightAngle, lightElevation: lightElevation)
    }
}

let defaultPoolSize = 1 << 20

/// Live-editable Physarum parameters. Names match the web version's settings
/// files (camelCase versions of Particles' names).
struct PhysarumParams: Equatable, Codable {
    var lookSlices = 6
    var lookRadians = 1.31
    var lookDistance = 17.0
    var directionRandomization = 0.35
    var directionMomentum = 0.25
    var minSpeed = 1.13
    var maxSpeed = 2.81
    var intensity = 0.37
    /// Floor on an actor's color brightness after each step's blend (0 = off).
    var minValue = 0.0
    var foodPerDeath = 0.5
    var foodExhaustion = 0.0
    var foodSensitivity = 0.1
    var life = 20000
    var alwaysSpawnFromParent = 1
    var spawnRandomOffset = 1.0
    var spawnProbability = 0.0134
    /// Children and parent respawns start in the parent's seed color, not its trail-blended one.
    var spawnWithSeedColor = false
    var directionVariance = 1.65
    var speedVariance = 0.1
    /// Actors past this many on one pixel in a step don't reproduce (0 = off).
    var crowdingLimit = 0
    var lockToHsvAngles = 0
    var hsvAngleOffset = 1.0
    var hsvSaturationMultiplier = 1.0
    var hsvValueMultiplier = 1.0
    var fadeDecrement = 0.001
    var blurMultiplier = 10.6
    var blurInterval = 1
    /// Fade the trail every this many steps, independently of blurring. Not in
    /// the web version, which fades only on blur steps.
    var fadeInterval = 1
    var foodFadeDecrement = 0.002
    var foodFadeInterval = 1
    var wrapBounds = true
    var rngSeed = 1
}

/// Per-step values that live in the SimParams uniform alongside the parameters.
struct SimFrame {
    var width: Int
    var height: Int
    var step: Int
    var poolSize: Int
    var maxChildren: Int
    var spawnCount: Int
}

extension SimParams {
    init(_ p: PhysarumParams, _ frame: SimFrame) {
        self.init(
            width: Float(frame.width),
            height: Float(frame.height),
            lookSlices: UInt32(clamping: p.lookSlices),
            lookRadians: Float(p.lookRadians),
            lookDistance: Float(p.lookDistance),
            directionRandomization: Float(p.directionRandomization),
            directionMomentum: Float(p.directionMomentum),
            minSpeed: Float(p.minSpeed),
            maxSpeed: Float(p.maxSpeed),
            intensity: Float(p.intensity),
            foodSensitivity: Float(p.foodSensitivity),
            foodExhaustion: Float(p.foodExhaustion),
            life: UInt32(clamping: p.life),
            alwaysSpawnFromParent: Int32(clamping: p.alwaysSpawnFromParent),
            spawnRandomOffset: Float(p.spawnRandomOffset),
            spawnProbability: Float(p.spawnProbability),
            directionVariance: Float(p.directionVariance),
            speedVariance: Float(p.speedVariance),
            lockToHsvAngles: UInt32(clamping: p.lockToHsvAngles),
            hsvAngleOffset: Float(p.hsvAngleOffset),
            hsvSaturationMultiplier: Float(p.hsvSaturationMultiplier),
            hsvValueMultiplier: Float(p.hsvValueMultiplier),
            wrapBounds: p.wrapBounds ? 1 : 0,
            step: UInt32(truncatingIfNeeded: frame.step),
            poolSize: UInt32(frame.poolSize),
            maxChildren: UInt32(frame.maxChildren),
            spawnCount: UInt32(frame.spawnCount),
            crowdingLimit: UInt32(clamping: p.crowdingLimit),
            minValue: Float(p.minValue),
            spawnWithSeedColor: p.spawnWithSeedColor ? 1 : 0,
            pad1: 0,
            pad2: 0
        )
    }
}

extension PhysarumParams {
    var hueLock: HueLock {
        HueLock(
            lockToHsvAngles: lockToHsvAngles,
            hsvAngleOffset: Float(hsvAngleOffset),
            hsvSaturationMultiplier: Float(hsvSaturationMultiplier),
            hsvValueMultiplier: Float(hsvValueMultiplier)
        )
    }
}

let actorBytes = MemoryLayout<Actor>.stride

/// Pool sizes (powers of two from 2^14 to 2^22) whose actor buffer fits the device's limit.
func supportedPoolSizes(maxBufferLength: Int) -> [Int] {
    (14...22).map { 1 << $0 }.filter { $0 * actorBytes <= maxBufferLength }
}
