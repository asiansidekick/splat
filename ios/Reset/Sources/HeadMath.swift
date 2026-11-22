import Foundation
import simd

/// The sums behind scanning a head (Phil, 2026-11-22: "scan a head either in selfie mode with the front facing camera
/// or manually scanning an actor's head"). Kept free of ARKit, SceneKit and UIKit so CI can test it on a Mac.
///
/// The head's own space ("head space"): metres, the middle of the head at 0,0,0, +Y up, +Z out of the face and +X to
/// the face's own left. ARKit's face anchor uses this way round, and so do the posable people (ScanRig), so a head
/// from either camera fits any character.
enum HeadMath {
    // MARK: Where the camera looks

    /// The point closest to every line of sight (least squares): where someone walking round a head keeps pointing
    /// the phone. Nil when the lines are nearly parallel (the phone hardly turned).
    static func raysMeet(_ origins: [SIMD3<Float>], _ directions: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard origins.count == directions.count, origins.count >= 2 else { return nil }
        var a = simd_double3x3()
        var b = SIMD3<Double>()
        for (o, d) in zip(origins, directions) {
            let length = simd_length(d)
            guard length > 1e-6 else { continue }
            let u = SIMD3<Double>(d / length)
            let m = matrix_identity_double3x3 - simd_double3x3(columns: (u * u.x, u * u.y, u * u.z))
            a += m
            b += m * SIMD3<Double>(o)
        }
        guard abs(a.determinant) > 1e-4 else { return nil }
        return SIMD3<Float>(a.inverse * b)
    }

    /// Head space from a head in the room: its middle, and a point in front of the face (the camera that saw it most
    /// square on). Up is the room's up. The matrix takes head space into the room.
    static func frame(centre: SIMD3<Float>, towards front: SIMD3<Float>) -> simd_float4x4 {
        var z = front - centre
        z.y = 0
        z = simd_length(z) > 1e-5 ? simd_normalize(z) : SIMD3(0, 0, 1)
        let y = SIMD3<Float>(0, 1, 0)
        let x = simd_normalize(simd_cross(y, z))
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(centre, 1))
    }

    // MARK: Which views are new

    /// The smallest angle (radians) between `direction` and any of `kept` (all unit length). Pi with none kept.
    static func nearestAngle(_ direction: SIMD3<Float>, _ kept: [SIMD3<Float>]) -> Float {
        var best: Float = .pi
        for k in kept { best = min(best, acos(min(1, max(-1, simd_dot(direction, k))))) }
        return best
    }

    /// Selfie: the slot of the ring (like Face ID's) that a view of the face lights, from where the camera is in head
    /// space. The screen shows the face as a mirror does, so the slot lit is the way the nose points: slot 0 at the
    /// screen's right (head turned to its own right, the camera off at the face's left, +X), going round anticlockwise.
    /// A slot lights once the head has turned far enough that way: 50° to the sides, 18° up or down.
    static func selfieSlot(_ cameraInHead: SIMD3<Float>, slots: Int) -> Int? {
        let length = simd_length(cameraInHead)
        guard length > 1e-4, slots > 0 else { return nil }
        let d = cameraInHead / length
        let off = acos(min(1, max(-1, d.z)))
        // Looking up puts the camera below the face (-Y), which lights the top of the ring.
        let angle = atan2(-d.y, d.x)
        let sideways = abs(cos(angle))
        let needed = (18 + 32 * sideways * sideways) * Float.pi / 180
        guard off >= needed else { return nil }
        let turn = angle < 0 ? angle + 2 * .pi : angle
        return Int((turn / (2 * .pi) * Float(slots)).rounded()) % slots
    }

    /// Walking round: the slot of the ring a view lights, by the way round the head the camera is (seen from above).
    static func roundSlot(camera: SIMD3<Float>, centre: SIMD3<Float>, slots: Int) -> Int? {
        let d = SIMD2(camera.x - centre.x, camera.z - centre.z)
        guard simd_length(d) > 0.05, slots > 0 else { return nil }
        let angle = atan2(d.y, d.x)
        let turn = angle < 0 ? angle + 2 * .pi : angle
        return Int((turn / (2 * .pi) * Float(slots)).rounded()) % slots
    }

    // MARK: Cutting the head out of each picture

    /// Points on the outside of the space a head (with its hair) can take, in head space, cut off flat below `floor`.
    static func headShell(floor: Float) -> [SIMD3<Float>] {
        let middle = SIMD3<Float>(0, 0.025, -0.01), radii = SIMD3<Float>(0.135, 0.17, 0.155)
        var out: [SIMD3<Float>] = []
        for i in 0...12 {
            let v = Float(i) / 12 * .pi
            for j in 0..<24 {
                let u = Float(j) / 24 * 2 * .pi
                var p = middle + radii * SIMD3(sin(v) * cos(u), cos(v), sin(v) * sin(u))
                p.y = max(p.y, floor)
                out.append(p)
            }
        }
        return out
    }

    /// A point in head space as a pixel of a picture: `camera` is where the camera was in head space (ARKit's way:
    /// it looks down its own -Z with +Y up), fx, fy, cx, cy its focal lengths and middle in pixels. Nil behind it.
    static func project(_ p: SIMD3<Float>, camera: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float) -> SIMD2<Float>? {
        let c = camera.inverse * SIMD4(p, 1)
        guard c.z < -0.02 else { return nil }
        return SIMD2(fx * c.x / -c.z + cx, fy * -c.y / -c.z + cy)
    }

    /// The convex outline round some points, anticlockwise (Andrew's monotone chain).
    static func hull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let p = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [SIMD2<Float>] = []
        for q in p {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        var upper: [SIMD2<Float>] = []
        for q in p.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    /// Whether a point is inside an anticlockwise convex outline.
    static func inside(_ q: SIMD2<Float>, _ hull: [SIMD2<Float>]) -> Bool {
        guard hull.count >= 3 else { return false }
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            if (b.x - a.x) * (q.y - a.y) - (b.y - a.y) * (q.x - a.x) < 0 { return false }
        }
        return true
    }

    /// For each row of a picture `width` x `height`, the first and last column inside the outline (empty rows give
    /// first > last). Filling a mask by rows is far quicker than asking about every pixel.
    static func rows(of hull: [SIMD2<Float>], width: Int, height: Int) -> [(Int, Int)] {
        var out = [(Int, Int)](repeating: (1, 0), count: max(0, height))
        guard hull.count >= 3, width > 0 else { return out }
        for y in 0..<height {
            let fy = Float(y) + 0.5
            var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
            for i in hull.indices {
                let a = hull[i], b = hull[(i + 1) % hull.count]
                guard (a.y <= fy && b.y > fy) || (b.y <= fy && a.y > fy) else { continue }
                let x = a.x + (fy - a.y) / (b.y - a.y) * (b.x - a.x)
                low = min(low, x)
                high = max(high, x)
            }
            guard low <= high else { continue }
            out[y] = (max(0, Int(low.rounded(.up))), min(width - 1, Int(high.rounded(.down))))
        }
        return out
    }

    // MARK: Where the neck is cut

    /// The chin's height in head space, read from the face's profile: the front-most points down the middle of the
    /// face. Going down from the tip of the nose, the chin ends where the front falls back more than 4.5 cm (the neck).
    static func chin(_ points: [SIMD3<Float>]) -> Float? {
        let step: Float = 0.005, bottom: Float = -0.26
        let count = 90
        var front = [Float](repeating: -.greatestFiniteMagnitude, count: count)
        for p in points where abs(p.x) < 0.03 {
            let i = Int(((p.y - bottom) / step).rounded(.down))
            if i >= 0, i < count { front[i] = max(front[i], p.z) }
        }
        func y(_ i: Int) -> Float { bottom + (Float(i) + 0.5) * step }
        // The nose: the front-most slice between 8 cm below and 6 cm above the middle of the head.
        var nose = -1
        for i in 0..<count where y(i) > -0.08 && y(i) < 0.06 && front[i] > -1 {
            if nose < 0 || front[i] > front[nose] { nose = i }
        }
        guard nose > 0 else { return nil }
        var i = nose
        while i > 0, y(i) > -0.2 {
            i -= 1
            // A gap in the profile (nothing scanned there) is passed over.
            guard front[i] > -1 else { continue }
            if front[i] < front[nose] - 0.045 { return min(-0.05, y(i) - 0.005) }
        }
        return nil
    }

    /// Where the head is cut from its neck (the head piece's 0,0,0, as ScanRig.headPiece cuts a person's head): 3.5 cm
    /// under the chin, across the middle of the neck. Its front is read from the neck's own profile where there is one.
    static func neckCut(_ points: [SIMD3<Float>], chin: Float) -> SIMD3<Float> {
        let y = chin - 0.035
        var front = -Float.greatestFiniteMagnitude
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for p in points {
            if abs(p.y - y) < 0.012, abs(p.x) < 0.03 { front = max(front, p.z) }
            if p.y > y { low = simd_min(low, p); high = simd_max(high, p) }
        }
        let midX = low.x <= high.x ? (low.x + high.x) / 2 : 0
        // A neck is about 11 cm front to back; its middle sits a little behind the middle of the skull.
        let z = front > -1 ? front - 0.055 : (low.z <= high.z ? (low.z + high.z) / 2 - 0.025 : -0.02)
        return SIMD3(midX, y, z)
    }
}
