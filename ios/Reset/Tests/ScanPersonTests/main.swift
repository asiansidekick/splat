// Tests for turning a scan of a person into a posable character (ScanRig.swift), run on a Mac by CI. A synthetic
// person made of capsules, standing in an A pose, turned 40° and moved off the middle, goes through every step:
// standing it up, filling it in, finding the joints, skinning, and writing the FBX, which is read back with Reset's
// own FBX reader (ufbx) and its own joint finder (RigFinder).

import Foundation
import simd

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS  " : "FAIL  ") + message)
    if !condition { failures += 1 }
}
func near(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ within: Float, _ what: String) {
    let d = simd_distance(a, b)
    expect(d < within, String(format: "%@ found within %.0f cm (off by %.1f cm: %.3f, %.3f vs %.3f, %.3f)", what, within * 100, d * 100, a.x, a.y, b.x, b.y))
}

// MARK: A synthetic person

var positions: [SIMD3<Float>] = []
var triangles: [UInt32] = []
/// A closed capsule from a to b.
func capsule(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ r: Float) {
    var d = b - a
    if simd_length(d) < 1e-5 { d = SIMD3(0, 1e-4, 0) }
    let axis = simd_normalize(d)
    let helper: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
    let u = simd_normalize(simd_cross(axis, helper)), w = simd_cross(axis, u)
    // Caps of 8 rings each, and a ring every 2 cm along the middle, so points are spread evenly over the skin.
    let around = 20
    let base = UInt32(positions.count)
    let middleRings = max(1, Int(ceil(simd_distance(a, b) / 0.02)))
    var ringList: [(SIMD3<Float>, Float)] = []
    for i in 0...8 { ringList.append((b, Float.pi / 2 - Float.pi / 2 * Float(i) / 8)) }
    if middleRings > 1 { for k in 1..<middleRings { ringList.append((b + (a - b) * (Float(k) / Float(middleRings)), 0)) } }
    for i in 0...8 { ringList.append((a, -Float.pi / 2 * Float(i) / 8)) }
    let rings = ringList.count - 1
    for (centre, lat) in ringList {
        for k in 0..<around {
            let lon = 2 * Float.pi * Float(k) / Float(around)
            let across = cos(lon) * u + sin(lon) * w
            let p = centre + r * (cos(lat) * across + sin(lat) * axis)
            positions.append(p)
        }
    }
    for i in 0..<rings {
        for k in 0..<around {
            let a0 = base + UInt32(i * around + k), a1 = base + UInt32(i * around + (k + 1) % around)
            let b0 = a0 + UInt32(around), b1 = a1 + UInt32(around)
            triangles += [a0, b0, a1, a1, b0, b1]
        }
    }
}
for s: Float in [1, -1] {
    capsule(SIMD3(s * 0.09, 0.90, 0), SIMD3(s * 0.10, 0.48, 0), 0.065)   // thigh
    capsule(SIMD3(s * 0.10, 0.48, 0), SIMD3(s * 0.10, 0.08, 0), 0.045)   // shin
    capsule(SIMD3(s * 0.10, 0.05, -0.02), SIMD3(s * 0.10, 0.04, 0.15), 0.04)  // foot, toes forward (+Z)
    capsule(SIMD3(s * 0.20, 1.42, 0), SIMD3(s * 0.33, 1.17, 0), 0.045)   // upper arm
    capsule(SIMD3(s * 0.33, 1.17, 0), SIMD3(s * 0.43, 0.95, 0), 0.04)    // forearm
    capsule(SIMD3(s * 0.43, 0.95, 0), SIMD3(s * 0.47, 0.85, 0), 0.04)    // hand
    capsule(SIMD3(s * 0.06, 0.92, 0), SIMD3(s * 0.06, 1.40, 0), 0.12)    // torso, wider than deep
}
capsule(SIMD3(0, 1.40, 0), SIMD3(0, 1.53, 0), 0.05)    // neck
capsule(SIMD3(0, 1.62, 0), SIMD3(0, 1.64, 0), 0.095)   // head
let truth = (elbowL: SIMD2<Float>(0.33, 1.17), elbowR: SIMD2<Float>(-0.33, 1.17), wristL: SIMD2<Float>(0.43, 0.95), wristR: SIMD2<Float>(-0.43, 0.95),
             kneeL: SIMD2<Float>(0.10, 0.48), kneeR: SIMD2<Float>(-0.10, 0.48))
let floorY = positions.map(\.y).min()!

// Turned 40° and moved off the middle, as a scan comes out.
let yaw: Float = 40 * .pi / 180
let moved = positions.map { p -> SIMD3<Float> in
    SIMD3(cos(yaw) * p.x + sin(yaw) * p.z + 1.3, p.y + 0.25, -sin(yaw) * p.x + cos(yaw) * p.z - 0.7)
}
let scan = BodyMesh(positions: moved, normals: BodyMesh.smoothNormals(moved, triangles), uvs: moved.map { SIMD2($0.x, $0.y) },
                    triangles: triangles, parts: [BodyMesh.Part(firstTriangle: 0, triangleCount: triangles.count / 3, texture: "skin0.jpg", color: SIMD3(1, 1, 1))])

// MARK: Leaving out stray bits

// A trimmed scan keeps the room's points that no triangle uses any more, and a speck of wall 4 m away.
var messy = scan
let roomPoints: [SIMD3<Float>] = [SIMD3(-6, -1, 5), SIMD3(7, 3, -6), SIMD3(5, 0, 8)]
messy.positions += roomPoints
messy.normals += roomPoints.map { _ in SIMD3<Float>(0, 1, 0) }
messy.uvs! += roomPoints.map { _ in SIMD2<Float>(0, 0) }
let speck = UInt32(messy.positions.count)
messy.positions += [SIMD3(5.3, 1.0, -0.7), SIMD3(5.4, 1.0, -0.7), SIMD3(5.3, 1.1, -0.7)]
messy.normals += [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 3)
messy.uvs! += [SIMD2<Float>](repeating: .zero, count: 3)
messy.triangles += [speck, speck + 1, speck + 2]
messy.parts[0].triangleCount += 1
let (cleaned, strayCount) = ScanRig.mainPiece(messy)
expect(strayCount == 1 && cleaned.triangleCount == scan.triangleCount, "the stray speck is left out, the person kept (\(strayCount) left out)")
expect(cleaned.positions.count == scan.positions.count, "points nothing uses are dropped (\(cleaned.positions.count) of \(messy.positions.count))")
expect(ScanRig.stance(of: messy).map { $0.height > 3.5 } == true && abs(ScanRig.stance(of: cleaned)!.height - ScanRig.stance(of: scan)!.height) < 0.001,
       "stray points made the scan look 4 m tall; cleaned it's the person's height")
let cleanedStood = ScanRig.stood(cleaned, ScanRig.stance(of: cleaned)!)
expect(ScanRig.Voxels.fitting(cleanedStood, height: ScanRig.stance(of: cleaned)!.height) != nil, "the cleaned scan fills in")
let wide = ScanRig.stood(messy, ScanRig.stance(of: messy)!)
expect(ScanRig.Voxels.fitting(wide, height: 1.7) != nil, "even a very wide box fits, with bigger cubes")

// MARK: Standing it up

guard let stance = ScanRig.stance(of: scan) else {
    expect(false, "the person's stance was found")
    exit(1)
}
let body = ScanRig.stood(scan, stance)
let height = body.positions.map(\.y).max()! - body.positions.map(\.y).min()!
expect(abs(height - (1.735 - floorY)) < 0.01, String(format: "height kept (%.3f m)", height))
expect(abs(body.positions.map(\.y).min()!) < 0.001, "feet on the floor")
// Facing +Z with its left at +X: the left hand (truth +X) must come out at +X, the toes at +Z.
let leftHand = ScanRig.stood(BodyMesh(positions: [SIMD3(cos(yaw) * 0.47 + 1.3, 0.85 + 0.25, -sin(yaw) * 0.47 - 0.7)], normals: [.zero], uvs: nil, triangles: [], parts: []), stance).positions[0]
expect(leftHand.x > 0.4, String(format: "the person's left is at +X (left hand at x %.2f)", leftHand.x))
expect(!stance.turned || stance.feetSignal > 0, "facing found from the feet")
let toes = ScanRig.stood(BodyMesh(positions: [SIMD3(cos(yaw) * 0.1 + sin(yaw) * 0.19 + 1.3, 0.3, -sin(yaw) * 0.1 + cos(yaw) * 0.19 - 0.7)], normals: [.zero], uvs: nil, triangles: [], parts: []), stance).positions[0]
expect(toes.z > 0.1, String(format: "the toes point to +Z (z %.2f), feet signal %.3f", toes.z, stance.feetSignal))

var trimmed = body
expect(ScanRig.trimFloor(&trimmed) == 0, "no floor cut from a person without one")

// MARK: Filling in and finding the marks

guard let voxels = ScanRig.Voxels(body, size: height / 150) else {
    expect(false, "voxels made")
    exit(1)
}
expect(voxels.solidCount > 2 * voxels.shellCount, "the body is filled in (\(voxels.solidCount) inside, \(voxels.shellCount) skin)")
expect(!voxels.closed, "no holes to close in a closed scan")
guard let found = ScanRig.findMarks(voxels) else {
    expect(false, "marks found")
    exit(1)
}
expect(found.handsFound, "both hands found")
expect(found.groinFound, "groin found")
// Truth moved into the stood-up space: x by the centre found, y by the floor.
let shift = SIMD2<Float>(0, -floorY)
let centreX = stance.apply(SIMD3(1.3, 0, -0.7)).x
func t(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(p.x + centreX, p.y) + shift }
near(found.marks.elbowL, t(truth.elbowL), 0.08, "left elbow")
near(found.marks.elbowR, t(truth.elbowR), 0.08, "right elbow")
near(found.marks.wristL, t(truth.wristL), 0.07, "left wrist")
near(found.marks.wristR, t(truth.wristR), 0.07, "right wrist")
near(found.marks.kneeL, t(truth.kneeL), 0.06, "left knee")
near(found.marks.kneeR, t(truth.kneeR), 0.06, "right knee")
expect(found.marks.groin.y > 0.72 - floorY && found.marks.groin.y < 0.86 - floorY, String(format: "groin height %.2f", found.marks.groin.y))
expect(found.marks.chin.y > 1.45 - floorY && found.marks.chin.y < 1.60 - floorY, String(format: "chin height %.2f", found.marks.chin.y))

// MARK: Joints

let joints = ScanRig.joints(found.marks, voxels, height: height)
expect(joints.count == ScanRig.boneNames.count, "a joint for every bone")
func joint(_ name: String) -> SIMD3<Float> { joints[ScanRig.bone(name)] }
expect(joint("LeftArm").x > 0.08 && joint("LeftArm").x < 0.30, String(format: "left shoulder at x %.2f", joint("LeftArm").x))
expect(joint("RightArm").x < -0.08, "right shoulder at -X")
expect(joint("Head").y > joint("Neck").y && joint("Neck").y > joint("Spine2").y && joint("Spine2").y > joint("Hips").y, "spine climbs from the hips to the head")
expect(joint("LeftFoot").y < joint("LeftLeg").y && joint("LeftLeg").y < joint("LeftUpLeg").y, "leg goes down hip, knee, ankle")
expect(joint("LeftToe_End").z > joint("LeftFoot").z + 0.08, "toes in front of the ankle")
expect(joint("HeadTop_End").y > 1.65 - floorY, "head top at the top of the head")
for (i, p) in joints.enumerated() { expect(p.x.isFinite && p.y.isFinite && p.z.isFinite, "\(ScanRig.boneNames[i]) is a real point") }

// MARK: Skin

let started = Date()
let skin = ScanRig.skin(body, joints: joints, voxels)
print(String(format: "skinning %d points took %.2f s", body.positions.count, Date().timeIntervalSince(started)))
expect(skin.loose == 0, "every point reached by a bone (\(skin.loose) loose)")
var sumsGood = true
for w in skin.weights where abs(w.x + w.y + w.z + w.w - 1) > 1e-3 { sumsGood = false }
expect(sumsGood, "weights add up to 1")
func strongest(near point: SIMD3<Float>) -> String {
    var best = 0
    var bestDistance = Float.greatestFiniteMagnitude
    for (i, p) in body.positions.enumerated() where simd_distance(p, point) < bestDistance { bestDistance = simd_distance(p, point); best = i }
    return ScanRig.boneNames[ScanRig.skinBones[Int(skin.bones[best].x)].bone]
}
let c = SIMD3<Float>(centreX, -floorY, 0)
let side = strongest(near: c + SIMD3(0.18, 1.15, 0))
expect(["Spine", "Spine1", "Spine2"].contains(side), "the side of the chest follows the spine, not the arm next to it (\(side))")
let forearm = strongest(near: c + SIMD3(0.42, 1.06, 0))
expect(forearm == "LeftForeArm", "the middle of the left forearm follows the forearm (\(forearm))")
let upperArm = strongest(near: c + SIMD3(0.31, 1.29, 0))
expect(upperArm == "LeftArm", "the left upper arm follows the arm (\(upperArm))")
let thigh = strongest(near: c + SIMD3(-0.16, 0.70, 0))
expect(thigh == "RightUpLeg", "the right thigh follows the thigh (\(thigh))")
let innerThigh = strongest(near: c + SIMD3(0.035, 0.62, 0))
expect(innerThigh == "LeftUpLeg", "the inside of the left thigh follows the left leg, not the right (\(innerThigh))")
let shin = strongest(near: c + SIMD3(0.10, 0.28, 0.045))
expect(shin == "LeftLeg", "the left shin follows the lower leg (\(shin))")
let head = strongest(near: c + SIMD3(0, 1.72, 0))
expect(head == "Head", "the top of the head follows the head (\(head))")

// MARK: The FBX, read back with Reset's own reader

let data = ScanRig.fbx(body, joints: joints, skin: skin, name: "Test person")
let file = FileManager.default.temporaryDirectory.appendingPathComponent("scan-person-\(UUID().uuidString).fbx")
try data.write(to: file)
defer { try? FileManager.default.removeItem(at: file) }
print(String(format: "FBX %.1f MB", Double(data.count) / 1_000_000))
let opened: UnsafeMutablePointer<rs_scene>? = rs_fbx_load(file.path)
defer { rs_fbx_free(opened) }
if let scene = opened?.pointee {
    let error = withUnsafeBytes(of: scene.error) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
    expect(scene.mesh_count == 1, "one shape read back (\(scene.mesh_count))\(error.isEmpty ? "" : ": " + error)")
    var nodes: [RigNode] = []
    var boneCount = 0
    var marker = false
    for i in 0..<Int(scene.node_count) {
        let n = scene.nodes[i]
        let namePointer: UnsafePointer<CChar>? = n.name
        let name = namePointer.map { String(cString: $0) } ?? ""
        func m<T>(_ tuple: T) -> simd_float4x4 {
            let f = withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Float.self)) }
            return simd_float4x4(SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]), SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15]))
        }
        nodes.append(RigNode(name: name, parent: Int(n.parent), isBone: n.is_bone != 0, local: m(n.local), world: m(n.world)))
        if n.is_bone != 0 { boneCount += 1 }
        if name == ScanRig.scanMarker { marker = true }
    }
    expect(boneCount == ScanRig.boneNames.count, "\(boneCount) bones read back")
    expect(marker, "the scanned-person marker is there (shown unlit)")
    if let hips = nodes.first(where: { $0.name == "mixamorig:Hips" }) {
        expect(simd_distance(hips.position, joint("Hips")) < 0.001, "the hips rest where they were found")
    } else {
        expect(false, "hips read back")
    }
    if let leftHand = nodes.first(where: { $0.name == "mixamorig:LeftHand" }) {
        expect(simd_distance(leftHand.position, joint("LeftHand")) < 0.001, "the left wrist rests where it was found")
    }
    if scene.mesh_count > 0 {
        let mesh = scene.meshes[0]
        expect(Int(mesh.vertex_count) == triangles.count, "every triangle read back (\(mesh.vertex_count) corners)")
        expect(Int(mesh.bone_count) == ScanRig.skinBones.count, "\(mesh.bone_count) bones pull the skin")
        let uvPointer: UnsafeMutablePointer<Float>? = mesh.uvs
        expect(uvPointer != nil, "picture coordinates read back")
        if mesh.part_count > 0 {
            let namePointer: UnsafePointer<CChar>? = mesh.parts[0].texture_name
            expect(namePointer.map { String(cString: $0) } == "skin0.jpg", "the picture's file name read back")
        }
        let positionPointer: UnsafeMutablePointer<Float>? = mesh.positions
        if let p = positionPointer {
            // The first triangle's first corner, after the reader stands the skin in its rest pose: where it was.
            let first = body.positions[Int(triangles[0])]
            let back = SIMD3(p[0], p[1], p[2])
            expect(simd_distance(first, back) < 0.001, String(format: "skin stands where the scan was (off %.4f m)", simd_distance(first, back)))
            var high: Float = -1
            for v in 0..<Int(mesh.vertex_count) { high = max(high, p[v * 3 + 1]) }
            expect(abs(high - height) < 0.01, String(format: "read back %.3f m tall", high))
        }
    }
    if let map = RigFinder.find(nodes) {
        expect(map.fromNames, "joints found from the bone names")
        expect(nodes[map.armL[0]].name == "mixamorig:LeftArm" && nodes[map.armL[1]].name == "mixamorig:LeftForeArm" && nodes[map.armL[2]].name == "mixamorig:LeftHand",
               "left arm: \(map.armL.map { nodes[$0].name })")
        expect(nodes[map.legR[0]].name == "mixamorig:RightUpLeg" && nodes[map.legR[1]].name == "mixamorig:RightLeg" && nodes[map.legR[2]].name == "mixamorig:RightFoot",
               "right leg: \(map.legR.map { nodes[$0].name })")
        expect(map.facing > 0, "faces +Z for the poser")
        let poser = RigPoser(nodes: nodes, map: map)
        let posed = poser.locals(for: MannequinPose())
        expect(posed.locals.count == nodes.count && posed.locals.allSatisfy { m in (0..<4).allSatisfy { m[$0].x.isFinite && m[$0].w.isFinite } },
               "posing it standing gives a real pose for every node")
    } else {
        expect(false, "Reset's joint finder knows the skeleton")
    }
} else {
    expect(false, "the FBX opened")
}

// MARK: Smoothing the head and shoulders, nothing else

// A lumpy ball, smoothed everywhere, comes out rounder and about the same size.
var ball = BodyMesh(positions: [], normals: [], uvs: nil, triangles: [], parts: [])
do {
    let rings = 24, around = 32
    var seed: UInt64 = 7
    func noise() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) - 0.5 }
    ball.positions.append(SIMD3(0, 0.1, 0))
    for i in 1..<rings {
        let lat = Float.pi / 2 - Float.pi * Float(i) / Float(rings)
        for k in 0..<around {
            let lon = 2 * Float.pi * Float(k) / Float(around)
            let r: Float = 0.1 + 0.006 * noise()
            ball.positions.append(SIMD3(r * cos(lat) * cos(lon), r * sin(lat), r * cos(lat) * sin(lon)))
        }
    }
    ball.positions.append(SIMD3(0, -0.1, 0))
    let last = UInt32(ball.positions.count - 1)
    for k in 0..<around { ball.triangles += [0, UInt32(1 + (k + 1) % around), UInt32(1 + k)] }
    for i in 0..<(rings - 2) {
        for k in 0..<around {
            let a0 = UInt32(1 + i * around + k), a1 = UInt32(1 + i * around + (k + 1) % around)
            ball.triangles += [a0, a1, a0 + UInt32(around), a1, a1 + UInt32(around), a0 + UInt32(around)]
        }
    }
    let bottom = UInt32(1 + (rings - 2) * around)
    for k in 0..<around { ball.triangles += [last, bottom + UInt32(k), bottom + UInt32((k + 1) % around)] }
    ball.normals = BodyMesh.smoothNormals(ball.positions, ball.triangles)
    ball.parts = [BodyMesh.Part(firstTriangle: 0, triangleCount: ball.triangles.count / 3, texture: nil, color: SIMD3(1, 1, 1))]
}
func roughness(_ m: BodyMesh) -> (Float, Float) {
    let radii = m.positions.map { simd_length($0) }
    let mean = radii.reduce(0, +) / Float(radii.count)
    let spread = (radii.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(radii.count)).squareRoot()
    return (mean, spread)
}
let (beforeMean, beforeSpread) = roughness(ball)
var smoothedBall = ball
ScanRig.smooth(&smoothedBall, ScanRig.Smoothing(fullFrom: -1, noneBelow: -2, rounds: 8))
let (afterMean, afterSpread) = roughness(smoothedBall)
expect(afterSpread < beforeSpread * 0.5, String(format: "smoothing takes the lumps out (spread %.2f mm to %.2f mm)", beforeSpread * 1000, afterSpread * 1000))
expect(abs(afterMean - beforeMean) < 0.003, String(format: "smoothing keeps the size (%.1f mm to %.1f mm)", beforeMean * 1000, afterMean * 1000))

// The person: the head and shoulders may move, everything below stays exactly as scanned.
let region = ScanRig.headAndShoulders(joints: joints, height: height)
expect(region.fullFrom > region.noneBelow && region.noneBelow > joint("Spine1").y, String(format: "smoothing from %.2f m up, none below %.2f m", region.fullFrom, region.noneBelow))
var smoothedPerson = body
let smoothedCount = ScanRig.smooth(&smoothedPerson, region)
var untouched = true, headMoved = false
for i in body.positions.indices {
    if body.positions[i].y <= region.noneBelow, smoothedPerson.positions[i] != body.positions[i] || smoothedPerson.normals[i] != body.normals[i] { untouched = false }
    if body.positions[i].y > region.fullFrom, simd_distance(smoothedPerson.positions[i], body.positions[i]) > 1e-5 { headMoved = true }
}
expect(untouched, "the body and costume below the shoulders stay exactly as scanned")
var furthest: Float = 0
for i in body.positions.indices { furthest = max(furthest, simd_distance(smoothedPerson.positions[i], body.positions[i])) }
expect(furthest <= region.maxMove + 1e-5, String(format: "no point moved more than %.1f mm, so the face keeps its features (furthest %.2f mm)", region.maxMove * 1000, furthest * 1000))
expect(headMoved && smoothedCount > 0, "the head and shoulders were smoothed (\(smoothedCount) points)")
expect(smoothedPerson.triangles == body.triangles && smoothedPerson.uvs! == body.uvs!, "triangles and photo kept as they were")
let smoothedHigh = smoothedPerson.positions.map(\.y).max()!
expect(abs(smoothedHigh - height) < 0.01, String(format: "still as tall (%.3f m)", smoothedHigh))
let smoothedSkin = ScanRig.skin(smoothedPerson, joints: joints, voxels)
expect(smoothedSkin.loose == 0, "every smoothed point reached by a bone")

// MARK: Swapping heads

// A donor: the same person 10% bigger, standing somewhere else. Its head goes on the first body at the first body's
// neck, keeping its own (bigger) size; the body below the cut stays exactly as scanned.
let donorShift = SIMD3<Float>(0.5, 0.03, 0.2)
var donor = body
donor.positions = body.positions.map { $0 * 1.1 + donorShift }
let donorJoints = joints.map { $0 * 1.1 + donorShift }
let cut = ScanRig.neckCut(joints: joints)
expect(cut.y > joint("Neck").y && cut.y < joint("Head").y, String(format: "head cut at %.2f m, between neck and head", cut.y))
let swapped = ScanRig.swapHead(body: body, joints: joints, donor: donor, donorJoints: donorJoints, rename: { "head-" + $0 })
let bodyPoints = Set(body.positions.map { SIMD3<Int32>(Int32(($0.x * 10_000).rounded()), Int32(($0.y * 10_000).rounded()), Int32(($0.z * 10_000).rounded())) })
var lowKept = true, lowCount = 0
for p in swapped.positions where p.y < cut.y - 0.01 {
    lowCount += 1
    if !bodyPoints.contains(SIMD3<Int32>(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()), Int32((p.z * 10_000).rounded()))) { lowKept = false }
}
expect(lowKept && lowCount > 0, "every point below the cut is the body's own, unmoved (\(lowCount))")
let lowBefore = body.positions.filter { $0.y < cut.y - 0.01 }.count
expect(lowBefore == lowCount, "no body point below the cut lost (\(lowBefore) before, \(lowCount) after)")
let swappedTop = swapped.positions.map(\.y).max()!, ownTop = body.positions.map(\.y).max()!
let ratio = (swappedTop - cut.y) / (ownTop - cut.y)
expect(abs(ratio - 1.1) < 0.03, String(format: "the new head keeps its own size (%.2f times the old)", ratio))
let headXs = swapped.positions.filter { $0.y > cut.y + 0.02 }.map(\.x)
expect(abs((headXs.min()! + headXs.max()!) / 2 - cut.x) < 0.02, "the new head stands over the neck")
expect(swapped.parts.count == 2 && swapped.parts[0].texture == "skin0.jpg" && swapped.parts[1].texture == "head-skin0.jpg", "the head brings its own picture, renamed (\(swapped.parts.map { $0.texture ?? "-" }))")
expect(swapped.uvs?.count == swapped.positions.count && swapped.normals.count == swapped.positions.count, "photo and normals for every point")
expect(swapped.triangles.allSatisfy { Int($0) < swapped.positions.count }, "triangles point at real points")
expect(swapped.parts.reduce(0) { $0 + $1.triangleCount } == swapped.triangleCount, "parts cover every triangle")
if let swappedVoxels = ScanRig.Voxels(swapped, size: height / 150) {
    let swappedSkin = ScanRig.skin(swapped, joints: joints, swappedVoxels)
    expect(swappedSkin.loose == 0, "every point of the swapped person reached by a bone (\(swappedSkin.loose) loose)")
    let swappedData = ScanRig.fbx(swapped, joints: joints, skin: swappedSkin, name: "Swapped person")
    let swappedFile = FileManager.default.temporaryDirectory.appendingPathComponent("swapped-\(UUID().uuidString).fbx")
    try swappedData.write(to: swappedFile)
    let swappedScene: UnsafeMutablePointer<rs_scene>? = rs_fbx_load(swappedFile.path)
    expect(swappedScene != nil && swappedScene!.pointee.mesh_count == 1, "swapped person's FBX reads back")
    rs_fbx_free(swappedScene)
    try? FileManager.default.removeItem(at: swappedFile)
} else {
    expect(false, "swapped person filled in")
}

// MARK: A scanned head on an imported character

let piece = ScanRig.headPiece(of: body, joints: joints)
expect(piece.triangleCount > 50 && piece.positions.allSatisfy { $0.y > 0 }, "the head piece stands on its cut (\(piece.triangleCount) triangles)")
let pieceBack = ScanRig.head(from: ScanRig.headData(piece))
expect(pieceBack != nil && pieceBack!.positions == piece.positions && pieceBack!.normals == piece.normals && pieceBack!.uvs! == piece.uvs!
       && pieceBack!.triangles == piece.triangles && pieceBack!.parts.count == piece.parts.count && pieceBack!.parts[0].texture == piece.parts[0].texture,
       "the head file reads back exactly")
expect(ScanRig.head(from: Data("RSH1junk".utf8)) == nil && ScanRig.head(from: Data()) == nil, "a broken head file is refused")
// A character in centimetres facing -Z: the head lands on its neck at real size, turned to face the same way.
let place = ScanRig.headPlacement(neck: SIMD3(0, 150, 0), head: SIMD3(0, 160, 2), facing: -1, metresPerUnit: 0.01)
let chin = place * SIMD4<Float>(0, 0, 0.1, 1), crown = place * SIMD4<Float>(0, 0.2, 0, 1)
expect(abs(chin.y - 154.5) < 0.01 && abs(chin.z - (2 - 10)) < 0.01, String(format: "the head's front faces the character's front (%.1f, %.1f)", chin.y, chin.z))
expect(abs(crown.y - 174.5) < 0.01, "the head keeps its real size in centimetres")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
