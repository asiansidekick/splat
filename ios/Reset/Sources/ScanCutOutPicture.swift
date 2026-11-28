import CoreImage
import Foundation
import ImageIO

/// A scan picture with the room round the object painted out, as the model builder reads it from a folder
/// (Phil, 2026-11-28: see ScanCutOut). Kept apart so the Mac tests can write one.
enum ScanCutOutPicture {
    /// One picture written for the builder at its full size with its own camera details (the builder reads the lens
    /// from them): the object kept, the rest plain grey, so the builder finds nothing there to build. A picture
    /// whose object wasn't found is written as it is (the builder still uses it to place the cameras).
    static func write(_ file: URL, keep: [Bool]?, width: Int, height: Int, to target: URL, context: CIContext) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let keep, width > 0, height > 0, keep.count == width * height else {
            do { try FileManager.default.copyItem(at: file, to: target); return true } catch { return false }
        }
        guard let picture = CGImageSourceCreateImageAtIndex(source, 0, nil), let maskImage = cgImage(keep, width: width, height: height) else { return false }
        let image = CIImage(cgImage: picture)
        let extent = image.extent
        let scaled = CIImage(cgImage: maskImage)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .cropped(to: extent)
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return false }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(grey, forKey: kCIInputBackgroundImageKey)
        blend.setValue(scaled, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage,
              let rendered = context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        var written = properties
        written[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(destination, rendered, written as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// The cut-out as a grey picture, rows top down: white is the object.
    static func cgImage(_ keep: [Bool], width: Int, height: Int) -> CGImage? {
        let bytes = keep.map { $0 ? UInt8(255) : UInt8(0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
