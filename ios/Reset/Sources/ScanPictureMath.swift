import Foundation

/// Picture checks for 3D scans (Phil, 2026-11-24: "How can we improve our scans"), kept free of Apple frameworks so
/// CI can test them: how sharp a picture is, and which part of a picture is the object being scanned.
enum ScanPictureMath {
    /// How sharp a grey picture is: the spread of its edges (variance of the 4-neighbour Laplacian). A blurred
    /// picture of the same thing scores much lower. Only comparable between pictures of the same scan.
    static func sharpness(_ grey: [UInt8], width: Int, height: Int) -> Float {
        guard width > 2, height > 2, grey.count >= width * height else { return 0 }
        var sum: Double = 0, sumSquares: Double = 0
        var n = 0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let l = 4 * Int(grey[i]) - Int(grey[i - 1]) - Int(grey[i + 1]) - Int(grey[i - width]) - Int(grey[i + width])
                let v = Double(l)
                sum += v
                sumSquares += v * v
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / Double(n)
        return Float(sumSquares / Double(n) - mean * mean)
    }

    /// Whether a new picture is too blurred to keep, against the pictures kept so far in this scan. Needs a few
    /// kept first; after `refusedInARow` refusals at one spot the picture is kept anyway, so a scan never stalls.
    static func tooBlurred(_ score: Float, kept: [Float], refusedInARow: Int) -> Bool {
        guard kept.count >= 5, refusedInARow < 2 else { return false }
        let recent = kept.suffix(15).sorted()
        let median = recent[recent.count / 2]
        return score < median * 0.55
    }

    /// The object in a picture from Vision's foreground instance labels (0 is background): the label covering most
    /// of the middle fifth of the picture, where the phone points. nil when the middle is background.
    static func middleLabel(_ labels: [UInt8], width: Int, height: Int) -> UInt8? {
        guard width > 0, height > 0, labels.count >= width * height else { return nil }
        var counts = [Int](repeating: 0, count: 256)
        let x0 = width * 2 / 5, x1 = max(x0 + 1, width * 3 / 5)
        let y0 = height * 2 / 5, y1 = max(y0 + 1, height * 3 / 5)
        var total = 0
        for y in y0..<min(y1, height) {
            for x in x0..<min(x1, width) {
                counts[Int(labels[y * width + x])] += 1
                total += 1
            }
        }
        var best = 0, bestCount = 0
        for label in 1..<256 where counts[label] > bestCount {
            best = label
            bestCount = counts[label]
        }
        // At least a third of the middle must be the object.
        guard best > 0, bestCount * 3 >= total else { return nil }
        return UInt8(best)
    }

    /// `keep` grown by `radius` cells each way (a square), so the cut-out never shaves the object's edges.
    static func grow(_ keep: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0, width > 0, height > 0 else { return keep }
        // Rows first, then columns: two passes of a running count.
        var rows = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            var count = 0
            let row = y * width
            for x in 0..<min(radius, width) where keep[row + x] { count += 1 }
            for x in 0..<width {
                if x + radius < width, keep[row + x + radius] { count += 1 }
                if x - radius - 1 >= 0, keep[row + x - radius - 1] { count -= 1 }
                rows[row + x] = count > 0
            }
        }
        var out = [Bool](repeating: false, count: width * height)
        for x in 0..<width {
            var count = 0
            for y in 0..<min(radius, height) where rows[y * width + x] { count += 1 }
            for y in 0..<height {
                if y + radius < height, rows[(y + radius) * width + x] { count += 1 }
                if y - radius - 1 >= 0, rows[(y - radius - 1) * width + x] { count -= 1 }
                out[y * width + x] = count > 0
            }
        }
        return out
    }

    /// Whether a scan's cut-outs can be trusted: most pictures must have found the object in the middle, else
    /// the builder gets no cut-outs at all (one wrong cut-out carves a piece off the model).
    static func useCutOuts(found: Int, of pictures: Int) -> Bool {
        pictures > 0 && found * 4 >= pictures * 3
    }
}
