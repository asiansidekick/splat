import Foundation
import simd

/// Keeping a dimension's ends on the picture (Phil, 2026-10-31): a small patch of the camera
/// image is remembered at each end and found again in later frames; two views of the same
/// patch fix how far away it is, from how far the phone has moved, whatever the depth map said.
enum FeatureTrack {
    /// Where a remembered patch sits in a grid of brightness values, searching `radius` pixels each way
    /// from the middle. `dx` and `dy` are the shift from the middle; `score` is the normalised
    /// cross-correlation, 1 for a perfect match. Nil for a patch with no texture to match on.
    static func find(patch: [Float], patchSize n: Int, in grid: [Float], gridSize g: Int, radius: Int) -> (dx: Int, dy: Int, score: Float)? {
        guard n > 2, g >= n, patch.count == n * n, grid.count == g * g else { return nil }
        let count = Float(n * n)
        let mean = patch.reduce(0, +) / count
        let zero = patch.map { $0 - mean }
        let norm = zero.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-3 else { return nil }
        let middle = (g - n) / 2
        var best: (dx: Int, dy: Int, score: Float)?
        zero.withUnsafeBufferPointer { p in
            grid.withUnsafeBufferPointer { w in
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let x0 = middle + dx, y0 = middle + dy
                        guard x0 >= 0, y0 >= 0, x0 + n <= g, y0 + n <= g else { continue }
                        var sum: Float = 0, square: Float = 0, dot: Float = 0
                        for j in 0..<n {
                            let row = (y0 + j) * g + x0
                            let prow = j * n
                            for i in 0..<n {
                                let v = w[row + i]
                                sum += v
                                square += v * v
                                dot += p[prow + i] * v
                            }
                        }
                        let variance = square - sum * sum / count
                        guard variance > 1e-3 else { continue }
                        let score = dot / (norm * variance.squareRoot())
                        if score > (best?.score ?? -2) { best = (dx, dy, score) }
                    }
                }
            }
        }
        return best
    }

    /// How far along the first ray (from `o1` in direction `d1`, a unit vector) the point is that is
    /// nearest to the second ray; nil when the two views are too alike (under `minAngle` radians
    /// apart) or the rays pass further than `maxGap` metres from each other (a bad match or a
    /// drifted position).
    static func depthAlong(o1: SIMD3<Float>, d1: SIMD3<Float>, o2: SIMD3<Float>, d2: SIMD3<Float>, minAngle: Float, maxGap: Float) -> Float? {
        let b = simd_dot(d1, d2)
        guard acos(min(1, max(-1, b))) > minAngle else { return nil }
        let w0 = o1 - o2
        let d = simd_dot(d1, w0), e = simd_dot(d2, w0)
        let denom = 1 - b * b
        guard denom > 1e-6 else { return nil }
        let s = (b * e - d) / denom
        let t = (e - b * d) / denom
        guard s > 0.05, t > 0 else { return nil }
        let gap = simd_distance(o1 + d1 * s, o2 + d2 * t)
        return gap <= maxGap ? s : nil
    }
}
