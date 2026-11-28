import CoreGraphics
import UIKit
import Vision
import simd

/// Phil, 2026-11-22: "one [eye] can be different from the other, enforce sampling both eyes simultaneously in the scan
/// to maintain realistic eye lines". The model builder colours each part of the head from whichever picture saw it
/// best, so each eye can come from a different picture, looking a different way. Here both eyes (and a little round
/// them) are coloured again from the one picture that saw the face most square on, blended softly into the rest.
enum HeadEyes {
    /// The tip of the nose in head space: the front-most point down the middle of the face, 3 to 10 cm above the chin.
    static func noseTip(_ points: [SIMD3<Float>], chin: Float) -> SIMD3<Float>? {
        var nose: SIMD3<Float>?
        for p in points where abs(p.x) < 0.03 && p.y > chin + 0.03 && p.y < chin + 0.1 {
            if nose == nil || p.z > nose!.z { nose = p }
        }
        return nose
    }

    /// Where the eyes are in head space when ARKit didn't say: about 3.3 cm either side of the middle, 3.5 cm above
    /// the tip of the nose and 2.5 cm behind it.
    static func guess(_ points: [SIMD3<Float>], chin: Float) -> [SIMD3<Float>]? {
        guard let tip = noseTip(points, chin: chin) else { return nil }
        return [SIMD3(0.033, tip.y + 0.035, tip.z - 0.025), SIMD3(-0.033, tip.y + 0.035, tip.z - 0.025)]
    }

    /// Both eyes as Vision sees them in a picture written on its side (as the camera wrote it): each eye's middle in
    /// the picture's own pixels, and how wide the eye is. Nil unless both eyes are found.
    static func find(in photo: CGImage) -> (eyes: [SIMD2<Float>], width: Float)? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: photo, orientation: .right, options: [:])
        guard (try? handler.perform([request])) != nil,
              let face = (request.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
              let marks = face.landmarks else { return nil }
        let w = Float(photo.width), h = Float(photo.height), box = face.boundingBox
        // Upright (x across, y up from the bottom, 0 to 1) back into the picture on its side, as HeadVision does.
        func back(_ p: CGPoint) -> SIMD2<Float> {
            let ux = Float(box.minX + p.x * box.width), uy = Float(box.minY + p.y * box.height)
            return SIMD2((1 - uy) * w, (1 - ux) * h)
        }
        var eyes: [SIMD2<Float>] = []
        var widths: [Float] = []
        for region in [marks.leftEye, marks.rightEye] {
            guard let region, region.pointCount >= 3 else { return nil }
            let points = region.normalizedPoints.map(back)
            eyes.append(points.reduce(SIMD2<Float>(0, 0), +) / Float(points.count))
            var far: Float = 0
            for a in points { for b in points { far = max(far, simd_distance(a, b)) } }
            widths.append(far)
        }
        guard simd_distance(eyes[0], eyes[1]) > 10 else { return nil }
        return (eyes, max(widths[0], widths[1], simd_distance(eyes[0], eyes[1]) * 0.4))
    }

    /// Recolours the eyes of `head` (head space, with picture places) in its pictures (by file name) from `photo`, taken
    /// by `camera` (head space) with the shot's focal lengths. `eyes` are the eyes' middles in the photo's pixels and
    /// `eyeWidth` how wide one is: every bit of the face facing the camera that lands within an eye's width of an eye's
    /// middle takes the photo's colour, fading out to one and a half widths. Returns how many picture pixels changed.
    static func match(_ head: BodyMesh, pictures: inout [String: UIImage], eyes: [SIMD2<Float>], eyeWidth: Float, photo: CGImage,
                      camera: simd_float4x4, shot: HeadShot, flip: Int) -> Int {
        guard let uvs = head.uvs, !eyes.isEmpty, eyeWidth > 1 else { return 0 }
        let inner = eyeWidth * 0.95, outer = eyeWidth * 1.5
        // The photo's pixels.
        let pw = photo.width, ph = photo.height
        var photoPixels = [UInt8](repeating: 0, count: pw * ph * 4)
        let drawn: Bool = photoPixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(photo, in: CGRect(x: 0, y: 0, width: pw, height: ph))
            return true
        }
        guard drawn else { return 0 }
        let sx = Float(pw) / Float(max(1, shot.width)), sy = Float(ph) / Float(max(1, shot.height))
        let eye = camera.columns.3.xyz
        /// Where a point of the head lands in the photo, in its pixels.
        func pixel(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            guard var q = HeadMath.project(p, camera: camera, fx: shot.fx, fy: shot.fy, cx: shot.cx, cy: shot.cy) else { return nil }
            if flip & 1 != 0 { q.x = Float(shot.width) - q.x }
            if flip & 2 != 0 { q.y = Float(shot.height) - q.y }
            return SIMD2(q.x * sx, q.y * sy)
        }
        func sample(_ q: SIMD2<Float>) -> SIMD3<Float>? {
            let x = Int(q.x), y = Int(q.y)
            guard x >= 0, y >= 0, x < pw, y < ph else { return nil }
            let i = (y * pw + x) * 4
            return SIMD3(Float(photoPixels[i]), Float(photoPixels[i + 1]), Float(photoPixels[i + 2]))
        }
        func nearest(_ q: SIMD2<Float>) -> Float {
            var best = Float.greatestFiniteMagnitude
            for e in eyes { best = min(best, simd_distance(e, q)) }
            return best
        }
        func nearestPoint(_ p: SIMD3<Float>) -> Float { pixel(p).map { nearest($0) } ?? .greatestFiniteMagnitude }
        // Only the front of the face: what lies further from the camera than the eyes' depth plus 6 cm is the back.
        var eyeDepth: Float = .greatestFiniteMagnitude
        for t in 0..<head.triangleCount {
            let c = (0..<3).map { head.positions[Int(head.triangles[t * 3 + $0])] }
            let normal = simd_cross(c[1] - c[0], c[2] - c[0])
            let middle = (c[0] + c[1] + c[2]) / 3
            guard simd_length(normal) > 1e-12, simd_dot(simd_normalize(normal), simd_normalize(eye - middle)) > 0.15,
                  let q = pixel(middle), nearest(q) < outer else { continue }
            eyeDepth = min(eyeDepth, simd_distance(middle, eye))
        }
        guard eyeDepth < 2 else { return 0 }

        var changed = 0
        for part in head.parts {
            guard let name = part.texture, let image = pictures[name]?.cgImage else { continue }
            let w = image.width, h = image.height
            let range = part.firstTriangle..<min(head.triangleCount, part.firstTriangle + part.triangleCount)
            // Only triangles near an eye, facing the camera.
            let near = range.filter { t in
                let c = (0..<3).map { head.positions[Int(head.triangles[t * 3 + $0])] }
                return c.contains { nearestPoint($0) < outer * 1.6 }
            }
            guard !near.isEmpty else { continue }
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let ok: Bool = pixels.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { continue }
            // Each picture pixel of those triangles: its place on the head, its colour in the square-on photo.
            var spots: [(index: Int, weight: Float, colour: SIMD3<Float>, ring: Bool)] = []
            for t in near {
                let ids = (0..<3).map { Int(head.triangles[t * 3 + $0]) }
                let p = ids.map { head.positions[$0] }
                let normal = simd_cross(p[1] - p[0], p[2] - p[0])
                let middle = (p[0] + p[1] + p[2]) / 3
                guard simd_length(normal) > 1e-12, simd_dot(simd_normalize(normal), simd_normalize(eye - middle)) > 0.15,
                      simd_distance(middle, eye) < eyeDepth + 0.06 else { continue }
                let u = ids.map { SIMD2(uvs[$0].x * Float(w), uvs[$0].y * Float(h)) }
                let lo = simd_max(simd_min(simd_min(u[0], u[1]), u[2]).rounded(.down), SIMD2(0, 0))
                let hi = simd_min(simd_max(simd_max(u[0], u[1]), u[2]).rounded(.up), SIMD2(Float(w - 1), Float(h - 1)))
                guard lo.x <= hi.x, lo.y <= hi.y, (hi.x - lo.x) * (hi.y - lo.y) < 250_000 else { continue }
                let d = (u[1].y - u[2].y) * (u[0].x - u[2].x) + (u[2].x - u[1].x) * (u[0].y - u[2].y)
                guard abs(d) > 1e-9 else { continue }
                for y in Int(lo.y)...Int(hi.y) {
                    for x in Int(lo.x)...Int(hi.x) {
                        let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                        let a = ((u[1].y - u[2].y) * (q.x - u[2].x) + (u[2].x - u[1].x) * (q.y - u[2].y)) / d
                        let b = ((u[2].y - u[0].y) * (q.x - u[2].x) + (u[0].x - u[2].x) * (q.y - u[2].y)) / d
                        let c = 1 - a - b
                        guard a >= -0.01, b >= -0.01, c >= -0.01 else { continue }
                        let place = p[0] * a + p[1] * b + p[2] * c
                        guard let q = pixel(place) else { continue }
                        let distance = nearest(q)
                        guard distance < outer * 1.15, let colour = sample(q) else { continue }
                        let weight = distance <= inner ? 1 : max(0, 1 - (distance - inner) / (outer - inner))
                        spots.append((y * w + x, weight, colour, distance > outer))
                    }
                }
            }
            guard !spots.isEmpty else { continue }
            // The photo's brightness and colour matched to the picture's, from a thin ring at the edge of the patch.
            var mine = SIMD3<Float>(repeating: 0), theirs = SIMD3<Float>(repeating: 0)
            var rings = 0
            for s in spots where s.ring {
                let i = s.index * 4
                mine += SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                theirs += s.colour
                rings += 1
            }
            var gain = SIMD3<Float>(repeating: 1)
            if rings > 20 { gain = simd_clamp(mine / simd_max(theirs, SIMD3(repeating: 1)), SIMD3(repeating: 0.7), SIMD3(repeating: 1.4)) }
            for s in spots where s.weight > 0 {
                let i = s.index * 4
                let old = SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                let new = simd_clamp(s.colour * gain, SIMD3(repeating: 0), SIMD3(repeating: 255))
                let mixed = old + (new - old) * s.weight
                pixels[i] = UInt8(mixed.x.rounded()); pixels[i + 1] = UInt8(mixed.y.rounded()); pixels[i + 2] = UInt8(mixed.z.rounded())
                changed += 1
            }
            let data = Data(pixels)
            guard let provider = CGDataProvider(data: data as CFData),
                  let made = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            pictures[name] = UIImage(cgImage: made)
            Diagnostics.log(String(format: "Head scan: eyes coloured from one picture in %@, colour matched x %.2f %.2f %.2f", name, gain.x, gain.y, gain.z))
        }
        return changed
    }
}
