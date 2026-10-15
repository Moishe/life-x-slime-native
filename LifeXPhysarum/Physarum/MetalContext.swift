import Metal

/// The GPU, its command queue and the app's compiled shaders.
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    /// nil when this Mac has no Metal device or the shaders failed to load.
    static let shared: MetalContext? = MetalContext()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
        queue.label = "Life × Physarum"
    }

    func function(_ name: String) -> MTLFunction {
        guard let function = library.makeFunction(name: name) else { fatalError("Missing shader function \(name)") }
        return function
    }

    func computePipeline(_ name: String) -> MTLComputePipelineState {
        do {
            return try device.makeComputePipelineState(function: function(name))
        } catch {
            fatalError("Could not build compute pipeline \(name): \(error)")
        }
    }

    func renderPipeline(_ label: String, configure: (MTLRenderPipelineDescriptor) -> Void) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        configure(descriptor)
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Could not build render pipeline \(label): \(error)")
        }
    }

    /// A shared-storage buffer of at least one actor's size, so a binding is
    /// always valid even when there is nothing to put in it.
    func makeBuffer(length: Int, label: String) -> MTLBuffer {
        let buffer = device.makeBuffer(length: max(length, actorBytes), options: .storageModeShared)!
        buffer.label = label
        return buffer
    }

    /// An rgba8Unorm texture usable by every pass (sampled, read/written, rendered into).
    func makeFieldTexture(width: Int, height: Int, label: String) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        texture.label = label
        return texture
    }

    /// Commits an empty command buffer and waits, so everything queued before it has finished.
    func waitUntilIdle() {
        let commandBuffer = queue.makeCommandBuffer()!
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}

extension MTLCommandBuffer {
    /// Commits and waits for completion without blocking the caller's thread.
    func commitAndWait() async {
        await withCheckedContinuation { continuation in
            addCompletedHandler { _ in continuation.resume() }
            commit()
        }
    }
}
