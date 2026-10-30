import CoreGraphics
import CoreImage
import Vision
import simd

/// Lining up the whole picture with the reference (the room, not an actor), with Vision's image
/// registration, plus the cropping and scaling the guide reads pictures at. No UIKit, so it can be
/// tested on a Mac.
enum Registration {
    static let width: CGFloat = 480
    static let actorWidth: CGFloat = 720

    /// Tested on a Mac with real photos (Tests/VisionTests), which showed two things: Vision's
    /// homography can be well off on plain shifts (a 6% slide read as 2%), and on a picture it
    /// can't match it can hand back "no change" as if lined up. So the slide comes from the plain
    /// shift registration, which was exact; the homography is only trusted for size, twist and
    /// perspective when it agrees with that shift; and "lined up" is only believed when the two
    /// pictures really look alike.
    static func read(live: CIImage, reference: CIImage) -> GuideReading? {
        let width = live.extent.width, height = live.extent.height
        guard width > 0, height > 0 else { return nil }
        let handler = VNImageRequestHandler(ciImage: reference, options: [:])
        let homography = VNHomographicImageRegistrationRequest(targetedCIImage: live)
        let translation = VNTranslationalImageRegistrationRequest(targetedCIImage: live)
        try? handler.perform([homography, translation])
        guard let t = translation.results?.first?.alignmentTransform,
            abs(t.tx) < width * 0.4, abs(t.ty) < height * 0.4
        else { return nil }
        // Live moved by t lands on the reference, so the reference's middle sits at -t in live
        // pixels (Vision counts y up).
        let dx = -t.tx / width
        let dy = t.ty / height
        let move = CGVector(dx: dx, dy: dy * height / width)
        var reading = GuideReading(move: move, turn: .zero, tilt: 0, scale: 1,
                                   corners: [CGPoint(x: dx, y: dy), CGPoint(x: 1 + dx, y: dy), CGPoint(x: 1 + dx, y: 1 + dy), CGPoint(x: dx, y: 1 + dy)])
        if let warp = homography.results?.first?.warpTransform, !isIdentity(warp),
            let full = GuideReading.from(warp: warp, reference: reference.extent.size, live: live.extent.size),
            full.scale > 0.5, full.scale < 2, abs(full.turn.dx) < 0.6, abs(full.turn.dy) < 0.6
        {
            if abs(full.move.dx - move.dx) < 0.03, abs(full.move.dy - move.dy) < 0.03 {
                reading = full
                reading.move = move
            } else {
                // A twist moves the picture's middle little, so the shift can disagree; the twist
                // itself is still worth having.
                reading.tilt = full.tilt
            }
        }
        if reading.lined, difference(live, reference) > 0.14 { return nil }
        return reading
    }

    // MARK: Fitting an imported photo

    /// Sizes and places a photo from another camera (a QTake screenshot) on the live view, where
    /// stepping in or back can't make up for a different lens. Tries a range of sizes, lines each
    /// up with the plain shift registration, and keeps the size whose pictures look most alike
    /// (by correlation, so a different grade or exposure doesn't matter). Both pictures prepared,
    /// the same shape. Nil if nothing clearly matches.
    static func fitRoom(live: CIImage, reference: CIImage) -> OverlayFit? {
        var tried: [(score: Double, fit: OverlayFit)] = []
        func attempt(_ s: Double) -> (score: Double, fit: OverlayFit)? {
            // Zoom whichever picture is shown smaller, so nothing is padded with empty space.
            let r = s >= 1 ? zoomed(reference, by: s) : reference
            let l = s >= 1 ? live : zoomed(live, by: 1 / s)
            let w = l.extent.width, h = l.extent.height
            let handler = VNImageRequestHandler(ciImage: r, options: [:])
            let request = VNTranslationalImageRegistrationRequest(targetedCIImage: l)
            try? handler.perform([request])
            guard let t = request.results?.first?.alignmentTransform, abs(t.tx) < w * 0.45, abs(t.ty) < h * 0.45 else { return nil }
            let shifted = l.transformed(by: CGAffineTransform(translationX: t.tx, y: t.ty))
            let overlap = shifted.extent.intersection(r.extent)
            guard overlap.width * overlap.height > r.extent.width * r.extent.height * 0.45 else { return nil }
            let score = correlation(shifted.cropped(to: overlap), r.cropped(to: overlap))
            let dx = Double(-t.tx / w), dy = Double(t.ty / h)
            let fit = s >= 1 ? OverlayFit(scale: s, x: dx, y: dy) : OverlayFit(scale: s, x: dx * s, y: dy * s)
            return (score, fit)
        }
        for s in [0.4, 0.5, 0.63, 0.8, 1.0, 1.25, 1.6, 2.0, 2.5] {
            if let found = attempt(s) { tried.append(found) }
        }
        guard var best = tried.max(by: { $0.score < $1.score }) else { return nil }
        // Finer sizes round the best.
        for k in [0.9, 0.95, 1.05, 1.1] {
            if let found = attempt(best.fit.scale * k), found.score > best.score { best = found }
        }
        let scores = tried.map(\.score).sorted()
        let median = scores[scores.count / 2]
        // A real match stands out from the other sizes and looks alike.
        guard best.score > 0.45, best.score > median + 0.12, best.fit.isSensible else { return nil }
        return best.fit
    }

    /// The picture as it shows once fitted: scaled about its middle and moved, cropped back to its
    /// own frame (empty where it no longer reaches).
    static func fitted(_ image: CIImage, by fit: OverlayFit) -> CIImage {
        let e = image.extent
        let s = CGFloat(fit.scale)
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: e.midX + CGFloat(fit.x) * e.width, y: e.midY - CGFloat(fit.y) * e.height))
        return image.transformed(by: t)
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: e))
            .cropped(to: e)
    }

    /// Bigger by `k` about the middle, cropped back to the same frame.
    static func zoomed(_ image: CIImage, by k: Double) -> CIImage {
        fitted(image, by: OverlayFit(scale: k, x: 0, y: 0))
    }

    /// How alike two pictures look, -1...1, ignoring brightness and contrast (Pearson correlation
    /// of small grey copies).
    static func correlation(_ a: CIImage, _ b: CIImage) -> Double {
        func pixels(_ image: CIImage) -> [Double] {
            let e = image.extent
            let side: CGFloat = 96
            let k = side / max(e.width, e.height)
            let w = max(1, Int(e.width * k)), h = max(1, Int(e.height * k))
            let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height)))
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            context.render(small, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBA8, colorSpace: nil)
            return stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) }
        }
        let x = pixels(a), y = pixels(b)
        guard x.count == y.count, x.count > 16 else { return 0 }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 1, syy > 1 else { return 0 }
        return sxy / (sxx * syy).squareRoot()
    }

    private static func isIdentity(_ m: simd_float3x3) -> Bool {
        let i = matrix_identity_float3x3
        return (0..<3).allSatisfy { c in (0..<3).allSatisfy { r in abs(m[c][r] - i[c][r]) < 1e-6 } }
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// How different two pictures of the same size look: the average brightness difference, 0...1.
    static func difference(_ a: CIImage, _ b: CIImage) -> Double {
        let extent = a.extent.intersection(b.extent)
        guard !extent.isEmpty else { return 1 }
        let diff = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b])
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(diff, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return Double(pixel[0]) / 255
    }

    /// The middle of a picture at the given width over height.
    static func centred(_ image: CIImage, aspect: CGFloat?) -> CIImage {
        guard let aspect, aspect > 0 else { return image }
        let e = image.extent
        var width = e.width
        var height = e.height
        if width / height > aspect { width = height * aspect } else { height = width / aspect }
        return image.cropped(to: CGRect(x: e.midX - width / 2, y: e.midY - height / 2, width: width, height: height))
    }

    /// In colour, from the origin, at the given width: for finding faces and bodies.
    static func scaled(_ image: CIImage, to width: CGFloat) -> CIImage {
        let extent = image.extent
        let scale = min(1, width / max(extent.width, 1))
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
    }

    /// Grey and small, from the origin, so lighting colour does not matter and it is quick.
    static func prepared(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = width / max(extent.width, 1)
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    }
}
