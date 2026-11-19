import simd

/// Posing by dragging a joint of a character in live view (Phil, 2026-11-18): the same limb maths as the Pose screen's
/// dots, worked on the character's own joint positions, in the space the mannequin angles use (facing +Z, left at +X).
enum PoseDrag {
    enum Joint: Equatable {
        case hand(Int), foot(Int), elbow(Int), knee(Int), head, wrist(Int), ankle(Int), hips  // Int: 0 left, 1 right
    }

    /// The pose after the joint is dragged to `target`. `top`, `middle` and `end` are the limb's joints now (shoulder or hip,
    /// elbow or knee, hand or foot); `hips` is used for the head.
    static func solve(_ joint: Joint, target: SIMD3<Float>, top s: SIMD3<Float>, middle m: SIMD3<Float>, end e: SIMD3<Float>,
                      hips: SIMD3<Float>, from pose: MannequinPose, screen: SIMD2<Float> = .zero) -> MannequinPose {
        var pose = pose
        switch joint {
        case .hips:
            // Sideways turns the pelvis, up and down tilts it.
            pose.detail.hipTurn = pose.detail.hipTurn + screen.x * 0.4
            pose.detail.hipTilt = pose.detail.hipTilt - screen.y * 0.2
        case .wrist(let side):
            let sign: Float = side == 0 ? 1 : -1
            if side == 0 {
                pose.detail.leftHand.bend -= screen.y * 0.5
                pose.detail.leftHand.side += screen.x * 0.3 * sign
            } else {
                pose.detail.rightHand.bend -= screen.y * 0.5
                pose.detail.rightHand.side += screen.x * 0.3 * sign
            }
        case .ankle(let side):
            let sign: Float = side == 0 ? 1 : -1
            if side == 0 {
                pose.detail.leftFoot.point += screen.y * 0.5
                pose.detail.leftFoot.turn += screen.x * 0.3 * sign
            } else {
                pose.detail.rightFoot.point += screen.y * 0.5
                pose.detail.rightFoot.turn += screen.x * 0.3 * sign
            }
        case .head:
            let direction = target - hips
            guard simd_length(direction) > 0.01 else { return pose }
            let d = simd_normalize(direction)
            pose.spineForward = max(-30, min(60, asin(max(-1, min(1, d.z))) * 180 / .pi))
            pose.spineSide = max(-30, min(30, atan2(-d.x, d.y) * 180 / .pi))
        case .elbow(let side), .knee(let side):
            let isArm: Bool
            if case .elbow = joint { isArm = true } else { isArm = false }
            let a = simd_length(m - s)
            guard a > 0.001, simd_length(target - s) > 0.01 else { return pose }
            // Swing the upper arm or thigh so the elbow or knee goes to the finger; the lower part keeps its bend.
            let swing = simd_quatf(from: simd_normalize(m - s), to: simd_normalize(target - s))
            let bent = s + a * simd_normalize(target - s)
            limb(isArm: isArm, side: side, shoulder: s, joint: bent, end: bent + swing.act(e - m), into: &pose)
        case .hand(let side), .foot(let side):
            let isArm: Bool
            if case .hand = joint { isArm = true } else { isArm = false }
            let a = simd_length(m - s), b = simd_length(e - m)
            var toTarget = target - s
            let reach = min(simd_length(toTarget), (a + b) * 0.995)
            guard a > 0.001, reach > 0.01 else { return pose }
            toTarget = simd_normalize(toTarget)
            // Bend the same way as now, so the elbow or knee keeps pointing where it did.
            var pole = (m - s) - simd_dot(m - s, toTarget) * toTarget
            if !isArm { pole = SIMD3(0, 0, 1) }  // a knee always points forward, so the shin never swings sideways
            if simd_length(pole) < 0.01 { pole = isArm ? SIMD3(0, -0.3, -1) : SIMD3(0, 0, 1) }
            pole = simd_normalize(pole - simd_dot(pole, toTarget) * toTarget)
            let cosAngle = max(-1, min(1, (a * a + reach * reach - b * b) / (2 * a * reach)))
            let bent = s + a * (cosAngle * toTarget + sqrt(max(0, 1 - cosAngle * cosAngle)) * pole)
            limb(isArm: isArm, side: side, shoulder: s, joint: bent, end: s + reach * toTarget, into: &pose)
        }
        return pose.limited
    }

    private static func limb(isArm: Bool, side index: Int, shoulder s: SIMD3<Float>, joint: SIMD3<Float>, end: SIMD3<Float>,
                             into pose: inout MannequinPose) {
        let sign: Float = index == 0 ? 1 : -1
        // Arms hang from the spine (as leant now), legs from the unturned pelvis.
        let spine = simd_quatf(angle: pose.spineSide * .pi / 180, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: pose.spineForward * .pi / 180, axis: SIMD3(1, 0, 0))
        let hips = simd_quatf(angle: pose.detail.hipTilt * .pi / 180, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: pose.detail.hipTurn * .pi / 180, axis: SIMD3(0, 1, 0))
        let frame = isArm ? hips * spine : hips
        let upper = frame.inverse.act(joint - s), lower = frame.inverse.act(end - joint)
        guard simd_length(upper) > 1e-5, simd_length(lower) > 1e-5 else { return }
        let solved = PoseFromSkeleton.aim(upper: upper, lower: lower, bendsForward: isArm)
        let deg: (Float) -> Float = { $0 * 180 / .pi }
        if isArm {
            let arm = MannequinPose.Arm(out: deg(solved.z) * sign, forward: -deg(solved.x), inward: -deg(solved.y) * sign, elbow: max(0, -deg(solved.bend)))
            if index == 0 { pose.left = arm } else { pose.right = arm }
        } else {
            let leg = MannequinPose.Leg(out: deg(solved.z) * sign, forward: -deg(solved.x), inward: -deg(solved.y) * sign, knee: max(0, deg(solved.bend)))
            if index == 0 { pose.leftLeg = leg } else { pose.rightLeg = leg }
        }
    }
}
