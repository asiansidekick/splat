import Foundation
import simd

/// Lines a model built from plain pictures up with the room. The model builder gives each picture a camera place in
/// its own made-up space (any size, any way up); ARKit knows where each picture was really taken. The best turn, size
/// and shift from one set of places to the other (Horn, 1987) makes the model real size and upright.
enum ScanAlign {
    struct Fit: Codable, Equatable {
        var scale: Float
        /// Quaternion x, y, z, w.
        var rotation: [Float]
        var translation: [Float]
        /// Root mean square distance left between the two sets, in metres.
        var error: Float

        var quaternion: simd_quatf { simd_quatf(ix: rotation[0], iy: rotation[1], iz: rotation[2], r: rotation[3]) }
    }

    /// The fit taking each `from` point onto its `to` point. Nil with too few points or cameras that hardly moved.
    static func fit(from a: [SIMD3<Float>], to b: [SIMD3<Float>]) -> Fit? {
        guard a.count == b.count, a.count >= 4 else { return nil }
        let n = Double(a.count)
        let pa = a.map { SIMD3<Double>($0) }, pb = b.map { SIMD3<Double>($0) }
        let ca = pa.reduce(SIMD3<Double>(), +) / n
        let cb = pb.reduce(SIMD3<Double>(), +) / n
        var s = [[Double]](repeating: [0, 0, 0], count: 3)
        var spreadA = 0.0, spreadB = 0.0
        for i in pa.indices {
            let p = pa[i] - ca, q = pb[i] - cb
            spreadA += simd_length_squared(p)
            spreadB += simd_length_squared(q)
            for r in 0..<3 { for c in 0..<3 { s[r][c] += p[r] * q[c] } }
        }
        // Cameras spread over less than about 10 cm say nothing about size.
        guard spreadA > 1e-9, spreadB / n > 0.01 else { return nil }
        let (xx, xy, xz) = (s[0][0], s[0][1], s[0][2])
        let (yx, yy, yz) = (s[1][0], s[1][1], s[1][2])
        let (zx, zy, zz) = (s[2][0], s[2][1], s[2][2])
        var m: [[Double]] = [
            [xx + yy + zz, yz - zy, zx - xz, xy - yx],
            [yz - zy, xx - yy - zz, xy + yx, zx + xz],
            [zx - xz, xy + yx, -xx + yy - zz, yz + zy],
            [xy - yx, zx + xz, yz + zy, -xx - yy + zz],
        ]
        // The turn is the eigenvector of the largest eigenvalue: shifted so every eigenvalue is positive, then found
        // by multiplying a vector through again and again.
        let shift = m.reduce(0) { $0 + $1.reduce(0) { $0 + abs($1) } }
        for i in 0..<4 { m[i][i] += shift }
        var v: [Double] = [1, 0.3, 0.2, 0.1]
        for _ in 0..<600 {
            var next = [Double](repeating: 0, count: 4)
            for r in 0..<4 { for c in 0..<4 { next[r] += m[r][c] * v[c] } }
            let length = sqrt(next.reduce(0) { $0 + $1 * $1 })
            guard length > 0 else { return nil }
            v = next.map { $0 / length }
        }
        let turn = simd_quatd(ix: v[1], iy: v[2], iz: v[3], r: v[0])
        let scale = sqrt(spreadB / spreadA)
        let shiftBy = cb - scale * turn.act(ca)
        var error = 0.0
        for i in pa.indices { error += simd_length_squared(scale * turn.act(pa[i]) + shiftBy - pb[i]) }
        return Fit(
            scale: Float(scale),
            rotation: [Float(turn.imag.x), Float(turn.imag.y), Float(turn.imag.z), Float(turn.real)],
            translation: [Float(shiftBy.x), Float(shiftBy.y), Float(shiftBy.z)],
            error: Float(sqrt(error / n)))
    }
}
