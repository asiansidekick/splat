import Foundation
import simd

// Phil, 2026-11-20: posing must keep to real human movement. A plain figure with a skin of points (so the torso can be
// measured as on a real character) is dragged about as live view does, and checked for range, body and jumps.

func runPoseLimitTests() {
    typealias L = HumanLimits
    let down = SIMD3<Float>(0, -1, 0)

    // Angles and turns give each other back, whichever way the limb points.
    var seed: UInt64 = 7
    func random(_ low: Float, _ high: Float) -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return low + (high - low) * Float(seed >> 40) / Float(1 << 24)
    }
    var worst: Float = 0
    for _ in 0..<500 {
        let l = L.Limb(out: random(-180, 180), forward: random(-90, 90), inward: random(-180, 180), bend: random(0, 150))
        let q = L.rotation(l), back = L.rotation(L.limb(q, bend: l.bend))
        worst = max(worst, simd_distance(q.act(down), back.act(down)), simd_distance(q.act(SIMD3(0, 0, 1)), back.act(SIMD3(0, 0, 1))))
    }
    expect(worst < 1e-3, "posing limits: a limb's angles and its turn give each other back (\(worst))")

    // The ready-made poses are all within a body's range. Sitting cross-legged turns the thighs out further than the
    // twist range (measured from hanging down) allows, as real people do.
    for (name, pose) in MannequinPose.all where name != "Cross-legged on the floor" {
        let misses = [L.overreach(L.rotation(.init(pose.left)), bend: pose.left.elbow, isArm: true),
                      L.overreach(L.rotation(.init(pose.right)), bend: pose.right.elbow, isArm: true),
                      L.overreach(L.rotation(.init(pose.leftLeg)), bend: pose.leftLeg.knee, isArm: false),
                      L.overreach(L.rotation(.init(pose.rightLeg)), bend: pose.rightLeg.knee, isArm: false)]
        expect((misses.max() ?? 0) < 1, "posing limits: \(name) is within a body's range \(misses)")
    }
    let behind = L.held(L.Limb(out: 0, forward: -100, inward: 0, bend: 0), isArm: true)
    let thighBack = L.held(L.Limb(out: 0, forward: -70, inward: 0, bend: 0), isArm: false)
    let twisted = L.held(L.Limb(out: 0, forward: 0, inward: 0, bend: 0), isArm: false)
    let thighTwist = L.twist(L.rotation(L.held(L.Limb(out: 0, forward: 0, inward: 90, bend: 0), isArm: false)))
    expect(behind.forward >= -61 && thighBack.forward >= -26 && twisted == L.Limb(out: 0, forward: 0, inward: 0, bend: 0) && thighTwist <= 35.5,
           "posing limits: an arm goes back 60° at most, a thigh 25°, a thigh twists in 35° (\(behind.forward), \(thighBack.forward), \(thighTwist))")

    // A figure: 1.75 m, arms in an A-pose, facing +Z with its left at +X, with a skin of points round its bones.
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
        add(n + "HandMiddle1", n + "Hand", shoulder + along * 0.62)
        add(n + "UpLeg", "mixamorig:Hips", SIMD3(s * 0.09, 0.9, 0))
        add(n + "Leg", n + "UpLeg", SIMD3(s * 0.09, 0.5, 0.01))
        add(n + "Foot", n + "Leg", SIMD3(s * 0.09, 0.08, -0.01))
        add(n + "ToeBase", n + "Foot", SIMD3(s * 0.09, 0.01, 0.12))
    }
    guard let map = RigFinder.find(nodes) else {
        expect(false, "posing limits: the test figure's joints are found")
        return
    }
    var samples: [(point: SIMD3<Float>, bone: Int)] = []
    // Torso: ellipses 0.16 wide each side at the hips, 0.13 at the waist, 0.15 at the chest; 0.1 to 0.12 deep.
    for k in 0..<40 {
        let y = 0.8 + Float(k) * 0.016
        let half: Float = y < 1.0 ? 0.16 : (y < 1.15 ? 0.13 : 0.15)
        let deep: Float = y < 1.15 ? 0.1 : 0.12
        let bone = y < 1.02 ? "mixamorig:Hips" : (y < 1.15 ? "mixamorig:Spine" : (y < 1.27 ? "mixamorig:Spine1" : "mixamorig:Spine2"))
        for a in 0..<36 {
            let t = Float(a) / 36 * 2 * .pi
            samples.append((SIMD3(cos(t) * half, y, sin(t) * deep), index[bone]!))
        }
    }
    for side in ["Left", "Right"] {
        for (bone, next, radius) in [("Arm", "ForeArm", Float(0.045)), ("ForeArm", "Hand", Float(0.038))] {
            let a = nodes[index["mixamorig:" + side + bone]!].position, b = nodes[index["mixamorig:" + side + next]!].position
            let axis = simd_normalize(b - a)
            let u = simd_normalize(simd_cross(axis, SIMD3(0, 0, 1))), v = simd_cross(axis, u)
            for k in 0..<10 {
                for r in 0..<12 {
                    let t = Float(r) / 12 * 2 * .pi
                    samples.append((a + (b - a) * (Float(k) / 10) + (u * cos(t) + v * sin(t)) * radius, index["mixamorig:" + side + bone]!))
                }
            }
        }
    }
    var poser = RigPoser(nodes: nodes, map: map)
    poser.torso = TorsoShape.measure(nodes: nodes, map: map, samples: samples)
    let torso = poser.torso
    expect((torso?.slabs.count ?? 0) >= 8 && abs((torso?.upperArm ?? 0) - 0.045) < 0.005 && abs((torso?.forearm ?? 0) - 0.038) < 0.005,
           "posing limits: the torso and arms are measured from the skin (\(torso?.slabs.count ?? 0) slices, arm \(torso?.upperArm ?? 0))")

    // Dragging, as live view does it.
    func spots(_ pose: MannequinPose) -> [SIMD3<Float>] { poser.worlds(for: pose).worlds.map(\.columns.3.xyz) }
    func body(_ pose: MannequinPose) -> BodyVolume? {
        guard let torso else { return nil }
        let worlds = poser.worlds(for: pose).worlds
        return BodyVolume(slabs: torso.slabs.map { $0.moved(by: worlds[$0.bone] * nodes[$0.bone].world.inverse) }, upperArm: torso.upperArm, forearm: torso.forearm)
    }
    let frames = PoseDrag.Frames(arm: { poser.armFrame($0, side: $1) }, leg: { poser.legFrame($0) })
    func drag(_ joint: PoseDrag.Joint, to target: SIMD3<Float>, from pose: MannequinPose) -> MannequinPose {
        let at = spots(pose)
        let chain: [Int]
        switch joint {
        case .hand(let s), .elbow(let s): chain = s == 0 ? map.armL : map.armR
        case .foot(let s), .knee(let s): chain = s == 0 ? map.legL : map.legR
        default: chain = map.armL
        }
        return PoseDrag.solve(joint, target: target, top: at[chain[0]], middle: at[chain[1]], end: at[chain[2]], hips: at[map.hips],
                              from: pose, frames: frames, body: body(pose))
    }
    let armL = map.armL, legL = map.legL
    var pose = poser.restPose

    // The hand goes where it is dragged, when it can reach, and stays put when dragged there again.
    let ahead = SIMD3<Float>(0.3, 1.25, 0.35)
    pose = drag(.hand(0), to: ahead, from: pose)
    let reached = spots(pose)
    let again = spots(drag(.hand(0), to: ahead, from: pose))
    expect(simd_distance(reached[armL[2]], ahead) < 0.01 && simd_distance(again[armL[1]], reached[armL[1]]) < 0.002,
           "posing limits: the hand reaches where it is dragged and holds still there (\(simd_distance(reached[armL[2]], ahead)))")

    // The right arm does the same, mirrored.
    let mirroredPose = drag(.hand(1), to: SIMD3(-ahead.x, ahead.y, ahead.z), from: poser.restPose)
    let r = mirroredPose.right, l = pose.left
    expect(abs(r.out - l.out) < 0.5 && abs(r.forward - l.forward) < 0.5 && abs(r.inward - l.inward) < 0.5 && abs(r.elbow - l.elbow) < 0.5,
           "posing limits: the right arm reaches as the left one does, mirrored (\(r) vs \(l))")

    // Swept round a big loop (side, forward, overhead, across the chest, behind the back), nothing jumps and the arm
    // never goes into the body or past a shoulder's range.
    let shoulder = reached[armL[0]]
    var path: [SIMD3<Float>] = []
    func arc(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ steps: Int) {
        for k in 0...steps {
            let t = Float(k) / Float(steps)
            let d = simd_normalize(from * (1 - t) + to * t)
            path.append(shoulder + d * 0.45)
        }
    }
    let side = SIMD3<Float>(1, -0.3, 0), front = SIMD3<Float>(0.2, 0, 1), up = SIMD3<Float>(0.2, 1, 0.1)
    let across = SIMD3<Float>(-1.2, -0.3, 0.5), hang = SIMD3<Float>(0.15, -1, 0.05), back = SIMD3<Float>(0.3, -0.6, -0.9)
    arc(side, front, 40); arc(front, up, 40); arc(up, side, 40); arc(side, across, 50); arc(across, hang, 40); arc(hang, back, 30); arc(back, side, 30)
    var jumps: Float = 0, deepest: Float = 0, overreach: Float = 0, swaps = 0
    pose = drag(.hand(0), to: path[0], from: pose)
    var last = spots(pose)
    for target in path {
        pose = drag(.hand(0), to: target, from: pose)
        let now = spots(pose)
        jumps = max(jumps, simd_distance(now[armL[1]], last[armL[1]]))
        if simd_distance(now[armL[1]], last[armL[1]]) > 0.06 { swaps += 1 }
        last = now
        let volume = body(pose)!
        for t in stride(from: Float(0.5), through: 1, by: 0.1) {
            deepest = max(deepest, volume.inside(now[armL[0]] + (now[armL[1]] - now[armL[0]]) * t, radius: 0))
            deepest = max(deepest, volume.inside(now[armL[1]] + (now[armL[2]] - now[armL[1]]) * t, radius: 0))
        }
        overreach = max(overreach, L.overreach(L.rotation(.init(pose.left)), bend: pose.left.elbow, isArm: true))
    }
    // Only where the arm would otherwise pass through the body may the elbow swing over to the other side, once.
    expect(swaps <= 1, "posing limits: dragging the hand round a big loop (1 to 2 cm a step) moves the elbow smoothly, swinging it round at most once to keep out of the body (\(swaps) swings, largest step \(jumps) m)")
    expect(deepest == 0, "posing limits: the arm never goes into the body (\(deepest))")
    expect(overreach < 0.5, "posing limits: the arm stays within a shoulder's range (\(overreach)°)")

    // A hand dragged into the belly stops on its skin, the arm outside.
    pose = poser.restPose
    let belly = SIMD3<Float>(0.02, 1.08, 0.0)
    for k in 0...20 { pose = drag(.hand(0), to: ahead + (belly - ahead) * (Float(k) / 20), from: pose) }
    let onBelly = spots(pose), volume = body(pose)!
    let inBelly = (0...10).map { k -> Float in
        let t = Float(k) / 10
        return max(volume.inside(onBelly[armL[1]] + (onBelly[armL[2]] - onBelly[armL[1]]) * t, radius: 0),
                   volume.inside(onBelly[armL[0]] + (onBelly[armL[1]] - onBelly[armL[0]]) * max(t, 0.5), radius: 0))
    }.max() ?? 0
    expect(inBelly == 0 && onBelly[armL[2]].z > 0.08, "posing limits: a hand pushed into the belly rests on it, in front (\(inBelly), hand z \(onBelly[armL[2]].z))")

    // The elbow dragged into the side stays out of it.
    pose = poser.restPose
    let intoSide = reached[armL[0]] + SIMD3(-0.12, -0.25, 0)
    pose = drag(.elbow(0), to: intoSide, from: pose)
    let tucked = spots(pose), sideVolume = body(pose)!
    expect(sideVolume.inside(tucked[armL[1]], radius: 0) == 0, "posing limits: an elbow pushed into the side stays out of it")

    // The knee lifts forward smoothly through level up toward the chest; the shin keeps hanging under it.
    pose = poser.restPose
    let hip = spots(pose)[legL[0]]
    var kneeJump: Float = 0, shinOut: Float = 0
    last = spots(pose)
    for k in 0...60 {
        let a = Float(k) / 60 * 130 * .pi / 180
        pose = drag(.knee(0), to: hip + SIMD3(0, -cos(a), sin(a)) * 0.4, from: pose)
        let now = spots(pose)
        kneeJump = max(kneeJump, simd_distance(now[legL[1]], last[legL[1]]))
        shinOut = max(shinOut, abs(now[legL[2]].x - now[legL[1]].x))
        last = now
    }
    let thigh = simd_normalize(last[legL[1]] - last[legL[0]])
    expect(kneeJump < 0.03 && shinOut < 0.08 && thigh.y > 0.2 && thigh.y < 0.6 && pose.leftLeg.knee >= 55,
           "posing limits: the knee lifts smoothly to the chest, bending as it goes, no further (step \(kneeJump), shin out \(shinOut), thigh up \(thigh.y), knee \(pose.leftLeg.knee))")

    // The foot swept round (forward, out, back, across), the knee moving smoothly and pointing the way the leg goes.
    pose = poser.restPose
    var footJump: Float = 0
    var kneeBack: Float = 0
    pose = drag(.foot(0), to: hip + SIMD3(0, -0.62, 0.3), from: pose)
    last = spots(pose)
    for k in 0...120 {
        let a = Float(k) / 120 * 2 * .pi
        let target = hip + SIMD3(0.12 * sin(a), -0.62, 0.3 * cos(a))
        pose = drag(.foot(0), to: target, from: pose)
        let now = spots(pose)
        footJump = max(footJump, simd_distance(now[legL[1]], last[legL[1]]))
        // The knee is never behind the line from hip to foot (it would be bending the wrong way).
        let line = simd_normalize(now[legL[2]] - now[legL[0]]), knee = now[legL[1]] - now[legL[0]]
        let off = knee - simd_dot(knee, line) * line
        kneeBack = min(kneeBack, off.z)
        last = now
    }
    expect(footJump < 0.03 && kneeBack > -0.02, "posing limits: the foot swept round moves the knee smoothly, never bending it backwards (step \(footJump), \(kneeBack))")

    // Phil, build 1392: a leg dragged out to the side stops at about 45° unless brought well forward; it never sticks
    // out sideways at level.
    var sideways: Float = 0
    pose = poser.restPose
    for k in 0...40 {
        let a = Float(k) / 40 * 100 * .pi / 180
        pose = drag(.foot(0), to: hip + SIMD3(sin(a), -cos(a), 0) * 0.8, from: pose)
        let thighNow = simd_normalize(spots(pose)[legL[1]] - spots(pose)[legL[0]])
        // How far out to the side the thigh points, while it is not brought much forward.
        sideways = max(sideways, atan2(thighNow.x, -thighNow.y) * 180 / .pi * (thighNow.z < 0.3 ? 1 : 0))
    }
    expect(sideways < 52, "posing limits: a leg dragged out to the side stops at about 45° (\(sideways)°)")

    // A foot dragged far behind swings the thigh back no more than a hip goes.
    pose = poser.restPose
    pose = drag(.foot(0), to: hip + SIMD3(0, -0.3, -0.8), from: pose)
    let kicked = spots(pose)
    let backThigh = simd_normalize(kicked[legL[1]] - kicked[legL[0]])
    expect(asin(-backThigh.z) * 180 / .pi < 27, "posing limits: a leg goes back about 25° at most (\(asin(-backThigh.z) * 180 / .pi)°)")

    // Bending forward from the hips, hands to the floor: the legs stay, hanging arms dangle, and come back on standing.
    pose = poser.restPose
    pose.left = MannequinPose.Arm(out: 8, forward: 0, inward: 0, elbow: 8)
    pose.right = pose.left
    let standing = spots(pose)
    let hips = standing[map.hips]
    let neck = standing[map.neck ?? map.head!]
    for k in 1...30 {
        let a = Float(k) / 30 * 110 * .pi / 180
        pose = drag(.head, to: hips + SIMD3(0, cos(a), sin(a)) * simd_distance(neck, hips), from: pose)
    }
    let bent = spots(pose)
    let hanging = simd_normalize(bent[armL[1]] - bent[armL[0]])
    expect(pose.spineForward > 100 && simd_distance(bent[legL[1]], standing[legL[1]]) < 0.001 && bent[map.head!].y < hips.y + 0.25 && hanging.y < -0.85,
           "posing limits: the body bends forward past level from the hips, legs still, arms dangling (lean \(pose.spineForward), head \(bent[map.head!].y), arm \(hanging.y))")
    for k in stride(from: 29, through: 0, by: -1) {
        let a = Float(k) / 30 * 110 * .pi / 180
        pose = drag(.head, to: hips + SIMD3(0, cos(a), sin(a)) * simd_distance(neck, hips), from: pose)
    }
    let upAgain = spots(pose)
    let armAgain = simd_normalize(upAgain[armL[1]] - upAgain[armL[0]])
    expect(abs(pose.spineForward) < 1 && armAgain.y < -0.9, "posing limits: standing up again brings the arms back to hanging (\(armAgain.y))")
}
