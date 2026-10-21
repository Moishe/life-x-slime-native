/// A named set of color stops for Life's organisms.
nonisolated struct NamedPalette: Identifiable, Sendable {
    /// The name in settings files, as in the web version.
    let name: String
    /// The name the interface shows.
    let title: String
    /// Stops in an order where neighbors blend well. Rainbow has none: it is
    /// generated as evenly spaced, fully saturated hues.
    let stops: [SIMD3<Float>]

    var id: String { name }

    init(_ name: String, _ title: String, _ hexes: [UInt32]) {
        self.name = name
        self.title = title
        stops = hexes.map { SIMD3(Float($0 >> 16 & 0xFF), Float($0 >> 8 & 0xFF), Float($0 & 0xFF)) / 255 }
    }
}

nonisolated let maxColors = 16

/// lcm(1...16): organisms draw a slot in 0..<colorSlots and wear slot % colorCount,
/// so the color count can change live and every count still picks colors uniformly.
nonisolated let colorSlots = 720_720

/// The web version's palettes, in its order.
nonisolated let palettes: [NamedPalette] = [
    NamedPalette("rainbow", "Rainbow", []),
    // sailorhg's fairyfloss editor theme.
    NamedPalette("fairy floss", "Fairy Floss", [0xFFB8D1, 0xFF857F, 0xE6C000, 0xFFF352, 0xC2FFDF, 0xC5A3FF, 0xAE81FF]),
    // The 1977–1998 six-stripe Apple logo, top to bottom.
    NamedPalette("apple 1980s", "Apple 1980s", [0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC]),
    NamedPalette("dracula", "Dracula", [0xFF79C6, 0xFF5555, 0xFFB86C, 0xF1FA8C, 0x50FA7B, 0x8BE9FD, 0xBD93F9]),
    NamedPalette("solarized", "Solarized", [0xB58900, 0xCB4B16, 0xDC322F, 0xD33682, 0x6C71C4, 0x268BD2, 0x2AA198, 0x859900]),
    NamedPalette("nord", "Nord", [0xBF616A, 0xD08770, 0xEBCB8B, 0xA3BE8C, 0x8FBCBB, 0x88C0D0, 0x81A1C1, 0xB48EAD]),
    NamedPalette("synthwave", "Synthwave", [0xFF71CE, 0xB967FF, 0x01CDFE, 0x05FFA1, 0xFFFB96]),
    NamedPalette("sunset", "Sunset", [0xF8B195, 0xF67280, 0xC06C84, 0x6C5B7B, 0x355C7D]),
    // PICO-8's 16 colors minus the blacks, greys and browns that vanish on the dark field.
    NamedPalette("pico-8", "PICO-8", [0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA, 0x7E2553, 0x008751]),
]

/// `count` colors from the named palette (rainbow if unknown): an even pick of
/// its stops when it has enough, otherwise blends between neighboring stops,
/// wrapping around.
nonisolated func paletteColors(_ name: String, count: Int) -> [SIMD3<Float>] {
    let n = min(maxColors, max(1, count))
    let stops = palettes.first { $0.name == name }?.stops ?? []
    if stops.isEmpty { return (0..<n).map { hsv2rgb(SIMD3(Float($0) / Float(n), 1, 1)) } }
    return (0..<n).map { i in
        // Color i sits at stop i * stops / n: stop k, plus a fraction toward the next.
        let k = i * stops.count / n
        if n <= stops.count { return stops[k] }
        let f = Float(i * stops.count - k * n) / Float(n)
        let a = stops[k], b = stops[(k + 1) % stops.count]
        return a + (b - a) * f
    }
}

/// The color an organism with this slot wears.
nonisolated func colorFor(_ colors: [SIMD3<Float>], slot: Int) -> SIMD3<Float> {
    colors[slot % colors.count]
}
