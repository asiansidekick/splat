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
            full.scale > 0.5, full.scale < 2, abs(full.turn.dx) < 0.6, abs(full.turn.dy) < 0.6,
            abs(full.move.dx - move.dx) < 0.03, abs(full.move.dy - move.dy) < 0.03
        {
            reading = full
            reading.move = move
        }
        if reading.lined, difference(live, reference) > 0.14 { return nil }
        return reading
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
