import Metal
import Testing
@testable import LifeXPhysarum

@Suite struct ColorShaderTests {
    @Test func metalColorFunctionsMatchColorMathOn256RandomPairs() {
        let rng = mulberry32(99)
        let n = 256
        let a = (0..<n).map { _ in SIMD4<Float>(Float(rng()), Float(rng()), Float(rng()), Float(rng())) }
        let b = (0..<n).map { _ in SIMD4<Float>(Float(rng()), Float(rng()), Float(rng()), Float(rng())) }
        let aBuffer = makeBuffer(a)
        let bBuffer = makeBuffer(b)
        let out = makeBuffer([SIMD4<Float>](), minimumCount: n * 4)
        let pipeline = gpu.computePipeline("color_probe")
        run { commandBuffer in
            let encoder = commandBuffer.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(aBuffer, offset: 0, index: 0)
            encoder.setBuffer(bBuffer, offset: 0, index: 1)
            encoder.setBuffer(out, offset: 0, index: 2)
            encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            encoder.endEncoding()
        }
        let rows = read(out, as: SIMD4<Float>.self, count: n * 4)
        let lock = HueLock(lockToHsvAngles: 6, hsvAngleOffset: 0.1, hsvSaturationMultiplier: 0.8, hsvValueMultiplier: 1.2)
        func circularDiff(_ x: Float, _ y: Float) -> Float {
            let d = abs(x - y).truncatingRemainder(dividingBy: 1)
            return min(d, 1 - d)
        }
        for i in 0..<n {
            let x = SIMD3(a[i].x, a[i].y, a[i].z)
            let y = SIMD3(b[i].x, b[i].y, b[i].z)
            let hsv = rgb2hsv(x)
            let gpuHsv = rows[i * 4]
            #expect(circularDiff(gpuHsv.x, hsv.x) < 1e-3)
            #expect(abs(gpuHsv.y - hsv.y) < 1e-3 && abs(gpuHsv.z - hsv.z) < 1e-3)
            let gpuRGB = rows[i * 4 + 1]
            #expect(close(SIMD3(gpuRGB.x, gpuRGB.y, gpuRGB.z), hsv2rgb(x), 1e-3))
            let mixed = rows[i * 4 + 2]
            #expect(close(SIMD3(mixed.x, mixed.y, mixed.z), hsvMix(x, y, a[i].w), 1e-2))
            #expect(abs(mixed.w - hsvDistance(rgb2hsv(x), rgb2hsv(y))) < 1e-3)
            let locked = rows[i * 4 + 3]
            #expect(close(SIMD3(locked.x, locked.y, locked.z), dominantColor(x, lock), 1e-2))
        }
    }
}
