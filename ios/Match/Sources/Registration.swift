import CoreGraphics
import CoreImage
import Vision

/// Lining up the whole picture with the reference (the room, not an actor), with Vision's image
/// registration, plus the cropping and scaling the guide reads pictures at. No UIKit, so it can be
/// tested on a Mac.
enum Registration {
    static let width: CGFloat = 480
    static let actorWidth: CGFloat = 720

    static func read(live: CIImage, reference: CIImage) -> GuideReading? {
        let handler = VNImageRequestHandler(ciImage: reference, options: [:])
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: live)
        if (try? handler.perform([request])) != nil, let warp = request.results?.first?.warpTransform,
            let reading = GuideReading.from(warp: warp, reference: reference.extent.size, live: live.extent.size),
            reading.scale > 0.4, reading.scale < 2.5, abs(reading.turn.dx) < 1, abs(reading.turn.dy) < 1
        {
            return reading
        }
        // Too far off for a full reading: a plain shift still gives move arrows.
        let shift = VNTranslationalImageRegistrationRequest(targetedCIImage: live)
        guard (try? handler.perform([shift])) != nil, let t = shift.results?.first?.alignmentTransform else { return nil }
        let width = live.extent.width
        let height = live.extent.height
        guard width > 0, height > 0 else { return nil }
        // Live shifted by t lands on the reference, so the reference middle sits at -t in live
        // pixels (Vision counts y up).
        let dx = -t.tx / width
        let dy = t.ty / height
        return GuideReading(move: CGVector(dx: dx, dy: dy * height / width), turn: .zero, tilt: 0, scale: 1,
                            corners: [CGPoint(x: dx, y: dy), CGPoint(x: 1 + dx, y: dy), CGPoint(x: 1 + dx, y: 1 + dy), CGPoint(x: dx, y: 1 + dy)])
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
