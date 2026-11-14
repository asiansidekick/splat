import ARKit
import simd

/// Phil's phone (iPhone 14 Pro, iOS 26.6) never gets a surface from ARKit inside Reset, not even with ARKit running
/// alone (Surface test, 2026-11-08), while Apple's own Measure works: the same kind of iOS fault Apple's forums report
/// for third-party apps. So Reset finds where a point sits itself: it keeps the LiDAR depth of the last second and a
/// half, from slightly different places as the hand moves, and takes the middle of what all of them say along the
/// line of sight. One frame's depth swims by 10 to 20 cm on this phone; many frames together do not.
@MainActor
final class DepthFusion {
    private struct Shot {
        let depth: [Float]
        let width: Int
        let height: Int
        let worldToCamera: simd_float4x4
        let intrinsics: simd_float3x3
        let resolution: SIMD2<Float>
        let time: TimeInterval
    }

    private var shots: [Shot] = []
    /// Frames kept at least this far apart, so they come from different places as the hand moves.
    private let spacing: TimeInterval = 0.1
    private let keep = 15

    /// Call with each new frame; keeps a copy of its depth now and then.
    func add(_ frame: ARFrame) {
        guard case .normal = frame.camera.trackingState else { return }
        if let last = shots.last, frame.timestamp - last.time < spacing { return }
        guard let depth = Measurer.depth(of: frame) else { return }
        let size = frame.camera.imageResolution
        shots.append(Shot(depth: depth.values, width: depth.width, height: depth.height,
                          worldToCamera: frame.camera.transform.inverse, intrinsics: frame.camera.intrinsics,
                          resolution: SIMD2(Float(size.width), Float(size.height)), time: frame.timestamp))
        if shots.count > keep { shots.removeFirst(shots.count - keep) }
    }

    func clear() { shots = [] }

    /// Where the line of sight through a place in the current picture (0 to 1, sensor layout) meets the surface,
    /// agreed by the recent frames; nil when too few of them see it.
    func point(in frame: ARFrame, normalized n: CGPoint) -> (point: SIMD3<Float>, frames: Int, samples: Int)? {
        guard shots.count >= 3 else { return nil }
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let t = frame.camera.transform
        let local = SIMD4((Float(n.x) * Float(res.width) - k[2][0]) / k[0][0], -(Float(n.y) * Float(res.height) - k[2][1]) / k[1][1], -1, 0)
        let w = t * local
        let origin = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let direction = simd_normalize(SIMD3(w.x, w.y, w.z))
        var along: [Float] = []
        var seenBy = 0
        // Walk out along the line of sight a centimetre at a time; a step is on the surface when a frame's depth
        // there puts the surface within 1.5 cm of it.
        for shot in shots {
            var hits = 0
            var distance: Float = 0.2
            while distance < 5 {
                let p = origin + direction * distance
                let c = shot.worldToCamera * SIMD4(p, 1)
                let z = -c.z
                if z > 0.1 {
                    let u = (shot.intrinsics[0][0] * c.x / z + shot.intrinsics[2][0]) / shot.resolution.x
                    let v = (-shot.intrinsics[1][1] * c.y / z + shot.intrinsics[2][1]) / shot.resolution.y
                    if u > 0, v > 0, u < 1, v < 1 {
                        let x = Int(u * Float(shot.width)), y = Int(v * Float(shot.height))
                        let reading = shot.depth[min(y, shot.height - 1) * shot.width + min(x, shot.width - 1)]
                        if reading.isFinite, reading > 0.1, abs(reading - z) < 0.015 {
                            along.append(distance)
                            hits += 1
                        }
                    }
                }
                distance += 0.01
            }
            if hits > 0 { seenBy += 1 }
        }
        guard seenBy >= 3, along.count >= 6 else { return nil }
        // The first surface the line meets: the middle of the readings in the nearest 10 cm band that most frames agree on.
        along.sort()
        var best = (count: 0, start: 0)
        var j = 0
        for i in 0..<along.count {
            while along[i] - along[j] > 0.1 { j += 1 }
            if i - j + 1 > best.count { best = (i - j + 1, j) }
        }
        // Prefer the nearest band that has at least half as many readings as the busiest (a wall behind shows through edges).
        var start = best.start
        var count = best.count
        j = 0
        for i in 0..<along.count {
            while along[i] - along[j] > 0.1 { j += 1 }
            if i - j + 1 >= max(6, best.count / 2) { start = j; count = i - j + 1; break }
        }
        let band = along[start..<(start + count)]
        let middle = band[band.startIndex + band.count / 2]
        return (origin + direction * middle, seenBy, band.count)
    }
}
