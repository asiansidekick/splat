import Foundation
import simd

/// Phil, 2026-11-26: "Can we add a soft edge to a hard cropped scan". A scan cut with Trim (Erase / Keep) or by the
/// scanner's box ends in a hard line where the triangles stop. These sums find those cut edges (an edge of only one
/// triangle) and how far each point of the model is from the nearest one, walking along the surface, so the model can
/// fade out toward its cut edges. Kept free of SceneKit so the crop tests can run it on a Mac.
enum SoftEdgeMath {
    /// The Soft edge button's steps: hard (as scanned), soft, softer.
    static let stepNames = ["Hard edge", "Soft edge", "Softer edge"]

    /// How far in from a cut edge the fade reaches (metres, in the model's own size), for a model `size` across at
    /// its longest. A share of the model, so a cropped room and a cropped cup both look soft, but never under 1 cm.
    static func width(step: Int, size: Float) -> Float {
        switch step {
        case 1: return max(size * 0.05, 0.01)
        case 2: return max(size * 0.12, 0.025)
        default: return 0
        }
    }

    /// The same number for every point at the same place: a scan repeats a point where the photo's pieces meet (a
    /// seam), and those repeats must count as one, or every seam would look like a cut edge.
    static func weld(_ positions: [SIMD3<Float>], tolerance: Float) -> [Int32] {
        let step = max(tolerance, 1e-7)
        var seen: [SIMD3<Int32>: Int32] = [:]
        seen.reserveCapacity(positions.count)
        var ids = [Int32](repeating: 0, count: positions.count)
        var next: Int32 = 0
        for (i, p) in positions.enumerated() {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                ids[i] = next
                next += 1
                continue
            }
            let key = SIMD3<Int32>(Int32(clamping: Int((p.x / step).rounded())), Int32(clamping: Int((p.y / step).rounded())),
                                   Int32(clamping: Int((p.z / step).rounded())))
            if let id = seen[key] {
                ids[i] = id
            } else {
                seen[key] = next
                ids[i] = next
                next += 1
            }
        }
        return ids
    }

    struct Result {
        /// For every point (as numbered in `positions`): how far it is from the nearest cut edge along the surface,
        /// or infinity when further than the limit.
        var distance: [Float]
        /// How many cut edges the model has (0 for a closed model: nothing to soften).
        var openEdges: Int
    }

    /// The cut edges of a model and each point's distance from them, up to `limit`. `triangles` holds the corner
    /// numbers of each material's triangles, three by three.
    static func distances(positions: [SIMD3<Float>], triangles: [[UInt32]], limit: Float, tolerance: Float) -> Result {
        let ids = weld(positions, tolerance: tolerance)
        let count = Int((ids.max() ?? -1) + 1)
        // Each edge (by its two welded ends, smaller first) and how many triangles use it.
        var uses: [UInt64: UInt8] = [:]
        var triangleCount = 0
        for list in triangles { triangleCount += list.count / 3 }
        uses.reserveCapacity(triangleCount * 2)
        func key(_ a: Int32, _ b: Int32) -> UInt64 {
            let low = UInt64(UInt32(bitPattern: min(a, b))), high = UInt64(UInt32(bitPattern: max(a, b)))
            return (low << 32) | high
        }
        for list in triangles {
            var t = 0
            while t + 2 < list.count {
                let a = Int(list[t]), b = Int(list[t + 1]), c = Int(list[t + 2])
                t += 3
                guard a < ids.count, b < ids.count, c < ids.count else { continue }
                let ia = ids[a], ib = ids[b], ic = ids[c]
                // A triangle squashed flat to a line or a point has no edges of its own.
                guard ia != ib, ib != ic, ia != ic else { continue }
                for k in [key(ia, ib), key(ib, ic), key(ic, ia)] {
                    let n = uses[k] ?? 0
                    if n < 255 { uses[k] = n + 1 }
                }
            }
        }
        // Neighbours of each welded point, with the length of the edge between them.
        var degree = [Int32](repeating: 0, count: count + 1)
        var open = 0
        var start = [Float](repeating: .infinity, count: count)
        var welded = [SIMD3<Float>](repeating: .zero, count: count)
        for (i, id) in ids.enumerated() { welded[Int(id)] = positions[i] }
        for (k, n) in uses {
            let a = Int(k >> 32), b = Int(k & 0xFFFF_FFFF)
            degree[a] += 1
            degree[b] += 1
            if n == 1 {
                open += 1
                start[a] = 0
                start[b] = 0
            }
        }
        guard open > 0 else {
            return Result(distance: [Float](repeating: .infinity, count: positions.count), openEdges: 0)
        }
        var first = [Int32](repeating: 0, count: count + 1)
        for i in 0..<count { first[i + 1] = first[i] + degree[i] }
        var fill = first
        var next = [Int32](repeating: 0, count: Int(first[count]))
        for k in uses.keys {
            let a = Int(k >> 32), b = Int(k & 0xFFFF_FFFF)
            next[Int(fill[a])] = Int32(b)
            fill[a] += 1
            next[Int(fill[b])] = Int32(a)
            fill[b] += 1
        }
        // Walk out from every cut edge at once, nearest first, stopping at the limit.
        var best = start
        var heap = Heap()
        for i in 0..<count where start[i] == 0 { heap.push(0, Int32(i)) }
        while let (d, node) = heap.pop() {
            let i = Int(node)
            guard d <= best[i] else { continue }
            for e in Int(first[i])..<Int(first[i + 1]) {
                let j = Int(next[e])
                let nd = d + simd_distance(welded[i], welded[j])
                if nd < best[j], nd <= limit {
                    best[j] = nd
                    heap.push(nd, Int32(j))
                }
            }
        }
        return Result(distance: ids.map { best[Int($0)] }, openEdges: open)
    }

    /// How solid a point is: 0 on a cut edge, 1 from `width` in, easing in and out (smoothstep) so no line shows
    /// where the fade starts.
    static func fade(_ distance: Float, width: Float) -> Float {
        guard width > 0, distance.isFinite else { return 1 }
        let t = min(max(distance / width, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Nearest-first list for the walk.
    private struct Heap {
        private var items: [(Float, Int32)] = []

        mutating func push(_ d: Float, _ n: Int32) {
            items.append((d, n))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard items[parent].0 > items[i].0 else { break }
                items.swapAt(parent, i)
                i = parent
            }
        }

        mutating func pop() -> (Float, Int32)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count, items[l].0 < items[m].0 { m = l }
                    if r < items.count, items[r].0 < items[m].0 { m = r }
                    if m == i { break }
                    items.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
    }
}
