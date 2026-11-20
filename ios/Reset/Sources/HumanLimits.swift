import Foundation
import simd

// Phil, 2026-11-20: "Characters should be able to bend forward, arms should not intersect with bodies, I find adjusting
// the arms awkward, the models jump into unnatural positions, focus on real range of motion and rotation of human limbs."
//
// Posing keeps to what a body can do. Each limb is worked out as a turn (no angles that flip over when an arm passes
// level or overhead), then held inside the real reach of the shoulder or hip, the real twist of the upper arm or thigh,
// and outside the torso. Dragging a hand or foot keeps the elbow or knee pointing where it was, so nothing snaps.
// Kept free of SceneKit so CI can test it on a Mac.

/// One slab of a torso: an ellipse across the body (or a whole egg shape when `round`), in some space.
struct BodySlab: Equatable {
    /// The bone it rides on (for a character's slabs in its rest pose), else -1.
    var bone: Int = -1
    var centre: SIMD3<Float>
    /// Half the width, pointing to the body's left; half the height, pointing up; half the depth, pointing forward.
    var across: SIMD3<Float>
    var up: SIMD3<Float>
    var depth: SIMD3<Float>
    var round = false

    /// Carried by a turn and move (and any even scale).
    func moved(by m: simd_float4x4) -> BodySlab {
        var s = self
        s.centre = (m * SIMD4(centre, 1)).xyz
        s.across = (m * SIMD4(across, 0)).xyz
        s.up = (m * SIMD4(up, 0)).xyz
        s.depth = (m * SIMD4(depth, 0)).xyz
        return s
    }

    /// Where a point is across the slab, each part 1 at its edge grown by `radius` (the thickness of an arm).
    private func spot(_ p: SIMD3<Float>, radius: Float) -> (x: Float, y: Float, z: Float)? {
        let a = simd_length(across), u = simd_length(up), d = simd_length(depth)
        guard a > 1e-6, u > 1e-6, d > 1e-6 else { return nil }
        let q = p - centre
        return (simd_dot(q, across) / a / (a + radius), simd_dot(q, up) / u / (round ? u + radius : u), simd_dot(q, depth) / d / (d + radius))
    }

    /// How deep a point of that thickness is inside: 0 outside, 1 at the middle.
    func inside(_ p: SIMD3<Float>, radius: Float) -> Float {
        guard let s = spot(p, radius: radius) else { return 0 }
        if round {
            let r = (s.x * s.x + s.y * s.y + s.z * s.z).squareRoot()
            return r < 1 ? 1 - r : 0
        }
        guard abs(s.y) <= 1 else { return 0 }
        let r = (s.x * s.x + s.z * s.z).squareRoot()
        return r < 1 ? 1 - r : 0
    }

    /// The point pushed straight out across the body (not up or down) to just outside.
    func pushedOut(_ p: SIMD3<Float>, radius: Float) -> SIMD3<Float> {
        guard inside(p, radius: radius) > 0, let s = spot(p, radius: radius) else { return p }
        let a = simd_length(across), d = simd_length(depth)
        var flat = SIMD2<Float>(s.x, s.z)
        // Straight through the middle: out the front.
        if simd_length(flat) < 1e-3 { flat = SIMD2(0, 1) }
        let edge: Float = round ? max(0.05, (1 - min(s.y * s.y, 1)).squareRoot()) : 1
        flat = simd_normalize(flat) * edge * 1.03
        let q = p - centre
        let along = simd_dot(q, simd_normalize(up)) * simd_normalize(up)
        return centre + along + simd_normalize(across) * (flat.x * (a + radius)) + simd_normalize(depth) * (flat.y * (d + radius))
    }
}

/// A torso to keep arms out of, and how thick the arms are, in the space a pose is worked out in.
struct BodyVolume {
    var slabs: [BodySlab]
    var upperArm: Float
    var forearm: Float

    func inside(_ p: SIMD3<Float>, radius: Float) -> Float { slabs.map { $0.inside(p, radius: radius) }.max() ?? 0 }

    func pushedOut(_ p: SIMD3<Float>, radius: Float) -> SIMD3<Float> {
        var p = p
        for _ in 0..<4 {
            guard let deepest = slabs.max(by: { $0.inside(p, radius: radius) < $1.inside(p, radius: radius) }),
                  deepest.inside(p, radius: radius) > 0 else { break }
            p = deepest.pushedOut(p, radius: radius)
        }
        return p
    }
}

/// An imported character's torso, measured from its own skin in the file's rest pose.
struct TorsoShape {
    var slabs: [BodySlab]
    var upperArm: Float
    var forearm: Float

    /// `samples`: points of the skin with the bone that pulls each most.
    static func measure(nodes: [RigNode], map: RigMap, samples: [(point: SIMD3<Float>, bone: Int)]) -> TorsoShape? {
        guard map.hips < nodes.count, map.armL.count == 3, map.armR.count == 3 else { return nil }
        let hipsY = nodes[map.hips].position.y
        let shoulderY = min(nodes[map.armL[0]].position.y, nodes[map.armR[0]].position.y)
        let span = shoulderY - hipsY
        guard span > 1e-4 else { return nil }
        // The thickness of an arm: how far its skin is from its bone, in the middle of the spread.
        func thickness(_ chains: [[Int]], _ k: Int, fallback: Float) -> Float {
            var gaps: [Float] = []
            for chain in chains {
                let a = nodes[chain[k]].position, b = nodes[chain[k + 1]].position
                let ab = b - a, length2 = simd_length_squared(ab)
                guard length2 > 1e-10 else { continue }
                for s in samples where s.bone == chain[k] {
                    let t = max(0, min(1, simd_dot(s.point - a, ab) / length2))
                    gaps.append(simd_distance(s.point, a + t * ab))
                }
            }
            guard gaps.count >= 8 else { return fallback }
            gaps.sort()
            return gaps[gaps.count / 2]
        }
        let upperArm = thickness([map.armL, map.armR], 0, fallback: span * 0.09)
        let forearm = thickness([map.armL, map.armR], 1, fallback: span * 0.075)
        // Slices from below the hips up to the shoulders, each as wide and deep as the skin pulled by the hips or spine.
        let torsoBones = Set([map.hips] + map.spine)
        let points = samples.filter { torsoBones.contains($0.bone) }
        let low = hipsY - span * 0.4, high = shoulderY - span * 0.02
        let count = 12
        let step = (high - low) / Float(count)
        func quantile(_ values: [Float], _ q: Float) -> Float {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * q)))]
        }
        var slabs: [BodySlab] = []
        for i in 0..<count {
            let y0 = low + Float(i) * step, y1 = y0 + step
            let inSlice = points.filter { $0.point.y >= y0 && $0.point.y < y1 }
            guard inSlice.count >= 8 else { continue }
            let xs = inSlice.map(\.point.x), zs = inSlice.map(\.point.z)
            let x0 = quantile(xs, 0.04), x1 = quantile(xs, 0.96), z0 = quantile(zs, 0.04), z1 = quantile(zs, 0.96)
            guard x1 > x0, z1 > z0 else { continue }
            var tally: [Int: Int] = [:]
            for p in inSlice { tally[p.bone, default: 0] += 1 }
            let bone = tally.max { $0.value < $1.value }?.key ?? map.hips
            slabs.append(BodySlab(bone: bone, centre: SIMD3((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
                                  across: SIMD3((x1 - x0) / 2, 0, 0), up: SIMD3(0, step * 0.55, 0), depth: SIMD3(0, 0, (z1 - z0) / 2)))
        }
        guard slabs.count >= 3 else { return nil }
        return TorsoShape(slabs: slabs, upperArm: upperArm, forearm: forearm)
    }
}

/// How far a shoulder, hip, elbow and knee can go, and posing that keeps to it.
enum HumanLimits {
    typealias Q = simd_quatf
    static let down = SIMD3<Float>(0, -1, 0)
    private static let xAxis = SIMD3<Float>(1, 0, 0), yAxis = SIMD3<Float>(0, 1, 0), zAxis = SIMD3<Float>(0, 0, 1)
    private static func turn(_ degrees: Float, _ axis: SIMD3<Float>) -> Q { Q(angle: degrees * .pi / 180, axis: axis) }
    private static func deg(_ r: Float) -> Float { r * 180 / .pi }
    private static func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

    /// A limb's angles: the same numbers as MannequinPose.Arm and Leg (bend is the elbow or knee).
    struct Limb: Equatable {
        var out: Float
        var forward: Float
        var inward: Float
        var bend: Float
    }

    static let elbowMost: Float = 150
    static let kneeMost: Float = 150

    // MARK: Turns and angles, seen as a left limb (a right limb is mirrored across the body first)

    /// How the upper arm or thigh is turned, in the frame it hangs from, as if it were a left limb.
    static func rotation(_ l: Limb) -> Q { turn(l.out, zAxis) * turn(-l.forward, xAxis) * turn(-l.inward, yAxis) }

    /// The angles back from a turn (exact, whatever way the limb points).
    static func limb(_ q: Q, bend: Float) -> Limb {
        let d = q.act(down)
        let x = asin(clamp(-d.z, -1, 1))
        let z = abs(d.x) < 1e-6 && abs(d.y) < 1e-6 ? 0 : atan2(d.x, -d.y)
        let r = (Q(angle: z, axis: zAxis) * Q(angle: x, axis: xAxis)).inverse * q
        var y = 2 * atan2(r.imag.y, r.real)
        if y > .pi { y -= 2 * .pi } else if y < -.pi { y += 2 * .pi }
        return Limb(out: deg(z), forward: -deg(x), inward: -deg(y), bend: bend)
    }

    /// The lower arm or shin's direction for a turn and bend: elbows fold forward, knees back.
    static func lowerDirection(_ q: Q, bend: Float, isArm: Bool) -> SIMD3<Float> {
        (q * turn(isArm ? -bend : bend, xAxis)).act(down)
    }

    /// Twist about the limb's own length, in degrees, measured from the shortest swing down to where it points:
    /// positive turns the upper arm or thigh in (a forearm folds across the belly, toes turn in).
    static func twist(_ q: Q) -> Float {
        let d = q.act(down)
        let s = swing(to: d)
        let t = q * s.inverse
        var a = 2 * atan2(simd_dot(t.imag, d), t.real)
        if a > .pi { a -= 2 * .pi } else if a < -.pi { a += 2 * .pi }
        return deg(a)
    }

    /// The shortest turn from hanging straight down to `d` (straight up goes by way of the side).
    static func swing(to d: SIMD3<Float>) -> Q {
        let n = simd_normalize(d)
        if n.y > 0.99999 { return turn(180, zAxis) }
        return Q(from: down, to: n)
    }

    // MARK: The real range

    /// The least a limb pointing `out` degrees (in the plane across the body) must come forward, in degrees;
    /// below it the arm would be behind the back further than a shoulder goes, or a thigh further back than a hip.
    static func leastForward(out a: Float, isArm: Bool, bend: Float) -> Float {
        // (out, least forward), out from -180 to 180: 0 hangs down, 90 straight out to the side, ±180 straight up,
        // -90 across the body.
        let table: [(Float, Float)] = isArm
            // Shoulder: back 60° hanging, 45° behind level to the side, little behind overhead or across the back.
            ? [(-180, -15), (-150, -15), (-120, 10), (-90, 30), (-60, 10), (-30, -30), (0, -60), (45, -55), (90, -45), (120, -40), (150, -30), (180, -15)]
            // Hip: back 25°, out 45°, across 25°; above level only when well forward (up to 125° with the knee bent).
            // Phil, 2026-11-20 (build 1392): a thigh raised out to the side near level is not a standing body's: out
            // past 45° needs the thigh well forward (as when sitting cross-legged).
            : [(-180, 55), (-135, 55), (-90, 40), (-60, 25), (-40, 10), (-25, -5), (-10, -20), (0, -25), (30, -18), (40, -10), (50, 15), (90, 60), (135, 70), (180, 55)]
        var g = table[0].1
        for k in 1..<table.count where a <= table[k].0 {
            let (a0, g0) = table[k - 1], (a1, g1) = table[k]
            g = g0 + (g1 - g0) * (a - a0) / max(a1 - a0, 1e-3)
            break
        }
        if a > table[table.count - 1].0 { g = table[table.count - 1].1 }
        if !isArm {
            // A straight leg lifts forward only to level (the back of the thigh pulls); a bent knee lets it come to the chest.
            let stiff = 35 * (1 - min(bend, 60) / 60)
            g += stiff * clamp((abs(a) - 90) / 45, 0, 1)
        }
        return g
    }

    /// How far the upper arm or thigh turns about its length (out, in), in degrees.
    static func twistRange(isArm: Bool) -> (low: Float, high: Float) { isArm ? (-90, 120) : (-45, 35) }

    /// How far a turn is outside the range, in degrees (0 inside it).
    static func overreach(_ q: Q, bend: Float, isArm: Bool) -> Float {
        let d = q.act(down)
        let a = abs(d.x) < 1e-6 && abs(d.y) < 1e-6 ? 0 : deg(atan2(d.x, -d.y))
        let forward = deg(asin(clamp(d.z, -1, 1)))
        var miss = max(0, leastForward(out: a, isArm: isArm, bend: bend) - forward)
        // An arm overhead has no clear twist; leave it free there.
        if !(isArm && d.y > 0.7) {
            let range = twistRange(isArm: isArm), t = twist(q)
            miss += max(0, t - range.high) + max(0, range.low - t)
        }
        return miss
    }

    /// The nearest turn inside the range: the limb brought round to where the shoulder or hip lets it point,
    /// its twist kept within what the joint allows, and the bend within what the elbow or knee allows.
    static func held(_ q: Q, bend: Float, isArm: Bool) -> (q: Q, bend: Float) {
        let bend = clamp(bend, 0, isArm ? elbowMost : kneeMost)
        var d = q.act(down)
        var t = twist(q)
        let a = abs(d.x) < 1e-6 && abs(d.y) < 1e-6 ? 0 : atan2(d.x, -d.y)
        let least = leastForward(out: deg(a), isArm: isArm, bend: bend)
        let forward = deg(asin(clamp(d.z, -1, 1)))
        var changed = false
        if forward < least {
            let g = least * .pi / 180
            d = SIMD3(cos(g) * sin(a), -cos(g) * cos(a), sin(g))
            changed = true
        }
        if !(isArm && d.y > 0.7) {
            let range = twistRange(isArm: isArm)
            let kept = clamp(t, range.low, range.high)
            if kept != t { t = kept; changed = true }
        }
        guard changed else { return (q, bend) }
        return (Q(angle: t * .pi / 180, axis: simd_normalize(d)) * swing(to: d), bend)
    }

    /// A limb's angles held inside the range.
    static func held(_ l: Limb, isArm: Bool) -> Limb {
        let q = rotation(l)
        let h = held(q, bend: l.bend, isArm: isArm)
        if simd_equal(h.q.vector, q.vector) && h.bend == l.bend { return l }
        return limb(h.q, bend: h.bend)
    }

    // MARK: Reaching

    /// What a limb hangs from and how long it is, in the space the pose is worked out in.
    struct Reach {
        var isArm: Bool
        var side: Int  // 0 left, 1 right
        /// The frame the limb hangs from (the chest for an arm, the pelvis for a leg): the body facing +Z, its left +X.
        var frame: Q
        var top: SIMD3<Float>  // shoulder or hip
        var upper: Float
        var lower: Float
        var body: BodyVolume?

        /// Into the limb's own frame, seen as a left limb.
        func inward(_ v: SIMD3<Float>) -> SIMD3<Float> {
            var c = frame.inverse.act(v)
            if side == 1 { c.x = -c.x }
            return c
        }

        func outward(_ c: SIMD3<Float>) -> SIMD3<Float> {
            var v = c
            if side == 1 { v.x = -v.x }
            return frame.act(v)
        }

        /// How deep the arm goes into the body, added up along it, for an arm `grow` times its own thickness.
        func collision(_ q: Q, bend: Float, grow: Float = 0.8) -> Float {
            guard isArm, let body else { return 0 }
            let d = q.act(HumanLimits.down), l = lowerDirection(q, bend: bend, isArm: true)
            let elbow = d * upper
            var total: Float = 0
            // Not the top of the upper arm: it always lies against the chest under the shoulder.
            for f: Float in [0.6, 0.8, 1] { total += body.inside(top + outward(d * (upper * f)), radius: body.upperArm * grow) }
            for f: Float in [0.25, 0.5, 0.75, 1] { total += body.inside(top + outward(elbow + l * (lower * f)), radius: body.forearm * grow) }
            return total
        }

        /// A rough cost of a turn: deep in the body costs most, then reaching past the joint's range. Coming close to the
        /// body costs a little, so the elbow eases away from it as the hand nears, rather than jumping clear at the touch.
        func cost(_ q: Q, bend: Float) -> Float {
            var cost = overreach(q, bend: bend, isArm: isArm)
            if isArm, body != nil { cost += collision(q, bend: bend) * 200 + collision(q, bend: bend, grow: 1.6) * 20 }
            if !isArm { cost += abs(twist(q)) * 0.02 }  // knees like to point forward
            return cost
        }

        /// Where the hand or foot is for a limb's angles.
        func end(_ l: Limb) -> SIMD3<Float> {
            let q = rotation(l)
            return top + outward(q.act(HumanLimits.down) * upper + lowerDirection(q, bend: l.bend, isArm: isArm) * lower)
        }
    }

    /// The limb reaching its hand or foot for `target`, the elbow or knee kept pointing as near as it can to where it
    /// points now (`now`: the limb's angles before), inside the joint's range and outside the body.
    static func reach(_ r: Reach, to target: SIMD3<Float>, now: Limb) -> Limb {
        var goal = target
        if r.isArm, let body = r.body {
            let radius = body.forearm * 1.3
            if body.inside(goal, radius: radius) > 0 {
                // Into the body: the hand stops on the skin where the finger went in, from where the hand is now.
                let from = r.end(now)
                if body.inside(from, radius: radius) == 0 {
                    var lo: Float = 0, hi: Float = 1
                    for _ in 0..<16 {
                        let mid = (lo + hi) / 2
                        if body.inside(from + (goal - from) * mid, radius: radius) > 0 { hi = mid } else { lo = mid }
                    }
                    goal = from + (goal - from) * lo
                } else {
                    goal = body.pushedOut(goal, radius: radius)
                }
            }
        }
        var t = r.inward(goal - r.top)
        let a = r.upper, b = r.lower
        guard a > 1e-6, b > 1e-6 else { return now }
        let most = a + b
        let fold = (180 - (r.isArm ? elbowMost : kneeMost)) * .pi / 180
        let least = (a * a + b * b - 2 * a * b * cos(fold)).squareRoot()
        var distance = simd_length(t)
        if distance < 1e-6 { t = down * least; distance = least }
        let reach = clamp(distance, least * 1.001, most * 0.999)
        let n = t / distance
        let cosA = clamp((a * a + reach * reach - b * b) / (2 * a * reach), -1, 1)
        let sinA = max(0, 1 - cosA * cosA).squareRoot()
        // Which way the elbow or knee sticks out now, across the line from the shoulder or hip to the target.
        let before = rotation(now)
        func across(_ v: SIMD3<Float>) -> SIMD3<Float> { v - simd_dot(v, n) * n }
        var pole: SIMD3<Float>
        let upperNow = before.act(down), endNow = upperNow * a + lowerDirection(before, bend: now.bend, isArm: r.isArm) * b
        if now.bend > 8, simd_length(endNow) > 1e-6 {
            // The way the elbow or knee sticks out from the line to the hand or foot now.
            let line = simd_normalize(endNow)
            pole = across(upperNow - simd_dot(upperNow, line) * line)
        } else {
            // Straight now: the side it would bend out to (an elbow sticks out behind the forearm, a knee in front).
            pole = across(before.act(SIMD3(0, 0, r.isArm ? -1 : 1)))
        }
        if simd_length(pole) < 1e-4 { pole = across(r.isArm ? SIMD3(0, -0.3, -1) : SIMD3(0, 0, 1)) }
        if simd_length(pole) < 1e-4 { pole = across(SIMD3(1, 0, 0)) }
        if simd_length(pole) < 1e-4 { pole = across(SIMD3(0, 0, 1)) }
        let u = simd_normalize(pole), v = simd_cross(n, u)
        let end = n * reach
        func at(_ spin: Float) -> (q: Q, bend: Float, cost: Float) {
            let s = spin * .pi / 180
            let elbow = n * (a * cosA) + (cos(s) * u + sin(s) * v) * (a * sinA)
            let pose = turnFor(upper: elbow, lower: end - elbow, isArm: r.isArm, before: before)
            return (pose.q, pose.bend, r.cost(pose.q, bend: pose.bend))
        }
        // Follow the way round the circle (the elbow or knee's possible places) that costs less, a little at a time
        // (at most 12° each move of the finger), so the elbow eases round rather than jumps.
        var found = at(0)
        for direction: Float in [1, -1] {
            var step = at(direction * 2)
            guard step.cost < found.cost - 1e-5 else { continue }
            var turned = direction * 2
            while abs(turned) < 12 {
                let next = at(turned + direction * 2)
                guard next.cost < step.cost - 1e-5 else { break }
                step = next
                turned += direction * 2
            }
            found = step
            break
        }
        // Still well into the body (more than grazing it): look all the way round, nearest first. Past the joint's range
        // the limb is just held at its limit (the hand stops short) rather than flipping round to some far-off way of
        // reaching; the elbow or knee dot moves it round when that is wanted.
        if r.isArm && r.body != nil && r.collision(found.q, bend: found.bend) > 0.08 {
            var best = (found, found.cost)
            for k in stride(from: Float(5), through: 180, by: 5) {
                for sign: Float in [1, -1] {
                    let candidate = at(sign * k)
                    let cost = candidate.cost + k * 0.05
                    if cost < best.1 { best = (candidate, cost) }
                }
            }
            found = best.0
        }
        let kept = held(found.q, bend: found.bend, isArm: r.isArm)
        return limb(kept.q, bend: kept.bend)
    }

    /// The elbow or knee taken to `target`: the upper arm or thigh turns the least way there, the forearm or shin keeps
    /// its bend, and an arm turns about its length only if the forearm would otherwise go into the body.
    static func swing(_ r: Reach, elbowTo target: SIMD3<Float>, now: Limb) -> Limb {
        var goal = target
        if r.isArm, let body = r.body { goal = body.pushedOut(goal, radius: body.upperArm * 0.9) }
        let to = r.inward(goal - r.top)
        guard simd_length(to) > 1e-6 else { return now }
        let before = rotation(now)
        let was = before.act(down), d = simd_normalize(to)
        let turnBy = simd_dot(was, d) < -0.9999 ? Q(angle: .pi, axis: simd_normalize(simd_cross(was, SIMD3(0, 0, 1)) + SIMD3(1e-4, 0, 0))) : Q(from: was, to: d)
        let wanted = turnBy * before
        var bend = now.bend
        if !r.isArm {
            // A thigh lifted past level needs the knee bent (the back of the thigh pulls): bend it as much as that takes.
            var least = overreach(wanted, bend: bend, isArm: false)
            for more in stride(from: bend + 5, through: max(bend, 60) + 0.001, by: 5) where least > 0.01 {
                let miss = overreach(wanted, bend: min(more, 60), isArm: false)
                if miss < least - 0.01 { least = miss; bend = min(more, 60) }
            }
        }
        var kept = held(wanted, bend: bend, isArm: r.isArm)
        if r.isArm, r.collision(kept.q, bend: kept.bend) > 0 {
            // Turn the arm about its own length until the forearm is clear.
            let axis = kept.q.act(down)
            var best = (q: kept.q, cost: r.cost(kept.q, bend: kept.bend))
            for k in stride(from: Float(5), through: 180, by: 5) {
                for sign: Float in [1, -1] {
                    let q = Q(angle: sign * k * .pi / 180, axis: axis) * kept.q
                    let cost = r.cost(q, bend: kept.bend) + k * 0.03
                    if cost < best.cost { best = (q, cost) }
                }
            }
            kept.q = best.q
        }
        return limb(kept.q, bend: kept.bend)
    }

    /// The turn and bend that point the upper part along `upper` with the lower part along `lower`. A limb too
    /// straight to show which way it bends keeps the twist it had.
    static func turnFor(upper: SIMD3<Float>, lower: SIMD3<Float>, isArm: Bool, before: Q) -> (q: Q, bend: Float) {
        let d = simd_normalize(upper), l = simd_normalize(lower)
        let bend = deg(acos(clamp(simd_dot(d, l), -1, 1)))
        let s = swing(to: d)
        // The bend folds the lower part toward the turned +Z (elbow) or -Z (knee); find the twist that does so.
        let folded = s.act(SIMD3(0, 0, isArm ? 1 : -1))
        let side = l - simd_dot(l, d) * d
        var t: Float
        if simd_length(side) < 0.03 {
            t = twist(before)
        } else {
            let want = simd_normalize(side)
            t = deg(atan2(simd_dot(simd_cross(folded, want), d), simd_dot(folded, want)))
        }
        return (Q(angle: t * .pi / 180, axis: d) * s, bend)
    }

    // MARK: Bending forward

    /// Arms hanging loose stay hanging when the body bends (they dangle, as real arms do); arms held up go with the chest.
    /// `was` and `now` are the chest's frame before and after, in the same space.
    static func dangle(_ l: Limb, side: Int, was: Q, now: Q) -> Limb {
        let mirror: (Q) -> Q = { q in side == 1 ? Q(ix: q.imag.x, iy: -q.imag.y, iz: -q.imag.z, r: q.real) : q }
        let q = rotation(l)
        // How far the arm is raised from hanging straight down to the floor (not from the chest, which is tipped).
        let d = (was * mirror(q)).act(down)
        let raised = deg(acos(clamp(-d.y, -1, 1)))
        let loose = clamp((70 - raised) / 40, 0, 1)
        guard loose > 0 else { return l }
        // Into the body's frame (mirrored back for a right arm), kept still there, and back into the new chest frame.
        let hanging = mirror(now.inverse * was * mirror(q))
        let blended = simd_slerp(q, hanging, loose)
        return held(limb(blended, bend: l.bend), isArm: true)
    }
}

extension HumanLimits.Limb {
    init(_ a: MannequinPose.Arm) { self.init(out: a.out, forward: a.forward, inward: a.inward, bend: a.elbow) }
    init(_ l: MannequinPose.Leg) { self.init(out: l.out, forward: l.forward, inward: l.inward, bend: l.knee) }
    var arm: MannequinPose.Arm { MannequinPose.Arm(out: out, forward: forward, inward: inward, elbow: bend) }
    var leg: MannequinPose.Leg { MannequinPose.Leg(out: out, forward: forward, inward: inward, knee: bend) }
}
