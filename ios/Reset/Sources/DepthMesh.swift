import simd

/// A grid mesh from one LiDAR depth picture, in room coordinates, with texture coordinates into the
/// camera picture it came with (0 to 1, y down). Pure maths, so CI can test it.
enum DepthMesh {
    struct Result {
        var vertices: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
    }

    /// `intrinsics` are the camera's for the full-size picture (`imageWidth` by `imageHeight`); depth
    /// pixels map onto that picture by proportion. Every `step`th depth pixel is a vertex. A square
    /// of four vertices is skipped if any is missing or if its depths differ by more than 4 cm plus
    /// 6% of the nearest, so there is no skin stretched across the gap between a near and a far thing.
    static func build(
        depth: [Float], width: Int, height: Int, camera: simd_float4x4, intrinsics k: simd_float3x3,
        imageWidth: Float, imageHeight: Float, step: Int, range: ClosedRange<Float> = 0.15...5
    ) -> Result {
        var result = Result()
        guard width > 1, height > 1, step >= 1, depth.count >= width * height else { return result }
        let fx = k[0][0], fy = k[1][1], cx = k[2][0], cy = k[2][1]
        let columns = (width - 1) / step + 1, rows = (height - 1) / step + 1
        var grid = [Int32](repeating: -1, count: columns * rows)
        func value(_ c: Int, _ r: Int) -> Float {
            depth[min(r * step, height - 1) * width + min(c * step, width - 1)]
        }
        for r in 0..<rows {
            for c in 0..<columns {
                let d = value(c, r)
                guard d.isFinite, range.contains(d) else { continue }
                let i = min(c * step, width - 1), j = min(r * step, height - 1)
                let u = (Float(i) + 0.5) / Float(width) * imageWidth
                let v = (Float(j) + 0.5) / Float(height) * imageHeight
                let w = camera * SIMD4((u - cx) / fx * d, -(v - cy) / fy * d, -d, 1)
                grid[r * columns + c] = Int32(result.vertices.count)
                result.vertices.append(SIMD3(w.x, w.y, w.z))
                result.uvs.append(SIMD2(u / imageWidth, v / imageHeight))
            }
        }
        guard rows > 1, columns > 1 else { return result }
        for r in 0..<rows - 1 {
            for c in 0..<columns - 1 {
                let a = grid[r * columns + c], b = grid[r * columns + c + 1]
                let d = grid[(r + 1) * columns + c], e = grid[(r + 1) * columns + c + 1]
                guard a >= 0, b >= 0, d >= 0, e >= 0 else { continue }
                let ds = [value(c, r), value(c + 1, r), value(c, r + 1), value(c + 1, r + 1)]
                guard let low = ds.min(), let high = ds.max(), high - low < 0.04 + 0.06 * low else { continue }
                result.indices.append(contentsOf: [UInt32(a), UInt32(d), UInt32(b), UInt32(b), UInt32(d), UInt32(e)])
            }
        }
        return result
    }
}
