import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision
import simd

/// The after photo lined up on the before photo, and where the two differ.
struct Aligned {
    /// The after photo moved, scaled and tilted to sit on the before photo, at the before photo's shape.
    let after: UIImage
    /// False when lining up made things worse (very different framing), so the photos are just overlaid.
    let lined: Bool
    /// Grey, brighter where the photos differ.
    let difference: CIImage
}

/// Image-only comparison, all on the device: Vision lines the photos up, Core Image finds what changed.
enum Differ {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let workingSide: CGFloat = 1600

    static func align(before: UIImage, after: UIImage) -> Aligned? {
        guard let beforeInput = CIImage(image: before), let afterInput = CIImage(image: after) else { return nil }
        let base = fit(beforeInput, maxSide: workingSide)
        let canvas = base.extent
        // Same size as the before photo, and the same overall brightness, so a lighting change
        // between takes does not show up as a change everywhere.
        let stretched = afterInput.transformed(by: CGAffineTransform(
            scaleX: canvas.width / afterInput.extent.width, y: canvas.height / afterInput.extent.height))
        let floating = matchBrightness(stretched.cropped(to: canvas), to: base)

        let black = CIImage(color: .black).cropped(to: canvas)
        var best = floating
        var bestScore = meanDifference(floating, base)
        var lined = false
        if let homography = homography(of: floating, onto: base) {
            // Vision's convention depends on the image origin and direction, so try each reading
            // and keep whichever lines up best. Areas pushed off the picture count as different,
            // so a warp cannot win by shrinking the photo away.
            for matrix in readings(of: homography, height: Float(canvas.height)) {
                guard let warped = warp(floating, by: matrix, canvas: canvas) else { continue }
                let score = meanDifference(warped.composited(over: black), base)
                if score < bestScore * 0.95 {
                    best = warped
                    bestScore = score
                    lined = true
                }
            }
        }

        let shown = best.composited(over: black)
        guard let cg = context.createCGImage(shown, from: canvas) else { return nil }
        // Outside the warped photo there is nothing to compare, so fill it from the before photo.
        let difference = differenceMap(best.composited(over: base), base)
        return Aligned(after: UIImage(cgImage: cg), lined: lined, difference: difference)
    }

    /// Red where the difference is above the threshold, with specks removed.
    static func changes(_ difference: CIImage, threshold: Float) -> UIImage? {
        let extent = difference.extent
        let cut = CIFilter.colorThreshold()
        cut.inputImage = difference
        cut.threshold = threshold
        let shrink = CIFilter.morphologyMinimum()
        shrink.inputImage = cut.outputImage?.clampedToExtent()
        shrink.radius = 2
        let grow = CIFilter.morphologyMaximum()
        grow.inputImage = shrink.outputImage
        grow.radius = 7
        let red = CIFilter.colorMatrix()
        red.inputImage = grow.outputImage
        red.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        red.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        red.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        red.aVector = CIVector(x: 0.55, y: 0, z: 0, w: 0)
        red.biasVector = CIVector(x: 1, y: 0.1, z: 0.1, w: 0)
        guard let output = red.outputImage?.cropped(to: extent),
            let cg = context.createCGImage(output, from: extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Steps

    private static func fit(_ image: CIImage, maxSide: CGFloat) -> CIImage {
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let moved = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        return moved.cropped(to: CGRect(x: 0, y: 0, width: moved.extent.width.rounded(.down), height: moved.extent.height.rounded(.down)))
    }

    private static func homography(of floating: CIImage, onto reference: CIImage) -> simd_float3x3? {
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: floating, options: [:])
        let handler = VNImageRequestHandler(ciImage: reference, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first?.warpTransform
    }

    private static func readings(of matrix: simd_float3x3, height: Float) -> [simd_float3x3] {
        // Flips y, to swap between top-left and bottom-left image origins.
        let flip = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, height, 1)))
        let flipped = flip * matrix * flip
        return [matrix, matrix.inverse, flipped, flipped.inverse]
    }

    private static func warp(_ image: CIImage, by matrix: simd_float3x3, canvas: CGRect) -> CIImage? {
        let w = Float(image.extent.width)
        let h = Float(image.extent.height)
        func map(_ x: Float, _ y: Float) -> CGPoint? {
            let p = matrix * SIMD3(x, y, 1)
            guard p.z > 1e-4 else { return nil }
            return CGPoint(x: CGFloat(p.x / p.z), y: CGFloat(p.y / p.z))
        }
        guard let bottomLeft = map(0, 0), let bottomRight = map(w, 0), let topRight = map(w, h), let topLeft = map(0, h)
        else { return nil }
        // Reject warps that fold the photo or change its size wildly.
        let corners = [bottomLeft, bottomRight, topRight, topLeft]
        var area: CGFloat = 0
        for i in 0..<4 {
            let a = corners[i]
            let b = corners[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        let ratio = area / 2 / (canvas.width * canvas.height)
        guard ratio > 0.4, ratio < 2.5 else { return nil }

        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.bottomLeft = bottomLeft
        filter.bottomRight = bottomRight
        filter.topRight = topRight
        filter.topLeft = topLeft
        return filter.outputImage?.cropped(to: canvas)
    }

    private static func matchBrightness(_ image: CIImage, to reference: CIImage) -> CIImage {
        let have = average(image)
        let want = average(reference)
        func gain(_ i: Int) -> CGFloat { CGFloat(min(max(want[i] / max(have[i], 0.01), 0.5), 2)) }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: gain(0), y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: gain(1), z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: gain(2), w: 0)
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    private static func average(_ image: CIImage) -> SIMD4<Float> {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return .zero }
        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: output.extent.minX, y: output.extent.minY, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return SIMD4(pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private static func meanDifference(_ a: CIImage, _ b: CIImage) -> Float {
        let filter = CIFilter.differenceBlendMode()
        filter.inputImage = a
        filter.backgroundImage = b
        guard let output = filter.outputImage?.cropped(to: b.extent) else { return .infinity }
        let value = average(output)
        return value.x + value.y + value.z
    }

    private static func differenceMap(_ a: CIImage, _ b: CIImage) -> CIImage {
        let extent = b.extent
        func soften(_ image: CIImage) -> CIImage {
            image.clampedToExtent().applyingGaussianBlur(sigma: 2.5).cropped(to: extent)
        }
        let difference = CIFilter.differenceBlendMode()
        difference.inputImage = soften(a)
        difference.backgroundImage = soften(b)
        let strongest = CIFilter.maximumComponent()
        strongest.inputImage = difference.outputImage
        return strongest.outputImage?.cropped(to: extent) ?? b
    }
}
