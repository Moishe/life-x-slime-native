import AppKit
import AVFoundation
import Metal
import Observation
import QuartzCore

/// Status-bar numbers, refreshed a few times a second.
struct Readouts: Equatable {
    var fps = 0.0
    var physStepsPerSec = 0.0
    var alive = 0
    var organisms = 0
    var lifeInsertsPerSec = 0.0
    var childInsertsPerSec = 0.0
    var movingCells = 0
}

/// What releases actors: Life's births, motion in front of the camera, or sound.
enum SeedSource: String, CaseIterable {
    case life, camera, audio
}

/// Camera options. Not part of settings files (the web version has no camera).
struct CameraSettings: Codable, Equatable {
    /// The chosen camera's unique ID; nil means the system default.
    var deviceID: String?
    var mirrored = true
    /// How much a cell's brightness must change between frames to count as motion (0–1).
    var motionThreshold = 0.08
    var colors = CameraColors.vivid
    /// Whether motion or edges release actors.
    var trigger = CameraTrigger.motion
    /// How sharp a brightness change across a cell must be to count as an edge (0–1).
    var edgeThreshold = 0.2

    init() {}

    // Tolerates settings saved before a field existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CameraSettings()
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? defaults.mirrored
        motionThreshold = try c.decodeIfPresent(Double.self, forKey: .motionThreshold) ?? defaults.motionThreshold
        colors = try c.decodeIfPresent(CameraColors.self, forKey: .colors) ?? defaults.colors
        trigger = try c.decodeIfPresent(CameraTrigger.self, forKey: .trigger) ?? defaults.trigger
        edgeThreshold = try c.decodeIfPresent(Double.self, forKey: .edgeThreshold) ?? defaults.edgeThreshold
    }
}

/// Audio options. Not part of settings files (the web version has no audio).
struct AudioSettings: Codable, Equatable {
    /// An AudioInput's ID; nil means the default input device.
    var inputID: String?
    var style = AudioStyle.waveform
    var colors = AudioColors.pitch
    /// The level (0–1) a trace's peak or a band must pass to light cells.
    var threshold = 0.1
    /// Spectrum and radial: bands light only within this many decibels of the loudest.
    var rangeDB = 24.0
    /// Radial: what sets each band's distance from the center.
    var distance = AudioDistance.pitch
    var autoGain = true
    /// Extra gain, in decibels.
    var gainDB = 0.0
    /// Radial sweep tempo in beats per minute (one turn per bar of 4); 0 draws whole rings.
    var sweepBPM = 60.0
    /// Set the sweep tempo from the detected tempo of what's playing.
    var autoTempo = false

    init() {}

    // Tolerates settings saved before a field existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AudioSettings()
        inputID = try c.decodeIfPresent(String.self, forKey: .inputID)
        style = try c.decodeIfPresent(AudioStyle.self, forKey: .style) ?? defaults.style
        colors = try c.decodeIfPresent(AudioColors.self, forKey: .colors) ?? defaults.colors
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? defaults.threshold
        rangeDB = try c.decodeIfPresent(Double.self, forKey: .rangeDB) ?? defaults.rangeDB
        distance = try c.decodeIfPresent(AudioDistance.self, forKey: .distance) ?? defaults.distance
        autoGain = try c.decodeIfPresent(Bool.self, forKey: .autoGain) ?? defaults.autoGain
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? defaults.gainDB
        autoTempo = try c.decodeIfPresent(Bool.self, forKey: .autoTempo) ?? defaults.autoTempo
        if let bpm = try c.decodeIfPresent(Double.self, forKey: .sweepBPM) {
            sweepBPM = bpm
        } else if let turns = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Double.self, forKey: .sweepSpeed) {
            sweepBPM = turns * 60 * AudioProcessor.beatsPerTurn
        }
    }

    /// Fields from earlier versions.
    private enum LegacyKeys: CodingKey {
        /// Turns per second, before the sweep was set in BPM.
        case sweepSpeed
    }
}

/// A message for the user, shown as an alert.
struct Notice: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Owns the simulations and clocks, runs them each display frame, and holds
/// all the state the interface shows and edits.
@Observable
final class SimulationModel {
    // MARK: Interface state

    var settings = AppSettings() {
        didSet {
            if settings.palette != oldValue.palette || settings.colorCount != oldValue.colorCount {
                life?.setColors(lifeColors)
            }
        }
    }
    var params = PhysarumParams()
    var tool: Tool = .paint {
        didSet {
            quarterTurns = 0
            refreshGhost()
        }
    }
    private(set) var quarterTurns = 0
    private(set) var readouts = Readouts()
    private(set) var recordingFrames: Int?
    private(set) var isStartingRecording = false
    var notice: Notice?
    private(set) var source = SeedSource.life
    private(set) var isStartingCamera = false
    var cameraSettings = CameraSettings() {
        didSet {
            if source == .camera, cameraSettings.deviceID != oldValue.deviceID { Task { await startCamera() } }
        }
    }
    private(set) var cameraDevices: [CameraDevice] = []
    /// The camera in use while the source is the camera.
    private(set) var activeCamera: CameraDevice?
    private(set) var isStartingAudio = false
    var audioSettings = AudioSettings() {
        didSet {
            if source == .audio, audioSettings.inputID != oldValue.inputID { Task { await startAudio() } }
        }
    }
    private(set) var audioInputs: [AudioInput] = []
    /// The input in use while the source is audio.
    private(set) var activeAudioInput: AudioInput?
    /// The tempo of what's playing, once the detector has settled on one.
    private(set) var detectedTempo: Double?
    /// The audio input's peak level (0–1, before gain), refreshed with the readouts.
    /// Kept out of `readouts` so only the level meter redraws as it moves: the
    /// inspector re-laying out on every readout made the field stutter.
    private(set) var audioLevel: Float = 0
    /// The last export, for the status bar's "Show in Finder".
    private(set) var lastSaved: URL?
    let poolSizes: [Int]

    // MARK: Simulation

    @ObservationIgnored private let context: MetalContext
    @ObservationIgnored let compositor: Compositor
    @ObservationIgnored private var life: LifeRunner!
    @ObservationIgnored private let sim: PhysarumSim
    @ObservationIgnored private let scheduler: SpawnScheduler
    @ObservationIgnored private var lifeClock = FixedStepClock(hz: 1, maxStepsPerAdvance: 1)
    @ObservationIgnored private var physClock = FixedStepClock(hz: physarumHz, maxStepsPerAdvance: 4)
    @ObservationIgnored private var recordingLifeTicker = StepTicker()
    @ObservationIgnored private var pendingSeeds: [FoodSeed] = []
    // Which Life board updates belong to, and the newest board image shown.
    @ObservationIgnored private var lifeEpoch = 0
    @ObservationIgnored private var lastLifeSequence = 0
    @ObservationIgnored private var organismCount = 0
    @ObservationIgnored private var hover: Cell?
    @ObservationIgnored private var recorder: MovieRecorder?
    @ObservationIgnored private var camera: CameraSource?
    @ObservationIgnored private var deviceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var movingCells = 0
    @ObservationIgnored private var audio: AudioSource?
    @ObservationIgnored private var latestAudioLevel: Float = 0

    // MARK: Readouts

    @ObservationIgnored private var frames = RateMeter()
    @ObservationIgnored private var physSteps = RateMeter()
    @ObservationIgnored private var lifeInserts = RateMeter()
    @ObservationIgnored private var childInserts = RateMeter()
    @ObservationIgnored private var lastChildrenInserted: UInt32 = 0
    @ObservationIgnored private var readoutTimer: Timer?

    init?(context: MetalContext? = .shared) {
        guard let context else { return nil }
        self.context = context
        let poolSizes = supportedPoolSizes(maxBufferLength: context.device.maxBufferLength)
        var initial = AppSettings()
        if !poolSizes.contains(initial.poolSize), let largest = poolSizes.last { initial.poolSize = largest }
        self.poolSizes = poolSizes
        compositor = Compositor(context: context, gridSize: initial.lifeSize)
        sim = PhysarumSim(context: context, width: fieldSize, height: fieldSize,
                          poolSize: initial.poolSize, cellSize: cellSize(forLifeSize: initial.lifeSize))
        scheduler = SpawnScheduler(maxQueued: initial.poolSize)
        settings = initial
        life = LifeRunner(size: initial.lifeSize, seed: params.rngSeed, colors: lifeColors) { [weak self] update in
            self?.apply(update)
        }

        // Keep the camera list current, and leave Camera mode if its camera goes away.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.object as? AVCaptureDevice)?.uniqueID
                MainActor.assumeIsolated { self?.cameraDevicesChanged(disconnected: name == AVCaptureDevice.wasDisconnectedNotification ? id : nil) }
            })
        }

        // Keep the audio inputs current, and leave Audio mode if its input goes away.
        AudioCapture.observeChanges { [weak self] in self?.audioInputsChanged() }

        readoutTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReadouts() }
        }
    }

    var isRecording: Bool { recordingFrames != nil }

    /// The colors Life's organisms wear: the chosen palette at the chosen count.
    var lifeColors: [SIMD3<Float>] { paletteColors(settings.palette, count: settings.colorCount) }

    /// The colors sound is drawn in: the chosen palette at 12 colors, one per note, C first.
    var audioColors: [SIMD3<Float>] { paletteColors(settings.palette, count: audioColorCount) }

    /// The field the view shows: the trail, or the food map in food view.
    var displayedField: MTLTexture { settings.foodView ? sim.foodTexture : sim.trail }

    // MARK: Frame loop

    /// Advances the simulations by `dtMs` of wall-clock time.
    func advance(dtMs: Double) {
        if source == .camera { camera?.setConfig(cameraConfig) }
        if source == .audio { audio?.setConfig(audioConfig) }
        if recorder != nil { recordingFrame(dtMs) } else { liveFrame(dtMs) }
        frames.add()
    }

    /// Wall-clock pacing: Life and Physarum each follow their own clock.
    private func liveFrame(_ dtMs: Double) {
        lifeClock.hz = settings.lifeHz
        if settings.playing && source == .life {
            for _ in 0..<lifeClock.advance(dtMs) { lifeTick() }
        } else {
            lifeClock.reset()
        }
        for _ in 0..<physClock.advance(dtMs) { physStep() }
    }

    /// Movie pacing: every Physarum step becomes one frame, and Life ticks every
    /// `stepsPerLifeTick` steps, so the movie runs at the simulation's own speed.
    /// While the encoder is behind, steps are skipped rather than frames dropped.
    private func recordingFrame(_ dtMs: Double) {
        guard let recorder else { return }
        var steps = physClock.advance(dtMs)
        while steps > 0 && !recorder.isBusy {
            steps -= 1
            if settings.playing && source == .life && recordingLifeTicker.step(stepsPerTick: stepsPerLifeTick) {
                apply(life.tickNow(spawn: spawnSettings, maxActors: settings.poolSize))
            }
            physStep()
            do {
                try recorder.addFrame { commandBuffer, target in
                    compositor.encode(into: commandBuffer, target: target, field: sim.trail,
                                      physarumOpacity: settings.physarumOpacity, lifeOpacity: settings.lifeOpacity, ghostOpacity: 0)
                }
                recordingFrames = recorder.frameCount
            } catch {
                abandonRecording(error)
                return
            }
        }
        if steps > 0 { physClock.reset() }
    }

    private var stepsPerLifeTick: Int { max(1, Int((physarumHz / settings.lifeHz).rounded())) }

    /// One Life generation. It runs on Life's queue; its spawns and food are
    /// queued for the Physarum steps after it arrives.
    func lifeTick() {
        life.tick(spawn: spawnSettings, maxActors: settings.poolSize)
    }

    private var spawnSettings: SpawnSettings {
        SpawnSettings(actorsPerBirth: settings.actorsPerBirth, cellSize: Float(cellSize(forLifeSize: settings.lifeSize)),
                      minSpeed: Float(params.minSpeed), life: UInt32(clamping: params.life))
    }

    /// Takes in a change to the Life board: its new image, and a tick's spawns and food.
    private func apply(_ update: LifeRunner.Update) {
        guard update.epoch == lifeEpoch, update.gridSize == compositor.gridSize else { return }
        if update.isTick {
            scheduler.enqueue(update.actors, stepsUntilNextTick: stepsPerLifeTick)
            pendingSeeds.append(contentsOf: update.seeds)
        }
        guard update.sequence > lastLifeSequence else { return }
        lastLifeSequence = update.sequence
        if source == .life { compositor.setLife(update.texels) }
        organismCount = update.organismCount
        readouts.organisms = organismCount
    }

    private func physStep() {
        scheduler.mode = settings.spawnMode
        sim.params = params
        let spawns = scheduler.takeForStep(limit: sim.maxSpawnsPerStep)
        let seedCount = min(pendingSeeds.count, sim.maxFoodSeedsPerStep)
        let seeds = Array(pendingSeeds.prefix(seedCount))
        pendingSeeds.removeFirst(seedCount)
        // Counts are capped above, so this never throws.
        try? sim.step(spawns: spawns, seeds: seeds)
        physSteps.add()
        lifeInserts.add(spawns.count)
    }

    /// Encodes the composite for the window: the field (or food) with Life and
    /// the placement ghost, into `viewport` of `target`.
    func encodeDisplay(into commandBuffer: MTLCommandBuffer, target: MTLTexture, viewport: MTLViewport, background: MTLClearColor) {
        compositor.encode(into: commandBuffer, target: target, viewport: viewport, background: background, field: displayedField,
                          physarumOpacity: settings.physarumOpacity, lifeOpacity: settings.lifeOpacity, ghostOpacity: 1)
    }

    // MARK: Editing

    func togglePlaying() {
        settings.playing.toggle()
    }

    /// Changes the Life board (on Life's queue, after any tick in progress).
    func editWorld(_ edit: @escaping @Sendable (LifeWorld) -> Void) {
        life.edit(edit)
    }

    func clearBoard() { editWorld { $0.clear() } }

    func randomFill() {
        let density = settings.randomDensity
        editWorld { $0.randomFill(density: density) }
    }

    func step() {
        guard source == .life else { return }
        lifeTick()
    }

    func rotate() {
        quarterTurns = (quarterTurns + 1) % 4
        refreshGhost()
    }

    /// Applies the current tool at `cell`. Returns the painted state in paint
    /// mode (so a drag can keep painting it), nil for patterns.
    @discardableResult
    func click(_ cell: Cell) -> Bool? {
        guard source == .life else { return nil }
        switch tool {
        case .pattern(let pattern):
            let turns = quarterTurns
            editWorld { $0.place(pattern, x: cell.x, y: cell.y, quarterTurns: turns) }
            return nil
        case .paint:
            return life.toggle(cell)
        }
    }

    /// Paints `cell` to `alive` while dragging in paint mode.
    func paint(_ cells: [Cell], alive: Bool) {
        guard case .paint = tool, source == .life else { return }
        editWorld { $0.setCells(cells, alive: alive) }
    }

    func setHover(_ cell: Cell?) {
        guard cell != hover else { return }
        hover = cell
        refreshGhost()
    }

    private func refreshGhost() {
        let cells = source != .life ? [] : hover.map { ghostCells(tool.pattern, quarterTurns: quarterTurns, anchor: $0, gridSize: settings.lifeSize) } ?? []
        compositor.setGhost(ghostTexels(cells, gridSize: settings.lifeSize))
    }

    // MARK: Structural changes

    /// Starts an empty board at the new size. The food map and pending food are
    /// cleared because they are laid out in the old cell blocks; actors and trail stay.
    func setLifeSize(_ lifeSize: Int) {
        guard lifeSize != compositor.gridSize else { return }
        settings.lifeSize = lifeSize
        lifeEpoch += 1
        life.resize(lifeSize)
        sim.setCellSize(cellSize(forLifeSize: lifeSize))
        pendingSeeds = []
        compositor.setGridSize(lifeSize)
        hover = nil
    }

    func setPoolSize(_ poolSize: Int) {
        settings.poolSize = poolSize
        sim.setPoolSize(poolSize)
        scheduler.maxQueued = poolSize
        scheduler.clear()
        lastChildrenInserted = 0
    }

    func clearActors() {
        sim.clearActors()
        scheduler.clear()
        lastChildrenInserted = 0
    }

    func clearTrail() { sim.clearTrail() }
    func clearFood() { sim.clearFood() }

    /// Restarts the seeded RNG (palette choices, random fill, spawned actors' RNG states).
    func reseed(_ seed: Int) {
        params.rngSeed = seed
        life.reseed(seed)
    }

    func resetPhysarumParameters() {
        let seed = params.rngSeed
        params = PhysarumParams()
        params.rngSeed = seed
    }

    // MARK: Settings files

    func settingsFileData() throws -> Data {
        try SettingsFile.serialize(settings, params)
    }

    /// Applies a settings file. Board and pool size go through setLifeSize and
    /// setPoolSize, so they clear the board or actors as the inspector does.
    func loadSettings(from data: Data, name: String) {
        do {
            let loaded = try SettingsFile.parse(data, poolSizes: poolSizes)
            let newSettings = loaded.applied(to: settings)
            let newParams = loaded.applied(to: params)
            var plain = newSettings
            plain.lifeSize = settings.lifeSize
            plain.poolSize = settings.poolSize
            settings = plain
            if newSettings.lifeSize != settings.lifeSize { setLifeSize(newSettings.lifeSize) }
            if newSettings.poolSize != settings.poolSize { setPoolSize(newSettings.poolSize) }
            let seedChanged = newParams.rngSeed != params.rngSeed
            params = newParams
            if seedChanged { reseed(newParams.rngSeed) }
            if !loaded.warnings.isEmpty {
                notice = Notice(title: "Loaded “\(name)” with problems", message: loaded.warnings.joined(separator: "\n"))
            }
        } catch {
            notice = Notice(title: "Couldn’t open “\(name)”", message: error.localizedDescription)
        }
    }

    // MARK: Camera

    /// Switches what releases actors. Starting the camera or audio asks for
    /// permission the first time; if it can't start, the source stays as it was
    /// and a notice explains why.
    func setSource(_ newSource: SeedSource) async {
        guard newSource != source, !isStartingSource else { return }
        switch newSource {
        case .camera:
            await startCamera()
        case .audio:
            await startAudio()
        case .life:
            stopCamera()
            stopAudio()
            source = .life
            life.edit { _ in } // Shows the Life board again.
        }
        refreshGhost()
    }

    var isStartingSource: Bool { isStartingCamera || isStartingAudio }

    private func stopCamera() {
        camera?.stop()
        activeCamera = nil
        movingCells = 0
    }

    func refreshCameraDevices() {
        cameraDevices = CameraSource.devices()
    }

    private func cameraDevicesChanged(disconnected id: String?) {
        refreshCameraDevices()
        guard let id, source == .camera, let active = activeCamera, active.id == id else { return }
        Task { await setSource(.life) }
        notice = Notice(title: "“\(active.name)” was disconnected", message: "Actors are coming from Life again.")
    }

    private func startCamera() async {
        isStartingCamera = true
        defer { isStartingCamera = false }
        let camera = camera ?? CameraSource(config: cameraConfig, seed: params.rngSeed) { [weak self] update in
            self?.receive(update)
        }
        self.camera = camera
        do {
            activeCamera = try await camera.start(deviceID: cameraSettings.deviceID)
            stopAudio()
            source = .camera
            scheduler.clear()
        } catch {
            notice = Notice(title: "Couldn’t use the camera", message: error.localizedDescription)
        }
        refreshCameraDevices()
        refreshGhost()
    }

    private var cameraConfig: CameraConfig {
        CameraConfig(gridSize: settings.lifeSize, mirrored: cameraSettings.mirrored, threshold: Float(cameraSettings.motionThreshold),
                     colors: cameraSettings.colors, palette: lifeColors,
                     spawn: spawnSettings, maxActors: settings.poolSize, seeding: settings.playing,
                     trigger: cameraSettings.trigger, edgeThreshold: Float(cameraSettings.edgeThreshold))
    }

    /// Takes in a processed camera frame: its image, and its spawns and food.
    private func receive(_ update: CameraUpdate) {
        guard source == .camera, update.gridSize == compositor.gridSize else { return }
        // Frames arrive about as often as Physarum steps, so each frame's spawns go on the next step.
        scheduler.enqueue(update.actors, stepsUntilNextTick: 1)
        pendingSeeds.append(contentsOf: update.seeds)
        compositor.setLife(update.texels)
        movingCells = update.movingCells
    }

    // MARK: Audio

    func refreshAudioInputs() {
        let inputs = AudioCapture.inputs()
        if inputs != audioInputs { audioInputs = inputs }
    }

    private func audioInputsChanged() {
        refreshAudioInputs()
        guard source == .audio, let active = activeAudioInput, !audioInputs.contains(where: { $0.id == active.id }) else { return }
        Task { await setSource(.life) }
        notice = Notice(title: "“\(active.name)” went away", message: "Actors are coming from Life again.")
    }

    #if DEBUG
    /// Seeds from a generated tune instead of the chosen input (for DebugSnapshot).
    @ObservationIgnored private var playsTestTune = false

    func startTestTune() async {
        playsTestTune = true
        await setSource(.audio)
    }
    #endif

    private func startAudio() async {
        isStartingAudio = true
        defer { isStartingAudio = false }
        let audio = audio ?? AudioSource(config: audioConfig, seed: params.rngSeed) { [weak self] update in
            self?.receive(update)
        }
        self.audio = audio
        refreshAudioInputs()
        // A saved input that isn't listed now is still tried, so its failure can say what's missing.
        var input = audioSettings.inputID.map { id in
            audioInputs.first { $0.id == id } ?? AudioInput(id: id, name: id.hasPrefix("app:") ? String(id.dropFirst(4)) : id,
                                                            kind: AudioInput.kind(of: id))
        }
        #if DEBUG
        if playsTestTune { input = .test }
        #endif
        do {
            activeAudioInput = try await audio.start(input)
            stopCamera()
            source = .audio
            scheduler.clear()
        } catch {
            if source == .audio { stopAudio(); source = .life; life.edit { _ in } }
            notice = Notice(title: "Couldn’t listen to \(input?.name ?? "the audio input")", message: error.localizedDescription)
        }
        refreshGhost()
    }

    private func stopAudio() {
        audio?.stop()
        activeAudioInput = nil
        movingCells = 0
        latestAudioLevel = 0
        detectedTempo = nil
    }

    private var audioConfig: AudioConfig {
        AudioConfig(gridSize: settings.lifeSize, style: audioSettings.style, colors: audioSettings.colors, palette: audioColors,
                    threshold: Float(audioSettings.threshold), rangeDB: Float(audioSettings.rangeDB),
                    distance: audioSettings.distance, gainDB: Float(audioSettings.gainDB), autoGain: audioSettings.autoGain,
                    sweepBPM: audioSettings.sweepBPM, spawn: spawnSettings, maxActors: settings.poolSize, seeding: settings.playing)
    }

    /// Takes in a processed moment of sound: its drawing, and its spawns and food.
    private func receive(_ update: AudioUpdate) {
        guard source == .audio, update.gridSize == compositor.gridSize else { return }
        scheduler.enqueue(update.actors, stepsUntilNextTick: 1)
        pendingSeeds.append(contentsOf: update.seeds)
        compositor.setLife(update.texels)
        movingCells = update.litCells
        latestAudioLevel = update.inputLevel
        // Observers hear every assignment, equal or not, and updates arrive 30 times a second.
        if detectedTempo != update.tempo { detectedTempo = update.tempo }
        if audioSettings.autoTempo, let tempo = update.tempo {
            let rounded = (tempo * 10).rounded() / 10
            // Ignore drift under 1%, so the inspector isn't rebuilt every second for a tenth of a BPM.
            if abs(rounded - audioSettings.sweepBPM) > audioSettings.sweepBPM * 0.01 { audioSettings.sweepBPM = rounded }
        }
    }

    // MARK: Remembered settings

    private static let savedSettingsKey = "LastSessionSettings"
    private static let cameraSettingsKey = "CameraSettings"
    private static let audioSettingsKey = "AudioSettings"
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    /// Restores the last session's settings (as a settings file) from `defaults`,
    /// and saves them there when the app quits.
    func persistSettings(in defaults: UserDefaults) {
        if let data = defaults.data(forKey: Self.savedSettingsKey) {
            loadSettings(from: data, name: "last session’s settings")
            notice = nil // Settings from an older version just fall back to defaults.
        }
        if let data = defaults.data(forKey: Self.cameraSettingsKey),
           let saved = try? JSONDecoder().decode(CameraSettings.self, from: data) {
            cameraSettings = saved
        }
        if let data = defaults.data(forKey: Self.audioSettingsKey),
           let saved = try? JSONDecoder().decode(AudioSettings.self, from: data) {
            audioSettings = saved
        }
        nonisolated(unsafe) let defaults = defaults // UserDefaults is thread-safe
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSettings(to: defaults) }
        }
    }

    func saveSettings(to defaults: UserDefaults) {
        if let data = try? settingsFileData() { defaults.set(data, forKey: Self.savedSettingsKey) }
        if let data = try? JSONEncoder().encode(cameraSettings) { defaults.set(data, forKey: Self.cameraSettingsKey) }
        if let data = try? JSONEncoder().encode(audioSettings) { defaults.set(data, forKey: Self.audioSettingsKey) }
    }

    // MARK: Export

    /// Remembers a saved file for the status bar's "Show in Finder".
    func markSaved(_ url: URL) {
        lastSaved = url
    }

    /// Saves the Life layer, the Physarum trail and their mix as PNGs named
    /// `<base>-life.png` etc. next to `baseURL`.
    func exportImages(to baseURL: URL) async {
        let images = await compositor.capture(
            field: sim.trail,
            layers: [(0, 1), (1, 0), (settings.physarumOpacity, settings.lifeOpacity)],
            size: fieldSize, context: context)
        let directory = baseURL.deletingLastPathComponent()
        let base = baseURL.deletingPathExtension().lastPathComponent
        do {
            for (part, image) in zip(SnapshotPart.allCases, images) {
                try writePNG(image, to: directory.appending(path: snapshotFilename(base: base, part: part)))
            }
            lastSaved = directory
        } catch {
            notice = Notice(title: "Couldn’t save the images", message: error.localizedDescription)
        }
    }

    // MARK: Recording

    func startRecording(to url: URL) {
        guard recorder == nil else { return }
        do {
            let recorder = try MovieRecorder(url: url, context: context)
            self.recorder = recorder
            recordingLifeTicker.reset()
            recordingFrames = 0
            if let notice = recorder.config.notice {
                self.notice = Notice(title: "Recording at reduced quality", message: notice)
            }
        } catch {
            notice = Notice(title: "Couldn’t start recording", message: error.localizedDescription)
        }
    }

    func stopRecording() async {
        guard let recorder else { return }
        self.recorder = nil
        recordingFrames = nil
        lifeClock.reset()
        physClock.reset()
        do {
            try await recorder.finish()
            lastSaved = recorder.url
        } catch {
            notice = Notice(title: "Couldn’t finish the movie", message: error.localizedDescription)
        }
    }

    private func abandonRecording(_ error: Error) {
        recorder?.cancel()
        recorder = nil
        recordingFrames = nil
        notice = Notice(title: "Recording stopped", message: error.localizedDescription)
    }

    // MARK: Readouts

    private func updateReadouts() {
        let now = CACurrentMediaTime() * 1000
        let counters = sim.latestCounters
        if counters.childrenInserted >= lastChildrenInserted {
            childInserts.add(Int(counters.childrenInserted - lastChildrenInserted))
        }
        lastChildrenInserted = counters.childrenInserted
        readouts = Readouts(
            fps: frames.sample(nowMs: now),
            physStepsPerSec: physSteps.sample(nowMs: now),
            alive: Int(counters.aliveCount),
            organisms: organismCount,
            lifeInsertsPerSec: lifeInserts.sample(nowMs: now),
            childInsertsPerSec: childInserts.sample(nowMs: now),
            movingCells: movingCells)
        if audioLevel != latestAudioLevel { audioLevel = latestAudioLevel }
    }
}
