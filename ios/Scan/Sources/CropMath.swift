import Foundation
import simd

/// An axis-aligned crop box in the model's own coordinates (metres, y up).
struct CropBox: Equatable, Codable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var size: SIMD3<Float> { max - min }
    var centre: SIMD3<Float> { (min + max) / 2 }

    func contains(_ p: SIMD3<Float>) -> Bool {
        p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y && p.z >= min.z && p.z <= max.z
    }

    static func around(_ points: [SIMD3<Float>]) -> CropBox? {
        guard var lo = points.first else { return nil }
        var hi = lo
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return CropBox(min: lo, max: hi)
    }

    /// Keeps the box at least `minSize` on every side so a drag can't collapse it.
    mutating func keepOpen(minSize: Float = 0.01) {
        for i in 0..<3 where max[i] - min[i] < minSize {
            let mid = (max[i] + min[i]) / 2
            min[i] = mid - minSize / 2
            max[i] = mid + minSize / 2
        }
    }
}

/// Finds the object in a scanned area: the floor (the big flat layer at the bottom) is cut away,
/// and the clump of points nearest the middle of what stands on the floor is kept.
enum CropMath {
    struct Result: Equatable {
        var box: CropBox
        /// Height of the floor that was found, or nil when nothing looked like a floor.
        var floorY: Float?
    }

    /// The floor: the most crowded 1 cm height band in the lowest third, if it holds at least
    /// `share` of all points. Returns the top of that band.
    static func floorHeight(_ points: [SIMD3<Float>], band: Float = 0.01, share: Float = 0.08) -> Float? {
        guard let all = CropBox.around(points), all.size.y > band * 3 else { return nil }
        let count = Int((all.size.y / band).rounded(.up)) + 1
        var bins = [Int](repeating: 0, count: count)
        for p in points {
            bins[Swift.min(count - 1, Int((p.y - all.min.y) / band))] += 1
        }
        let low = Swift.max(1, count / 3)
        var best = 0
        for i in 0..<low where bins[i] > bins[best] { best = i }
        // Spread across two bands when the floor sits on a boundary.
        let pair = bins[best] + Swift.max(best > 0 ? bins[best - 1] : 0, best + 1 < count ? bins[best + 1] : 0)
        guard Float(pair) >= share * Float(points.count) else { return nil }
        var top = best
        if best + 1 < count && bins[best + 1] * 2 >= bins[best] { top = best + 1 }
        return all.min.y + Float(top + 1) * band
    }

    /// Suggested crop: above the floor, round the clump nearest the middle, plus a small margin.
    static func suggest(_ points: [SIMD3<Float>], cell: Float = 0.02, margin: Float = 0.02) -> Result? {
        guard let all = CropBox.around(points) else { return nil }
        let floor = floorHeight(points)
        let lift: Float = 0.01
        let above = floor.map { f in points.filter { $0.y > f + lift } } ?? points
        guard above.count >= 20, let upper = CropBox.around(above) else {
            return Result(box: all, floorY: floor)
        }

        // Footprint grid (x, z) of what stands above the floor.
        let nx = Swift.max(1, Int((upper.size.x / cell).rounded(.up)) + 1)
        let nz = Swift.max(1, Int((upper.size.z / cell).rounded(.up)) + 1)
        var grid = [Int](repeating: 0, count: nx * nz)
        func index(_ p: SIMD3<Float>) -> Int {
            let i = Swift.min(nx - 1, Int((p.x - upper.min.x) / cell))
            let k = Swift.min(nz - 1, Int((p.z - upper.min.z) / cell))
            return k * nx + i
        }
        for p in above { grid[index(p)] += 1 }

        // Seed: the busiest cell, weighted towards the middle of the upright points.
        var mean = SIMD3<Float>(repeating: 0)
        for p in above { mean += p }
        mean /= Float(above.count)
        let reach = Swift.max(upper.size.x, upper.size.z) / 2 + cell
        var seed = -1
        var seedScore: Float = -1
        for k in 0..<nz {
            for i in 0..<nx where grid[k * nx + i] > 0 {
                let x = upper.min.x + (Float(i) + 0.5) * cell
                let z = upper.min.z + (Float(k) + 0.5) * cell
                let d = simd_length(SIMD2<Float>(x - mean.x, z - mean.z)) / reach
                let score = Float(grid[k * nx + i]) * Swift.max(0.05, 1 - d)
                if score > seedScore { seedScore = score; seed = k * nx + i }
            }
        }
        guard seed >= 0 else { return Result(box: all, floorY: floor) }

        // Grow the clump through occupied neighbours (8-connected). Lone specks (one point) are
        // not walked through, so stray points don't bridge the object to clutter nearby.
        let solid = 2
        var keep = [Bool](repeating: false, count: nx * nz)
        var stack = [seed]
        keep[seed] = true
        while let c = stack.popLast() {
            let i = c % nx, k = c / nx
            for dk in -1...1 {
                for di in -1...1 where di != 0 || dk != 0 {
                    let ii = i + di, kk = k + dk
                    guard ii >= 0, ii < nx, kk >= 0, kk < nz else { continue }
                    let n = kk * nx + ii
                    if !keep[n] && grid[n] >= solid {
                        keep[n] = true
                        stack.append(n)
                    }
                }
            }
        }

        let kept = above.filter { keep[index($0)] }
        guard var box = CropBox.around(kept) else { return Result(box: all, floorY: floor) }
        box.min -= SIMD3<Float>(repeating: margin)
        box.max += SIMD3<Float>(repeating: margin)
        if let floor { box.min.y = floor + 0.005 }
        // Never reach past the scan itself.
        box.min = simd_max(box.min, all.min)
        box.max = simd_min(box.max, all.max)
        box.keepOpen()
        return Result(box: box, floorY: floor)
    }

    /// Evenly thins points to at most `limit` (for drawing and for speed).
    static func thin(_ points: [SIMD3<Float>], limit: Int) -> [SIMD3<Float>] {
        guard points.count > limit, limit > 0 else { return points }
        let step = Double(points.count) / Double(limit)
        return (0..<limit).map { points[Int(Double($0) * step)] }
    }
}
