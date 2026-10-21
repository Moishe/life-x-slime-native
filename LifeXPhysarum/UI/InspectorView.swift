import SwiftUI

/// Every live-editable setting, in collapsible sections.
struct InspectorView: View {
    @Bindable var model: SimulationModel

    @AppStorage("section.layers") private var layersOpen = true
    @AppStorage("section.life") private var lifeOpen = true
    @AppStorage("section.camera") private var cameraOpen = true
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
            life
            camera
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
            ParameterSlider(title: model.source == .camera ? "Camera Opacity" : "Life Opacity", value: $model.settings.lifeOpacity,
                            range: 0...1, step: 0.01, defaultValue: defaults.lifeOpacity, key: "lifeOpacity",
                            help: model.source == .camera ? "How strongly the camera image shows over the Physarum layer"
                                                          : "How strongly the Life cells show over the Physarum layer")
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
            .disabled(model.source == .camera)
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
            }
            .pickerStyle(.segmented)
            .help("Vivid: the scene’s hues at full strength, which actors tell apart easily. True: the camera’s own colors, more faithful but muddier")
            Toggle("Mirror", isOn: $model.cameraSettings.mirrored)
                .help("Flip the image left to right, so the field moves like a mirror")
            ParameterSlider(title: "Motion Threshold", value: $model.cameraSettings.motionThreshold, range: 0.01...0.5, step: 0.01,
                            defaultValue: CameraSettings().motionThreshold,
                            help: "How much a cell’s brightness must change between frames to release actors. Raise it if a still scene sparkles")
        }
        .onAppear(perform: model.refreshCameraDevices)
    }

    private var bridge: some View {
        Section("Bridge", isExpanded: $bridgeOpen) {
            ParameterSlider(title: "Actors per Birth", value: $model.settings.actorsPerBirth, range: 0...256,
                            defaultValue: defaults.actorsPerBirth, key: "actorsPerBirth",
                            help: "Physarum actors spawned in each newborn Life cell's block, or each moving cell in Camera mode")
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
                            defaultValue: defaultParams.fadeDecrement, key: "fadeDecrement", help: "Subtracted from the trail on each blur step")
            ParameterSlider(title: "Blur Center Weight", value: $model.params.blurMultiplier, range: 0...16, step: 0.1,
                            defaultValue: defaultParams.blurMultiplier, key: "blurMultiplier", help: "Weight of each pixel against its 8 neighbors when blurring (0 = no blur)")
            ParameterSlider(title: "Blur Every", value: $model.params.blurInterval, range: 1...10,
                            defaultValue: defaultParams.blurInterval, unit: "steps", key: "blurInterval", help: "Blur and fade the trail every this many steps")
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
