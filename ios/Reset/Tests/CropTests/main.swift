import Foundation
import simd
import CoreGraphics

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

// OutlineStrips: a picked thing's outline (a disc, and a ring with a hole) as strips, exact to the pixel.
do {
    let w = 400, h = 300
    func disc(_ x: Int, _ y: Int) -> Bool { let dx = Float(x) + 0.5 - 200, dy = Float(y) + 0.5 - 150; return dx * dx + dy * dy < 80 * 80 }
    let strips = OutlineStrips.make(width: w, height: h, stepY: 1, inside: disc)
    var area = 0, truth = 0
    for strip in strips { area += (strip.x1 - strip.x0) * (strip.y1 - strip.y0) }
    for y in 0..<h { for x in 0..<w where disc(x, y) { truth += 1 } }
    check(area == truth, "strips: every pixel of the outline covered, none outside (\(area) of \(truth))")
    check(strips.allSatisfy { s in (s.x0..<s.x1).allSatisfy { disc($0, s.y0) } && !disc(s.x0 - 1, s.y0) && !disc(s.x1, s.y0) }, "strips: each strip starts and ends on the outline's edge")
    func ring(_ x: Int, _ y: Int) -> Bool { let dx = Float(x) + 0.5 - 200, dy = Float(y) + 0.5 - 150; let r = dx * dx + dy * dy; return r < 80 * 80 && r > 30 * 30 }
    let middle = OutlineStrips.make(width: w, height: h, stepY: 1, inside: ring).filter { $0.y0 == 150 }
    check(middle.count == 2, "strips: a hole leaves a gap (\(middle.count) strips across the middle)")
    check(OutlineStrips.make(width: w, height: h, stepY: 2, inside: disc).count * 2 >= strips.count - 2, "strips: every second row halves the strips")
    check(OutlineStrips.make(width: w, height: h, stepY: 1) { _, _ in false }.isEmpty, "strips: nothing picked, nothing drawn")
    let edge = OutlineStrips.make(width: 10, height: 1, stepY: 1) { x, _ in x >= 7 }
    check(edge == [OutlineStrips.Strip(x0: 7, x1: 10, y0: 0, y1: 1)], "strips: a thing at the picture's edge runs to the edge")
}

// Holding still: an edge that flickers between pictures settles on the side it is on most of the time.
do {
    // 6 pictures of a row of 10 pixels: box (1.5 m) on the left 5, wall (3 m) on the right; pixel 4 and 5 flicker.
    var history: [[Float]] = []
    for k in 0..<6 {
        var row = [Float](repeating: 3, count: 10)
        for i in 0..<5 { row[i] = 1.5 }
        if k == 2 { row[4] = 3 }          // the box's last pixel lost once
        if k == 1 || k == 4 { row[5] = 1.5 }  // the wall's first pixel taken twice
        if k == 3 { row[8] = 0 }          // a missing reading once
        history.append(row)
    }
    let steady = EdgeDepth.steady(history)
    check(steady[4] == 1.5 && steady[5] == 3, "still: the flickering edge settles where it is most often (\(steady[4]), \(steady[5]))")
    check(steady[8] == 3, "still: a reading missing once is filled from the others")
    check(EdgeDepth.steady([history[0]]) == history[0], "still: one picture is kept as it is")
    var gone = history
    for k in 0..<4 { gone[k][9] = 0 }
    check(EdgeDepth.steady(gone)[9] == 0, "still: a pixel missing in most pictures stays empty")
    let masks: [[Bool]] = [[true, true, false], [true, false, false], [true, true, false], [true, true, true], [true, true, false]]
    check(OutlineVote.steady(masks) == [true, true, false], "still: a picked outline keeps the shape it has most often")
    check(OutlineVote.steady([[false, true]]) == [false, true], "still: one outline is kept as it is")
}

// Held outline: a picked thing stays in front where Vision misses it, and moves with the camera.
do {
    let lens = HeldOutline.Lens(fx: 100, fy: 100, cx: 50, cy: 40, imageWidth: 100, imageHeight: 80)
    // A 20 x 16 grid (5 pixels a cell); the thing fills cells x 8..<12, y 6..<10, 2 m away.
    var cells = [Bool](repeating: false, count: 20 * 16)
    for y in 6..<10 { for x in 8..<12 { cells[y * 20 + x] = true } }
    let pose = matrix_identity_float4x4
    let held = HeldOutline(cells: cells, width: 20, height: 16, pose: pose, lens: lens, distance: 2)
    check(held.seen(from: pose, lens: lens) == cells, "held: from the same camera the outline is unchanged")
    // Step 0.2 m to the right: a thing 2 m away moves left by 100 * 0.2 / 2 = 10 pixels = 2 cells.
    var right = pose
    right.columns.3 = SIMD4(0.2, 0, 0, 1)
    let moved = held.seen(from: right, lens: lens)
    var expected = [Bool](repeating: false, count: 20 * 16)
    for y in 6..<10 { for x in 6..<10 { expected[y * 20 + x] = true } }
    check(moved == expected, "held: stepping right moves the outline left by the parallax of its distance")
    // Step back 2 m: twice as far, half the size around the centre.
    var back = pose
    back.columns.3 = SIMD4(0, 0, 2, 1)
    let far = held.seen(from: back, lens: lens)
    let count = far.filter { $0 }.count
    check(count >= 3 && count <= 6, "held: stepping back shrinks the outline (\(count) cells of 16)")
    // Turn away: the card is behind the camera and shows nowhere.
    let away = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)))
    check(!held.seen(from: away, lens: lens).contains(true), "held: a card behind the camera hides nothing")
    check(HeldOutline.distance(of: SIMD3(0.3, 0, -1.5), from: pose) == 1.5, "held: the card stands at the touched point's distance")
    // Agreement: Vision's outline of the same thing is taken, half of it or something else is not.
    var half = cells
    for y in 8..<10 { for x in 8..<12 { half[y * 20 + x] = false } }
    var shifted = [Bool](repeating: false, count: 20 * 16)
    for y in 6..<10 { for x in 12..<16 { shifted[y * 20 + x] = true } }
    var grown = cells
    for x in 8..<12 { grown[10 * 20 + x] = true }
    check(HeldOutline.agrees(grown, with: cells), "held: a fresh outline of the same thing is taken")
    check(!HeldOutline.agrees(half, with: cells), "held: half the thing is not taken (the held outline stays)")
    check(!HeldOutline.agrees(shifted, with: cells), "held: something else is not taken")
    check(!HeldOutline.agrees([Bool](repeating: false, count: 20 * 16), with: cells), "held: an empty picture is not taken")
}

// The picked model's tools round the edges (EdgeLayoutMath): on the screen, apart, clear of the middle.
do {
    func tools(_ words: [CGFloat]) -> [CGSize] { words.map { CGSize(width: max(58, $0), height: 42) } }
    // Left: Move Turn Size Rotate Lift Carry Floor Pose. Right: Add, Place here, Pin, In front, True size, Upright, Sizes, Done, Delete.
    let left = tools([58, 58, 58, 58, 58, 58, 58, 58])
    let right = tools([58, 62, 58, 62, 58, 58, 58, 58, 58])
    // iPhone 14 Pro: upright, on its side in the live view, on its side on the Reset screen (more room kept at the top),
    // iPhone SE on its side, iPad.
    let screens: [(name: String, width: CGFloat, height: CGFloat, top: CGFloat)] = [
        ("14 Pro upright", 377, 591, 90), ("14 Pro sideways", 677, 312, 0), ("14 Pro sideways Reset", 677, 312, 40),
        ("SE sideways", 551, 315, 0), ("iPad", 818, 1050, 90),
    ]
    for screen in screens {
        let half = screen.width / 2
        var rects: [CGRect] = []
        // The Reset screen has no Add among them (its own add button waits until Done).
        for (leading, sizes) in [(true, left), (false, screen.top == 40 ? Array(right.dropFirst()) : right)] {
            let points = EdgeLayoutMath.places(sizes: sizes, width: half, height: screen.height, leading: leading, top: screen.top, middle: 124, maxGap: 18)
            check(points.count == sizes.count, "edge tools \(screen.name): every tool has a place")
            for (point, size) in zip(points, sizes) {
                let x = leading ? point.x : point.x + half
                rects.append(CGRect(x: x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height))
            }
        }
        let bounds = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        check(rects.allSatisfy { bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) }, "edge tools \(screen.name): all on the screen")
        var overlaps = 0
        for i in rects.indices { for j in rects.indices where j > i && rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j]) { overlaps += 1 } }
        check(overlaps == 0, "edge tools \(screen.name): no two overlap (\(overlaps))")
        check(rects.allSatisfy { $0.minY >= screen.top - 0.5 }, "edge tools \(screen.name): the top stays free")
        // Every tool stands against an edge: the left, the right, the bottom or the top (narrower ones centred in their column).
        let onEdge = rects.allSatisfy { $0.minX < 10 || $0.maxX > screen.width - 10 || $0.maxY > screen.height - 1 || $0.minY < screen.top + 1 }
        check(onEdge, "edge tools \(screen.name): every tool is against an edge")
        // The middle of the picture (its middle third each way) is clear.
        let centre = CGRect(x: screen.width / 3, y: screen.height / 3, width: screen.width / 3, height: screen.height / 3)
        check(!rects.contains { $0.intersects(centre) }, "edge tools \(screen.name): the middle is clear")
        if screen.name != "SE sideways" {
            let gap = CGRect(x: half - 100, y: screen.height - 42, width: 200, height: 42)
            check(!rects.contains { $0.intersects(gap) }, "edge tools \(screen.name): the finger picture's place at the bottom is clear")
        }
    }
    // Upright the sides hold everything, spread out over most of their height.
    let upright = EdgeLayoutMath.places(sizes: left, width: 188, height: 591, leading: true, top: 90, middle: 124, maxGap: 18)
    check(Set(upright.map(\.x)).count == 1, "edge tools upright: one column")
    check((upright.last!.y - upright.first!.y) > 400, "edge tools upright: spread along the edge (\(Int(upright.last!.y - upright.first!.y)) points)")
    check(EdgeLayoutMath.places(sizes: [], width: 100, height: 100, leading: true, top: 0, middle: 0, maxGap: 18).isEmpty, "edge tools: none is fine")
    // Posing on its side: the pose buttons hold 392 points in the middle of the bottom; the tools keep out of it.
    do {
        for count in [8, 9, 11] {
            let many = tools(Array(repeating: 60, count: count))
            let points = EdgeLayoutMath.places(sizes: many, width: 338, height: 312, leading: true, top: 0, middle: 196, maxGap: 18)
            check(zip(points, many).allSatisfy { $0.x + $1.width / 2 <= 338 - 196 + 0.5 || $0.y < 312 - 42 }, "edge tools posing \(count): the pose row's place is clear")
        }
    }
    // Eleven on one side, on its side: what the bottom has no room for goes along the top (the ring), still apart and clear of the middle.
    do {
        let many = tools(Array(repeating: 60, count: 11))
        let points = EdgeLayoutMath.places(sizes: many, width: 338, height: 312, leading: false, top: 0, middle: 124, maxGap: 18)
        let rects = zip(points, many).map { CGRect(x: $0.x - $1.width / 2, y: $0.y - $1.height / 2, width: $1.width, height: $1.height) }
        var overlaps = 0
        for i in rects.indices { for j in rects.indices where j > i && rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j]) { overlaps += 1 } }
        check(overlaps == 0, "edge tools eleven: no two overlap (\(overlaps))")
        check(rects.contains { $0.minY < 1 && $0.maxX < 338 - 61 }, "edge tools eleven: some go along the top edge")
        check(rects.allSatisfy { $0.minX >= 124 - 0.5 }, "edge tools eleven: the middle stays clear")
    }
}

// Depth strips: a picked rail's outline keeps its edges; depth only says how near each part is.
do {
    // 20 x 2 pixels: the rail fills x 4..<16 on both rows. Row 0 recedes from 1.0 to 1.22 m; row 1 has a hole at 8..<11.
    var depth = [Float](repeating: 3, count: 40)
    for x in 4..<16 { depth[x] = 1 + Float(x - 4) * 0.02; depth[20 + x] = 1 + Float(x - 4) * 0.02 }
    for x in 8..<11 { depth[20 + x] = 0 }
    let strips = DepthStrips.make(width: 20, height: 2, depth: depth, maxRun: 6) { x, _ in x >= 4 && x < 16 }
    let row0 = strips.filter { $0.y == 0 }, row1 = strips.filter { $0.y == 1 }
    check(row0.first?.x0 == 4 && row0.last?.x1 == 16, "depth strips: the outline's edges are kept exactly")
    check(row0.count == 2 && row0[0].x1 == 10, "depth strips: a long run is cut every 6 pixels")
    check(row1.first?.x0 == 4 && row1.last?.x1 == 16 && row1.reduce(0) { $0 + $1.x1 - $1.x0 } == 12, "depth strips: a hole in the depth is filled, not left open")
    check(near(row0[0].d0, 1, 0.001) && near(row0[0].d1, 1.10, 0.001), "depth strips: each run carries the depth at its ends")
    // A jump inside the outline (rail in front of the steps behind) cuts the run.
    var step = [Float](repeating: 1, count: 10)
    for x in 5..<10 { step[x] = 2 }
    let cut = DepthStrips.make(width: 10, height: 1, depth: step, maxRun: 16) { _, _ in true }
    check(cut.count == 2 && cut[0].x1 == 5 && cut[1].d0 == 2, "depth strips: a jump in depth starts a new run")
    check(DepthStrips.make(width: 4, height: 1, depth: [0, 0, 0, 0]) { _, _ in true }.isEmpty, "depth strips: no depth at all gives nothing")
}

// MARK: Head scanning (HeadMath)

do {
    // Lines of sight from a circle of cameras round a head all meet at its middle.
    let middle = SIMD3<Float>(1, 1.6, -2)
    var places: [SIMD3<Float>] = [], looks: [SIMD3<Float>] = []
    for i in 0..<24 {
        let a = Float(i) / 24 * 2 * .pi
        let p = middle + SIMD3(0.5 * cos(a), 0.15 + rng.range(-0.05, 0.05), 0.5 * sin(a))
        var aim = middle + SIMD3(rng.range(-0.01, 0.01), rng.range(-0.01, 0.01), rng.range(-0.01, 0.01)) - p
        aim = simd_normalize(aim)
        places.append(p); looks.append(aim)
    }
    let met = HeadMath.raysMeet(places, looks)
    check(met.map { simd_distance($0, middle) < 0.02 } ?? false, "Head: lines of sight meet at the middle of the head (\(met.map { simd_distance($0, middle) } ?? -1) m off)")
    check(HeadMath.raysMeet([.zero, SIMD3(0.1, 0, 0)], [SIMD3(0, 0, -1), SIMD3(0, 0, -1)]) == nil, "Head: parallel lines of sight give no middle")

    // Head space faces the camera that saw the face, up stays up, left is +X.
    let frame = HeadMath.frame(centre: middle, towards: middle + SIMD3(0, 0.3, 0.5))
    let z = SIMD3(frame.columns.2.x, frame.columns.2.y, frame.columns.2.z), x = SIMD3(frame.columns.0.x, frame.columns.0.y, frame.columns.0.z)
    check(simd_distance(z, SIMD3(0, 0, 1)) < 1e-4 && simd_distance(x, SIMD3(1, 0, 0)) < 1e-4, "Head: head space faces the face's camera, level, left at +X")

    // A camera half a metre in front of the face, looking at it: the middle of the head lands in the middle of the picture.
    var camera = matrix_identity_float4x4
    camera.columns.3 = SIMD4(0, 0, 0.5, 1)
    let c = HeadMath.project(.zero, camera: camera, fx: 1000, fy: 1000, cx: 640, cy: 360)
    let left = HeadMath.project(SIMD3(0.1, 0, 0), camera: camera, fx: 1000, fy: 1000, cx: 640, cy: 360)
    let up = HeadMath.project(SIMD3(0, 0.1, 0), camera: camera, fx: 1000, fy: 1000, cx: 640, cy: 360)
    check(c.map { simd_distance($0, SIMD2(640, 360)) < 0.01 } ?? false, "Head: the middle projects to the middle of the picture")
    check((left?.x ?? 0) > 800 && (up?.y ?? 999) < 200, "Head: +X goes right and +Y goes up the picture (\(String(describing: left)), \(String(describing: up)))")
    check(HeadMath.project(SIMD3(0, 0, 0.9), camera: camera, fx: 1000, fy: 1000, cx: 640, cy: 360) == nil, "Head: a point behind the camera isn't drawn")

    // The outline of a square of points, and which rows of a picture it covers.
    let square: [SIMD2<Float>] = [SIMD2(10, 10), SIMD2(30, 10), SIMD2(30, 30), SIMD2(10, 30), SIMD2(20, 20), SIMD2(15, 25)]
    let hull = HeadMath.hull(square)
    check(hull.count == 4, "Head: a square's outline has 4 corners (\(hull.count))")
    check(HeadMath.inside(SIMD2(20, 20), hull) && !HeadMath.inside(SIMD2(40, 20), hull), "Head: inside and outside the outline")
    let rows = HeadMath.rows(of: hull, width: 50, height: 50)
    check(rows[20].0 == 10 && rows[20].1 == 30 && rows[5].0 > rows[5].1, "Head: rows inside the outline (\(rows[20]), row 5 \(rows[5]))")

    // The space a head can take, seen from in front: an outline round the middle of the picture, wider than a face.
    let shell = HeadMath.headShell(floor: -0.18)
    let outline = HeadMath.hull(shell.compactMap { HeadMath.project($0, camera: camera, fx: 1000, fy: 1000, cx: 640, cy: 360) })
    let across = (outline.map(\.x).max() ?? 0) - (outline.map(\.x).min() ?? 0)
    check(HeadMath.inside(SIMD2(640, 360), outline) && across > 400 && across < 900, "Head: the head's outline sits round the middle, \(Int(across)) px across")
    check(shell.allSatisfy { $0.y >= -0.18 }, "Head: the outline stops at the floor given")

    // Selfie ring: turned to the side lights the side, looking up lights the top, square on lights nothing.
    let slots = 24
    check(HeadMath.selfieSlot(SIMD3(0.35, 0, 0.15), slots: slots) == 0, "Head: head turned to its right lights the ring's right")
    check(HeadMath.selfieSlot(SIMD3(0, -0.2, 0.3), slots: slots) == slots / 4, "Head: head up lights the ring's top")
    check(HeadMath.selfieSlot(SIMD3(0.02, 0.01, 0.4), slots: slots) == nil, "Head: square on lights nothing")
    check(HeadMath.selfieSlot(SIMD3(0.2, 0, 0.35), slots: slots) == nil, "Head: a small turn to the side isn't enough")
    check(HeadMath.roundSlot(camera: SIMD3(1.5, 1.6, -2), centre: middle, slots: slots) == 0, "Head: walking round, the slot follows the way round")

    // A synthetic head: skull, face and jaw, nose, neck. The chin is found 11.5 cm below the middle.
    var head: [SIMD3<Float>] = []
    func blob(_ c: SIMD3<Float>, _ r: SIMD3<Float>, _ n: Int) {
        for _ in 0..<n {
            let u = rng.range(0, 2 * .pi), v = acos(rng.range(-1, 1))
            head.append(c + r * SIMD3(sin(v) * cos(u), cos(v), sin(v) * sin(u)))
        }
    }
    blob(SIMD3(0, 0.02, -0.005), SIMD3(0.095, 0.11, 0.1), 20000)
    blob(SIMD3(0, -0.04, 0.04), SIMD3(0.06, 0.075, 0.055), 15000)
    blob(SIMD3(0, -0.01, 0.095), SIMD3(0.015, 0.025, 0.02), 3000)
    for _ in 0..<15000 {
        let a = rng.range(0, 2 * .pi)
        head.append(SIMD3(0.055 * cos(a), rng.range(-0.25, -0.06), -0.02 + 0.055 * sin(a)))
    }
    let chin = HeadMath.chin(head)
    check(chin.map { abs($0 - -0.115) < 0.02 } ?? false, "Head: chin found from the face's profile (\(chin ?? 0), truly -0.115)")
    let cut = HeadMath.neckCut(head, chin: chin ?? -0.115)
    check(abs(cut.x) < 0.01 && abs(cut.z - (0.115 - 0.12)) < 0.01 && abs(cut.y - ((chin ?? -0.115) - 0.035)) < 1e-4, "Head: neck cut across the middle of the neck (\(cut))")
    check(HeadMath.chin(head.filter { $0.y > 0.05 }) == nil, "Head: no chin found without a face")
}

print(failures == 0 ? "All crop tests passed" : "\(failures) crop test(s) failed")
exit(failures == 0 ? 0 : 1)
