import CoreImage
import Foundation
import simd

/// A LiDAR depth map and the camera that took it.
struct DepthView: @unchecked Sendable {
    let depth: [Float]  // metres, row major, width x height
    let width: Int
    let height: Int
    let cameraToWorld: simd_float4x4
    let intrinsics: simd_float3x3  // in camera image pixels
    let imageWidth: Int  // camera image width the intrinsics refer to
    /// ARKit's per-pixel confidence (0 low, 1 medium, 2 high), when known.
    var confidence: [UInt8]? = nil

    /// Intrinsics scaled down to the depth map's resolution.
    var depthIntrinsics: (fx: Float, fy: Float, cx: Float, cy: Float) {
        let s = Float(width) / Float(imageWidth)
        return (intrinsics[0][0] * s, intrinsics[1][1] * s, intrinsics[2][0] * s, intrinsics[2][1] * s)
    }
}

enum DepthDiff {
    /// Changes smaller than this (plus 2 cm per metre of distance) are LiDAR or tracking noise.
    /// Tuned up after the first device test showed the whole table flagged with nothing moved.
    static let threshold: Float = 0.06
    static let perMetre: Float = 0.02
    /// A flagged pixel needs this many flagged neighbours (of 8) to count, so only solid areas show.
    static let minNeighbours = 6
    static let maxRange: Float = 5

    /// A colour mask at the live depth map's resolution: red where something is now nearer than
    /// in the reference (added or moved in), blue where the reference surface is now missing.
    static func mask(live: DepthView, references: [DepthView]) -> CIImage? {
        let w = live.width
        let h = live.height
        guard w > 0, h > 0, live.depth.count == w * h else { return nil }
        var expected = [Float](repeating: .infinity, count: w * h)
        let worldToLive = live.cameraToWorld.inverse
        let liveK = live.depthIntrinsics

        // Re-project each reference depth map into the live camera, keeping the nearest surface.
        for ref in references where ref.width > 0 && ref.depth.count == ref.width * ref.height {
            let k = ref.depthIntrinsics
            let toLive = worldToLive * ref.cameraToWorld
            for v in stride(from: 0, to: ref.height, by: 2) {
                for u in stride(from: 0, to: ref.width, by: 2) {
                    let d = ref.depth[v * ref.width + u]
                    guard d > 0.1, d < maxRange else { continue }
                    // ARKit camera space: x right, y up, looking down -z.
                    let pRef = SIMD4<Float>((Float(u) - k.cx) / k.fx * d, -(Float(v) - k.cy) / k.fy * d, -d, 1)
                    let p = toLive * pRef
                    let z = -p.z
                    guard z > 0.1 else { continue }
                    let lu = Int((liveK.fx * p.x / z + liveK.cx).rounded())
                    let lv = Int((-liveK.fy * p.y / z + liveK.cy).rounded())
                    // Fill a 2x2 block to cover the stride.
                    for dv in 0...1 {
                        for du in 0...1 {
                            let x = lu + du
                            let y = lv + dv
                            guard x >= 0, x < w, y >= 0, y < h else { continue }
                            let i = y * w + x
                            if z < expected[i] { expected[i] = z }
                        }
                    }
                }
            }
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var changed = 0
        for i in 0..<(w * h) {
            let e = expected[i]
            let d = live.depth[i]
            guard e.isFinite, d > 0.1, d < maxRange else { continue }
            if let confidence = live.confidence, confidence.count == w * h, confidence[i] < DepthMap.minConfidence { continue }
            let limit = threshold + perMetre * e
            let o = i * 4
            if d < e - limit {
                pixels[o] = 135; pixels[o + 1] = 24; pixels[o + 2] = 24; pixels[o + 3] = 150  // premultiplied red
                changed += 1
            } else if d > e + limit {
                pixels[o] = 24; pixels[o + 1] = 65; pixels[o + 2] = 141; pixels[o + 3] = 150  // premultiplied blue
                changed += 1
            }
        }
        guard changed > 0 else { return nil }
        let cleaned = removeSpeckles(pixels, width: w, height: h)
        let data = Data(cleaned)
        return CIImage(
            bitmapData: data, bytesPerRow: w * 4, size: CGSize(width: w, height: h),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Drops isolated flagged pixels so single noisy readings do not flicker.
    private static func removeSpeckles(_ pixels: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var out = pixels
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                guard pixels[o + 3] > 0 else { continue }
                var neighbours = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        let ny = y + dy
                        if nx >= 0, nx < w, ny >= 0, ny < h, pixels[(ny * w + nx) * 4 + 3] > 0 { neighbours += 1 }
                    }
                }
                if neighbours < minNeighbours { out.replaceSubrange(o..<(o + 4), with: [0, 0, 0, 0]) }
            }
        }
        return out
    }
}
