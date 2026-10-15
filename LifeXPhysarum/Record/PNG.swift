import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageWriteError: LocalizedError {
    case encodeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let url): "Could not write \(url.lastPathComponent)."
        }
    }
}

func writePNG(_ image: RGBAImage, to url: URL) throws {
    guard let cgImage = image.cgImage,
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw ImageWriteError.encodeFailed(url) }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageWriteError.encodeFailed(url) }
}
