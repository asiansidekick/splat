import Foundation
import simd

// Copying a person's pose onto a character (Phil, 2026-11-22: "copy a pose it sees in live view or an imported image
// and apply to a character"). The joints come from the phone's body tracking or from a photo; this turns them into the
// same angles every character and mannequin is posed with (MannequinPose), worked out with the posing system's own
// frames (RigPoser) and kept inside a real body's range (HumanLimits). Free of ARKit and Vision so CI can test it.

/// Where a person's joints are, in any space (metres or not), with which way is up in that space.
struct BodyJoints {
    enum Joint: CaseIterable {
        case hips, neck, head
        case leftShoulder, leftElbow, leftWrist, rightShoulder, rightElbow, rightWrist
        case leftHip, leftKnee, leftAnkle, rightHip, rightKnee, rightAnkle
    }

    var points: [Joint: SIMD3<Float>] = [:]
    /// Up in the points' space: the real up when the phone knows it (ARKit), or the picture's up (a photo).
    var up = SIMD3<Float>(0, 1, 0)
    /// The up is only the picture's: a standing person's legs may say better where up is (a camera tipped down).
    var upFromPicture = false

    subscript(_ joint: Joint) -> SIMD3<Float>? {
        get { points[joint] }
        set { points[joint] = newValue }
    }

    /// The same body seen in a mirror (across the first axis).
    var mirrored: BodyJoints {
        var m = self
        let flip = SIMD3<Float>(-1, 1, 1)
        m.points = points.mapValues { $0 * flip }
        m.up = up * flip
        return m
    }
}

enum PoseFromBody {
    private static func deg(_ r: Float) -> Float { r * 180 / .pi }
    private static func turn(_ degrees: Float, _ axis: SIMD3<Float>) -> simd_quatf { simd_quatf(angle: degrees * .pi / 180, axis: axis) }
    private static let x = SIMD3<Float>(1, 0, 0), y = SIMD3<Float>(0, 1, 0), z = SIMD3<Float>(0, 0, 1)
    private static let identity = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    /// How much of the spine's lean shows between the hips and the base of the neck: the spine curves, its top
    /// leaning most (as RigPoser shares the lean along the spine bones).
    static let chordShare: Float = 0.6

    /// Up, corrected for a camera tipped up or down: a person standing on straight legs stands upright, so their
    /// legs show where up is when the picture's up is near it.
    static func up(_ body: BodyJoints) -> SIMD3<Float> {
        let picture = simd_normalize(body.up)
        guard body.upFromPicture else { return picture }
        var legs: [SIMD3<Float>] = []
        for (hip, knee, ankle) in [(BodyJoints.Joint.leftHip, BodyJoints.Joint.leftKnee, BodyJoints.Joint.leftAnkle),
                                   (.rightHip, .rightKnee, .rightAnkle)] {
            guard let h = body[hip], let k = body[knee], let a = body[ankle] else { return picture }
            let thigh = h - k, shin = k - a
            guard simd_length(thigh) > 1e-4, simd_length(shin) > 1e-4 else { return picture }
            // A knee bent more than 20° is not a standing leg.
            if simd_dot(simd_normalize(thigh), simd_normalize(shin)) < cos(20 * .pi / 180) { return picture }
            legs.append(simd_normalize(h - a))
        }
        let legUp = simd_normalize(legs[0] + legs[1])
        // Within 30° of the picture's up: the camera was tipped, the person stands. Further: they lean or lie.
        return simd_dot(legUp, picture) > cos(30 * .pi / 180) ? legUp : picture
    }

    /// The body's own frame in the points' space: its left (+X), up (+Y) and front (+Z), from across the hips and
    /// shoulders. Nil when the hips or shoulders are missing, or their lines point straight up.
    static func frame(_ body: BodyJoints, up: SIMD3<Float>) -> simd_float3x3? {
        guard let lh = body[.leftHip], let rh = body[.rightHip], let ls = body[.leftShoulder], let rs = body[.rightShoulder] else { return nil }
        // Hips mostly (the legs hang from them), the shoulders a little (the arms are measured from the chest).
        var across = simd_normalize(lh - rh) * 0.65 + simd_normalize(ls - rs) * 0.35
        across -= simd_dot(across, up) * up
        guard simd_length(across) > 1e-3 else { return nil }
        let left = simd_normalize(across)
        let front = simd_cross(left, up)
        return simd_float3x3(columns: (left, up, front))
    }

    /// The chest's frame for a lean, as RigPoser works it out for a character with spine bones.
    static func chest(forward: Float, side: Float) -> simd_quatf {
        let split = RigPoser.bend(forward)
        return turn(split.pelvis, x) * turn(side, z) * turn(split.spine, x)
    }

    /// Which way the line from the hips to the base of the neck points for a lean (the spine curves, see chordShare).
    static func chord(forward: Float, side: Float) -> SIMD3<Float> {
        let split = RigPoser.bend(forward)
        let pelvis = turn(split.pelvis, x)
        let lean = turn(side, z) * turn(split.spine, x)
        return (pelvis * simd_slerp(identity, lean, chordShare)).act(y)
    }

    /// The lean (forward, to the side, in degrees) whose hips-to-neck line points along `want` (body space).
    static func lean(toward want: SIMD3<Float>) -> (forward: Float, side: Float) {
        let w = simd_normalize(want)
        var f = deg(asin(max(-1, min(1, w.z)))) / chordShare
        var s = deg(atan2(-w.x, max(w.y, 0.05))) / chordShare
        f = max(-30, min(120, f))
        s = max(-45, min(45, s))
        // A few Gauss-Newton steps on the two angles, the slopes found by nudging each.
        for _ in 0..<12 {
            let c = chord(forward: f, side: s)
            let miss = w - c
            if simd_length(miss) < 1e-4 { break }
            let h: Float = 0.5
            let df = (chord(forward: f + h, side: s) - c) / h
            let ds = (chord(forward: f, side: s + h) - c) / h
            // Normal equations of [df ds] * step = miss.
            let a = simd_dot(df, df), b = simd_dot(df, ds), d = simd_dot(ds, ds)
            let p = simd_dot(df, miss), q = simd_dot(ds, miss)
            let det = a * d - b * b
            guard abs(det) > 1e-9 else { break }
            f = max(-30, min(120, f + (d * p - b * q) / det))
            s = max(-45, min(45, s + (a * q - b * p) / det))
        }
        return (f, s)
    }

    /// Whether the joints look as if seen in a mirror (a space of the other handedness): knees only fold backward, so
    /// a bent knee folding forward says so. Below 0 mirrored, above 0 not, near 0 no bent knee to tell by.
    static func handedness(_ body: BodyJoints) -> Float {
        let up = Self.up(body)
        guard let axes = Self.frame(body, up: up) else { return 0 }
        var score: Float = 0
        for (hip, knee, ankle) in [(BodyJoints.Joint.leftHip, BodyJoints.Joint.leftKnee, BodyJoints.Joint.leftAnkle),
                                   (.rightHip, .rightKnee, .rightAnkle)] {
            guard let h = body[hip], let k = body[knee], let a = body[ankle], simd_length(k - h) > 1e-4, simd_length(a - k) > 1e-4 else { continue }
            // The knee's hinge runs across the body, left to right; the thigh-to-shin turn is about it, forward.
            score += simd_dot(simd_cross(simd_normalize(k - h), simd_normalize(a - k)), axes.columns.0)
        }
        return score
    }

    /// The pose of the person. Nil when too few joints were seen to tell.
    static func pose(_ body: BodyJoints) -> MannequinPose? {
        let up = Self.up(body)
        guard let axes = Self.frame(body, up: up), let lh = body[.leftHip], let rh = body[.rightHip] else { return nil }
        // Into the body's own space: facing +Z, its left +X, up +Y.
        let into = axes.transpose
        func local(_ v: SIMD3<Float>) -> SIMD3<Float> { into * v }
        let hips = body[.hips] ?? (lh + rh) / 2
        var p = MannequinPose()
        // Spine.
        let neck = body[.neck] ?? ((body[.leftShoulder] ?? lh) + (body[.rightShoulder] ?? rh)) / 2
        if simd_length(neck - hips) > 1e-4 {
            let lean = Self.lean(toward: local(neck - hips))
            p.spineForward = lean.forward
            p.spineSide = lean.side
        }
        let chest = Self.chest(forward: p.spineForward, side: p.spineSide)
        // Head: down toward the chest, and over toward a shoulder, from the base of the neck.
        if let head = body[.head], simd_length(head - neck) > 1e-4 {
            let h = simd_normalize(chest.inverse.act(local(head - neck)))
            p.headDown = max(-40, min(50, deg(asin(max(-1, min(1, h.z))))))
            p.detail.headTilt = max(-35, min(35, deg(atan2(-h.x, max(h.y, 0.05)))))
        }
        // Arms from the chest, legs from the pelvis (which does not tip with the lean: RigPoser.legFrame).
        let limbs: [(BodyJoints.Joint, BodyJoints.Joint, BodyJoints.Joint, Bool, Int)] = [
            (.leftShoulder, .leftElbow, .leftWrist, true, 0), (.rightShoulder, .rightElbow, .rightWrist, true, 1),
            (.leftHip, .leftKnee, .leftAnkle, false, 0), (.rightHip, .rightKnee, .rightAnkle, false, 1),
        ]
        for (top, middle, end, isArm, side) in limbs {
            guard let a = body[top], let b = body[middle], let c = body[end] else { return nil }
            var upper = local(b - a), lower = local(c - b)
            guard simd_length(upper) > 1e-4, simd_length(lower) > 1e-4 else { return nil }
            if isArm {
                upper = chest.inverse.act(upper)
                lower = chest.inverse.act(lower)
            }
            // Seen as a left limb: a right one mirrored across the body.
            if side == 1 { upper.x = -upper.x; lower.x = -lower.x }
            let resting = isArm ? HumanLimits.Limb(MannequinPose.Arm()) : HumanLimits.Limb(MannequinPose.Leg())
            let turned = HumanLimits.turnFor(upper: upper, lower: lower, isArm: isArm, before: HumanLimits.rotation(resting))
            let limb = HumanLimits.held(HumanLimits.limb(turned.q, bend: turned.bend), isArm: isArm)
            switch (isArm, side) {
            case (true, 0): p.left = limb.arm
            case (true, _): p.right = limb.arm
            case (false, 0): p.leftLeg = limb.leg
            default: p.rightLeg = limb.leg
            }
        }
        return p
    }
}
