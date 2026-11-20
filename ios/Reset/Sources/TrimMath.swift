import Foundation
import simd

/// The arithmetic of trimming a scan: which triangles a loop drawn on the screen takes away.
enum TrimMath {
    /// Whether a point is inside a closed loop (crossing count).
    static func inside(_ p: SIMD2<Float>, loop: [SIMD2<Float>]) -> Bool {
        guard loop.count >= 3 else { return false }
        var result = false
        var j = loop.count - 1
        for i in loop.indices {
            let a = loop[i], b = loop[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
            j = i
        }
        return result
    }

    /// The triangles left after a loop. `screen` holds where each corner point shows on the screen (nil behind the
    /// camera). Erase takes away triangles with two or more corners in the loop; Keep takes away all the others.
    static func trim(_ triangles: [UInt32], screen: [SIMD2<Float>?], loop: [SIMD2<Float>], keep: Bool) -> [UInt32] {
        guard loop.count >= 3 else { return triangles }
        var low = loop[0], high = loop[0]
        for p in loop { low = simd_min(low, p); high = simd_max(high, p) }
        // Each corner is tested once, however many triangles share it.
        var state = [UInt8](repeating: 0, count: screen.count)  // 0 unknown, 1 out, 2 in
        func isIn(_ index: UInt32) -> Bool {
            let i = Int(index)
            guard i < screen.count else { return false }
            if state[i] == 0 {
                var hit = false
                if let p = screen[i], p.x >= low.x, p.x <= high.x, p.y >= low.y, p.y <= high.y { hit = inside(p, loop: loop) }
                state[i] = hit ? 2 : 1
            }
            return state[i] == 2
        }
        var out: [UInt32] = []
        out.reserveCapacity(triangles.count)
        var t = 0
        while t + 2 < triangles.count {
            let a = triangles[t], b = triangles[t + 1], c = triangles[t + 2]
            let count = (isIn(a) ? 1 : 0) + (isIn(b) ? 1 : 0) + (isIn(c) ? 1 : 0)
            let caught = count >= 2
            if caught == keep { out.append(a); out.append(b); out.append(c) }
            t += 3
        }
        return out
    }
}
