import CoreGraphics
import CoreImage
import Foundation
import Vision
import simd

/// Compares the live camera picture with the reference photo, so the lock follows what the eye
/// sees and not only ARKit's position, which can drift a few centimetres after finding the room
/// again. Kept free of ARKit so the tests can run it on a Mac.
enum ImageMatch {
    /// Lined up when no corner of the picture needs to move more than this share of its width.
    static let tolerance: CGFloat = 0.03
    /// The ghost photo snaps onto the live picture when no corner needs to move more than this.
    static let snapLimit: CGFloat = 0.12
    /// Pictures are compared this wide, which is quick and plenty for the check.
    static let width: CGFloat = 480

    struct Result {
        /// How far the furthest corner must move to line up, as a share of the picture's width.
        let error: CGFloat
        /// Where the middle of the reference photo shows in the live picture, from 0 to 1 across
        /// and down (top left is 0, 0), in the sensor's orientation like `ARFrame.capturedImage`.
        /// The guide balls use it so they meet when the pictures do.
        let centre: CGPoint?
        /// Takes the live picture onto the reference, in the compared (480 wide) pixels.
        let warp: simd_float3x3
        let referenceSize: CGSize
        let liveSize: CGSize
        var aligned: Bool { error < ImageMatch.tolerance }

        /// Where the reference photo's corners land in the live picture, in its own pixels and
        /// Core Image's way up (y from the bottom): top left, top right, bottom right, bottom
        /// left. Stretching the photo onto these lays it exactly over what the camera sees.
        func corners(reference full: CGSize, live fullLive: CGSize) -> [CGPoint]? {
            guard abs(warp.determinant) > 1e-9, full.width > 0, liveSize.width > 0 else { return nil }
            let toCompared = Float(referenceSize.width / full.width)
            let toLive = Float(fullLive.width / liveSize.width)
            let inverse = warp.inverse
            var out: [CGPoint] = []
            for corner in [CGPoint(x: 0, y: full.height), CGPoint(x: full.width, y: full.height), CGPoint(x: full.width, y: 0), .zero] {
                let p = inverse * SIMD3<Float>(Float(corner.x) * toCompared, Float(corner.y) * toCompared, 1)
                guard abs(p.z) > 1e-6 else { return nil }
                out.append(CGPoint(x: CGFloat(p.x / p.z * toLive), y: CGFloat(p.y / p.z * toLive)))
            }
            return out
        }

        /// The reference photo stretched onto the live picture, the live picture's size.
        func snapped(_ photo: CIImage, live fullLive: CGSize) -> CIImage? {
            let extent = photo.extent
            let origin = photo.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            guard let c = corners(reference: extent.size, live: fullLive),
                let filter = CIFilter(name: "CIPerspectiveTransform")
            else { return nil }
            filter.setValue(origin, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgPoint: c[0]), forKey: "inputTopLeft")
            filter.setValue(CIVector(cgPoint: c[1]), forKey: "inputTopRight")
            filter.setValue(CIVector(cgPoint: c[2]), forKey: "inputBottomRight")
            filter.setValue(CIVector(cgPoint: c[3]), forKey: "inputBottomLeft")
            guard let output = filter.outputImage else { return nil }
            let canvas = CGRect(origin: .zero, size: fullLive)
            return output.cropped(to: canvas).composited(over: CIImage(color: .clear).cropped(to: canvas))
        }
    }

    /// Both pictures in the camera's sensor orientation. Nil when Vision cannot pair them up, for
    /// example when they show too little in common.
    static func compare(live: CIImage, reference: CIImage) -> Result? {
        let a = prepared(live)
        let b = prepared(reference)
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: a)
        let handler = VNImageRequestHandler(ciImage: b, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
        let warp = observation.warpTransform
        return Result(
            error: cornerError(warp, size: b.extent.size),
            centre: centre(warp, reference: b.extent.size, live: a.extent.size),
            warp: warp, referenceSize: b.extent.size, liveSize: a.extent.size)
    }

    /// The warp takes the live picture onto the reference, so its inverse takes the reference's
    /// middle to where that shows live. Vision counts pixels up from the bottom.
    static func centre(_ warp: simd_float3x3, reference: CGSize, live: CGSize) -> CGPoint? {
        guard abs(warp.determinant) > 1e-9, live.width > 0, live.height > 0 else { return nil }
        let p = warp.inverse * SIMD3<Float>(Float(reference.width) / 2, Float(reference.height) / 2, 1)
        guard abs(p.z) > 1e-6 else { return nil }
        return CGPoint(x: CGFloat(p.x / p.z) / live.width, y: 1 - CGFloat(p.y / p.z) / live.height)
    }

    /// How far the warp moves the picture's corners, at most, as a share of its width.
    static func cornerError(_ warp: simd_float3x3, size: CGSize) -> CGFloat {
        let w = Float(size.width)
        let h = Float(size.height)
        var worst: Float = 0
        for corner in [SIMD3<Float>(0, 0, 1), SIMD3(w, 0, 1), SIMD3(w, h, 1), SIMD3(0, h, 1)] {
            let p = warp * corner
            guard abs(p.z) > 1e-6 else { return .infinity }
            worst = max(worst, simd_length(SIMD2(p.x / p.z - corner.x, p.y / p.z - corner.y)))
        }
        return CGFloat(worst / w)
    }

    /// Grey, the same size, from the origin, so lighting colour does not matter and the warp is
    /// in matching pixels.
    private static func prepared(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = width / max(extent.width, 1)
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    }
}
