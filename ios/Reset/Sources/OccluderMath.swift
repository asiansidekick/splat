import simd

/// One depth picture as an invisible mesh in room coordinates, used to hide 3D models behind the real things
/// in front of them: in Review frames from each frame's saved depth (build 1272) and in the live camera from
/// LiDAR (Phil, 2026-11-20: "Can models be obscured by objects in the room while in live view").
/// Pure maths, so CI can test it (CropTests).
///
/// The mesh is pushed back (5 cm, more far away where the depth is rougher) so a model standing against a
/// wall is not cut by it. Jumps in depth (the edge of a pillar) are left open. Phil, 2026-11-11: feet and legs
/// were chopped into blocks by the floor, so the floor itself never hides anything (a table top still does).
struct OccluderMesh: Sendable {
    var positions: [Float] = []
    var indices: [UInt32] = []
    /// The floor this picture showed (the lowest level much of it sits on), in room coordinates.
    var seenFloor: Float?

    /// `depth` is `width` by `height` metres; `confidence`, if given, the same size (ARKit: 0 low, 1 medium,
    /// 2 high), and readings below `minConfidence` are left out. `intrinsics` are the camera's for the full
    /// picture (`imageWidth` by `imageHeight`), `pose` the camera's place in the room (ARKit: x right, y up,
    /// looking down -z). Every `step`th depth pixel is a vertex. `floor` overrides the floor found in this
    /// picture (a live camera knows it better from the planes ARKit found).
    static func build(depth: [Float], confidence: [UInt8]? = nil, minConfidence: UInt8 = 0, width dw: Int, height dh: Int,
                      intrinsics k: simd_float3x3, pose: simd_float4x4, imageWidth w: Float, imageHeight h: Float,
                      step: Int = 1, floor knownFloor: Float? = nil,
                      pushBack: Float = 0.05, pushPerMetre: Float = 0.03, denoise: Bool = false) -> OccluderMesh? {
        guard dw > 8, dh > 8, step >= 1, w > 0, h > 0, depth.count >= dw * dh,
              k[0][0] > 0, k[1][1] > 0 else { return nil }
        if let confidence, confidence.count < dw * dh { return nil }
        // Phil, 2026-11-20 (build 1391): live edges flickered. A reading most of whose neighbours disagree or are
        // missing is a speck of noise: each reading becomes the middle of its 3 by 3 neighbourhood, or none.
        let depth = denoise ? median3(depth, width: dw, height: dh) : depth
        let cols = (dw - 1) / step + 1, rows = (dh - 1) / step + 1
        var mesh = OccluderMesh()
        mesh.positions.reserveCapacity(cols * rows * 3)
        var valid = [Bool](repeating: false, count: cols * rows)
        var values = [Float](repeating: 0, count: cols * rows)
        for gy in 0..<rows {
            for gx in 0..<cols {
                let x = gx * step, y = gy * step
                let d = depth[y * dw + x]
                var p = SIMD3<Float>.zero
                let sure = confidence.map { $0[y * dw + x] >= minConfidence } ?? true
                if sure, d.isFinite, d > 0.12, d < 8 {
                    let back = d + pushBack + pushPerMetre * d
                    let u = (Float(x) + 0.5) / Float(dw) * w, v = (Float(y) + 0.5) / Float(dh) * h
                    let world = pose * SIMD4((u - k[2][0]) / k[0][0] * back, -(v - k[2][1]) / k[1][1] * back, -back, 1)
                    p = SIMD3(world.x, world.y, world.z)
                    valid[gy * cols + gx] = true
                    values[gy * cols + gx] = d
                }
                mesh.positions.append(contentsOf: [p.x, p.y, p.z])
            }
        }
        // The floor: the lowest level that much of the picture sits on.
        var heights: [Float] = []
        heights.reserveCapacity(cols * rows / 4)
        for i in stride(from: 0, to: cols * rows, by: 4) where valid[i] { heights.append(mesh.positions[i * 3 + 1]) }
        heights.sort()
        if heights.count > 50 { mesh.seenFloor = heights[heights.count / 50] }
        let floor = knownFloor ?? mesh.seenFloor
        func point(_ i: Int) -> SIMD3<Float> { SIMD3(mesh.positions[i * 3], mesh.positions[i * 3 + 1], mesh.positions[i * 3 + 2]) }
        // Neighbours further apart on the grid may differ more in depth before they count as an edge.
        let spread = Float(step)
        for gy in 0..<(rows - 1) {
            for gx in 0..<(cols - 1) {
                let a = gy * cols + gx, b = a + 1, c = a + cols, e = c + 1
                guard valid[a], valid[b], valid[c], valid[e] else { continue }
                let low = min(min(values[a], values[b]), min(values[c], values[e]))
                let high = max(max(values[a], values[b]), max(values[c], values[e]))
                guard high - low < (0.03 + 0.05 * low) * spread else { continue }
                if let floor {
                    let pa = point(a), pe = point(e)
                    let normal = simd_cross(point(c) - pa, point(b) - pa)
                    let length = simd_length(normal)
                    let flat = length > 0 && abs(normal.y) / length > 0.8
                    if flat, (pa.y + pe.y) / 2 < floor + 0.12 { continue }
                }
                mesh.indices.append(contentsOf: [UInt32(a), UInt32(c), UInt32(b), UInt32(b), UInt32(c), UInt32(e)])
            }
        }
        return mesh.indices.isEmpty ? nil : mesh
    }

    /// Each reading replaced by the median of the real readings (0.12 to 8 m) in its 3 by 3 neighbourhood; 0 (none)
    /// where fewer than 5 of the 9 are real.
    static func median3(_ depth: [Float], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        var near = [Float](repeating: 0, count: 9)
        for y in 0..<height {
            for x in 0..<width {
                var n = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < height else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < width else { continue }
                        let d = depth[yy * width + xx]
                        if d.isFinite, d > 0.12, d < 8 { near[n] = d; n += 1 }
                    }
                }
                guard n >= 5 else { continue }
                // Insertion sort of at most 9.
                for i in 1..<n {
                    let v = near[i]
                    var j = i - 1
                    while j >= 0, near[j] > v { near[j + 1] = near[j]; j -= 1 }
                    near[j + 1] = v
                }
                out[y * width + x] = near[n / 2]
            }
        }
        return out
    }
}
