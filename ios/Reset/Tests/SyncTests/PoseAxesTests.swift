import Foundation
import simd

// Phil, 2026-11-21: every handle follows the finger, and a selected handle shows wheels for its joint's turns.
// The wheel and drag maths is checked here without SceneKit.

func runPoseAxesTests() {
    let rest = MannequinPose()

    // Every axis changes the pose, and turning it back gives the pose again (away from the limits).
    for joint: PoseDrag.Joint in [.headLook, .headTilt, .shoulder(0), .shoulder(1), .wrist(0), .hand(1), .ankle(0), .foot(1), .hips, .head, .elbow(0), .knee(1)] {
        for axis in PoseAxis.axes(for: joint) {
            let base: MannequinPose = {
                if case .swivel(let arm, _) = axis { var p = rest; if arm { p.left.elbow = 60; p.right.elbow = 60 } else { p.leftLeg.knee = 60; p.rightLeg.knee = 60 }; return p }
                if case .bend(let arm, _) = axis { var p = rest; if arm { p.left.elbow = 40; p.right.elbow = 40 } else { p.leftLeg.knee = 40; p.rightLeg.knee = 40 }; return p }
                return rest
            }()
            let there = axis.changed(base, by: 5, ratio: 1), back = axis.changed(there, by: -5, ratio: 1)
            let moved = there != base
            let returned = close(back, base)
            expect(moved && returned, "pose wheels: \(axis.words) turns and turns back (\(moved), \(returned))")
        }
    }

    // Swinging the elbow round keeps the hand where it is and moves the elbow.
    var bent = MannequinPose()
    bent.left = MannequinPose.Arm(out: 30, forward: 40, inward: 0, elbow: 70)
    func ends(_ p: MannequinPose) -> (elbow: SIMD3<Float>, hand: SIMD3<Float>) {
        let l = HumanLimits.Limb(p.left), q = HumanLimits.rotation(l)
        return (q.act(HumanLimits.down), q.act(HumanLimits.down) + HumanLimits.lowerDirection(q, bend: l.bend, isArm: true) * 0.9)
    }
    let swung = PoseAxis.swivel(arm: true, side: 0).changed(bent, by: 20, ratio: 0.9)
    let e0 = ends(bent), e1 = ends(swung)
    expect(simd_distance(e0.hand, e1.hand) < 0.01 && simd_distance(e0.elbow, e1.elbow) > 0.1,
           "pose wheels: swinging the elbow round keeps the hand put (\(simd_distance(e0.hand, e1.hand)), \(simd_distance(e0.elbow, e1.elbow)))")

    // A wheel measured from a point turned about a known axis lies round that axis.
    let pivot = SIMD3<Float>(0.2, 1.5, 0)
    let axisZ = simd_normalize(SIMD3<Float>(0.3, 0.2, 1))
    let start = pivot + simd_normalize(simd_cross(axisZ, SIMD3(0, 1, 0))) * 0.1
    let wheel = PoseWheel.measured(.headTurn, pivot: pivot, before: start,
                                   after: pivot + simd_quatf(angle: 8 * .pi / 180, axis: axisZ).act(start - pivot), step: 4, smallest: 0.01)
    if let wheel {
        expect(simd_distance(wheel.normal, axisZ) < 1e-3 && abs(wheel.perDegree - 2) < 1e-2 && simd_distance(wheel.centre, pivot) < 1e-4,
               "pose wheels: a measured wheel lies round the turn (\(wheel.normal), \(wheel.perDegree))")
        // Seen from the front (x right, y up), the grabbed spot follows a finger round the rim.
        let project: (SIMD3<Float>) -> SIMD2<Float>? = { SIMD2($0.x * 1000, -$0.y * 1000) }
        let target = wheel.turn(start, by: 50)
        let turned = wheel.turnToward(project(target)!, grabbed: start, near: 0, project: project)
        expect(abs(turned - 50) < 1, "pose wheels: the grabbed spot comes under the finger (\(turned))")
        // The curved arrow is half the rim, centred on the side the moving point is on.
        let arc = wheel.arc(31)
        let onRim = arc.allSatisfy { abs(simd_distance($0, wheel.centre) - wheel.radius) < 1e-4 && abs(simd_dot($0 - wheel.centre, wheel.normal)) < 1e-4 }
        let middle = simd_distance(arc[15], start), across = simd_distance(arc[0], arc[30])
        expect(onRim && middle < 1e-3 && abs(across - 2 * wheel.radius) < 1e-3,
               "pose wheels: the curved arrow is a half circle round the moving point (\(middle), \(across))")
    } else {
        expect(false, "pose wheels: a measured wheel lies round the turn")
    }
    expect(PoseWheel.measured(.headTurn, pivot: pivot, before: start, after: start, step: 4, smallest: 0.01) == nil,
           "pose wheels: no wheel when the point doesn't move")

    // Dragging a handle: the turns move the point the way the finger went.
    let moves: [SIMD2<Float>] = [SIMD2(3, 0.5), SIMD2(-0.4, -2)]
    for wanted: SIMD2<Float> in [SIMD2(30, 0), SIMD2(0, -30), SIMD2(-20, 25)] {
        let t = PoseAxes.turns(for: wanted, moves: moves)
        let got = moves[0] * t[0] + moves[1] * t[1]
        expect(simd_dot(got, wanted) > 0.8 * simd_length(got) * simd_length(wanted) && simd_length(got) > 0.7 * simd_length(wanted),
               "pose wheels: a handle goes the way the finger goes (\(wanted) → \(got))")
    }
    let one = PoseAxes.turns(for: SIMD2(10, 0), moves: [SIMD2(-2, 0)])
    expect(one.count == 1 && one[0] < 0, "pose wheels: one axis turns the right way round (\(one))")
    let flat = PoseAxes.turns(for: SIMD2(10, 0), moves: [SIMD2(0, 0), SIMD2(0, 0)])
    expect(flat.allSatisfy { abs($0) < 1e-3 }, "pose wheels: an axis that moves nothing doesn't spin (\(flat))")
}

private func close(_ a: MannequinPose, _ b: MannequinPose) -> Bool {
    let la = HumanLimits.Limb(a.left), lb = HumanLimits.Limb(b.left), ra = HumanLimits.Limb(a.right), rb = HumanLimits.Limb(b.right)
    let ga = HumanLimits.Limb(a.leftLeg), gb = HumanLimits.Limb(b.leftLeg), ha = HumanLimits.Limb(a.rightLeg), hb = HumanLimits.Limb(b.rightLeg)
    func same(_ x: HumanLimits.Limb, _ y: HumanLimits.Limb) -> Bool {
        let down = SIMD3<Float>(0, -1, 0), z = SIMD3<Float>(0, 0, 1)
        let qx = HumanLimits.rotation(x), qy = HumanLimits.rotation(y)
        return simd_distance(qx.act(down), qy.act(down)) < 0.01 && simd_distance(qx.act(z), qy.act(z)) < 0.01 && abs(x.bend - y.bend) < 0.5
    }
    var a2 = a
    a2.left = b.left; a2.right = b.right; a2.leftLeg = b.leftLeg; a2.rightLeg = b.rightLeg
    return same(la, lb) && same(ra, rb) && same(ga, gb) && same(ha, hb) && approx(a2, b)
}

private func approx(_ a: MannequinPose, _ b: MannequinPose) -> Bool {
    // Everything but the limbs (which are compared as turns above) back within half a degree.
    let ma = Mirror(reflecting: a), mb = Mirror(reflecting: b)
    func numbers(_ m: Mirror) -> [Float] {
        m.children.flatMap { child -> [Float] in
            if let f = child.value as? Float { return [f] }
            let inner = Mirror(reflecting: child.value)
            return inner.children.isEmpty ? [] : numbers(inner)
        }
    }
    let x = numbers(ma), y = numbers(mb)
    return x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) < 0.5 }
}
