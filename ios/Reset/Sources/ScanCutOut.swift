import CoreImage
import CoreVideo
import ImageIO
import RealityKit
import Vision

/// Phil, 2026-11-24 ("How can we improve our scans"): an object scan built from Reset's own pictures used to build
/// the floor and the room round the object too, which left a ragged base to trim. Now each picture tells the model
/// builder which part is the object (Vision's foreground cut-out, the thing in the middle of the picture, grown a
/// little so no edge is shaved), the way Apple's own capture does with its depth pictures.
/// If most pictures don't find the object in the middle, no cut-outs are used at all: one wrong cut-out would
/// carve a piece off the model.
enum ScanCutOut {
    struct Mask: @unchecked Sendable {
        let keep: [Bool]
        let width: Int
        let height: Int
    }

    struct Prepared: @unchecked Sendable {
        let samples: Samples
        /// Sample number to picture file name, for matching the builder's camera places to Reset's.
        let names: [Int: String]
        let found: Int
    }

    /// The scan's pictures with their cut-outs, or nil when the cut-outs aren't to be trusted.
    static func prepare(_ folder: ScanFolder, progress: @escaping @Sendable (Double) -> Void) -> Prepared? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder.images, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return nil }
        var masks: [Mask?] = []
        for (i, file) in files.enumerated() {
            masks.append(autoreleasepool { mask(file) })
            progress(Double(i + 1) / Double(files.count))
        }
        let found = masks.compactMap { $0 }.count
        ScanLog.add("Cut-outs: the object found in the middle of \(found) of \(files.count) pictures")
        guard ScanPictureMath.useCutOuts(found: found, of: files.count) else { return nil }
        var names: [Int: String] = [:]
        for (i, file) in files.enumerated() { names[i] = file.lastPathComponent }
        return Prepared(samples: Samples(files: files, masks: masks), names: names, found: found)
    }

    /// Vision's foreground for one picture: the thing in the middle, grown by a fortieth of the picture's width.
    static func mask(_ url: URL) -> Mask? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return nil }
        let buffer = result.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var labels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { labels[y * w + x] = base[y * row + x] } }
        guard let label = ScanPictureMath.middleLabel(labels, width: w, height: h) else { return nil }
        let keep = labels.map { $0 == label }
        return Mask(keep: ScanPictureMath.grow(keep, width: w, height: h, radius: max(2, w / 40)), width: w, height: h)
    }

    /// The pictures as the builder's samples, read one at a time as it asks for them.
    struct Samples: Sequence, @unchecked Sendable {
        let files: [URL]
        let masks: [Mask?]

        func makeIterator() -> AnyIterator<PhotogrammetrySample> {
            var index = 0
            let context = CIContext()
            return AnyIterator {
                while index < files.count {
                    let i = index
                    index += 1
                    if let sample = autoreleasepool(invoking: { Self.sample(i, file: files[i], mask: masks[i], context: context) }) {
                        return sample
                    }
                    ScanLog.add("Cut-outs: picture \(files[i].lastPathComponent) couldn't be read, left out")
                }
                return nil
            }
        }

        private static func sample(_ id: Int, file: URL, mask: Mask?, context: CIContext) -> PhotogrammetrySample? {
            guard let image = CIImage(contentsOf: file) else { return nil }
            let w = Int(image.extent.width), h = Int(image.extent.height)
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            var made: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess, let pixels = made else { return nil }
            context.render(image, to: pixels, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            var sample = PhotogrammetrySample(id: id, image: pixels)
            if let mask { sample.objectMask = Self.objectMask(mask, width: w, height: h) }
            return sample
        }

        /// The cut-out at the picture's own size: 255 is the object, 0 the rest. The cut-out's rows run top down,
        /// as do the pixel buffer's.
        private static func objectMask(_ mask: Mask, width: Int, height: Int) -> CVPixelBuffer? {
            var made: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent8, attributes, &made) == kCVReturnSuccess,
                  let buffer = made else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let row = CVPixelBufferGetBytesPerRow(buffer)
            var columns = [Int](repeating: 0, count: width)
            for x in 0..<width { columns[x] = min(mask.width - 1, x * mask.width / width) }
            for y in 0..<height {
                let my = min(mask.height - 1, y * mask.height / height) * mask.width
                let line = base + y * row
                for x in 0..<width { line[x] = mask.keep[my + columns[x]] ? 255 : 0 }
            }
            return buffer
        }
    }
}
