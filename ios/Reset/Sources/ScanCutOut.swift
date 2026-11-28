import CoreImage
import CoreVideo
import ImageIO
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

    struct Prepared: Sendable {
        /// The cut-out pictures on disk, same file names as the scan's own pictures (so the builder's camera places
        /// match Reset's by name), the room round the object painted plain grey.
        let images: URL
        let found: Int
    }

    /// Phil, 2026-11-25 (1423) and 2026-11-28 (1428): every build that handed the builder its pictures from memory
    /// with cut-outs stopped the app the moment the builder took them, whatever their size (1428 fed them in at
    /// 46% and 56%, it stopped before the first picture went in), while every build from the pictures folder works.
    /// So the cut-outs are now written as pictures in their own folder and the builder reads that folder the way it
    /// reads the scan's own pictures, one at a time from disk. If that build fails, the whole pictures are built.
    /// A build that stops the app still leaves a marker: after two such stops cut-outs are no longer used.
    private static let stopsKey = "scanCutOutFolderStops"
    static func marker(_ folder: ScanFolder) -> URL { folder.url.appendingPathComponent("cut-outs-building") }
    /// The marker of the memory-fed cut-outs (1423 to 1428): no longer counted, just cleared.
    private static func oldMarker(_ folder: ScanFolder) -> URL { folder.url.appendingPathComponent("cut-outs-running") }
    static func images(_ folder: ScanFolder) -> URL { folder.url.appendingPathComponent("Images cut-outs", isDirectory: true) }

    /// Counts builds with cut-outs that stopped the app (their marker is still there).
    static func noteStops() {
        for folder in ScanFolder.all() {
            try? FileManager.default.removeItem(at: oldMarker(folder))
            guard FileManager.default.fileExists(atPath: marker(folder).path) else { continue }
            try? FileManager.default.removeItem(at: marker(folder))
            try? FileManager.default.removeItem(at: images(folder))
            let stops = UserDefaults.standard.integer(forKey: stopsKey) + 1
            UserDefaults.standard.set(stops, forKey: stopsKey)
            ScanLog.add("Cut-outs: the app stopped while building \(folder.name) with cut-outs (\(stops) so far)")
        }
    }

    /// The scan's pictures with the room round the object painted out, in their own folder, or nil when the
    /// cut-outs aren't to be trusted (or couldn't be written).
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
            progress(0.5 * Double(i + 1) / Double(files.count))
        }
        let found = masks.compactMap { $0 }.count
        ScanLog.add("Cut-outs: the object found in the middle of \(found) of \(files.count) pictures")
        guard ScanPictureMath.useCutOuts(found: found, of: files.count) else { return nil }

        let out = images(folder)
        try? FileManager.default.removeItem(at: out)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            ScanLog.add("Cut-outs: couldn't make their folder: \(error)")
            return nil
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        var written = 0
        for (i, file) in files.enumerated() {
            let target = out.appendingPathComponent(file.lastPathComponent)
            let ok = autoreleasepool { ScanCutOutPicture.write(file, keep: masks[i]?.keep, width: masks[i]?.width ?? 0, height: masks[i]?.height ?? 0, to: target, context: context) }
            if ok { written += 1 } else { ScanLog.add("Cut-outs: picture \(file.lastPathComponent) couldn't be written, left out") }
            if i % 20 == 0 { ScanLog.add("Cut-outs: picture \(i) written, " + Diagnostics.memory()) }
            progress(0.5 + 0.5 * Double(i + 1) / Double(files.count))
        }
        guard written >= max(3, files.count * 3 / 4) else {
            ScanLog.add("Cut-outs: only \(written) of \(files.count) pictures written, building from the whole pictures")
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        ScanLog.add("Cut-outs: \(written) pictures written, " + Diagnostics.memory())
        return Prepared(images: out, found: found)
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
}
