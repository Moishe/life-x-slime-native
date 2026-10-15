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
        #expect(Set(settings.keys) == ["lifeHz", "randomDensity", "actorsPerBirth", "spawnMode", "lifeOpacity", "physarumOpacity", "poolSize", "lifeSize"])
        #expect(settings["spawnMode"] as? String == "trickle")
        let physarum = json["physarum"] as! [String: Any]
        #expect(physarum.count == 28)
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
        var p = PhysarumParams()
        p.lookDistance = 33
        p.wrapBounds = false
        p.rngSeed = 5
        let loaded = try SettingsFile.parse(SettingsFile.serialize(s, p), poolSizes: poolSizes)
        #expect(loaded.warnings.isEmpty)
        #expect(loaded.applied(to: AppSettings()) == AppSettings(lifeOpacity: 0.3, poolSize: 1 << 16, lifeSize: 256, spawnMode: .burst))
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
            file(["lifeOpacity": "high", "spawnMode": "sometimes"], ["wrapBounds": 1, "lookDistance": NSNull(), "minSpeed": true]),
            poolSizes: poolSizes
        )
        #expect(loaded.settingKeys.isEmpty && loaded.physarumKeys.isEmpty)
        #expect(loaded.warnings == [
            "Skipped \"spawnMode\": expected \"burst\" or \"trickle\".",
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
}

private extension AppSettings {
    init(lifeOpacity: Double, poolSize: Int, lifeSize: Int, spawnMode: SpawnMode) {
        self.init()
        self.lifeOpacity = lifeOpacity
        self.poolSize = poolSize
        self.lifeSize = lifeSize
        self.spawnMode = spawnMode
    }
}
