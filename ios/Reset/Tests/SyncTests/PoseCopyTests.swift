import Foundation
import simd

// Phil, 2026-11-22: copy a person's pose from the camera or a photo onto a character. A plain Mixamo-named figure is
// posed, its joints read off as the phone would see a person's, turned into a pose again, and the figure posed with
// that: every limb must point the same way. Also seen turned round, tipped, mirrored and from a camera tilted down.

func runPoseCopyTests() {
    var nodes: [RigNode] = []
    var index: [String: Int] = [:]
    func add(_ name: String, _ parent: String?, _ p: SIMD3<Float>) {
        let up = parent.flatMap { index[$0] } ?? -1
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(p, 1)
        var local = world
        if up >= 0 { local.columns.3 = SIMD4(p - nodes[up].position, 1) }
        index[name] = nodes.count
        nodes.append(RigNode(name: name, parent: up, isBone: true, local: local, world: world))
    }
    add("mixamorig:Hips", nil, SIMD3(0, 0.95, 0))
    add("mixamorig:Spine", "mixamorig:Hips", SIMD3(0, 1.05, 0))
    add("mixamorig:Spine1", "mixamorig:Spine", SIMD3(0, 1.17, 0))
    add("mixamorig:Spine2", "mixamorig:Spine1", SIMD3(0, 1.3, 0))
    add("mixamorig:Neck", "mixamorig:Spine2", SIMD3(0, 1.47, 0))
    add("mixamorig:Head", "mixamorig:Neck", SIMD3(0, 1.56, 0))
    add("mixamorig:HeadTop_End", "mixamorig:Head", SIMD3(0, 1.75, 0))
    for (s, side) in [(Float(1), "Left"), (Float(-1), "Right")] {
        let n = "mixamorig:" + side
        add(n + "Shoulder", "mixamorig:Spine2", SIMD3(s * 0.06, 1.42, 0))
        let shoulder = SIMD3<Float>(s * 0.18, 1.42, 0), along = simd_normalize(SIMD3<Float>(s * 0.7, -0.7, 0))
        add(n + "Arm", n + "Shoulder", shoulder)
        add(n + "ForeArm", n + "Arm", shoulder + along * 0.28)
        add(n + "Hand", n + "ForeArm", shoulder + along * 0.53)
        add(n + "UpLeg", "mixamorig:Hips", SIMD3(s * 0.09, 0.9, 0))
        add(n + "Leg", n + "UpLeg", SIMD3(s * 0.09, 0.5, 0.01))
        add(n + "Foot", n + "Leg", SIMD3(s * 0.09, 0.08, -0.01))
        add(n + "ToeBase", n + "Foot", SIMD3(s * 0.09, 0.01, 0.12))
    }
    guard let map = RigFinder.find(nodes) else {
        expect(false, "pose copy: the test figure's joints are found")
        return
    }
    let poser = RigPoser(nodes: nodes, map: map)

    /// The figure's joints in a pose, as the phone would see a person's, moved into another space by `m`.
    func seen(_ pose: MannequinPose, _ m: simd_float4x4 = matrix_identity_float4x4) -> BodyJoints {
        let worlds = poser.worlds(for: pose).worlds
        var body = BodyJoints()
        let names: [(BodyJoints.Joint, String)] = [
            (.hips, "Hips"), (.neck, "Neck"), (.head, "Head"),
            (.leftShoulder, "LeftArm"), (.leftElbow, "LeftForeArm"), (.leftWrist, "LeftHand"),
            (.rightShoulder, "RightArm"), (.rightElbow, "RightForeArm"), (.rightWrist, "RightHand"),
            (.leftHip, "LeftUpLeg"), (.leftKnee, "LeftLeg"), (.leftAnkle, "LeftFoot"),
            (.rightHip, "RightUpLeg"), (.rightKnee, "RightLeg"), (.rightAnkle, "RightFoot"),
        ]
        for (joint, name) in names { body[joint] = (m * SIMD4(worlds[index["mixamorig:" + name]!].columns.3.xyz, 1)).xyz }
        body.up = simd_normalize((m * SIMD4(0, 1, 0, 0)).xyz)
        return body
    }

    /// The worst angle, in degrees, between where each limb part and the torso point in two poses.
    func miss(_ a: MannequinPose, _ b: MannequinPose) -> Float {
        let wa = poser.worlds(for: a).worlds.map(\.columns.3.xyz), wb = poser.worlds(for: b).worlds.map(\.columns.3.xyz)
        var worst: Float = 0
        let parts = [map.armL, map.armR, map.legL, map.legR].flatMap { [($0[0], $0[1]), ($0[1], $0[2])] } + [(map.hips, index["mixamorig:Neck"]!)]
        for (from, to) in parts {
            let da = simd_normalize(wa[to] - wa[from]), db = simd_normalize(wb[to] - wb[from])
            worst = max(worst, acos(max(-1, min(1, simd_dot(da, db)))) * 180 / .pi)
        }
        return worst
    }

    var reaching = MannequinPose()
    reaching.spineForward = 45
    reaching.left = MannequinPose.Arm(out: 20, forward: 70, inward: 10, elbow: 30)
    reaching.right = MannequinPose.Arm(out: 60, forward: 20, inward: 0, elbow: 90)
    reaching.leftLeg = MannequinPose.Leg(out: 5, forward: 10, inward: 0, knee: 20)
    var overhead = MannequinPose()
    overhead.spineSide = 12
    overhead.left = MannequinPose.Arm(out: 150, forward: 10, inward: 0, elbow: 20)
    overhead.rightLeg = MannequinPose.Leg(out: 0, forward: 60, inward: 0, knee: 100)
    let poses: [(name: String, pose: MannequinPose)] = MannequinPose.all + [(name: "Reaching", pose: reaching), (name: "Arm up, knee up", pose: overhead)]
    for (name, pose) in poses {
        guard let back = PoseFromBody.pose(seen(pose)) else {
            expect(false, "pose copy: \(name) is read")
            continue
        }
        let worst = miss(pose, back)
        expect(worst < 8, "pose copy: \(name) copied, every limb within 8° (\(worst)°)")
    }

    // The same person seen turned round, from somewhere else, in centimetres, in a space tipped on its side
    // (as a camera's space may be): the same pose.
    var placed = simd_float4x4(simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0))) * simd_float4x4(simd_quatf(angle: 1.2, axis: simd_normalize(SIMD3(1, 0.3, 0.2))))
    placed = placed * simd_float4x4(diagonal: SIMD4(100, 100, 100, 1))
    placed.columns.3 = SIMD4(3, -1, 7, 1)
    let still = PoseFromBody.pose(seen(reaching)), moved = PoseFromBody.pose(seen(reaching, placed))
    expect(still != nil && moved != nil && miss(still!, moved!) < 0.5, "pose copy: the same pose wherever the person stands and however the space is turned")

    // Seen in a mirror (a space of the other handedness): bent knees say so, and mirroring back gives the pose.
    let sitting = seen(.sitting)
    let mirror = sitting.mirrored
    let unmirrored = PoseFromBody.pose(mirror.mirrored)
    expect(PoseFromBody.handedness(sitting) > 0.5 && PoseFromBody.handedness(mirror) < -0.5 && unmirrored != nil && miss(.sitting, unmirrored!) < 8,
           "pose copy: a mirrored space is noticed by the knees (\(PoseFromBody.handedness(sitting)), \(PoseFromBody.handedness(mirror)))")

    // A photo from a camera tipped 20° down: up is the picture's, but a person standing on straight legs stands upright.
    var tipped = seen(.standing)
    let tip = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3(1, 0, 0))
    tipped.up = tip.act(SIMD3(0, 1, 0))
    tipped.upFromPicture = true
    let upright = PoseFromBody.pose(tipped)
    expect(upright != nil && abs(upright!.spineForward) < 3 && miss(.standing, upright!) < 8,
           "pose copy: a camera tipped down still gives an upright standing pose (lean \(upright?.spineForward ?? 99)°)")
    // Sitting, the legs can't say where up is: the picture's up is kept.
    var sat = seen(.sitting)
    sat.up = tip.act(SIMD3(0, 1, 0))
    sat.upFromPicture = true
    expect(simd_distance(PoseFromBody.up(sat), sat.up) < 1e-4, "pose copy: bent legs leave the picture's up as it is")

    // Every copied pose is within a body's range.
    var wild = seen(.standing)
    wild[.leftElbow] = wild[.leftShoulder]! + SIMD3(0.05, 0.02, -0.27)  // upper arm straight back
    wild[.leftWrist] = wild[.leftElbow]! + SIMD3(0, 0.25, 0.02)
    if let held = PoseFromBody.pose(wild) {
        let limb = HumanLimits.Limb(held.left)
        let over = HumanLimits.overreach(HumanLimits.rotation(limb), bend: limb.bend, isArm: true)
        expect(over < 1, "pose copy: an arm seen past a shoulder's range is held within it (\(over)°)")
    } else {
        expect(false, "pose copy: an arm seen past a shoulder's range is read")
    }

    // Nothing to read without the legs.
    var half = seen(.standing)
    half[.leftKnee] = nil
    expect(PoseFromBody.pose(half) == nil, "pose copy: a person cut off at the knees gives no pose")
}

// Phil, 2026-11-22: copying hands-free once the person holds still.
func runStillWatchTests() {
    var a = MannequinPose.standing
    a.left.out = 60
    var wobble = a
    wobble.left.out = 64
    wobble.spineForward = 3
    expect(PoseFromBody.change(a, a) < 0.01 && PoseFromBody.change(a, wobble) < 6 && PoseFromBody.change(a, .sitting) > 60,
           "pose copy: a wobble is a small change, sitting down a big one (\(PoseFromBody.change(a, wobble)), \(PoseFromBody.change(a, .sitting)))")

    var watch = StillWatch()
    var fired: [Double] = []
    var t = 0.0
    func feed(_ pose: MannequinPose?, for seconds: Double) {
        let end = t + seconds
        while t < end {
            if watch.see(pose, at: t).fire { fired.append(t) }
            t += 0.35
        }
    }
    feed(a, for: 1.0)
    expect(fired.isEmpty, "pose copy: nothing copied before the person has held still long enough")
    feed(wobble, for: 1.0)
    expect(fired.count == 1, "pose copy: held still (with a little wobble) for 1.5 s, it is copied once (\(fired))")
    feed(a, for: 4)
    expect(fired.count == 1, "pose copy: the same pose held on is not copied again")
    feed(.sitting, for: 0.8)
    feed(.sitting, for: 1.5)
    expect(fired.count == 2, "pose copy: a new pose held still is copied too (\(fired))")
    feed(nil, for: 2)
    feed(.sitting, for: 2)
    expect(fired.count == 3, "pose copy: stepping out and back in copies the pose again (\(fired))")
    var moving = StillWatch()
    var anyFired = false
    for k in 0..<20 {
        var p = MannequinPose.standing
        p.left.out = Float(k % 2) * 40
        if moving.see(p, at: Double(k) * 0.35).fire { anyFired = true }
    }
    expect(!anyFired, "pose copy: a person moving about is not copied")
}
