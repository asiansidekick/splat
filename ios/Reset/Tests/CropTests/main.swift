import Foundation
import simd

// Synthetic scans for CropMath: a floor patch with an object on it, clutter, and noise.
var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

struct Rng {
    var s: UInt64
    mutating func next() -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float((s >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
    }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
}

var rng = Rng(s: 42)

func floorPatch(_ n: Int, size: Float, y: Float = 0, noise: Float = 0.003) -> [SIMD3<Float>] {
    (0..<n).map { _ in SIMD3(rng.range(-size, size), y + rng.range(-noise, noise), rng.range(-size, size)) }
}

/// Surface points of a box standing on the floor.
func boxSurface(_ n: Int, centre: SIMD2<Float>, size: SIMD3<Float>, floorY: Float = 0) -> [SIMD3<Float>] {
    (0..<n).map { _ in
        var p = SIMD3(rng.range(-0.5, 0.5) * size.x, rng.range(0, 1) * size.y, rng.range(-0.5, 0.5) * size.z)
        switch Int(rng.next() * 5) {
        case 0: p.x = -size.x / 2
        case 1: p.x = size.x / 2
        case 2: p.z = -size.z / 2
        case 3: p.z = size.z / 2
        default: p.y = size.y
        }
        return SIMD3(p.x + centre.x, p.y + floorY, p.z + centre.y)
    }
}

func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

// 1. Chair-sized box on a 2.4 m floor patch: floor found and cut, box hugs the object.
do {
    let pts = floorPatch(20000, size: 1.2) + boxSurface(8000, centre: [0.1, -0.05], size: [0.45, 0.8, 0.5])
    let r = CropMath.suggest(pts)
    check(r?.floorY != nil && near(r!.floorY!, 0, 0.02), "chair: floor found near 0 (got \(String(describing: r?.floorY)))")
    if let b = r?.box {
        check(b.min.y > 0 && b.min.y < 0.03, "chair: crop bottom just above floor (\(b.min.y))")
        check(near(b.max.y, 0.82, 0.04), "chair: crop top at object top (\(b.max.y))")
        check(near(b.min.x, 0.1 - 0.225 - 0.02, 0.04) && near(b.max.x, 0.1 + 0.225 + 0.02, 0.04), "chair: x hugs object (\(b.min.x)...\(b.max.x))")
        check(near(b.min.z, -0.05 - 0.25 - 0.02, 0.04) && near(b.max.z, -0.05 + 0.25 + 0.02, 0.04), "chair: z hugs object (\(b.min.z)...\(b.max.z))")
        let floorKept = pts.prefix(20000).filter { b.contains($0) }.count
        check(floorKept == 0, "chair: no floor points kept (\(floorKept))")
    } else { check(false, "chair: a crop was suggested") }
}

// 2. Small object (mug) with clutter 50 cm away: the clutter is left out.
do {
    let mug = boxSurface(3000, centre: [0, 0], size: [0.09, 0.1, 0.09])
    let clutter = boxSurface(2000, centre: [0.5, 0.3], size: [0.15, 0.05, 0.1])
    let pts = floorPatch(15000, size: 0.8) + mug + clutter
    let r = CropMath.suggest(pts)
    if let b = r?.box {
        check(mug.filter { b.contains($0) }.count > mug.count * 8 / 10, "mug: mug kept")
        check(clutter.filter { b.contains($0) }.isEmpty, "mug: clutter 50 cm away left out")
        check(b.size.x < 0.2 && b.size.z < 0.2, "mug: crop is mug sized (\(b.size))")
    } else { check(false, "mug: a crop was suggested") }
}

// 3. Floor not at zero and tilted noise; object off centre of the floor patch.
do {
    let pts = floorPatch(20000, size: 1.0, y: -1.3, noise: 0.006) + boxSurface(6000, centre: [0.4, 0.4], size: [0.3, 0.3, 0.3], floorY: -1.3)
    let r = CropMath.suggest(pts)
    check(r?.floorY != nil && near(r!.floorY!, -1.3, 0.025), "offset floor: found (\(String(describing: r?.floorY)))")
    if let b = r?.box {
        check(near(b.centre.x, 0.4, 0.05) && near(b.centre.z, 0.4, 0.05), "offset floor: box on the object (\(b.centre))")
    }
}

// 4. No floor (object scanned in the air, e.g. held or hanging): keep everything.
do {
    let pts = boxSurface(5000, centre: [0, 0], size: [0.3, 0.3, 0.3], floorY: 0.5)
    let r = CropMath.suggest(pts)
    check(r != nil, "no floor: a crop was suggested")
    if let b = r?.box {
        check(pts.filter { b.contains($0) }.count > pts.count * 95 / 100, "no floor: nearly all points kept")
    }
}

// 5. Edge cases: empty, a handful of points, flat floor only.
do {
    check(CropMath.suggest([]) == nil, "empty: nil")
    let few = (0..<5).map { SIMD3<Float>(Float($0) * 0.1, 0, 0) }
    check(CropMath.suggest(few) != nil, "few points: still a box")
    let flat = floorPatch(5000, size: 1)
    check(CropMath.suggest(flat) != nil, "floor only: still a box")
    var b = CropBox(min: [0, 0, 0], max: [0, 0.5, 0.5])
    b.keepOpen()
    check(b.size.x >= 0.0099, "keepOpen widens a flat box")
    check(CropMath.thin(Array(repeating: SIMD3<Float>(0, 0, 0), count: 1000), limit: 100).count == 100, "thin to limit")
}

// 6. Mapping between the loaded model and the session's space.
do {
    let model = CropBox(min: [-0.5, 0, -0.5], max: [0.5, 1, 0.5])
    check(CropMath.mapping(model: model, session: nil) == CropMath.Mapping(), "mapping: none without session bounds")
    let same = CropBox(min: [-0.51, 0.01, -0.49], max: [0.5, 1.01, 0.52])
    check(CropMath.mapping(model: model, session: same) == CropMath.Mapping(), "mapping: identity when they nearly match")
    let moved = CropBox(min: [1.5, -1, 2.5], max: [2.5, 0, 3.5])
    let m = CropMath.mapping(model: model, session: moved)
    check(m.scale == 1 && simd_length(m.offset - SIMD3(2, -1, 3)) < 0.001, "mapping: offset when recentred (\(m))")
    let b = m.toSession(CropBox(min: [0, 0, 0], max: [0.1, 0.1, 0.1]))
    check(simd_length(b.min - SIMD3(2, -1, 3)) < 0.001, "mapping: box moved into session space")
    let cm = CropBox(min: [-50, 0, -50], max: [50, 100, 50])
    let s = CropMath.mapping(model: cm, session: model)
    check(abs(s.scale - 0.01) < 0.0001, "mapping: centimetres to metres scale (\(s.scale))")
}

// ScanAlign: a model in made-up space lined up with the room from where the pictures were taken.
do {
    var rng = Rng(s: 99)
    var from: [SIMD3<Float>] = []
    for _ in 0..<40 { from.append(SIMD3(rng.range(-1, 1), rng.range(0, 0.6), rng.range(-1, 1))) }
    let turn = simd_quatf(angle: 1.1, axis: simd_normalize(SIMD3<Float>(0.3, 1, -0.5)))
    let to = from.map { 2.7 * turn.act($0) + SIMD3<Float>(0.4, -1.2, 3) }
    if let fit = ScanAlign.fit(from: from, to: to) {
        check(abs(fit.scale - 2.7) < 0.01, "align: size found (\(fit.scale))")
        check(fit.error < 0.01, "align: places land on each other (\(fit.error) m)")
        let back = fit.scale * fit.quaternion.act(from[7]) + SIMD3<Float>(fit.translation[0], fit.translation[1], fit.translation[2])
        check(simd_length(back - to[7]) < 0.01, "align: a point carried over")
    } else {
        check(false, "align: fit found")
    }
    check(ScanAlign.fit(from: Array(from.prefix(3)), to: Array(to.prefix(3))) == nil, "align: too few pictures refused")
    let still = from.map { _ in SIMD3<Float>(1, 1, 1) }
    check(ScanAlign.fit(from: from, to: still) == nil, "align: a camera that never moved refused")
}

// TrimMath: a loop on the screen takes triangles away, or keeps only them.
do {
    let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
    check(TrimMath.inside(SIMD2(5, 5), loop: square), "trim: middle of a loop is inside")
    check(!TrimMath.inside(SIMD2(15, 5), loop: square), "trim: beside a loop is outside")
    // Two triangles: one inside the square, one far away; a third with a corner behind the camera.
    let screen: [SIMD2<Float>?] = [SIMD2(2, 2), SIMD2(8, 2), SIMD2(5, 8), SIMD2(50, 50), SIMD2(60, 50), SIMD2(55, 60), nil]
    let triangles: [UInt32] = [0, 1, 2, 3, 4, 5, 3, 4, 6]
    let erased = TrimMath.trim(triangles, screen: screen, loop: square, keep: false)
    check(erased == [3, 4, 5, 3, 4, 6], "trim: erase takes the looped triangle only (\(erased))")
    let kept = TrimMath.trim(triangles, screen: screen, loop: square, keep: true)
    check(kept == [0, 1, 2], "trim: keep leaves the looped triangle only (\(kept))")
    check(TrimMath.trim(triangles, screen: screen, loop: [SIMD2(0, 0), SIMD2(1, 1)], keep: false) == triangles, "trim: a loop too short changes nothing")
}

// PinMath: two lines of sight find how far away an object really is.
do {
    let spot = SIMD3<Float>(0.3, 0.8, -2.0)
    let first = SIMD3<Float>(0, 1.5, 0)
    let direction = simd_normalize(spot - first)
    let second = SIMD3<Float>(0.4, 1.5, 0.1)
    if let t = PinMath.along(origin: first, direction: direction, from: second, toward: simd_normalize(spot - second)) {
        check(abs(t - simd_length(spot - first)) < 0.001, "pin: true distance found (\(t))")
    } else {
        check(false, "pin: lines that cross give a distance")
    }
    check(PinMath.along(origin: first, direction: direction, from: second, toward: direction) == nil, "pin: lines side by side refused")
    check(PinMath.along(origin: first, direction: direction, from: second, toward: simd_normalize(SIMD3<Float>(1, 0, 0.2))) == nil, "pin: a meeting behind the camera refused")
    check(abs(PinMath.aside(origin: first, direction: SIMD3(0, 0, -1), camera: SIMD3(0.25, 1.5, -0.4)) - 0.25) < 0.001, "pin: step to the side measured")
    check(PinMath.stepNeeded(distance: 0.5) == 0.12 && PinMath.stepNeeded(distance: 10) == 0.5, "pin: step needed stays between 12 and 50 cm")
}

// OccluderMesh: a depth picture of a room (floor, wall 3 m away, a box 1.5 m away) as an invisible mesh.
do {
    let w = 256, h = 192
    let k = simd_float3x3(SIMD3(200, 0, 0), SIMD3(0, 200, 0), SIMD3(128, 96, 1))
    var depth = [Float](repeating: 3, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let u = Float(x) + 0.5, v = Float(y) + 0.5
            var d: Float = 3
            let down = (v - 96) / 200
            if down > 0 { d = min(d, 1 / down) }  // floor 1 m below the camera
            if abs(u - 128) < 30, abs(v - 96) < 30 { d = 1.5 }  // a box
            depth[y * w + x] = d
        }
    }
    func triangles(_ mesh: OccluderMesh) -> [[SIMD3<Float>]] {
        stride(from: 0, to: mesh.indices.count, by: 3).map { t in
            (0..<3).map { j in
                let i = Int(mesh.indices[t + j]) * 3
                return SIMD3(mesh.positions[i], mesh.positions[i + 1], mesh.positions[i + 2])
            }
        }
    }
    func flatLow(_ t: [SIMD3<Float>]) -> Bool {
        let n = simd_cross(t[1] - t[0], t[2] - t[0])
        let length = simd_length(n)
        return length > 0 && abs(n.y) / length > 0.8 && t.map(\.y).reduce(0, +) / 3 < -0.95
    }
    let pose = matrix_identity_float4x4
    if let mesh = OccluderMesh.build(depth: depth, width: w, height: h, intrinsics: k, pose: pose, imageWidth: Float(w), imageHeight: Float(h)) {
        let all = triangles(mesh)
        check(!all.isEmpty, "occluder: a mesh is made")
        check(!all.contains { t in t.contains { $0.z > -2 } && t.contains { $0.z < -2.5 } }, "occluder: no skin from the box to the wall")
        check(all.contains { t in t.allSatisfy { abs($0.z + 1.595) < 0.01 } }, "occluder: the box is there, pushed back 9.5 cm")
        check(!all.contains(where: flatLow), "occluder: the floor hides nothing")
        check(mesh.seenFloor.map { $0 < -1.0 && $0 > -1.1 } ?? false, "occluder: floor found (\(mesh.seenFloor ?? 0))")
    } else {
        check(false, "occluder: a mesh is made")
    }
    if let kept = OccluderMesh.build(depth: depth, width: w, height: h, intrinsics: k, pose: pose, imageWidth: Float(w), imageHeight: Float(h), floor: -10) {
        check(triangles(kept).contains(where: flatLow), "occluder: a floor given lower keeps this one")
    } else {
        check(false, "occluder: a floor given lower keeps this one")
    }
    let unsure = [UInt8](repeating: 0, count: w * h)
    check(OccluderMesh.build(depth: depth, confidence: unsure, minConfidence: 1, width: w, height: h, intrinsics: k, pose: pose,
                             imageWidth: Float(w), imageHeight: Float(h)) == nil, "occluder: unsure depth makes nothing")
    let full = OccluderMesh.build(depth: depth, width: w, height: h, intrinsics: k, pose: pose, imageWidth: 1920, imageHeight: 1440)
    let coarse = OccluderMesh.build(depth: depth, width: w, height: h, intrinsics: k, pose: pose, imageWidth: 1920, imageHeight: 1440, step: 2)
    check((coarse?.indices.count ?? 0) > 0 && (coarse?.indices.count ?? 0) < (full?.indices.count ?? 0) / 3, "occluder: every second pixel makes a lighter mesh")
    // A speck of noise in the middle of the wall: a 1 m reading on its own.
    var specked = depth
    specked[40 * w + 200] = 1
    let median = OccluderMesh.median3(specked, width: w, height: h)
    check(abs(median[40 * w + 200] - 3) < 0.001, "occluder: a lone speck is smoothed away")
    check(abs(median[96 * w + 128] - 1.5) < 0.001 && abs(median[20 * w + 20] - 3) < 0.001, "occluder: smoothing keeps the box and the wall")
    var holes = depth
    for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) { holes[50 * w + 50 + dy * w + dx] = 0 } }
    check(OccluderMesh.median3(holes, width: w, height: h)[50 * w + 50] == 0, "occluder: a reading with no neighbours is dropped")
    if let wide = OccluderMesh.build(depth: depth, width: w, height: h, intrinsics: k, pose: pose, imageWidth: Float(w), imageHeight: Float(h),
                                     pushBack: 0.08, pushPerMetre: 0.04, denoise: true) {
        check(triangles(wide).contains { t in t.allSatisfy { abs($0.z + 1.64) < 0.01 } }, "occluder: live pushes the box back 14 cm")
    } else {
        check(false, "occluder: live pushes the box back 14 cm")
    }
    // The camera moved and turned: the box lands where the pose says.
    var moved = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
    moved.columns.3 = SIMD4(1, 2, 3, 1)
    if let turned = OccluderMesh.build(depth: depth, width: w, height: h, intrinsics: k, pose: moved, imageWidth: Float(w), imageHeight: Float(h)) {
        // Looking down -z turned left a quarter is looking down -x: the box 1.595 m away at x = 1 - 1.595.
        check(triangles(turned).contains { t in t.allSatisfy { abs($0.x - (1 - 1.595)) < 0.01 && abs($0.z - 3) < 0.4 } }, "occluder: the camera's place and turn are used")
    } else {
        check(false, "occluder: the camera's place and turn are used")
    }
}

// EdgeDepth: LiDAR-sized depth sharpened with the camera picture. A dark box 1.5 m away in front of a light wall
// 3 m away, its edges between pixels of both pictures; slight noise in the picture, as a camera has.
do {
    let dw = 256, dh = 192, gw = 480, gh = 360
    let left: Float = 173.3, right: Float = 301.7, top: Float = 100.2, bottom: Float = 250.6  // in guide pixels
    func inBox(_ x: Float, _ y: Float) -> Bool { x >= left && x < right && y >= top && y < bottom }
    var rng = Rng(s: 7)
    func picture(box: UInt8, wall: UInt8) -> [UInt8] {
        var g = [UInt8](repeating: 0, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw {
            let base = inBox(Float(x) + 0.5, Float(y) + 0.5) ? Float(box) : Float(wall)
            g[y * gw + x] = UInt8(max(0, min(255, base + rng.range(-6, 6))))
        } }
        return g
    }
    // LiDAR reads the depth at the middle of each of its pixels.
    var depth = [Float](repeating: 0, count: dw * dh)
    for j in 0..<dh { for i in 0..<dw {
        let x = (Float(i) + 0.5) * Float(gw) / Float(dw), y = (Float(j) + 0.5) * Float(gh) / Float(dh)
        depth[j * dw + i] = inBox(x, y) ? 1.5 : 3
    } }
    func wrong(_ out: [Float]) -> Int {
        var n = 0
        for y in 0..<gh { for x in 0..<gw {
            let truth: Float = inBox(Float(x) + 0.5, Float(y) + 0.5) ? 1.5 : 3
            if abs(out[y * gw + x] - truth) > 0.2 { n += 1 }
        } }
        return n
    }
    let guide = picture(box: 60, wall: 200)
    let started = Date()
    let sharp = EdgeDepth.refine(depth: depth, width: dw, height: dh, guide: guide, guideWidth: gw, guideHeight: gh)
    let took = Date().timeIntervalSince(started)
    let blocky = EdgeDepth.nearest(depth: depth, width: dw, height: dh, guideWidth: gw, guideHeight: gh)
    let sharpWrong = wrong(sharp), blockyWrong = wrong(blocky)
    print(String(format: "edges: %d pixels on the wrong side sharpened, %d before, %.0f ms", sharpWrong, blockyWrong, took * 1000))
    check(blockyWrong > 0, "edges: the LiDAR-sized edge is off (\(blockyWrong) pixels)")
    check(sharpWrong * 10 <= blockyWrong, "edges: sharpening puts at least 90% of those pixels right (\(sharpWrong) left)")
    // Along the middle row the edge lands on the box's real edge, within a pixel.
    let row = 175
    let firstNear = (0..<gw).first { sharp[row * gw + $0] < 2.2 } ?? -1
    let lastNear = (0..<gw).last { sharp[row * gw + $0] < 2.2 } ?? -1
    check(abs(Float(firstNear) + 0.5 - left) <= 1 && abs(Float(lastNear) + 0.5 - right) <= 1.5,
          "edges: the box's sides land within a pixel (\(firstNear)...\(lastNear), truth \(left)...\(right))")
    let column = 240
    let topNear = (0..<gh).first { sharp[$0 * gw + column] < 2.2 } ?? -1
    check(abs(Float(topNear) + 0.5 - top) <= 1, "edges: the box's top lands within a pixel (\(topNear), truth \(top))")
    check(!sharp.contains { $0 > 1.7 && $0 < 2.8 }, "edges: no depth halfway between the box and the wall")
    // Box and wall the same brightness: nothing to follow, so no worse than before.
    let flat = picture(box: 128, wall: 128)
    let flatWrong = wrong(EdgeDepth.refine(depth: depth, width: dw, height: dh, guide: flat, guideWidth: gw, guideHeight: gh))
    check(Double(flatWrong) <= Double(blockyWrong) * 1.3, "edges: a picture with no edge to follow is no worse (\(flatWrong) vs \(blockyWrong))")
    // A missing reading in the box is filled from its neighbours.
    var holed = depth
    holed[80 * dw + 100] = 0
    let filled = EdgeDepth.refine(depth: holed, width: dw, height: dh, guide: guide, guideWidth: gw, guideHeight: gh)
    check(abs(filled[(80 * gh / dh) * gw + 100 * gw / dw] - 1.5) < 0.01, "edges: a missing reading is filled from its neighbours")
    check(took < 1.5, "edges: fast enough (\(Int(took * 1000)) ms on the test Mac)")
}

print(failures == 0 ? "All crop tests passed" : "\(failures) crop test(s) failed")
exit(failures == 0 ? 0 : 1)
