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
    static let tolerance: CGFloat = 0.02
    /// Pictures are compared this wide, which is quick and plenty for the check.
    static let width: CGFloat = 480

    struct Result {
        /// How far the furthest corner must move to line up, as a share of the picture's width.
        let error: CGFloat
        var aligned: Bool { error < ImageMatch.tolerance }
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
        return Result(error: cornerError(observation.warpTransform, size: b.extent.size))
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
