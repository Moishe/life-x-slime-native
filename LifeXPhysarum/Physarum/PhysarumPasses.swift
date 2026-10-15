import Metal

/// The Physarum GPU passes, each encoded into a caller's command buffer.
/// `PhysarumSim` strings them together into a step; tests run them one at a time.
final class PhysarumPasses {
    private let context: MetalContext
    private let agentPipeline: MTLComputePipelineState
    private let injectPipeline: MTLComputePipelineState
    private let diffusePipeline: MTLComputePipelineState
    private let depositPipeline: MTLRenderPipelineState
    private let foodSeedPipeline: MTLRenderPipelineState
    private let foodFadePipeline: MTLRenderPipelineState

    init(context: MetalContext) {
        self.context = context
        agentPipeline = context.computePipeline("agent_step")
        injectPipeline = context.computePipeline("inject")
        diffusePipeline = context.computePipeline("diffuse")
        depositPipeline = context.renderPipeline("deposit") { d in
            d.vertexFunction = context.function("deposit_vertex")
            d.fragmentFunction = context.function("deposit_fragment")
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            d.inputPrimitiveTopology = .point
        }
        foodSeedPipeline = context.renderPipeline("food seed") { d in
            d.vertexFunction = context.function("food_seed_vertex")
            d.fragmentFunction = context.function("food_seed_fragment")
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            d.colorAttachments[0].setBlend(.add)
        }
        foodFadePipeline = context.renderPipeline("food fade") { d in
            d.vertexFunction = context.function("fullscreen_vertex")
            d.fragmentFunction = context.function("food_fade_fragment")
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            d.colorAttachments[0].setBlend(.reverseSubtract)
        }
    }

    /// Blurs and fades `source` into `target` (ping-pong).
    func encodeDiffuse(_ commandBuffer: MTLCommandBuffer, fade: FadeParams, source: MTLTexture, target: MTLTexture) {
        var fade = fade
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.label = "diffuse"
        encoder.setComputePipelineState(diffusePipeline)
        encoder.setBytes(&fade, length: MemoryLayout<FadeParams>.stride, index: 0)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    /// Adds each seed's food over its cell block, then (if `fade` is given)
    /// fades the whole food map.
    func encodeFood(
        _ commandBuffer: MTLCommandBuffer, target: MTLTexture,
        seeds: MTLBuffer, seedCount: Int, foodParams: FoodParams, fade: FadeParams?
    ) {
        guard seedCount > 0 || fade != nil else { return }
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: .loading(target))!
        encoder.label = "food"
        if seedCount > 0 {
            var foodParams = foodParams
            encoder.setRenderPipelineState(foodSeedPipeline)
            encoder.setVertexBytes(&foodParams, length: MemoryLayout<FoodParams>.stride, index: 0)
            encoder.setVertexBuffer(seeds, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: seedCount)
        }
        if var fade {
            encoder.setRenderPipelineState(foodFadePipeline)
            encoder.setFragmentBytes(&fade, length: MemoryLayout<FadeParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    /// Moves, kills/respawns, steers and reproduces every actor slot.
    func encodeAgents(
        _ commandBuffer: MTLCommandBuffer, params: SimParams, actors: MTLBuffer, children: MTLBuffer,
        counters: MTLBuffer, trail: MTLTexture, food: MTLTexture
    ) {
        var params = params
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.label = "agents"
        encoder.setComputePipelineState(agentPipeline)
        encoder.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 0)
        encoder.setBuffer(actors, offset: 0, index: 1)
        encoder.setBuffer(children, offset: 0, index: 2)
        encoder.setBuffer(counters, offset: 0, index: 3)
        encoder.setTexture(trail, index: 0)
        encoder.setTexture(food, index: 1)
        encoder.dispatchThreads(MTLSize(width: Int(params.poolSize), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Copies `params.spawnCount` spawns and this step's queued children into the ring.
    func encodeInject(
        _ commandBuffer: MTLCommandBuffer, params: SimParams, actors: MTLBuffer, spawns: MTLBuffer,
        children: MTLBuffer, counters: MTLBuffer
    ) {
        let items = Int(params.spawnCount + params.maxChildren)
        guard items > 0 else { return }
        var params = params
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.label = "inject"
        encoder.setComputePipelineState(injectPipeline)
        encoder.setBytes(&params, length: MemoryLayout<SimParams>.stride, index: 0)
        encoder.setBuffer(actors, offset: 0, index: 1)
        encoder.setBuffer(spawns, offset: 0, index: 2)
        encoder.setBuffer(children, offset: 0, index: 3)
        encoder.setBuffer(counters, offset: 0, index: 4)
        encoder.dispatchThreads(MTLSize(width: items, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// Draws each alive actor's deposit color into the trail, replacing what was there.
    func encodeDeposit(_ commandBuffer: MTLCommandBuffer, params: SimParams, actors: MTLBuffer, target: MTLTexture) {
        var params = params
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: .loading(target))!
        encoder.label = "deposit"
        encoder.setRenderPipelineState(depositPipeline)
        encoder.setVertexBytes(&params, length: MemoryLayout<SimParams>.stride, index: 0)
        encoder.setVertexBuffer(actors, offset: 0, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Int(params.poolSize))
        encoder.endEncoding()
    }
}

extension MTLRenderPassDescriptor {
    /// Draws into `texture`, keeping what is already there.
    static func loading(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        return pass
    }
}

extension MTLRenderPipelineColorAttachmentDescriptor {
    /// One/one blending with the given operation on every channel.
    func setBlend(_ operation: MTLBlendOperation) {
        isBlendingEnabled = true
        rgbBlendOperation = operation
        alphaBlendOperation = operation
        sourceRGBBlendFactor = .one
        destinationRGBBlendFactor = .one
        sourceAlphaBlendFactor = .one
        destinationAlphaBlendFactor = .one
    }
}
