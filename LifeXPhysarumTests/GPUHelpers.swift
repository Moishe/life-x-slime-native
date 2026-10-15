import Metal
@testable import LifeXPhysarum

/// The shared Metal context. Every Mac this app runs on has one.
var gpu: MetalContext { MetalContext.shared! }

/// A red, alive, motionless actor at (32, 32); override any field.
func actor(
    x: Float = 32, y: Float = 32, dir: Float = 0, speed: Float = 0,
    seed: SIMD4<Float> = [1, 0, 0, 1], color: SIMD4<Float> = [1, 0, 0, 1],
    age: UInt32 = 0, life: UInt32 = 100_000, alive: Bool = true, rng: UInt32 = 12345
) -> Actor {
    Actor(pos: [x, y], dir: dir, speed: speed, seed: seed, color: color, age: age, life: life, alive: alive ? 1 : 0, rng: rng)
}

func makeBuffer<T>(_ items: [T], minimumCount: Int = 0) -> MTLBuffer {
    let length = max(items.count, minimumCount) * MemoryLayout<T>.stride
    let buffer = gpu.makeBuffer(length: length, label: "test")
    items.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    return buffer
}

func read<T>(_ buffer: MTLBuffer, as type: T.Type, count: Int) -> [T] {
    Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
}

func counters(_ buffer: MTLBuffer) -> CounterValues {
    buffer.contents().load(as: Counters.self).values
}

func countersBuffer(_ values: CounterValues = CounterValues()) -> MTLBuffer {
    makeBuffer([Counters(head: values.head, childCount: values.childCount,
                         aliveCount: values.aliveCount, childrenInserted: values.childrenInserted)])
}

func solidTexels(_ width: Int, _ height: Int, _ rgba: [UInt8]) -> [UInt8] {
    Array([[UInt8]](repeating: rgba, count: width * height).joined())
}

func setPixel(_ data: inout [UInt8], _ width: Int, _ x: Int, _ y: Int, _ rgba: [UInt8]) {
    let o = (y * width + x) * 4
    data.replaceSubrange(o..<o + 4, with: rgba)
}

func texture(_ size: Int, _ texels: [UInt8]? = nil, format: MTLPixelFormat = .rgba8Unorm) -> MTLTexture {
    let t: MTLTexture = format == .rgba8Unorm
        ? gpu.makeFieldTexture(width: size, height: size, label: "test")
        : gpu.makeRenderTarget(size: size, format: format)
    if let texels { write(t, texels) }
    return t
}

func write(_ texture: MTLTexture, _ texels: [UInt8]) {
    let commandBuffer = gpu.queue.makeCommandBuffer()!
    gpu.encodeUpload(texels, to: texture, in: commandBuffer)
    commandBuffer.commit()
}

func readTexture(_ texture: MTLTexture) -> RGBAImage {
    let commandBuffer = gpu.queue.makeCommandBuffer()!
    let buffer = gpu.encodeReadback(texture, in: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return buffer.rgbaImage(width: texture.width, height: texture.height)
}

/// Runs `encode` in one command buffer and waits for it.
func run(_ encode: (MTLCommandBuffer) -> Void) {
    let commandBuffer = gpu.queue.makeCommandBuffer()!
    encode(commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
}

/// Each channel within 1 of the expected value (8-bit rounding).
func near(_ actual: [UInt8], _ expected: [Int], tolerance: Int = 1) -> Bool {
    zip(actual, expected).allSatisfy { abs(Int($0) - $1) <= tolerance }
}

/// Mirror of the shader's xorshift32 + rand(): the nth (0-based) draw from a state.
func nthRand(_ state: UInt32, _ n: Int) -> Float {
    var x = state
    var r: Float = 0
    for _ in 0...n {
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        r = Float(x >> 8) / 16_777_216
    }
    return r
}
