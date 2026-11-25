import CoreImage
import CoreVideo
import ImageIO
import RealityKit
import Vision
import os

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

    /// Phil, 2026-11-25 (1423): Reset stopped 13 s into the first build fed picture by picture. The likely cause is
    /// memory (62 4K pictures are about 2 GB as the builder holds them), so the pictures are made smaller when they
    /// would not fit in 40% of the memory left, memory is logged as they go in, and a build that stops the app leaves
    /// a marker: after two such stops cut-outs are no longer used.
    private static let stopsKey = "scanCutOutStops"
    static func marker(_ folder: ScanFolder) -> URL { folder.url.appendingPathComponent("cut-outs-running") }

    /// Counts builds with cut-outs that stopped the app (their marker is still there).
    static func noteStops() {
        for folder in ScanFolder.all() where FileManager.default.fileExists(atPath: marker(folder).path) {
            try? FileManager.default.removeItem(at: marker(folder))
            let stops = UserDefaults.standard.integer(forKey: stopsKey) + 1
            UserDefaults.standard.set(stops, forKey: stopsKey)
            ScanLog.add("Cut-outs: the app stopped while building \(folder.name) with cut-outs (\(stops) so far)")
        }
    }

    /// The scan's pictures with their cut-outs, or nil when the cut-outs aren't to be trusted.
    static func prepare(_ folder: ScanFolder, progress: @escaping @Sendable (Double) -> Void) -> Prepared? {
        if UserDefaults.standard.integer(forKey: stopsKey) >= 2 {
            ScanLog.add("Cut-outs: off, the app stopped twice building with them")
            return nil
        }
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
        // How big the pictures may be: all of them, with cut-outs, in 40% of the memory left.
        var scale = 1.0
        if let source = CGImageSourceCreateWithURL(files[0] as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int {
            let needed = Double(files.count) * Double(w * h) * 5
            let free = Double(os_proc_available_memory())
            scale = min(1, (0.4 * free / needed).squareRoot())
            ScanLog.add(String(format: "Cut-outs: %.0f MB free, %d pictures %d x %d, fed in at %.0f%%", free / 1_000_000, files.count, w, h, scale * 100))
        }
        return Prepared(samples: Samples(files: files, masks: masks, scale: scale), names: names, found: found)
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
        /// The pictures are made this much smaller (1 keeps them as taken).
        let scale: Double

        func makeIterator() -> AnyIterator<PhotogrammetrySample> {
            var index = 0
            let context = CIContext()
            return AnyIterator {
                while index < files.count {
                    let i = index
                    index += 1
                    if i % 10 == 0 {
                        ScanLog.add(String(format: "Cut-outs: picture %d going in, %.0f MB free", i, Double(os_proc_available_memory()) / 1_000_000))
                    }
                    if let sample = autoreleasepool(invoking: { Self.sample(i, file: files[i], mask: masks[i], scale: scale, context: context) }) {
                        return sample
                    }
                    ScanLog.add("Cut-outs: picture \(files[i].lastPathComponent) couldn't be read, left out")
                }
                return nil
            }
        }

        private static func sample(_ id: Int, file: URL, mask: Mask?, scale: Double, context: CIContext) -> PhotogrammetrySample? {
            guard let read = CIImage(contentsOf: file) else { return nil }
            let image = scale < 0.999 ? read.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : read
            let w = Int(image.extent.width), h = Int(image.extent.height)
            guard w > 16, h > 16 else { return nil }
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
            var made: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes, &made) == kCVReturnSuccess, let pixels = made else { return nil }
            context.render(image, to: pixels, bounds: CGRect(x: image.extent.minX, y: image.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
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
            for x in 0..<width { columns[x] = Swift.min(mask.width - 1, x * mask.width / width) }
            for y in 0..<height {
                let my = Swift.min(mask.height - 1, y * mask.height / height) * mask.width
                let line = base + y * row
                for x in 0..<width { line[x] = mask.keep[my + columns[x]] ? 255 : 0 }
            }
            return buffer
        }
    }
}
