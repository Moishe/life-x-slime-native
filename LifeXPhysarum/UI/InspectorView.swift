import SwiftUI

/// Every live-editable setting, in collapsible sections.
struct InspectorView: View {
    @Bindable var model: SimulationModel

    @AppStorage("section.layers") private var layersOpen = true
    @AppStorage("section.relief") private var reliefOpen = false
    @AppStorage("section.life") private var lifeOpen = true
    @AppStorage("section.camera") private var cameraOpen = true
    @AppStorage("section.audio") private var audioOpen = true
    @AppStorage("section.bridge") private var bridgeOpen = true
    @AppStorage("section.sensing") private var sensingOpen = true
    @AppStorage("section.movement") private var movementOpen = true
    @AppStorage("section.deposit") private var depositOpen = false
    @AppStorage("section.food") private var foodOpen = false
    @AppStorage("section.fade") private var fadeOpen = false
    @AppStorage("section.lifecycle") private var lifecycleOpen = false
    @AppStorage("section.world") private var worldOpen = false

    private let defaults = AppSettings()
    private let defaultParams = PhysarumParams()

    var body: some View {
        Form {
            layers
            relief
            life
            camera
            audio
            bridge
            sensing
            movement
            deposit
            food
            fade
            lifecycle
            world
        }
        .formStyle(.grouped)
    }

    // MARK: Sections

    private var layers: some View {
        Section("Layers", isExpanded: $layersOpen) {
            Picker("Show", selection: $model.settings.foodView) {
                Text("Trail").tag(false)
                Text("Food").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Show the pheromone trail, or the food left where Life cells died (T)")
            ParameterSlider(title: "Physarum Opacity", value: $model.settings.physarumOpacity, range: 0...1, step: 0.01,
                            defaultValue: defaults.physarumOpacity, key: "physarumOpacity", help: "How strongly the Physarum layer shows")
            ParameterSlider(title: "\(sourceLayerName) Opacity", value: $model.settings.lifeOpacity,
                            range: 0...1, step: 0.01, defaultValue: defaults.lifeOpacity, key: "lifeOpacity",
                            help: "How strongly the \(model.source == .life ? "Life cells show" : model.source == .camera ? "camera image shows" : "sound’s drawing shows") over the Physarum layer")
        }
    }

    private var relief: some View {
        Section("Relief", isExpanded: $reliefOpen) {
            ParameterSlider(title: "Relief", value: $model.settings.relief, range: 0...1, step: 0.01,
                            defaultValue: defaults.relief, key: "relief",
                            help: "How strongly the Physarum layer is shaded as terrain, lit from the side, where actors have piled up (0 = flat)")
            ParameterSlider(title: "Height", value: $model.settings.reliefHeight, range: 0...64, step: 0.5,
                            defaultValue: defaults.reliefHeight, unit: "px", key: "reliefHeight",
                            help: "How tall the piles look: the height field's scale in pixels")
            ParameterSlider(title: "Light Angle", value: $model.settings.lightAngle, range: 0...(2 * Double.pi), step: 0.01,
                            defaultValue: defaults.lightAngle, unit: "rad", key: "lightAngle",
                            help: "The direction the light comes from, around the field")
            ParameterSlider(title: "Light Elevation", value: $model.settings.lightElevation, range: 0.05...(Double.pi / 2), step: 0.01,
                            defaultValue: defaults.lightElevation, unit: "rad", key: "lightElevation",
                            help: "How high the light is above the field: low for long shadows, π/2 for straight overhead")
            ParameterSlider(title: "Height Gain", value: $model.settings.heightGain, range: 0...1, step: 0.005,
                            defaultValue: defaults.heightGain, key: "heightGain",
                            help: "How much each actor on a pixel raises the height field per step")
            ParameterSlider(title: "Height Decay", value: $model.settings.heightDecay, range: 0...0.2, step: 0.001,
                            defaultValue: defaults.heightDecay, key: "heightDecay",
                            help: "The fraction of the height field that settles away each step. Clear Trail flattens it")
        }
    }

    private var life: some View {
        Section("Life", isExpanded: $lifeOpen) {
            Picker("Board Size", selection: Binding(get: { model.settings.lifeSize }, set: { model.setLifeSize($0) })) {
                ForEach(lifeSizes, id: \.self) { size in
                    Text("\(size) × \(size)").tag(size)
                }
            }
            .help("Cells per side, and the camera’s resolution in Camera mode. Changing it starts an empty board and clears the food map")
            Group {
            ParameterSlider(title: "Tick Rate", value: $model.settings.lifeHz, range: 0.25...8, step: 0.25,
                            defaultValue: defaults.lifeHz, unit: "Hz", key: "lifeHz", help: "Life generations per second")
            ParameterSlider(title: "Fill Density", value: $model.settings.randomDensity, range: 0...1, step: 0.01,
                            defaultValue: defaults.randomDensity, key: "randomDensity", help: "Fraction of cells alive after Random Fill")
            HStack {
                Button("Random Fill", action: model.randomFill)
                Button("Clear Board", action: model.clearBoard)
            }
            }
            .disabled(model.source != .life)
            Group {
            Picker("Palette", selection: $model.settings.palette) {
                ForEach(palettes) { palette in
                    Text(palette.title).tag(palette.name)
                }
            }
            .help("The colors organisms wear, and so the colors of the actors they release and the food they leave. With the camera’s Colors set to Palette, the colors camera cells are matched to; in Audio mode, the colors sound is drawn in\npalette")
            ParameterSlider(title: "Color Count", value: $model.settings.colorCount, range: 1...maxColors,
                            defaultValue: defaults.colorCount, key: "colorCount",
                            help: "How many colors organisms wear. Fewer than the palette has picks evenly among them; more blends between neighbors. Audio always uses 12, one per note")
                .disabled(model.source == .audio)
            if model.source == .audio {
                PaletteSwatch(colors: model.audioColors, labels: noteNames)
                    .help("Audio draws in 12 of the palette’s colors, one per note, C to B. With Colors set to Pitch, every note takes its color in any octave")
            } else {
                PaletteSwatch(colors: model.lifeColors)
            }
            }
            .disabled(model.source == .camera && model.cameraSettings.colors != .palette)
        }
    }

    private var camera: some View {
        Section("Camera", isExpanded: $cameraOpen) {
            Picker("Camera", selection: $model.cameraSettings.deviceID) {
                Text("Default").tag(String?.none)
                ForEach(model.cameraDevices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .help("Which camera to use in Camera mode")
            Picker("Colors", selection: $model.cameraSettings.colors) {
                Text("Vivid").tag(CameraColors.vivid)
                Text("True").tag(CameraColors.trueColor)
                Text("Palette").tag(CameraColors.palette)
            }
            .pickerStyle(.segmented)
            .help("Vivid: the scene’s hues at full strength, which actors tell apart easily. True: the camera’s own colors, more faithful but muddier. Palette: the nearest color in the Life section’s palette")
            Toggle("Mirror", isOn: $model.cameraSettings.mirrored)
                .help("Flip the image left to right, so the field moves like a mirror")
            Picker("Spawn From", selection: $model.cameraSettings.trigger) {
                Text("Motion").tag(CameraTrigger.motion)
                Text("Edges").tag(CameraTrigger.edges)
            }
            .pickerStyle(.segmented)
            .help("Motion: cells whose image changes release actors. Edges: cells on an edge in the image release actors every frame, even in a still scene")
            if model.cameraSettings.trigger == .motion {
                ParameterSlider(title: "Motion Threshold", value: $model.cameraSettings.motionThreshold, range: 0.01...0.5, step: 0.01,
                                defaultValue: CameraSettings().motionThreshold,
                                help: "How much a cell’s brightness must change between frames to release actors. Raise it if a still scene sparkles")
            } else {
                ParameterSlider(title: "Edge Threshold", value: $model.cameraSettings.edgeThreshold, range: 0.02...1, step: 0.01,
                                defaultValue: CameraSettings().edgeThreshold,
                                help: "How sharply brightness must change across a cell for it to be an edge. Raise it to keep only the strongest outlines")
            }
        }
        .onAppear(perform: model.refreshCameraDevices)
    }

    private var sourceLayerName: String {
        switch model.source {
        case .life: "Life"
        case .camera: "Camera"
        case .audio: "Audio"
        }
    }

    private var audio: some View {
        Section("Audio", isExpanded: $audioOpen) {
            Picker("Input", selection: $model.audioSettings.inputID) {
                Text("Default Input").tag(String?.none)
                Section("Devices") {
                    ForEach(model.audioInputs.filter { $0.kind == .device }) { input in
                        Text(input.name).tag(Optional(input.id))
                    }
                }
                Section("Playing on This Mac") {
                    ForEach(model.audioInputs.filter { $0.kind != .device }) { input in
                        Text(input.name).tag(Optional(input.id))
                    }
                }
            }
            .help("What to listen to in Audio mode: a microphone or audio interface, a virtual device such as BlackHole (for routing Logic, Live or GarageBand here), everything the Mac plays, or one app that has played sound, such as Music. Listening to apps asks for System Audio Recording permission the first time")
            LabeledContent("Level") {
                AudioLevelMeter(model: model)
            }
            .help("The input’s peak level, before gain. If it stays empty while sound plays, check the input, and in System Settings → Privacy & Security, that Life × Physarum may use the microphone or record system audio")
            Picker("Style", selection: $model.audioSettings.style) {
                Text("Waveform").tag(AudioStyle.waveform)
                Text("Ring").tag(AudioStyle.ring)
                Text("Spectrum").tag(AudioStyle.spectrum)
                Text("Radial").tag(AudioStyle.radial)
            }
            .help("Waveform: an oscilloscope trace across the field. Ring: the trace wrapped around a circle. Spectrum: loudness by pitch, low notes on the left. Radial: pitch as distance from the center, swept around like radar, each turn drawn over the last. Every lit cell releases actors; cells that go dark leave food")
            Picker("Colors", selection: $model.audioSettings.colors) {
                Text("Pitch").tag(AudioColors.pitch)
                Text("Loudness").tag(AudioColors.loudness)
            }
            .pickerStyle(.segmented)
            .help("Picks colors from the Life section’s palette, at 12 colors. Pitch: each note of the scale, C to B, has its own color in any octave (the traces take the loudest note’s). Loudness: quiet takes the palette’s first colors, loud its last")
            Toggle("Auto Gain", isOn: $model.audioSettings.autoGain)
                .help("Scale the sound so its recent peak fills the field, whatever the input’s level")
            ParameterSlider(title: "Gain", value: $model.audioSettings.gainDB, range: -20...40, step: 0.5,
                            defaultValue: AudioSettings().gainDB, unit: "dB", help: "Boosts or cuts the sound, after Auto Gain if it’s on")
            ParameterSlider(title: "Threshold", value: $model.audioSettings.threshold, range: 0...1, step: 0.01,
                            defaultValue: AudioSettings().threshold,
                            help: "How loud the sound must be to light cells: a trace’s peak, or each band of the spectrum. Raise it to keep quiet passages and noise from spawning")
            if model.audioSettings.style == .spectrum || model.audioSettings.style == .radial {
                ParameterSlider(title: "Range", value: $model.audioSettings.rangeDB, range: 6...60, step: 1,
                                defaultValue: AudioSettings().rangeDB, unit: "dB",
                                help: "Only bands within this much of the loudest light, so the notes that stand out are drawn rather than every band over the threshold. 60 lights every band over the threshold")
            }
            if model.audioSettings.style == .radial {
                Picker("Distance", selection: $model.audioSettings.distance) {
                    Text("Pitch").tag(AudioDistance.pitch)
                    Text("Loudness").tag(AudioDistance.loudness)
                }
                .pickerStyle(.segmented)
                .help("What sets how far from the center each band is drawn. Pitch: low notes in the middle, high notes at the edge. Loudness: quiet in the middle, loud at the edge")
                ParameterSlider(title: "Sweep Tempo", value: $model.audioSettings.sweepBPM, range: 0...240, step: 0.1,
                                defaultValue: AudioSettings().sweepBPM, unit: "BPM",
                                help: "The radial sweep goes around once every 4 beats at this tempo, once a bar (0 = whole rings, every band lit all the way around)")
                    .disabled(model.audioSettings.autoTempo)
                Toggle(isOn: $model.audioSettings.autoTempo) {
                    HStack {
                        Text("Auto Tempo")
                        Spacer()
                        if model.audioSettings.autoTempo {
                            TempoStatus(model: model)
                        }
                    }
                }
                .help("Listen for the beat of what’s playing and set the Sweep Tempo to it. It takes several seconds of steady rhythm to settle, and follows when the tempo changes. Turn it off to keep the last tempo found")
            }
        }
        .onAppear(perform: model.refreshAudioInputs)
    }

    private var bridge: some View {
        Section("Bridge", isExpanded: $bridgeOpen) {
            ParameterSlider(title: "Actors per Birth", value: $model.settings.actorsPerBirth, range: 0...256,
                            defaultValue: defaults.actorsPerBirth, key: "actorsPerBirth",
                            help: "Physarum actors spawned in each newborn Life cell's block, each moving cell in Camera mode, or each lit cell in Audio mode")
            Picker("Spawn Mode", selection: $model.settings.spawnMode) {
                Text("Burst").tag(SpawnMode.burst)
                Text("Trickle").tag(SpawnMode.trickle)
            }
            .pickerStyle(.segmented)
            .help("Burst: a tick's spawns all arrive on the next step. Trickle: they're spread out until the next tick")
            Picker("Actor Pool", selection: Binding(get: { model.settings.poolSize }, set: { model.setPoolSize($0) })) {
                ForEach(model.poolSizes, id: \.self) { size in
                    Text(poolSizeLabel(size)).tag(size)
                }
            }
            .help("The most actors alive at once. Changing it clears all actors")
        }
    }

    private var sensing: some View {
        Section("Sensing", isExpanded: $sensingOpen) {
            ParameterSlider(title: "Look Slices", value: $model.params.lookSlices, range: 1...8, defaultValue: defaultParams.lookSlices,
                            key: "lookSlices", help: "Sensors on each side of an actor's heading")
            ParameterSlider(title: "Look Angle", value: $model.params.lookRadians, range: 0...Double.pi, step: 0.01,
                            defaultValue: defaultParams.lookRadians, unit: "rad", key: "lookRadians", help: "How far either side of its heading an actor looks")
            ParameterSlider(title: "Look Distance", value: $model.params.lookDistance, range: 1...64, step: 1,
                            defaultValue: defaultParams.lookDistance, unit: "px", key: "lookDistance", help: "How far ahead the sensors are")
        }
    }

    private var movement: some View {
        Section("Movement", isExpanded: $movementOpen) {
            ParameterSlider(title: "Wander", value: $model.params.directionRandomization, range: 0...2, step: 0.01,
                            defaultValue: defaultParams.directionRandomization, key: "directionRandomization", help: "Random turning added each step")
            ParameterSlider(title: "Momentum", value: $model.params.directionMomentum, range: 0...1, step: 0.01,
                            defaultValue: defaultParams.directionMomentum, key: "directionMomentum", help: "How much of the old heading is kept when turning")
            ParameterSlider(title: "Min Speed", value: $model.params.minSpeed, range: 0...5, step: 0.01,
                            defaultValue: defaultParams.minSpeed, unit: "px", key: "minSpeed", help: "Speed of new and respawned actors, per step")
            ParameterSlider(title: "Max Speed", value: $model.params.maxSpeed, range: 0...10, step: 0.01,
                            defaultValue: defaultParams.maxSpeed, unit: "px", key: "maxSpeed", help: "Actors speed up slowly to this, per step")
        }
    }

    private var deposit: some View {
        Section("Deposit & Color", isExpanded: $depositOpen) {
            ParameterSlider(title: "Intensity", value: $model.params.intensity, range: 0...2, step: 0.01,
                            defaultValue: defaultParams.intensity, key: "intensity", help: "How far an actor's deposit blends from the trail under it toward its own color")
            ParameterSlider(title: "Min Brightness", value: $model.params.minValue, range: 0...1, step: 0.01,
                            defaultValue: defaultParams.minValue, key: "minValue",
                            help: "Keeps actors' colors at least this bright after blending, so colonies crossing the dark field don't fade to black (0 = off)")
            ParameterSlider(title: "Lock to Hues", value: $model.params.lockToHsvAngles, range: 0...12,
                            defaultValue: defaultParams.lockToHsvAngles, key: "lockToHsvAngles", help: "Snap respawned actors' hues to this many directions (0 = off)")
            ParameterSlider(title: "Hue Offset", value: $model.params.hsvAngleOffset, range: 0...1, step: 0.01,
                            defaultValue: defaultParams.hsvAngleOffset, key: "hsvAngleOffset", help: "Added to locked hues (1 = no offset)")
            ParameterSlider(title: "Saturation ×", value: $model.params.hsvSaturationMultiplier, range: 0...2, step: 0.01,
                            defaultValue: defaultParams.hsvSaturationMultiplier, key: "hsvSaturationMultiplier", help: "Scales locked colors' saturation")
            ParameterSlider(title: "Value ×", value: $model.params.hsvValueMultiplier, range: 0...2, step: 0.01,
                            defaultValue: defaultParams.hsvValueMultiplier, key: "hsvValueMultiplier", help: "Scales locked colors' brightness")
        }
    }

    private var food: some View {
        Section("Food", isExpanded: $foodOpen) {
            ParameterSlider(title: "Food per Death", value: $model.params.foodPerDeath, range: 0...1, step: 0.01,
                            defaultValue: defaultParams.foodPerDeath, key: "foodPerDeath", help: "Food left over a Life cell's block when it dies, in its organism's color")
            ParameterSlider(title: "Exhaustion", value: $model.params.foodExhaustion, range: 0...1, step: 0.01,
                            defaultValue: defaultParams.foodExhaustion, key: "foodExhaustion", help: "Actors die on food at least this dense (0 = never)")
            ParameterSlider(title: "Sensitivity", value: $model.params.foodSensitivity, range: 0...2, step: 0.01,
                            defaultValue: defaultParams.foodSensitivity, key: "foodSensitivity", help: "How strongly actors steer toward food of their own hue")
        }
    }

    private var fade: some View {
        Section("Fade", isExpanded: $fadeOpen) {
            ParameterSlider(title: "Trail Fade", value: $model.params.fadeDecrement, range: 0...0.1, step: 0.001,
                            defaultValue: defaultParams.fadeDecrement, key: "fadeDecrement", help: "Subtracted from the trail on each fade step. The trail has 256 levels, so values under about 0.002 don't fade it; use Fade Every to fade more slowly")
            ParameterSlider(title: "Blur Center Weight", value: $model.params.blurMultiplier, range: 0...16, step: 0.1,
                            defaultValue: defaultParams.blurMultiplier, key: "blurMultiplier", help: "Weight of each pixel against its 8 neighbors when blurring (0 = no blur)")
            ParameterSlider(title: "Blur Every", value: $model.params.blurInterval, range: 1...10,
                            defaultValue: defaultParams.blurInterval, unit: "steps", key: "blurInterval", help: "Blur the trail every this many steps")
            ParameterSlider(title: "Fade Every", value: $model.params.fadeInterval, range: 1...100,
                            defaultValue: defaultParams.fadeInterval, unit: "steps", key: "fadeInterval",
                            help: "Fade the trail every this many steps, for trails that last longer")
            ParameterSlider(title: "Food Fade", value: $model.params.foodFadeDecrement, range: 0...0.1, step: 0.0005,
                            defaultValue: defaultParams.foodFadeDecrement, key: "foodFadeDecrement", help: "Subtracted from the food map on each food fade step")
            ParameterSlider(title: "Food Fade Every", value: $model.params.foodFadeInterval, range: 1...10,
                            defaultValue: defaultParams.foodFadeInterval, unit: "steps", key: "foodFadeInterval", help: "Fade the food map every this many steps")
        }
    }

    private var lifecycle: some View {
        Section("Reproduction & Lifecycle", isExpanded: $lifecycleOpen) {
            ParameterSlider(title: "Reproduction", value: $model.params.spawnProbability, range: 0...0.05, step: 0.0001,
                            defaultValue: defaultParams.spawnProbability, key: "spawnProbability", help: "Chance per step that an actor has a child")
            ParameterSlider(title: "Crowding Limit", value: $model.params.crowdingLimit, range: 0...64,
                            defaultValue: defaultParams.crowdingLimit, key: "crowdingLimit",
                            help: "Only the first this-many actors on one pixel each step may have a child, which keeps dense colonies from swamping the pool (0 = no limit)")
            ParameterSlider(title: "Child Heading Spread", value: $model.params.directionVariance, range: 0...Double.pi, step: 0.01,
                            defaultValue: defaultParams.directionVariance, unit: "rad", key: "directionVariance", help: "Children head off up to this far from their parent's heading")
            ParameterSlider(title: "Child Speed Spread", value: $model.params.speedVariance, range: 0...1, step: 0.01,
                            defaultValue: defaultParams.speedVariance, key: "speedVariance", help: "Children's speed varies by up to this fraction of their parent's")
            ParameterSlider(title: "Spawn Offset", value: $model.params.spawnRandomOffset, range: 0...16, step: 0.1,
                            defaultValue: defaultParams.spawnRandomOffset, unit: "px", key: "spawnRandomOffset", help: "How far to the side of a parent children and respawns appear")
            Picker("On Death", selection: $model.params.alwaysSpawnFromParent) {
                Text("Respawn at a Random Actor").tag(1)
                Text("Respawn Anywhere").tag(0)
                Text("Stay Dead").tag(-1)
            }
            .help("What happens to an actor that dies of old age, exhaustion or leaving the field (always_spawn_from_parent)")
            Toggle("Inherit Seed Color", isOn: $model.params.spawnWithSeedColor)
                .help("Children and actors respawned at a parent start in the parent's original color instead of the color it has picked up from the trail\nspawnWithSeedColor")
            ParameterSlider(title: "Lifespan", value: $model.params.life, range: 1...100_000,
                            defaultValue: defaultParams.life, unit: "steps", key: "life", help: "Steps an actor lives, given when it's inserted or respawned")
        }
    }

    private var world: some View {
        Section("World", isExpanded: $worldOpen) {
            Toggle("Wrap at Edges", isOn: $model.params.wrapBounds)
                .help("Actors leaving one edge come back at the other; otherwise they die")
            LabeledContent("Random Seed") {
                TextField("Random Seed", value: Binding(get: { model.params.rngSeed }, set: { model.reseed($0) }),
                          format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
            }
            .help("Restarts the random sequence for organism colors, random fill and new actors")
            HStack {
                Button("Clear Trail", action: model.clearTrail)
                Button("Clear Food", action: model.clearFood)
                Button("Clear Actors", action: model.clearActors)
            }
            Button("Reset Physarum Parameters", action: model.resetPhysarumParameters)
                .help("Sets every Sensing, Movement, Deposit, Food, Fade, Lifecycle and World value back to its default")
        }
    }
}

/// The audio input's level. Its own view, so only it updates as the level moves,
/// and drawn with shapes and a scale rather than a Gauge: a Gauge is an AppKit
/// control whose every change relays out the whole inspector form, which costs
/// enough to drop frames from the field.
private struct AudioLevelMeter: View {
    let model: SimulationModel

    var body: some View {
        let level = min(1, max(0, CGFloat(model.audioLevel)))
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(level >= 0.99 ? Color.red : Color.accentColor)
                    .scaleEffect(x: level, y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: 6)
            .accessibilityElement()
            .accessibilityLabel("Input level")
            .accessibilityValue(Text(level, format: .percent.precision(.fractionLength(0))))
    }
}

/// Whether Auto Tempo has found a tempo yet. Its own view, like AudioLevelMeter.
private struct TempoStatus: View {
    let model: SimulationModel

    var body: some View {
        Text(model.detectedTempo == nil ? "Listening…" : "Detected")
            .foregroundStyle(.secondary)
    }
}
