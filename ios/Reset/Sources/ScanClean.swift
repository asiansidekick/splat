import simd

/// Picks the object out of a free scan (Phil, 2026-11-05: a chair scanned with the whole room round
/// it was unusable). The object is wherever the scan was aimed: the screen middle, kept on it while
/// walking round. Triangles are kept if they are above the floor under it, near it, the best view of
/// their patch of surface, and joined to it. Pure maths, so CI can test it.
enum ScanClean {
    struct Mesh {
        var vertices: [SIMD3<Float>]
        var indices: [UInt32]
        /// Where the camera was for this picture.
        var eye: SIMD3<Float>
    }

    /// The middle of the places the scan was aimed at (median per axis), nil with none.
    static func centre(of points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard !points.isEmpty else { return nil }
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
        return SIMD3(median(points.map(\.x)), median(points.map(\.y)), median(points.map(\.z)))
    }

    /// For each mesh, the indices (three per triangle) of the triangles to keep.
    /// `radius`: how far from the centre, sideways, the object may reach.
    static func isolate(_ meshes: [Mesh], centre: SIMD3<Float>, radius: Float = 1.5) -> [[UInt32]] {
        struct Triangle {
            var mesh: Int
            var first: Int  // position of its three indices in the mesh
            var middle: SIMD3<Float>
            var score: Float
        }
        func sideways(_ p: SIMD3<Float>) -> Float { simd_length(SIMD2(p.x - centre.x, p.z - centre.z)) }

        // Every triangle, with its middle and how well its picture saw it.
        var all: [Triangle] = []
        for (m, mesh) in meshes.enumerated() {
            var i = 0
            while i + 2 < mesh.indices.count {
                let a = mesh.vertices[Int(mesh.indices[i])], b = mesh.vertices[Int(mesh.indices[i + 1])], c = mesh.vertices[Int(mesh.indices[i + 2])]
                let middle = (a + b + c) / 3
                let normal = simd_cross(b - a, c - a)
                let length = simd_length(normal)
                if length > 1e-9 {
                    let toEye = mesh.eye - middle
                    let distance = simd_length(toEye)
                    let facing = abs(simd_dot(normal / length, toEye / max(distance, 0.001)))
                    all.append(Triangle(mesh: m, first: i, middle: middle, score: facing / (1 + distance * 0.4)))
                }
                i += 3
            }
        }
        // The floor under the object: the low end of what is within 35 cm of its middle.
        let near = all.filter { sideways($0.middle) < 0.35 }.map(\.middle.y).sorted()
        let floor = near.isEmpty ? centre.y - 0.5 : near[near.count / 50]
        let candidates = all.filter {
            $0.middle.y > floor + 0.03 && $0.middle.y < floor + 2.5 && sideways($0.middle) < radius
        }
        // One layer: in each 4 cm cell, only the picture that saw it best keeps its triangles there
        // (all of that picture's, so there are no holes within one picture).
        func key(_ p: SIMD3<Float>, _ cell: Float) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
        }
        var best: [SIMD3<Int32>: (mesh: Int, score: Float)] = [:]
        for t in candidates {
            let k = key(t.middle, 0.04)
            if let old = best[k], old.score >= t.score { continue }
            best[k] = (t.mesh, t.score)
        }
        let layer = candidates.filter { best[key($0.middle, 0.04)]?.mesh == $0.mesh }
        // Joined to the object: cells of 6 cm that touch, starting from the one nearest the middle.
        var cells: [SIMD3<Int32>: [Int]] = [:]
        for (n, t) in layer.enumerated() { cells[key(t.middle, 0.06), default: []].append(n) }
        var kept = Set<Int>()
        if let seed = layer.indices.min(by: { simd_distance(layer[$0].middle, centre) < simd_distance(layer[$1].middle, centre) }) {
            var stack = [key(layer[seed].middle, 0.06)]
            var seen: Set<SIMD3<Int32>> = [stack[0]]
            while let cell = stack.popLast() {
                for n in cells[cell] ?? [] { kept.insert(n) }
                for dx in Int32(-1)...1 {
                    for dy in Int32(-1)...1 {
                        for dz in Int32(-1)...1 {
                            let next = SIMD3(cell.x + dx, cell.y + dy, cell.z + dz)
                            if cells[next] != nil, seen.insert(next).inserted { stack.append(next) }
                        }
                    }
                }
            }
        }
        var result = [[UInt32]](repeating: [], count: meshes.count)
        for n in kept {
            let t = layer[n]
            result[t.mesh].append(contentsOf: meshes[t.mesh].indices[t.first..<t.first + 3])
        }
        return result
    }
}
