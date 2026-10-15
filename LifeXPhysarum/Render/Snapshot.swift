import CoreGraphics
import Metal

/// RGBA pixels, row by row from the top.
struct RGBAImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let o = (y * width + x) * 4
        return Array(pixels[o..<o + 4])
    }

    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension MetalContext {
    /// Copies a texture's pixels into a CPU-visible buffer at the end of
    /// `commandBuffer`. Read the result once the command buffer completes.
    func encodeReadback(_ texture: MTLTexture, in commandBuffer: MTLCommandBuffer) -> MTLBuffer {
        let bytesPerRow = texture.width * 4
        let buffer = device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared)!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        return buffer
    }

    /// Copies pixels into a texture at the end of `commandBuffer`.
    func encodeUpload(_ pixels: [UInt8], to texture: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        let staging = pixels.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: texture.width * 4, sourceBytesPerImage: pixels.count,
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
    }

    func makeRenderTarget(size: Int, format: MTLPixelFormat = .rgba8Unorm) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)!
    }
}

extension MTLBuffer {
    func rgbaImage(width: Int, height: Int) -> RGBAImage {
        let bytes = UnsafeRawBufferPointer(start: contents(), count: width * height * 4)
        return RGBAImage(width: width, height: height, pixels: Array(bytes))
    }
}

extension Compositor {
    /// Composites the field and Life layer (no placement ghost) into an
    /// offscreen size×size image for each of `layers`, all in one command
    /// buffer so they show the same moment.
    func capture(
        field: MTLTexture, layers: [(physarumOpacity: Double, lifeOpacity: Double)], size: Int, context: MetalContext
    ) async -> [RGBAImage] {
        let commandBuffer = context.queue.makeCommandBuffer()!
        commandBuffer.label = "snapshot"
        let buffers = layers.map { layer in
            let target = context.makeRenderTarget(size: size)
            encode(into: commandBuffer, target: target, field: field,
                   physarumOpacity: layer.physarumOpacity, lifeOpacity: layer.lifeOpacity, ghostOpacity: 0)
            return context.encodeReadback(target, in: commandBuffer)
        }
        await commandBuffer.commitAndWait()
        return buffers.map { $0.rgbaImage(width: size, height: size) }
    }
}
