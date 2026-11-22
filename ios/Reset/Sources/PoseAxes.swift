import Foundation
import simd

// Phil, 2026-11-21: "I find head turning handle logic and shoulder are reversed to the rest of the movements, a limb's
// rotation is hard to control, hands also. When a handle is selected show 2 axis control wheels."
//
// Each handle works one or two of a joint's turns (its axes). A selected handle shows a wheel for each, around the joint:
// drag a wheel and the joint turns with it, the grabbed spot on the wheel following the finger. Dragging a handle that
// turns a joint (yellow) moves the joint the way the finger goes on the screen, the same as every other handle.
// The maths here is kept free of SceneKit so CI can test it on a Mac.

/// One way a joint turns.
enum PoseAxis: Equatable {
    case headTurn, headNod, headTilt
    case shrug(Int), roll(Int)  // shoulder: 0 left, 1 right
    case wristBend(Int), wristSide(Int)
    case anklePoint(Int), ankleTurn(Int)
    case hipTurn, hipTilt
    case leanForward, leanSide
    /// The elbow or knee swung round the line from shoulder to hand (or hip to foot), the hand or foot staying put.
    case swivel(arm: Bool, side: Int)
    /// The elbow or knee bent or straightened.
    case bend(arm: Bool, side: Int)

    /// The axes a handle works, when it is selected.
    static func axes(for joint: PoseDrag.Joint) -> [PoseAxis] {
        switch joint {
        case .headLook: return [.headTurn, .headNod]
        case .headTilt: return [.headTilt]
        case .shoulder(let s): return [.shrug(s), .roll(s)]
        case .wrist(let s), .hand(let s): return [.wristBend(s), .wristSide(s)]
        case .ankle(let s), .foot(let s): return [.anklePoint(s), .ankleTurn(s)]
        case .hips: return [.hipTurn, .hipTilt]
        case .head: return [.leanForward, .leanSide]
        case .elbow(let s): return [.swivel(arm: true, side: s), .bend(arm: true, side: s)]
        case .knee(let s): return [.swivel(arm: false, side: s), .bend(arm: false, side: s)]
        }
    }

    /// A few words for the hint while its wheel is turned.
    var words: String {
        switch self {
        case .headTurn: return "Turn the head"
        case .headNod: return "Nod the head"
        case .headTilt: return "Tilt the head"
        case .shrug: return "Shrug the shoulder"
        case .roll: return "Roll the shoulder forward or back"
        case .wristBend: return "Bend the wrist"
        case .wristSide: return "Turn the hand sideways"
        case .anklePoint: return "Point the foot"
        case .ankleTurn: return "Turn the foot"
        case .hipTurn: return "Turn the hips"
        case .hipTilt: return "Tilt the hips"
        case .leanForward: return "Bend forward or back"
        case .leanSide: return "Lean to the side"
        case .swivel(let arm, _): return arm ? "Swing the elbow round" : "Swing the knee round"
        case .bend(let arm, _): return arm ? "Bend the elbow" : "Bend the knee"
        }
    }

    /// The pose with this axis turned `degrees` further, kept within what a body can do. `ratio` is the lower arm or
    /// shin's length over the upper arm or thigh's (for swinging the elbow or knee round).
    func changed(_ pose: MannequinPose, by degrees: Float, ratio: Float = 1) -> MannequinPose {
        var p = pose
        func hand(_ s: Int, _ change: (inout MannequinPose.Hand) -> Void) {
            if s == 0 { change(&p.detail.leftHand) } else { change(&p.detail.rightHand) }
        }
        func foot(_ s: Int, _ change: (inout MannequinPose.Foot) -> Void) {
            if s == 0 { change(&p.detail.leftFoot) } else { change(&p.detail.rightFoot) }
        }
        func shoulder(_ s: Int, _ change: (inout MannequinPose.Shoulder) -> Void) {
            if s == 0 { change(&p.detail.leftShoulder) } else { change(&p.detail.rightShoulder) }
        }
        switch self {
        case .headTurn: p.headTurn += degrees
        case .headNod: p.headDown += degrees
        case .headTilt: p.detail.headTilt += degrees
        case .shrug(let s): shoulder(s) { $0.shrug += degrees }
        case .roll(let s): shoulder(s) { $0.roll += degrees }
        case .wristBend(let s): hand(s) { $0.bend += degrees }
        case .wristSide(let s): hand(s) { $0.side += degrees }
        case .anklePoint(let s): foot(s) { $0.point += degrees }
        case .ankleTurn(let s): foot(s) { $0.turn += degrees }
        case .hipTurn: p.detail.hipTurn += degrees
        case .hipTilt: p.detail.hipTilt += degrees
        case .leanForward: p.spineForward += degrees
        case .leanSide: p.spineSide += degrees
        case .swivel(let arm, let s):
            let limb = Self.limb(p, arm: arm, side: s)
            let q = HumanLimits.rotation(limb)
            let end = q.act(HumanLimits.down) + HumanLimits.lowerDirection(q, bend: limb.bend, isArm: arm) * ratio
            guard simd_length(end) > 1e-5 else { return p }
            let turned = simd_quatf(angle: degrees * .pi / 180, axis: simd_normalize(end)) * q
            let kept = HumanLimits.held(turned, bend: limb.bend, isArm: arm)
            Self.set(HumanLimits.limb(kept.q, bend: kept.bend), in: &p, arm: arm, side: s)
        case .bend(let arm, let s):
            var limb = Self.limb(p, arm: arm, side: s)
            limb.bend += degrees
            Self.set(HumanLimits.held(limb, isArm: arm), in: &p, arm: arm, side: s)
        }
        return p.limited
    }

    private static func limb(_ p: MannequinPose, arm: Bool, side: Int) -> HumanLimits.Limb {
        arm ? HumanLimits.Limb(side == 0 ? p.left : p.right) : HumanLimits.Limb(side == 0 ? p.leftLeg : p.rightLeg)
    }

    private static func set(_ l: HumanLimits.Limb, in p: inout MannequinPose, arm: Bool, side: Int) {
        switch (arm, side) {
        case (true, 0): p.left = l.arm
        case (true, _): p.right = l.arm
        case (false, 0): p.leftLeg = l.leg
        default: p.rightLeg = l.leg
        }
    }
}

/// A wheel round a joint for one axis: where it is, which way it faces, and how far the joint turns per degree.
struct PoseWheel {
    var axis: PoseAxis
    /// The middle of the wheel, the way it faces (a turn of the axis turns things right-handed about it), its size.
    var centre: SIMD3<Float>
    var normal: SIMD3<Float>
    var radius: Float
    /// How many degrees the joint turns in the world for each degree of the axis.
    var perDegree: Float
    /// A point that the axis moves (on the wheel's rim), before and after a small turn of `step` degrees.
    var probe: SIMD3<Float>
    var probeTurned: SIMD3<Float>
    var step: Float

    /// The wheel worked out from where a point riding on the joint goes when the axis turns `step` degrees about a
    /// pivot. Nil when the point does not move (the axis is at its limit, or does nothing on this character).
    static func measured(_ axis: PoseAxis, pivot: SIMD3<Float>, before: SIMD3<Float>, after: SIMD3<Float>, step: Float, smallest: Float) -> PoseWheel? {
        let a = before - pivot, b = after - pivot
        let cross = simd_cross(a, b)
        guard simd_length(cross) > 1e-9, simd_length(a) > 1e-6 else { return nil }
        let normal = simd_normalize(cross)
        let ua = a - simd_dot(a, normal) * normal, ub = b - simd_dot(b, normal) * normal
        guard simd_length(ua) > 1e-6, simd_length(ub) > 1e-6 else { return nil }
        let turned = acos(min(max(simd_dot(simd_normalize(ua), simd_normalize(ub)), -1), 1)) * 180 / .pi
        guard turned > 1e-4 else { return nil }
        let centre = pivot + simd_dot(a, normal) * normal
        return PoseWheel(axis: axis, centre: centre, normal: normal, radius: max(simd_length(ua), smallest),
                         perDegree: turned / abs(step), probe: before, probeTurned: after, step: step)
    }

    /// A point on the rim turned `degrees` (in the world) about the wheel.
    func turn(_ point: SIMD3<Float>, by degrees: Float) -> SIMD3<Float> {
        centre + simd_quatf(angle: degrees * .pi / 180, axis: normal).act(point - centre)
    }

    /// Points round the rim, for drawing and picking.
    func rim(_ count: Int) -> [SIMD3<Float>] {
        var side = simd_cross(normal, SIMD3(0, 1, 0))
        if simd_length(side) < 0.1 { side = simd_cross(normal, SIMD3(1, 0, 0)) }
        let u = simd_normalize(side), v = simd_cross(normal, u)
        return (0..<count).map { k in
            let t = Float(k) / Float(count) * 2 * .pi
            return centre + (u * cos(t) + v * sin(t)) * radius
        }
    }

    /// How far (in the world, degrees) the grabbed spot of the rim must turn to come under the finger, near where it
    /// was last (`near`) so a wheel seen edge-on doesn't flip. `project` puts a world point on the screen.
    func turnToward(_ finger: SIMD2<Float>, grabbed: SIMD3<Float>, near: Float, project: (SIMD3<Float>) -> SIMD2<Float>?) -> Float {
        func miss(_ d: Float) -> Float {
            guard let shown = project(turn(grabbed, by: d)) else { return .greatestFiniteMagnitude }
            return simd_length(shown - finger)
        }
        var best = near, bestMiss = miss(near)
        for d in stride(from: near - 90, through: near + 90, by: 2) where miss(d) < bestMiss - 0.01 {
            best = d
            bestMiss = miss(d)
        }
        for d in stride(from: best - 2, through: best + 2, by: 0.2) where miss(d) < bestMiss - 0.01 {
            best = d
            bestMiss = miss(d)
        }
        return best
    }
}

enum PoseAxes {
    /// How far to turn each axis (in its own degrees) so a point it moves goes `wanted` across the screen: `moves` is
    /// how far that point goes on the screen per degree of each axis. Least squares, held back a little where an axis
    /// barely moves the point, so it can't spin wildly.
    static func turns(for wanted: SIMD2<Float>, moves: [SIMD2<Float>]) -> [Float] {
        switch moves.count {
        case 0: return []
        case 1:
            let j = moves[0]
            let damp = max(simd_dot(j, j) * 0.05, 1e-6)
            return [simd_dot(j, wanted) / (simd_dot(j, j) + damp)]
        default:
            let a = moves[0], b = moves[1]
            let aa = simd_dot(a, a), bb = simd_dot(b, b), ab = simd_dot(a, b)
            let damp = max((aa + bb) * 0.05, 1e-6)
            let m00 = aa + damp, m11 = bb + damp, m01 = ab
            let det = m00 * m11 - m01 * m01
            guard abs(det) > 1e-12 else { return [0, 0] }
            let r0 = simd_dot(a, wanted), r1 = simd_dot(b, wanted)
            return [(m11 * r0 - m01 * r1) / det, (m00 * r1 - m01 * r0) / det]
        }
    }
}
