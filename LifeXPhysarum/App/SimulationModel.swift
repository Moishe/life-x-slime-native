import AppKit
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

    var settings = AppSettings()
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
        life = LifeRunner(size: initial.lifeSize, seed: params.rngSeed) { [weak self] update in
            self?.apply(update)
        }

        readoutTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReadouts() }
        }
    }

    var isRecording: Bool { recordingFrames != nil }

    /// The field the view shows: the trail, or the food map in food view.
    var displayedField: MTLTexture { settings.foodView ? sim.foodTexture : sim.trail }

    // MARK: Frame loop

    /// Advances the simulations by `dtMs` of wall-clock time.
    func advance(dtMs: Double) {
        if recorder != nil { recordingFrame(dtMs) } else { liveFrame(dtMs) }
        frames.add()
    }

    /// Wall-clock pacing: Life and Physarum each follow their own clock.
    private func liveFrame(_ dtMs: Double) {
        lifeClock.hz = settings.lifeHz
        if settings.playing {
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
            if settings.playing && recordingLifeTicker.step(stepsPerTick: stepsPerLifeTick) {
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
        compositor.setLife(update.texels)
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
        guard case .paint = tool else { return }
        editWorld { $0.setCells(cells, alive: alive) }
    }

    func setHover(_ cell: Cell?) {
        guard cell != hover else { return }
        hover = cell
        refreshGhost()
    }

    private func refreshGhost() {
        let cells = hover.map { ghostCells(tool.pattern, quarterTurns: quarterTurns, anchor: $0, gridSize: settings.lifeSize) } ?? []
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

    // MARK: Remembered settings

    private static let savedSettingsKey = "LastSessionSettings"
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    /// Restores the last session's settings (as a settings file) from `defaults`,
    /// and saves them there when the app quits.
    func persistSettings(in defaults: UserDefaults) {
        if let data = defaults.data(forKey: Self.savedSettingsKey) {
            loadSettings(from: data, name: "last session’s settings")
            notice = nil // Settings from an older version just fall back to defaults.
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
            childInsertsPerSec: childInserts.sample(nowMs: now))
    }
}
