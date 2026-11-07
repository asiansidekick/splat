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

print(failures == 0 ? "All crop tests passed" : "\(failures) crop test(s) failed")
exit(failures == 0 ? 0 : 1)
