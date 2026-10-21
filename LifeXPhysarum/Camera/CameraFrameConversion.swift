import Accelerate
import CoreVideo

/// Scales the centered square of a BGRA camera image to gridSize × gridSize
/// RGBA, mirrored left to right if asked (so the field works like a mirror).
nonisolated func cameraFrame(from pixelBuffer: CVPixelBuffer, gridSize: Int, mirrored: Bool) -> CameraFrame? {
    guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let side = min(width, height)
    let origin = base + ((height - side) / 2) * rowBytes + ((width - side) / 2) * 4
    var source = vImage_Buffer(data: origin, height: vImagePixelCount(side), width: vImagePixelCount(side), rowBytes: rowBytes)

    var out = [UInt8](repeating: 0, count: gridSize * gridSize * 4)
    let ok = out.withUnsafeMutableBytes { bytes -> Bool in
        var dest = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(gridSize), width: vImagePixelCount(gridSize),
                                 rowBytes: gridSize * 4)
        guard vImageScale_ARGB8888(&source, &dest, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return false }
        if mirrored, vImageHorizontalReflect_ARGB8888(&dest, &dest, vImage_Flags(kvImageNoFlags)) != kvImageNoError { return false }
        let bgraToRGBA: [UInt8] = [2, 1, 0, 3]
        return vImagePermuteChannels_ARGB8888(&dest, &dest, bgraToRGBA, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
    return ok ? CameraFrame(size: gridSize, rgba: out) : nil
}
