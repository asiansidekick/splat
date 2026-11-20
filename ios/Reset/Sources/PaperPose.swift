import Foundation
import simd

/// How far away a sheet of paper of known size is, worked out from its four corners in the camera
/// picture alone (Phil, 2026-10-31): the pinhole camera's own geometry, independent of the LiDAR,
/// so the two can be compared.
enum PaperPose {
    struct Result {
        /// Metres from the camera to the middle of the sheet, along the camera's viewing direction.
        let distance: Float
        /// How far the two edge directions disagree in scale (0 for a true rectangle of this shape).
        let mismatch: Float
        /// The sheet's middle in the camera's frame (x right, y down, z forward), metres.
        let centre: SIMD3<Double>
    }

    /// `corners` go round the sheet (in pixels, y down); `longSide` and `shortSide` are in metres.
    /// The first edge might be either side, so both are tried and the likelier one kept.
    static func solve(corners: [SIMD2<Float>], longSide: Float, shortSide: Float, fx: Float, fy: Float, cx: Float, cy: Float) -> Result? {
        guard corners.count == 4 else { return nil }
        let a = pose(corners, w: Double(longSide), h: Double(shortSide), fx: Double(fx), fy: Double(fy), cx: Double(cx), cy: Double(cy))
        let b = pose(corners, w: Double(shortSide), h: Double(longSide), fx: Double(fx), fy: Double(fy), cx: Double(cx), cy: Double(cy))
        switch (a, b) {
        case let (a?, b?): return a.mismatch <= b.mismatch ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    private static func pose(_ c: [SIMD2<Float>], w: Double, h: Double, fx: Double, fy: Double, cx: Double, cy: Double) -> Result? {
        let model: [(Double, Double)] = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
        // Homography from the sheet's plane to the picture: eight equations in eight unknowns.
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = model[i]
            let u = Double(c[i].x), v = Double(c[i].y)
            m[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            m[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        guard let s = gauss(m) else { return nil }
        let H = [[s[0], s[1], s[2]], [s[3], s[4], s[5]], [s[6], s[7], 1]]
        // K^-1 H, column by column.
        func column(_ j: Int) -> SIMD3<Double> {
            SIMD3((H[0][j] - cx * H[2][j]) / fx, (H[1][j] - cy * H[2][j]) / fy, H[2][j])
        }
        let a1 = column(0), a2 = column(1), a3 = column(2)
        let n1 = simd_length(a1), n2 = simd_length(a2)
        guard n1 > 1e-9, n2 > 1e-9 else { return nil }
        // The two columns of a rotation have length 1, so each carries the same scale.
        let lambda = 2 / (n1 + n2)
        var t = a3 * lambda
        if t.z < 0 { t = -t }
        guard t.z > 0.05 else { return nil }
        return Result(distance: Float(t.z), mismatch: Float(abs(n1 - n2) / ((n1 + n2) / 2)), centre: t)
    }

    /// Solves the 8 x 9 augmented system by elimination with pivoting.
    private static func gauss(_ input: [[Double]]) -> [Double]? {
        var m = input
        let n = 8
        for col in 0..<n {
            var pivot = col
            for row in col..<n where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for row in 0..<n where row != col {
                let f = m[row][col] / m[col][col]
                if f == 0 { continue }
                for k in col...n { m[row][k] -= f * m[col][k] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }
}
