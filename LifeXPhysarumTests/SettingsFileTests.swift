import Foundation
import Testing
@testable import LifeXPhysarum

@Suite struct SettingsFileTests {
    let poolSizes = (14...20).map { 1 << $0 }

    func file(_ settings: [String: Any], _ physarum: [String: Any], version: Any = SettingsFile.version) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": version, "settings": settings, "physarum": physarum])
    }

    @Test func serializesVersionedJSONWithoutMomentToMomentState() throws {
        var s = AppSettings()
        s.playing = false
        s.foodView = true
        let json = try JSONSerialization.jsonObject(with: SettingsFile.serialize(s, PhysarumParams())) as! [String: Any]
        #expect(json["version"] as? Int == SettingsFile.version)
        let settings = json["settings"] as! [String: Any]
        #expect(Set(settings.keys) == ["lifeHz", "randomDensity", "actorsPerBirth", "spawnMode", "palette", "colorCount",
                                        "lifeOpacity", "physarumOpacity", "poolSize", "lifeSize"])
        #expect(settings["palette"] as? String == "rainbow" && settings["colorCount"] as? Int == 8)
        #expect(settings["spawnMode"] as? String == "trickle")
        let physarum = json["physarum"] as! [String: Any]
        #expect(physarum.count == 32)
        #expect(physarum["minValue"] as? Double == 0 && physarum["crowdingLimit"] as? Int == 0)
        #expect(physarum["spawnWithSeedColor"] as? Bool == false)
        #expect(physarum["lookRadians"] as? Double == 1.31)
        #expect(physarum["wrapBounds"] as? Bool == true)
    }

    @Test func writesNumbersTheWayTheWebVersionDoes() throws {
        let text = String(decoding: try SettingsFile.serialize(AppSettings(), PhysarumParams()), as: UTF8.self)
        #expect(text.contains("\"intensity\" : 0.37"))
        #expect(text.contains("\"physarumOpacity\" : 1"))
        #expect(text.contains("\"spawnProbability\" : 0.0134"))
    }

    @Test func roundTripsEverythingThatWasSaved() throws {
        var s = AppSettings()
        s.lifeOpacity = 0.3
        s.lifeSize = 256
        s.spawnMode = .burst
        s.poolSize = 1 << 16
        s.palette = "fairy floss"
        s.colorCount = 5
        var p = PhysarumParams()
        p.lookDistance = 33
        p.wrapBounds = false
        p.rngSeed = 5
        p.minValue = 0.25
        p.crowdingLimit = 9
        p.spawnWithSeedColor = true
        p.fadeInterval = 4
        let loaded = try SettingsFile.parse(SettingsFile.serialize(s, p), poolSizes: poolSizes)
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.applied(to: AppSettings()) == s)
        #expect(loaded.applied(to: PhysarumParams()) == p)
    }

    @Test func leavesOutKeysTheFileDoesNotMention() throws {
        let loaded = try SettingsFile.parse(file(["lifeHz": 2], ["lookSlices": 4]), poolSizes: poolSizes)
        #expect(loaded.settingKeys == ["lifeHz"])
        #expect(loaded.physarumKeys == ["lookSlices"])
        #expect(loaded.applied(to: AppSettings()).lifeHz == 2)
        #expect(loaded.applied(to: PhysarumParams()).lookSlices == 4)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func ignoresUnknownKeysWithAWarning() throws {
        let loaded = try SettingsFile.parse(file(["playing": false, "colour": "red"], ["warpFactor": 9]), poolSizes: poolSizes)
        #expect(loaded.settingKeys.isEmpty && loaded.physarumKeys.isEmpty)
        #expect(loaded.warnings == [
            "Ignored unknown setting \"colour\".",
            "Ignored unknown setting \"playing\".",
            "Ignored unknown setting \"warpFactor\".",
        ])
    }

    @Test func skipsValuesOfTheWrongTypeWithAWarning() throws {
        let loaded = try SettingsFile.parse(
            file(["lifeOpacity": "high", "spawnMode": "sometimes", "palette": "plaid"],
                 ["wrapBounds": 1, "lookDistance": NSNull(), "minSpeed": true]),
            poolSizes: poolSizes
        )
        #expect(loaded.settingKeys.isEmpty && loaded.physarumKeys.isEmpty)
        #expect(loaded.warnings == [
            "Skipped \"spawnMode\": expected \"burst\" or \"trickle\".",
            "Skipped \"palette\": expected one of rainbow, fairy floss, apple 1980s, dracula, solarized, nord, synthwave, sunset, pico-8.",
            "Skipped \"lifeOpacity\": expected a number.",
            "Skipped \"lookDistance\": expected a number.",
            "Skipped \"minSpeed\": expected a number.",
            "Skipped \"wrapBounds\": expected true or false.",
        ])
    }

    @Test func skipsAnUnsupportedBoardSizeWithAWarning() throws {
        let loaded = try SettingsFile.parse(file(["lifeSize": 300], [:]), poolSizes: poolSizes)
        #expect(loaded.settingKeys.isEmpty)
        #expect(loaded.warnings == ["Skipped \"lifeSize\": 300 is not one of 64, 128, 256, 512, 1024."])
    }

    @Test func fallsBackToTheLargestSupportedPoolSizeWithAWarning() throws {
        let loaded = try SettingsFile.parse(file(["poolSize": 1 << 22], [:]), poolSizes: poolSizes)
        #expect(loaded.applied(to: AppSettings()).poolSize == 1 << 20)
        #expect(loaded.warnings == ["Pool size 4194304 is not supported on this GPU; using 1048576."])
    }

    @Test func rejectsTextThatIsNotJSON() {
        #expect(throws: SettingsFile.Failure.notASettingsFile) {
            try SettingsFile.parse(Data("not json {".utf8), poolSizes: poolSizes)
        }
    }

    @Test func rejectsAFileWithNoSettingsObject() {
        #expect(throws: SettingsFile.Failure.notASettingsFile) {
            try SettingsFile.parse(Data("[1, 2, 3]".utf8), poolSizes: poolSizes)
        }
    }

    @Test func rejectsADifferentFileVersion() {
        #expect(throws: SettingsFile.Failure.unsupportedVersion("99")) {
            try SettingsFile.parse(file([:], [:], version: 99), poolSizes: poolSizes)
        }
        #expect(SettingsFile.Failure.unsupportedVersion("99").localizedDescription
            == "This settings file is version 99; this app reads version 1.")
    }

    @Test func readsAFileSavedByTheWebVersion() throws {
        let web = """
        {
          "version": 1,
          "settings": { "lifeHz": 7.5, "randomDensity": 0.2, "actorsPerBirth": 129, "spawnMode": "trickle",
                        "lifeOpacity": 0.05, "physarumOpacity": 1, "poolSize": 1048576, "lifeSize": 64 },
          "physarum": { "lookSlices": 6, "lookRadians": 1.31, "lookDistance": 17, "directionRandomization": 0.35,
                        "directionMomentum": 0.25, "minSpeed": 1.13, "maxSpeed": 2.81, "intensity": 0.37,
                        "foodPerDeath": 0.5, "foodExhaustion": 0, "foodSensitivity": 0.1, "life": 20000,
                        "alwaysSpawnFromParent": 1, "spawnRandomOffset": 1, "spawnProbability": 0.0134,
                        "directionVariance": 1.65, "speedVariance": 0.1, "lockToHsvAngles": 0, "hsvAngleOffset": 1,
                        "hsvSaturationMultiplier": 1, "hsvValueMultiplier": 1, "fadeDecrement": 0.001,
                        "blurMultiplier": 10.6, "blurInterval": 1, "foodFadeDecrement": 0.002, "foodFadeInterval": 1,
                        "wrapBounds": true, "rngSeed": 1 }
        }
        """
        let loaded = try SettingsFile.parse(Data(web.utf8), poolSizes: poolSizes)
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.settingKeys.count == 8 && loaded.physarumKeys.count == 28)
        #expect(loaded.applied(to: PhysarumParams()) == PhysarumParams())
    }

    @Test func fadesOnTheBlurIntervalWhenAFileHasNoFadeInterval() throws {
        // The web version fades the trail only on blur steps.
        let web = try SettingsFile.parse(file([:], ["blurInterval": 3]), poolSizes: poolSizes)
        #expect(web.applied(to: PhysarumParams()).fadeInterval == 3)
        let native = try SettingsFile.parse(file([:], ["blurInterval": 3, "fadeInterval": 5]), poolSizes: poolSizes)
        #expect(native.applied(to: PhysarumParams()).fadeInterval == 5)
        #expect(web.warnings.isEmpty && native.warnings.isEmpty)
    }

    @Test func readsTheWebVersionsPaletteAndNewParameters() throws {
        let web = """
        {
          "version": 1,
          "settings": { "palette": "pico-8", "colorCount": 12 },
          "physarum": { "minValue": 0.4, "spawnWithSeedColor": true, "crowdingLimit": 6 }
        }
        """
        let loaded = try SettingsFile.parse(Data(web.utf8), poolSizes: poolSizes)
        #expect(loaded.warnings.isEmpty)
        let s = loaded.applied(to: AppSettings())
        #expect(s.palette == "pico-8" && s.colorCount == 12)
        let p = loaded.applied(to: PhysarumParams())
        #expect(p.minValue == 0.4 && p.spawnWithSeedColor && p.crowdingLimit == 6)
    }
}

@Suite @MainActor struct SettingsPersistenceTests {
    /// removePersistentDomain leaves an empty plist behind; delete it too.
    private func removeSuite(_ suite: String, _ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suite)
        let file = URL.libraryDirectory.appending(path: "Preferences/\(suite).plist")
        try? FileManager.default.removeItem(at: file)
    }

    @Test func restoresTheLastSessionsSettings() throws {
        let suite = "LifeXPhysarumTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeSuite(suite, defaults) }

        let first = try #require(SimulationModel())
        first.params.lookDistance = 33
        first.settings.lifeHz = 3
        first.saveSettings(to: defaults)

        let second = try #require(SimulationModel())
        second.persistSettings(in: defaults)
        #expect(second.params.lookDistance == 33)
        #expect(second.settings.lifeHz == 3)
        #expect(second.notice == nil)
    }

    @Test func cameraSettingsSavedBeforeColorsExistedStillLoad() throws {
        let old = Data(#"{"mirrored":false,"motionThreshold":0.2}"#.utf8)
        let settings = try JSONDecoder().decode(CameraSettings.self, from: old)
        var expected = CameraSettings()
        expected.mirrored = false
        expected.motionThreshold = 0.2
        #expect(settings == expected && settings.colors == .vivid && settings.trigger == .motion)
    }

    @Test func startsFromDefaultsWhenNothingIsSaved() throws {
        let suite = "LifeXPhysarumTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeSuite(suite, defaults) }
        let model = try #require(SimulationModel())
        model.persistSettings(in: defaults)
        #expect(model.params.lookDistance == PhysarumParams().lookDistance)
    }
}
