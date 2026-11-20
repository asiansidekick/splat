import Foundation
import simd

// Phil, 2026-11-20: "My scan turned out a little unflattering… Keep the body, as is, there may be costume elements I
// don't want smoothed. Improve head and shoulders." The head and shoulders are smoothed of the small lumps
// photogrammetry leaves (Taubin smoothing, which does not shrink), fading out to nothing below the shoulders, so the
// body and costume stay exactly as scanned. The photo is untouched. Kept free of SceneKit and UIKit for CI.

extension ScanRig {
    struct Smoothing {
        /// Full strength from here up.
        var fullFrom: Float
        /// No smoothing from here down; in between it fades.
        var noneBelow: Float
        var rounds: Int
    }

    /// Head and shoulders: full from the neck up, fading to nothing a little below the shoulder joints.
    static func headAndShoulders(joints J: [SIMD3<Float>], height H: Float) -> Smoothing {
        let shoulders = (J[bone("LeftArm")].y + J[bone("RightArm")].y) / 2
        let neck = J[bone("Neck")].y
        return Smoothing(fullFrom: max(neck, shoulders + 0.01 * H), noneBelow: shoulders - 0.07 * H, rounds: 8)
    }

    /// How much a point at height y is smoothed, 0 to 1.
    static func strength(_ y: Float, _ s: Smoothing) -> Float {
        if y >= s.fullFrom { return 1 }
        if y <= s.noneBelow { return 0 }
        let t = (y - s.noneBelow) / max(1e-4, s.fullFrom - s.noneBelow)
        return t * t * (3 - 2 * t)
    }

    /// Taubin smoothing (shrink, then grow back) where `s` says, leaving every other point exactly where it was.
    /// Points at the same place (a scan splits them where its photo is cut) move together, so no seams open; points on
    /// an open edge stay put. Normals are made again where points moved. Returns how many points moved.
    @discardableResult
    static func smooth(_ mesh: inout BodyMesh, _ s: Smoothing) -> Int {
        guard s.rounds > 0, !mesh.positions.isEmpty else { return 0 }
        // One shared point per place (to a tenth of a millimetre).
        var key: [SIMD3<Int32>: Int] = [:]
        var welded = [Int](repeating: 0, count: mesh.positions.count)
        var places: [SIMD3<Float>] = []
        for (i, p) in mesh.positions.enumerated() {
            let k = SIMD3<Int32>(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()), Int32((p.z * 10_000).rounded()))
            if let found = key[k] { welded[i] = found } else { key[k] = places.count; welded[i] = places.count; places.append(p) }
        }
        let weight = places.map { strength($0.y, s) }
        guard weight.contains(where: { $0 > 0 }) else { return 0 }
        // Neighbours, and edges used once (an open edge).
        var neighbours = [Set<Int>](repeating: [], count: places.count)
        var edgeUse: [SIMD2<Int32>: Int] = [:]
        var t = 0
        while t + 2 < mesh.triangles.count {
            let c = (0..<3).map { welded[Int(mesh.triangles[t + $0])] }
            t += 3
            guard weight[c[0]] > 0 || weight[c[1]] > 0 || weight[c[2]] > 0 else { continue }
            for (a, b) in [(c[0], c[1]), (c[1], c[2]), (c[2], c[0])] where a != b {
                neighbours[a].insert(b); neighbours[b].insert(a)
                edgeUse[SIMD2(Int32(min(a, b)), Int32(max(a, b))), default: 0] += 1
            }
        }
        var pinned = [Bool](repeating: false, count: places.count)
        for (edge, uses) in edgeUse where uses == 1 { pinned[Int(edge.x)] = true; pinned[Int(edge.y)] = true }
        let moving = places.indices.filter { weight[$0] > 0 && !pinned[$0] && !neighbours[$0].isEmpty }
        let lists = neighbours.map { Array($0) }
        func step(_ factor: Float) {
            var moved = places
            for i in moving {
                var mean = SIMD3<Float>(0, 0, 0)
                for n in lists[i] { mean += places[n] }
                mean /= Float(lists[i].count)
                moved[i] = places[i] + weight[i] * factor * (mean - places[i])
            }
            places = moved
        }
        for _ in 0..<s.rounds { step(0.5); step(-0.53) }
        // Normals from the welded shape, so they agree across the photo's seams; only where something moved.
        var weldedTriangles: [UInt32] = []
        weldedTriangles.reserveCapacity(mesh.triangles.count)
        for corner in mesh.triangles { weldedTriangles.append(UInt32(welded[Int(corner)])) }
        let normals = BodyMesh.smoothNormals(places, weldedTriangles)
        var changed = 0
        for i in mesh.positions.indices where weight[welded[i]] > 0 {
            let p = places[welded[i]]
            if p != mesh.positions[i] { changed += 1 }
            mesh.positions[i] = p
            if i < mesh.normals.count { mesh.normals[i] = normals[welded[i]] }
        }
        return changed
    }
}
