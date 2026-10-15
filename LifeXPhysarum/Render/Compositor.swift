import Metal

/// Draws the Physarum field, the Life cells and the placement ghost into one target.
final class Compositor {
    private let context: MetalContext
    // One pipeline per target pixel format (the view's, the movie's, snapshots').
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let sampler: MTLSamplerState
    private(set) var gridSize: Int
    private var lifeTexture: MTLTexture!
    private var ghostTexture: MTLTexture!
    // Texels waiting to be uploaded on the next render.
    private var pendingLife: [UInt8]?
    private var pendingGhost: [UInt8]?

    init(context: MetalContext, gridSize: Int) {
        self.context = context
        self.gridSize = gridSize
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        sampler = context.device.makeSamplerState(descriptor: descriptor)!
        setGridSize(gridSize)
    }

    /// Recreates the per-cell textures (both start transparent) for a new Life board size.
    func setGridSize(_ gridSize: Int) {
        self.gridSize = gridSize
        lifeTexture = makeCellTexture("life cells")
        ghostTexture = makeCellTexture("ghost cells")
        let empty = [UInt8](repeating: 0, count: gridSize * gridSize * 4)
        pendingLife = empty
        pendingGhost = empty
    }

    func setLife(_ texels: [UInt8]) {
        precondition(texels.count == gridSize * gridSize * 4)
        pendingLife = texels
    }

    func setGhost(_ texels: [UInt8]) {
        precondition(texels.count == gridSize * gridSize * 4)
        pendingGhost = texels
    }

    /// Encodes the composite into `target`, clearing it to black first. When
    /// `viewport` is given the field is drawn into just that region.
    func encode(
        into commandBuffer: MTLCommandBuffer, target: MTLTexture, viewport: MTLViewport? = nil,
        field: MTLTexture, physarumOpacity: Double, lifeOpacity: Double, ghostOpacity: Double
    ) {
        uploadPending(commandBuffer)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.label = "composite"
        if let viewport { encoder.setViewport(viewport) }
        var params = CompositeParams(
            physarumOpacity: Float(physarumOpacity), lifeOpacity: Float(lifeOpacity),
            ghostOpacity: Float(ghostOpacity), pad: 0)
        encoder.setRenderPipelineState(pipeline(for: target.pixelFormat))
        encoder.setFragmentBytes(&params, length: MemoryLayout<CompositeParams>.stride, index: 0)
        encoder.setFragmentTexture(field, index: 0)
        encoder.setFragmentTexture(lifeTexture, index: 1)
        encoder.setFragmentTexture(ghostTexture, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func pipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState {
        if let pipeline = pipelines[format] { return pipeline }
        let pipeline = context.renderPipeline("composite (\(format.rawValue))") { d in
            d.vertexFunction = context.function("composite_vertex")
            d.fragmentFunction = context.function("composite_fragment")
            d.colorAttachments[0].pixelFormat = format
        }
        pipelines[format] = pipeline
        return pipeline
    }

    private func makeCellTexture(_ label: String) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: gridSize, height: gridSize, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        let texture = context.device.makeTexture(descriptor: descriptor)!
        texture.label = label
        return texture
    }

    // Uploads through a staging buffer inside the command buffer, so a frame
    // still on the GPU never sees a half-written texture.
    private func uploadPending(_ commandBuffer: MTLCommandBuffer) {
        guard pendingLife != nil || pendingGhost != nil else { return }
        let blit = commandBuffer.makeBlitCommandEncoder()!
        for (texels, texture) in [(pendingLife, lifeTexture!), (pendingGhost, ghostTexture!)] {
            guard let texels else { continue }
            let staging = texels.withUnsafeBytes { context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
            blit.copy(
                from: staging, sourceOffset: 0, sourceBytesPerRow: gridSize * 4, sourceBytesPerImage: texels.count,
                sourceSize: MTLSize(width: gridSize, height: gridSize, depth: 1),
                to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        }
        blit.endEncoding()
        pendingLife = nil
        pendingGhost = nil
    }
}
