import Foundation

/// Reads and writes settings files in the web version's JSON format, so presets
/// move freely between the two.
enum SettingsFile {
    nonisolated static let version = 1

    enum Failure: LocalizedError, Equatable {
        case notASettingsFile
        case unsupportedVersion(String)

        var errorDescription: String? {
            switch self {
            case .notASettingsFile:
                "This file is not a Life x Physarum settings file."
            case .unsupportedVersion(let found):
                "This settings file is version \(found); this app reads version \(SettingsFile.version)."
            }
        }
    }

    /// Everything in the inspector except moment-to-moment state (playing, food view).
    private struct Saved: Codable {
        var lifeHz: Double
        var randomDensity: Double
        var actorsPerBirth: Int
        var spawnMode: String
        var palette: String
        var colorCount: Int
        var lifeOpacity: Double
        var physarumOpacity: Double
        var poolSize: Int
        var lifeSize: Int
    }

    private struct File: Codable {
        var version: Int
        var settings: Saved
        var physarum: PhysarumParams
    }

    static func serialize(_ s: AppSettings, _ params: PhysarumParams) throws -> Data {
        let saved = Saved(
            lifeHz: s.lifeHz, randomDensity: s.randomDensity, actorsPerBirth: s.actorsPerBirth,
            spawnMode: s.spawnMode.rawValue, palette: s.palette, colorCount: s.colorCount,
            lifeOpacity: s.lifeOpacity, physarumOpacity: s.physarumOpacity,
            poolSize: s.poolSize, lifeSize: s.lifeSize
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(version: version, settings: saved, physarum: params))
    }

    /// Reads a settings file. Fields that are unknown or invalid are skipped with
    /// a warning so one bad value doesn't spoil the rest; only an unreadable file
    /// or a different version is an error.
    static func parse(_ data: Data, poolSizes: [Int]) throws -> LoadedSettings {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = object as? [String: Any],
              let settings = root["settings"] as? [String: Any],
              let physarum = root["physarum"] as? [String: Any]
        else { throw Failure.notASettingsFile }
        guard let version = root["version"] as? NSNumber, !version.isBool, version.doubleValue == Double(Self.version) else {
            throw Failure.unsupportedVersion(root["version"].map(describe) ?? "undefined")
        }

        var loaded = LoadedSettings()
        loaded.settings = readSection(settings, fields: settingsFields, warnings: &loaded.warnings)
        loaded.physarum = readSection(physarum, fields: physarumFields, warnings: &loaded.warnings)

        if let i = loaded.settings.firstIndex(where: { $0.key == "lifeSize" }),
           let size = (settings["lifeSize"] as? NSNumber)?.intValue, !lifeSizes.contains(size) {
            let sizes = lifeSizes.map(String.init).joined(separator: ", ")
            loaded.warnings.append("Skipped \"lifeSize\": \(size) is not one of \(sizes).")
            loaded.settings.remove(at: i)
        }
        if let i = loaded.settings.firstIndex(where: { $0.key == "poolSize" }),
           let size = (settings["poolSize"] as? NSNumber)?.intValue, !poolSizes.contains(size),
           let fallback = poolSizes.max() {
            loaded.warnings.append("Pool size \(size) is not supported on this GPU; using \(fallback).")
            loaded.settings[i] = ("poolSize", { $0.poolSize = fallback })
        }
        return loaded
    }

    // MARK: Fields

    private struct Field<Root> {
        enum Kind { case number, bool, spawnMode, palette }
        let key: String
        let kind: Kind
        let apply: (Any, inout Root) -> Void
    }

    private static func number<Root>(_ key: String, _ path: WritableKeyPath<Root, Double>) -> Field<Root> {
        Field(key: key, kind: .number) { value, root in root[keyPath: path] = (value as! NSNumber).doubleValue }
    }

    private static func integer<Root>(_ key: String, _ path: WritableKeyPath<Root, Int>) -> Field<Root> {
        Field(key: key, kind: .number) { value, root in
            root[keyPath: path] = Int(clamping: Int64((value as! NSNumber).doubleValue.rounded()))
        }
    }

    private static func bool<Root>(_ key: String, _ path: WritableKeyPath<Root, Bool>) -> Field<Root> {
        Field(key: key, kind: .bool) { value, root in root[keyPath: path] = (value as! NSNumber).boolValue }
    }

    private static let settingsFields: [Field<AppSettings>] = [
        number("lifeHz", \.lifeHz),
        number("randomDensity", \.randomDensity),
        integer("actorsPerBirth", \.actorsPerBirth),
        Field(key: "spawnMode", kind: .spawnMode) { value, s in s.spawnMode = SpawnMode(rawValue: value as! String)! },
        Field(key: "palette", kind: .palette) { value, s in s.palette = value as! String },
        // Out-of-range counts are pulled in, as the web version's palette does.
        Field(key: "colorCount", kind: .number) { value, s in
            s.colorCount = min(maxColors, max(1, Int(clamping: Int64((value as! NSNumber).doubleValue.rounded()))))
        },
        number("lifeOpacity", \.lifeOpacity),
        number("physarumOpacity", \.physarumOpacity),
        integer("poolSize", \.poolSize),
        integer("lifeSize", \.lifeSize),
    ]

    private static let physarumFields: [Field<PhysarumParams>] = [
        integer("lookSlices", \.lookSlices),
        number("lookRadians", \.lookRadians),
        number("lookDistance", \.lookDistance),
        number("directionRandomization", \.directionRandomization),
        number("directionMomentum", \.directionMomentum),
        number("minSpeed", \.minSpeed),
        number("maxSpeed", \.maxSpeed),
        number("intensity", \.intensity),
        number("minValue", \.minValue),
        number("foodPerDeath", \.foodPerDeath),
        number("foodExhaustion", \.foodExhaustion),
        number("foodSensitivity", \.foodSensitivity),
        integer("life", \.life),
        integer("alwaysSpawnFromParent", \.alwaysSpawnFromParent),
        number("spawnRandomOffset", \.spawnRandomOffset),
        number("spawnProbability", \.spawnProbability),
        bool("spawnWithSeedColor", \.spawnWithSeedColor),
        number("directionVariance", \.directionVariance),
        number("speedVariance", \.speedVariance),
        integer("crowdingLimit", \.crowdingLimit),
        integer("lockToHsvAngles", \.lockToHsvAngles),
        number("hsvAngleOffset", \.hsvAngleOffset),
        number("hsvSaturationMultiplier", \.hsvSaturationMultiplier),
        number("hsvValueMultiplier", \.hsvValueMultiplier),
        number("fadeDecrement", \.fadeDecrement),
        number("blurMultiplier", \.blurMultiplier),
        integer("blurInterval", \.blurInterval),
        number("foodFadeDecrement", \.foodFadeDecrement),
        integer("foodFadeInterval", \.foodFadeInterval),
        bool("wrapBounds", \.wrapBounds),
        integer("rngSeed", \.rngSeed),
    ]

    /// Known keys in field order, then unknown keys alphabetically.
    private static func readSection<Root>(
        _ section: [String: Any], fields: [Field<Root>], warnings: inout [String]
    ) -> [(key: String, apply: (inout Root) -> Void)] {
        var out: [(key: String, apply: (inout Root) -> Void)] = []
        for field in fields {
            guard let value = section[field.key] else { continue }
            if let problem = typeProblem(value, field.kind) {
                warnings.append("Skipped \"\(field.key)\": \(problem).")
            } else {
                out.append((field.key, { field.apply(value, &$0) }))
            }
        }
        let known = Set(fields.map(\.key))
        for key in section.keys.sorted() where !known.contains(key) {
            warnings.append("Ignored unknown setting \"\(key)\".")
        }
        return out
    }

    private static func typeProblem<Root>(_ value: Any, _ kind: Field<Root>.Kind) -> String? {
        switch kind {
        case .spawnMode:
            return (value as? String).flatMap(SpawnMode.init(rawValue:)) == nil ? "expected \"burst\" or \"trickle\"" : nil
        case .palette:
            let names = palettes.map(\.name)
            return (value as? String).map(names.contains) == true ? nil : "expected one of \(names.joined(separator: ", "))"
        case .bool:
            return (value as? NSNumber)?.isBool == true ? nil : "expected true or false"
        case .number:
            guard let n = value as? NSNumber, !n.isBool, n.doubleValue.isFinite else { return "expected a number" }
            return nil
        }
    }

    private static func describe(_ value: Any) -> String {
        if let n = value as? NSNumber, !n.isBool { return n.stringValue }
        if let s = value as? String { return s }
        if value is NSNull { return "null" }
        return String(describing: value)
    }
}

/// Values read from a settings file, ready to apply over the current ones.
struct LoadedSettings {
    var settings: [(key: String, apply: (inout AppSettings) -> Void)] = []
    var physarum: [(key: String, apply: (inout PhysarumParams) -> Void)] = []
    var warnings: [String] = []

    var settingKeys: [String] { settings.map(\.key) }
    var physarumKeys: [String] { physarum.map(\.key) }

    func applied(to base: AppSettings) -> AppSettings {
        var s = base
        for field in settings { field.apply(&s) }
        return s
    }

    func applied(to base: PhysarumParams) -> PhysarumParams {
        var p = base
        for field in physarum { field.apply(&p) }
        return p
    }
}

private extension NSNumber {
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}
