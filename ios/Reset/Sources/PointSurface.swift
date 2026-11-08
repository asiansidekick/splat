import ARKit
import simd

/// Surfaces from the camera picture alone, the way Apple's Measure manages on phones without working LiDAR (Phil,
/// 2026-11-08: his LiDAR is faulty, so ARKit gives Reset no surfaces). ARKit tracks hundreds of points of detail in
/// the picture (grout lines, wood grain, marks) and knows where each one is in the room: these are what the phone's
/// own position is worked out from. Kept for a few seconds, the ones round a line of sight give the surface there,
/// and a line end put on that surface stays with the picture as the phone moves, because both come from the same
/// tracking.
@MainActor
final class PointSurface {
    private var points: [UInt64: (point: SIMD3<Float>, time: TimeInterval)] = [:]
    private let keepFor: TimeInterval = 5
    private let most = 5000
    private var lastFrame: TimeInterval = 0

    func add(_ frame: ARFrame) {
        guard case .normal = frame.camera.trackingState, frame.timestamp - lastFrame > 0.05,
              let cloud = frame.rawFeaturePoints else { return }
        lastFrame = frame.timestamp
        for (i, id) in cloud.identifiers.enumerated() {
            points[id] = (cloud.points[i], frame.timestamp)
        }
        if points.count > most || Int(frame.timestamp * 2) % 4 == 0 {
            points = points.filter { frame.timestamp - $0.value.time < keepFor }
            if points.count > most {
                let newest = points.sorted { $0.value.time > $1.value.time }.prefix(most)
                points = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
        }
    }

    func clear() { points = [:] }

    var count: Int { points.count }

    /// Where the line of sight through a place in the current picture (0 to 1, sensor layout) meets the surface the
    /// tracked points round it lie on; nil when too few points are near it or they do not lie flat.
    func point(in frame: ARFrame, normalized n: CGPoint) -> (point: SIMD3<Float>, points: Int)? {
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let t = frame.camera.transform
        let local = SIMD4((Float(n.x) * Float(res.width) - k[2][0]) / k[0][0], -(Float(n.y) * Float(res.height) - k[2][1]) / k[1][1], -1, 0)
        let w = t * local
        let origin = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let direction = simd_normalize(SIMD3(w.x, w.y, w.z))
        // Points in a narrow cone round the line of sight (about 7 degrees, at least 4 cm across).
        var near: [SIMD3<Float>] = []
        for (_, entry) in points {
            let v = entry.point - origin
            let along = simd_dot(v, direction)
            guard along > 0.15, along < 6 else { continue }
            let off = simd_length(v - direction * along)
            if off < max(0.04, along * 0.12) { near.append(entry.point) }
        }
        guard near.count >= 10 else { return nil }
        // The flat surface most of them lie on (random tries of three points), then refined from all that agree.
        var best: (centre: SIMD3<Float>, normal: SIMD3<Float>, inliers: [SIMD3<Float>]) = (.zero, .zero, [])
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<80 {
            let a = near[Int.random(in: 0..<near.count, using: &generator)]
            let b = near[Int.random(in: 0..<near.count, using: &generator)]
            let c = near[Int.random(in: 0..<near.count, using: &generator)]
            let cross = simd_cross(b - a, c - a)
            guard simd_length(cross) > 1e-6 else { continue }
            let normal = simd_normalize(cross)
            let inliers = near.filter { abs(simd_dot($0 - a, normal)) < 0.012 }
            if inliers.count > best.inliers.count { best = (a, normal, inliers) }
        }
        guard best.inliers.count >= 8, Float(best.inliers.count) >= Float(near.count) * 0.5 else { return nil }
        let centre = best.inliers.reduce(SIMD3<Float>.zero, +) / Float(best.inliers.count)
        var normal = Self.flattest(best.inliers, centre: centre) ?? best.normal
        if simd_dot(normal, direction) > 0 { normal = -normal }
        let facing = simd_dot(direction, normal)
        guard abs(facing) > 0.12 else { return nil }  // seen almost edge on: too unsure
        let distance = simd_dot(centre - origin, normal) / facing
        guard distance > 0.1, distance < 6 else { return nil }
        return (origin + direction * distance, best.inliers.count)
    }

    /// The direction the points vary least in: the surface's normal.
    private static func flattest(_ points: [SIMD3<Float>], centre: SIMD3<Float>) -> SIMD3<Float>? {
        var c = simd_float3x3(0)
        for p in points {
            let d = p - centre
            c += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        // The smallest eigenvector of c is the largest of (trace * I - c): power iteration.
        let trace = c[0][0] + c[1][1] + c[2][2]
        let m = simd_float3x3(diagonal: SIMD3(repeating: trace)) - c
        var v = simd_normalize(SIMD3<Float>(0.3, 1, 0.2))
        for _ in 0..<30 {
            let next = m * v
            guard simd_length(next) > 1e-9 else { return nil }
            v = simd_normalize(next)
        }
        return v
    }
}
