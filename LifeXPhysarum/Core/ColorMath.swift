import simd

// CPU reference for the color math in Shaders/Common.h. Keep the two in sync;
// ColorShaderTests checks that they agree. Hue, saturation and value are all in [0, 1].

nonisolated private func fract(_ x: Float) -> Float { x - x.rounded(.down) }
nonisolated private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
nonisolated private func step(_ edge: Float, _ x: Float) -> Float { x < edge ? 0 : 1 }
nonisolated private func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }

/// Branchless conversion, ported from Particles' Shaders.metal.
nonisolated func rgb2hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
    let (r, g, b) = (c.x, c.y, c.z)
    let s1 = step(b, g)
    let p = SIMD4<Float>(mix(b, g, s1), mix(g, b, s1), mix(-1, 0, s1), mix(2.0 / 3, -1.0 / 3, s1))
    let s2 = step(p.x, r)
    let q = SIMD4<Float>(mix(p.x, r, s2), p.y, mix(p.w, p.z, s2), mix(r, p.x, s2))
    let d = q.x - min(q.w, q.y)
    let e: Float = 1.0e-10
    let h = abs(q.z + (q.w - q.y) / (6 * d + e))
    return SIMD3(h, d / (q.x + e), q.x)
}

nonisolated func hsv2rgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
    let (h, s, v) = (c.x, c.y, c.z)
    func channel(_ k: Float) -> Float { v * mix(1, clamp01(abs(fract(h + k) * 6 - 3) - 1), s) }
    return SIMD3(channel(1), channel(2.0 / 3), channel(1.0 / 3))
}

/// Distance between two HSV colors, treating hue as circular.
nonisolated func hsvDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let dh = abs(a.x - b.x)
    let hd = min(dh, 1 - dh)
    let sd = a.y - b.y
    let vd = a.z - b.z
    return (hd * hd + sd * sd + vd * vd).squareRoot()
}

/// Blends two RGB colors in HSV space, going the short way around the hue
/// circle. `d` is the weight toward `rgb2`.
nonisolated func hsvMix(_ rgb1: SIMD3<Float>, _ rgb2: SIMD3<Float>, _ d: Float) -> SIMD3<Float> {
    let a = rgb2hsv(rgb1)
    let b = rgb2hsv(rgb2)
    let dh = abs(a.x - b.x)
    let h: Float
    if dh < 1 - dh {
        h = mix(a.x, b.x, d)
    } else if a.x < b.x {
        h = fract(mix(a.x + 1, b.x, d))
    } else {
        h = fract(mix(a.x, b.x + 1, d))
    }
    return hsv2rgb(SIMD3(h, mix(a.y, b.y, d), mix(a.z, b.z, d)))
}

nonisolated struct HueLock {
    var lockToHsvAngles: Int
    var hsvAngleOffset: Float
    var hsvSaturationMultiplier: Float
    var hsvValueMultiplier: Float
}

/// Snaps a color's hue to one of `lockToHsvAngles` directions (0 = off), then
/// offsets the hue and scales saturation/value.
nonisolated func dominantColor(_ rgb: SIMD3<Float>, _ lock: HueLock) -> SIMD3<Float> {
    guard lock.lockToHsvAngles != 0 else { return rgb }
    let hsv = rgb2hsv(rgb)
    let n = Float(lock.lockToHsvAngles)
    let h = fmodf((hsv.x * n + 0.5).rounded(.down) / n + lock.hsvAngleOffset, 1)
    return hsv2rgb(SIMD3(h, min(1, hsv.y * lock.hsvSaturationMultiplier), min(1, hsv.z * lock.hsvValueMultiplier)))
}
