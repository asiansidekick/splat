import Foundation
import simd

/// Finds a sharp corner in a small patch of the camera picture, so a measuring point can be moved
/// from where a finger landed onto the corner it was aimed at (a sheet of paper, a box, a screen).
enum CornerSnap {
    /// `luma` is a width by height patch of brightness, 0 to 255, row by row. Returns the corner
    /// nearest `centre` within `radius` pixels, in patch pixels, or nil when there is no clear one
    /// (a straight edge, a flat area, a blur).
    static func corner(luma: [Float], width: Int, height: Int, near centre: SIMD2<Float>, within radius: Float) -> SIMD2<Float>? {
        guard width > 12, height > 12, luma.count == width * height else { return nil }
        // Smoothed a little so camera noise is not mistaken for edges.
        var blurred = [Float](repeating: 0, count: luma.count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum: Float = 0
                for j in -1...1 { for i in -1...1 { sum += luma[(y + j) * width + x + i] } }
                blurred[y * width + x] = sum / 9
            }
        }
        var gx = [Float](repeating: 0, count: luma.count)
        var gy = [Float](repeating: 0, count: luma.count)
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                gx[y * width + x] = (blurred[y * width + x + 1] - blurred[y * width + x - 1]) / 2
                gy[y * width + x] = (blurred[(y + 1) * width + x] - blurred[(y - 1) * width + x]) / 2
            }
        }
        // The weaker of the two directions the picture changes in, over a small window: big only
        // where it changes both ways, which is a corner (an edge changes one way only).
        let margin = 5
        let window = 2
        var response = [Float](repeating: 0, count: luma.count)
        let lowX = max(margin, Int(centre.x - radius) - 2), highX = min(width - margin, Int(centre.x + radius) + 3)
        let lowY = max(margin, Int(centre.y - radius) - 2), highY = min(height - margin, Int(centre.y + radius) + 3)
        guard lowX < highX, lowY < highY else { return nil }
        for y in lowY..<highY {
            for x in lowX..<highX {
                var a: Float = 0, b: Float = 0, c: Float = 0
                for j in -window...window {
                    for i in -window...window {
                        let dx = gx[(y + j) * width + x + i]
                        let dy = gy[(y + j) * width + x + i]
                        a += dx * dx
                        b += dx * dy
                        c += dy * dy
                    }
                }
                response[y * width + x] = 0.5 * (a + c - (((a - c) * (a - c) + 4 * b * b) as Float).squareRoot())
            }
        }
        var candidates: [(point: SIMD2<Float>, score: Float)] = []
        for y in lowY..<highY {
            for x in lowX..<highX {
                let here = response[y * width + x]
                guard here >= minimumResponse else { continue }
                let p = SIMD2(Float(x), Float(y))
                guard simd_distance(p, centre) <= radius else { continue }
                var isPeak = true
                search: for j in -2...2 {
                    for i in -2...2 where (i != 0 || j != 0) {
                        let nx = x + i, ny = y + j
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        if response[ny * width + nx] > here { isPeak = false; break search }
                    }
                }
                if isPeak { candidates.append((p, here)) }
            }
        }
        guard let best = candidates.map { $0.score }.max() else { return nil }
        // Of the clear corners, the one nearest where the finger was.
        return candidates.filter { $0.score >= best * 0.5 }.min { simd_distance($0.point, centre) < simd_distance($1.point, centre) }?.point
    }

    /// Below this a corner is too faint to trust.
    static let minimumResponse: Float = 600
}
