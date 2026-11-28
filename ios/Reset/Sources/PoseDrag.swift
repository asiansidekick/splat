import simd

/// Posing by dragging a joint of a character in live view (Phil, 2026-11-18): the same limb maths as the Pose screen's
/// dots, worked on the character's own joint positions, in the space the mannequin angles use (facing +Z, left at +X).
enum PoseDrag {
    enum Joint: Equatable {
        case hand(Int), foot(Int), elbow(Int), knee(Int), head, wrist(Int), ankle(Int), hips, headLook, headTilt, shoulder(Int)  // Int: 0 left, 1 right
    }

    /// What the limbs hang from, for a pose, in the space the joints are given in: the frame each arm hangs from
    /// (0 left, 1 right) and the frame the legs hang from. The default is the example mannequin's.
    struct Frames {
        var arm: (MannequinPose, Int) -> simd_quatf
        var leg: (MannequinPose) -> simd_quatf

        static var mannequin: Frames {
            Frames(arm: { pose, _ in Frames.legs(pose) * Frames.turn(pose.spineSide, SIMD3(0, 0, 1)) * Frames.turn(pose.spineForward, SIMD3(1, 0, 0)) },
                   leg: { Frames.legs($0) })
        }
        private static func legs(_ pose: MannequinPose) -> simd_quatf {
            pose.lieTurn * turn(pose.detail.hipTilt, SIMD3(0, 0, 1)) * turn(pose.detail.hipTurn, SIMD3(0, 1, 0))
        }
        private static func turn(_ degrees: Float, _ axis: SIMD3<Float>) -> simd_quatf { simd_quatf(angle: degrees * .pi / 180, axis: axis) }
    }

    /// The pose after the joint is dragged to `target`. `top`, `middle` and `end` are the limb's joints now (shoulder or hip,
    /// elbow or knee, hand or foot); `hips` is used for the head. `body` keeps the arms out of the torso.
    static func solve(_ joint: Joint, target: SIMD3<Float>, top s: SIMD3<Float>, middle m: SIMD3<Float>, end e: SIMD3<Float>,
                      hips: SIMD3<Float>, from pose: MannequinPose, screen: SIMD2<Float> = .zero,
                      frames: Frames = .mannequin, body: BodyVolume? = nil) -> MannequinPose {
        var pose = pose
        switch joint {
        case .hips:
            // Sideways turns the pelvis, up and down tilts it.
            pose.detail.hipTurn = pose.detail.hipTurn + screen.x * 0.4
            pose.detail.hipTilt = pose.detail.hipTilt - screen.y * 0.2
        case .shoulder(let side):
            // Up and down on the screen shrugs the shoulder, sideways rolls it forward or back.
            let sign: Float = side == 0 ? 1 : -1
            if side == 0 {
                pose.detail.leftShoulder.shrug -= screen.y * 0.3
                pose.detail.leftShoulder.roll += screen.x * 0.3 * sign
            } else {
                pose.detail.rightShoulder.shrug -= screen.y * 0.3
                pose.detail.rightShoulder.roll += screen.x * 0.3 * sign
            }
        case .headLook:
            // Sideways turns the head, up and down nods it.
            pose.headTurn += screen.x * 0.4
            pose.headDown += screen.y * 0.3
        case .headTilt:
            pose.detail.headTilt += screen.x * 0.3
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
            // Phil, 2026-11-20: bends forward a long way, from the hips; arms hanging loose keep hanging.
            // A body lying down leans as it would standing, in its own frame (Phil, 2026-11-22).
            let lean = MannequinPose.lean(toward: pose.lieTurn.inverse.act(target - hips))
            var bent = pose
            bent.spineForward = lean.forward
            bent.spineSide = lean.side
            for side in 0..<2 {
                let arm = side == 0 ? pose.left : pose.right
                let kept = HumanLimits.dangle(HumanLimits.Limb(arm), side: side, was: frames.arm(pose, side), now: frames.arm(bent, side)).arm
                if side == 0 { bent.left = kept } else { bent.right = kept }
            }
            pose = bent
        case .elbow(let side), .knee(let side):
            let isArm: Bool
            if case .elbow = joint { isArm = true } else { isArm = false }
            let reach = HumanLimits.Reach(isArm: isArm, side: side, frame: isArm ? frames.arm(pose, side) : frames.leg(pose), top: s,
                                          upper: simd_length(m - s), lower: simd_length(e - m), body: body)
            guard reach.upper > 0.001 else { return pose }
            set(HumanLimits.swing(reach, elbowTo: target, now: limb(isArm, side, of: pose)), isArm, side, in: &pose)
        case .hand(let side), .foot(let side):
            let isArm: Bool
            if case .hand = joint { isArm = true } else { isArm = false }
            let reach = HumanLimits.Reach(isArm: isArm, side: side, frame: isArm ? frames.arm(pose, side) : frames.leg(pose), top: s,
                                          upper: simd_length(m - s), lower: simd_length(e - m), body: body)
            guard reach.upper > 0.001, reach.lower > 0.001 else { return pose }
            set(HumanLimits.reach(reach, to: target, now: limb(isArm, side, of: pose)), isArm, side, in: &pose)
        }
        return pose.limited
    }

    private static func limb(_ isArm: Bool, _ side: Int, of pose: MannequinPose) -> HumanLimits.Limb {
        isArm ? HumanLimits.Limb(side == 0 ? pose.left : pose.right) : HumanLimits.Limb(side == 0 ? pose.leftLeg : pose.rightLeg)
    }

    private static func set(_ l: HumanLimits.Limb, _ isArm: Bool, _ side: Int, in pose: inout MannequinPose) {
        switch (isArm, side) {
        case (true, 0): pose.left = l.arm
        case (true, _): pose.right = l.arm
        case (false, 0): pose.leftLeg = l.leg
        default: pose.rightLeg = l.leg
        }
    }
}
