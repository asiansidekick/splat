import Foundation
import simd

// Turning a 3D scan of a person into a posable character (Phil, 2026-11-20: "maps a 3d scan of a person to a fully
// proportioned fbx character to then be used in reset"). Kept free of SceneKit and UIKit so CI can test it on a Mac.
//
// 1. The scan is stood up facing +Z with its left at +X and its feet on y = 0 (the shoulders' line is the widest
//    way across; the feet stick out at the front).
// 2. It is filled in as small cubes (voxels), so "inside the body" is known.
// 3. From the front, the points Mixamo asks people to mark are found: chin, elbows, wrists, knees and groin. The
//    crew can drag them if they are off. The rest of the skeleton follows from those and the body's shape.
// 4. Each point of the skin follows the bones nearest to it through the inside of the body (geodesic voxel
//    binding), so an arm never pulls on the side of the chest it hangs next to.
// 5. It is written as an FBX with Mixamo bone names, which Reset already poses, keeps in the gallery and AirDrops.

/// A scan's shape, as read from its file. Positions in metres, Y up.
struct BodyMesh {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    /// SceneKit's way round: (0, 0) is the top left of the picture. Nil when the scan has no picture.
    var uvs: [SIMD2<Float>]?
    /// Three corners per triangle.
    var triangles: [UInt32]
    struct Part {
        var firstTriangle: Int
        var triangleCount: Int
        /// The picture's file name next to the FBX, or nil for a plain colour.
        var texture: String?
        var color: SIMD3<Float>
    }
    var parts: [Part]

    var triangleCount: Int { triangles.count / 3 }

    /// Normals made from the triangles, for a scan that came without them.
    static func smoothNormals(_ positions: [SIMD3<Float>], _ triangles: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var t = 0
        while t + 2 < triangles.count {
            let a = Int(triangles[t]), b = Int(triangles[t + 1]), c = Int(triangles[t + 2])
            t += 3
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            let n = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        return normals.map { simd_length($0) > 1e-12 ? simd_normalize($0) : SIMD3(0, 1, 0) }
    }
}

enum ScanRig {
    // MARK: The skeleton

    /// Mixamo's names, so every rig tool (Reset's own RigFinder, Blender, Unity, Unreal) knows them.
    static let boneNames = [
        "Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "HeadTop_End",
        "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand", "LeftHandEnd",
        "RightShoulder", "RightArm", "RightForeArm", "RightHand", "RightHandEnd",
        "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase", "LeftToe_End",
        "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase", "RightToe_End",
    ]
    static func bone(_ name: String) -> Int { boneNames.firstIndex(of: name) ?? 0 }
    static let parents: [Int] = boneNames.map { name in
        switch name {
        case "Hips": return -1
        case "Spine": return bone("Hips")
        case "Spine1": return bone("Spine")
        case "Spine2": return bone("Spine1")
        case "Neck": return bone("Spine2")
        case "Head": return bone("Neck")
        case "HeadTop_End": return bone("Head")
        case "LeftShoulder", "RightShoulder": return bone("Spine2")
        case "LeftUpLeg", "RightUpLeg": return bone("Hips")
        default:
            // Down each limb: arm from shoulder, forearm from arm, and so on.
            let chains = [["LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand", "LeftHandEnd"],
                          ["RightShoulder", "RightArm", "RightForeArm", "RightHand", "RightHandEnd"],
                          ["LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase", "LeftToe_End"],
                          ["RightUpLeg", "RightLeg", "RightFoot", "RightToeBase", "RightToe_End"]]
            for chain in chains { if let i = chain.firstIndex(of: name), i > 0 { return bone(chain[i - 1]) } }
            return 0
        }
    }

    /// The bones that move the skin, each laid along one or more stretches between joints.
    static let skinBones: [(bone: Int, segments: [(Int, Int)])] = {
        func b(_ n: String) -> Int { bone(n) }
        var out: [(Int, [(Int, Int)])] = [
            (b("Hips"), [(b("Hips"), b("Spine")), (b("Hips"), b("LeftUpLeg")), (b("Hips"), b("RightUpLeg"))]),
            (b("Spine"), [(b("Spine"), b("Spine1"))]),
            (b("Spine1"), [(b("Spine1"), b("Spine2"))]),
            (b("Spine2"), [(b("Spine2"), b("Neck"))]),
            (b("Neck"), [(b("Neck"), b("Head"))]),
            (b("Head"), [(b("Head"), b("HeadTop_End"))]),
        ]
        for s in ["Left", "Right"] {
            for (from, to) in [("Shoulder", "Arm"), ("Arm", "ForeArm"), ("ForeArm", "Hand"), ("Hand", "HandEnd"),
                               ("UpLeg", "Leg"), ("Leg", "Foot"), ("Foot", "ToeBase"), ("ToeBase", "Toe_End")] {
                out.append((b(s + from), [(b(s + from), b(s + to))]))
            }
        }
        return out.map { (bone: $0.0, segments: $0.1) }
    }()

    // MARK: 1. Standing it up

    /// How the scan is turned and moved so it faces +Z with its feet on the floor.
    struct Stance: Equatable {
        var yaw: Float
        var centre: SIMD2<Float>  // x, z of the middle of the body, before turning
        var low: Float
        var height: Float
        var turned: Bool  // turned round from what the feet said
        /// How far the feet stick out in front of the shins, as a share of the height: small means unsure.
        var feetSignal: Float

        func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let c = cos(-yaw), s = sin(-yaw)
            let x = p.x - centre.x, z = p.z - centre.y
            var X = c * x - s * z, Z = s * x + c * z
            if turned { X = -X; Z = -Z }
            return SIMD3(X, p.y - low, Z)
        }
        func turn(_ n: SIMD3<Float>) -> SIMD3<Float> {
            let c = cos(-yaw), s = sin(-yaw)
            var X = c * n.x - s * n.z, Z = s * n.x + c * n.z
            if turned { X = -X; Z = -Z }
            return SIMD3(X, n.y, Z)
        }
    }

    private static func areasAndCentres(_ positions: [SIMD3<Float>], _ triangles: [UInt32]) -> [(Float, SIMD3<Float>)] {
        var out: [(Float, SIMD3<Float>)] = []
        out.reserveCapacity(triangles.count / 3)
        var t = 0
        while t + 2 < triangles.count {
            let a = positions[Int(triangles[t])], b = positions[Int(triangles[t + 1])], c = positions[Int(triangles[t + 2])]
            t += 3
            out.append((0.5 * simd_length(simd_cross(b - a, c - a)), (a + b + c) / 3))
        }
        return out
    }

    static func stance(of mesh: BodyMesh) -> Stance? {
        guard let first = mesh.positions.first else { return nil }
        var low = first.y, high = first.y
        for p in mesh.positions { low = min(low, p.y); high = max(high, p.y) }
        let height = high - low
        guard height > 0.2 else { return nil }
        let pieces = areasAndCentres(mesh.positions, mesh.triangles)
        // The widest way across, from the hips to the shoulders (arms included), weighted by skin area.
        var total: Float = 0, mean = SIMD2<Float>(0, 0)
        for (area, c) in pieces where c.y - low > 0.45 * height && c.y - low < 0.85 * height {
            total += area; mean += area * SIMD2(c.x, c.z)
        }
        guard total > 0 else { return nil }
        mean /= total
        var a: Float = 0, b: Float = 0, d: Float = 0
        for (area, c) in pieces where c.y - low > 0.45 * height && c.y - low < 0.85 * height {
            let x = c.x - mean.x, z = c.z - mean.y
            a += area * x * x; b += area * x * z; d += area * z * z
        }
        let yaw = 0.5 * atan2(2 * b, a - d)
        var stance = Stance(yaw: yaw, centre: mean, low: low, height: height, turned: false, feetSignal: 0)
        // The feet stick out forwards from the shins.
        var feet: Float = 0, feetArea: Float = 0, shins: Float = 0, shinArea: Float = 0
        for (area, c) in pieces {
            let p = stance.apply(c)
            if p.y < 0.05 * height { feet += area * p.z; feetArea += area }
            if p.y > 0.10 * height, p.y < 0.25 * height { shins += area * p.z; shinArea += area }
        }
        if feetArea > 0, shinArea > 0 {
            let difference = feet / feetArea - shins / shinArea
            stance.turned = difference < 0
            stance.feetSignal = abs(difference) / height
        }
        return stance
    }

    /// The scan stood up: feet on y = 0, facing +Z, its left at +X.
    static func stood(_ mesh: BodyMesh, _ stance: Stance) -> BodyMesh {
        var out = mesh
        out.positions = mesh.positions.map(stance.apply)
        out.normals = mesh.normals.map(stance.turn)
        return out
    }

    /// Phil, 2026-11-20: a good scan of a standing person was refused. A scan can hold stray bits far from the
    /// person (a speck of wall, a far piece of floor) and points no triangle uses, which made the box round it too big
    /// to fill. Keeps the largest connected piece and whatever lies within reach of it; everything else goes.
    /// Returns the mesh and how many triangles were left out.
    static func mainPiece(_ mesh: BodyMesh) -> (BodyMesh, Int) {
        let count = mesh.positions.count
        guard count > 0, mesh.triangles.count >= 3 else { return (mesh, 0) }
        // Points at the same place count as joined (a scan splits them where its photo is cut).
        var key: [SIMD3<Int32>: Int] = [:]
        var place = [Int](repeating: 0, count: count)
        for (i, p) in mesh.positions.enumerated() {
            let k = SIMD3<Int32>(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()), Int32((p.z * 10_000).rounded()))
            if let found = key[k] { place[i] = found } else { key[k] = i; place[i] = i }
        }
        var parent = Array(0..<count)
        func root(_ a: Int) -> Int {
            var a = a
            while parent[a] != a { parent[a] = parent[parent[a]]; a = parent[a] }
            return a
        }
        func join(_ a: Int, _ b: Int) { let ra = root(a), rb = root(b); if ra != rb { parent[ra] = rb } }
        let triangleCount = mesh.triangles.count / 3
        for t in 0..<triangleCount {
            let a = place[Int(mesh.triangles[t * 3])], b = place[Int(mesh.triangles[t * 3 + 1])], c = place[Int(mesh.triangles[t * 3 + 2])]
            join(a, b); join(b, c)
        }
        // Each piece's skin area and box.
        var area: [Int: Float] = [:]
        var low: [Int: SIMD3<Float>] = [:], high: [Int: SIMD3<Float>] = [:]
        var pieceOf = [Int](repeating: 0, count: triangleCount)
        for t in 0..<triangleCount {
            let i = Int(mesh.triangles[t * 3]), j = Int(mesh.triangles[t * 3 + 1]), k = Int(mesh.triangles[t * 3 + 2])
            let a = mesh.positions[i], b = mesh.positions[j], c = mesh.positions[k]
            let r = root(place[i])
            pieceOf[t] = r
            area[r, default: 0] += 0.5 * simd_length(simd_cross(b - a, c - a))
            low[r] = simd_min(low[r] ?? a, simd_min(a, simd_min(b, c)))
            high[r] = simd_max(high[r] ?? a, simd_max(a, simd_max(b, c)))
        }
        guard let biggest = area.max(by: { $0.value < $1.value })?.key, let bigLow = low[biggest], let bigHigh = high[biggest] else { return (mesh, 0) }
        // Within reach: a piece whose box comes within a tenth of the main piece's height of a kept piece's box (a hand
        // or foot the scan cut loose, a hat brim), and so on outwards; a speck across the room never joins.
        let reach = 0.1 * max(0.2, bigHigh.y - bigLow.y)
        func near(_ r: Int, _ k: Int) -> Bool {
            guard let l = low[r], let h = high[r], let kl = low[k], let kh = high[k] else { return false }
            return l.x <= kh.x + reach && h.x >= kl.x - reach && l.y <= kh.y + reach && h.y >= kl.y - reach
                && l.z <= kh.z + reach && h.z >= kl.z - reach
        }
        var keepPiece: [Int: Bool] = [biggest: true]
        var kept = [biggest]
        var waiting = area.keys.filter { $0 != biggest }
        var grew = true
        while grew, !waiting.isEmpty {
            grew = false
            var still: [Int] = []
            for r in waiting {
                if kept.contains(where: { near(r, $0) }) { keepPiece[r] = true; kept.append(r); grew = true } else { still.append(r) }
            }
            waiting = still
        }
        // The kept triangles, with only the points they use.
        var newIndex = [Int32](repeating: -1, count: count)
        var out = BodyMesh(positions: [], normals: [], uvs: mesh.uvs == nil ? nil : [], triangles: [], parts: [])
        var removed = 0
        for part in mesh.parts {
            let first = out.triangles.count / 3
            for t in part.firstTriangle..<min(triangleCount, part.firstTriangle + part.triangleCount) {
                guard keepPiece[pieceOf[t]] == true else { removed += 1; continue }
                for corner in 0..<3 {
                    let c = Int(mesh.triangles[t * 3 + corner])
                    if newIndex[c] < 0 {
                        newIndex[c] = Int32(out.positions.count)
                        out.positions.append(mesh.positions[c])
                        out.normals.append(c < mesh.normals.count ? mesh.normals[c] : SIMD3(0, 1, 0))
                        if let source = mesh.uvs { out.uvs!.append(c < source.count ? source[c] : .zero) }
                    }
                    out.triangles.append(UInt32(newIndex[c]))
                }
            }
            let n = out.triangles.count / 3 - first
            if n > 0 { out.parts.append(BodyMesh.Part(firstTriangle: first, triangleCount: n, texture: part.texture, color: part.color)) }
        }
        return (out, removed)
    }

    /// A scan often keeps a piece of the floor round the feet. When the lowest few centimetres spread much wider than
    /// the ankles, the triangles down there are left out. Returns the number of triangles taken away.
    static func trimFloor(_ mesh: inout BodyMesh) -> Int {
        guard let first = mesh.positions.first else { return 0 }
        var low = first.y, high = first.y
        for p in mesh.positions { low = min(low, p.y); high = max(high, p.y) }
        let height = high - low
        guard height > 0.3 else { return 0 }
        func spread(_ from: Float, _ to: Float) -> Float {
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for p in mesh.positions where p.y - low >= from && p.y - low < to {
                lo = simd_min(lo, SIMD2(p.x, p.z)); hi = simd_max(hi, SIMD2(p.x, p.z))
            }
            return hi.x >= lo.x ? max(hi.x - lo.x, hi.y - lo.y) : 0
        }
        let ankles = spread(0.08 * height, 0.14 * height)
        guard ankles > 0 else { return 0 }
        var cut: Float = -1
        var y: Float = 0
        while y < 0.06 * height {
            if spread(y, y + 0.01) > 1.8 * ankles { cut = y + 0.01 }
            y += 0.01
        }
        guard cut > 0 else { return 0 }
        var kept: [UInt32] = []
        kept.reserveCapacity(mesh.triangles.count)
        var parts = mesh.parts
        var removed = 0
        for (index, part) in mesh.parts.enumerated() {
            let start = kept.count / 3
            for t in part.firstTriangle..<(part.firstTriangle + part.triangleCount) {
                let corners = (0..<3).map { Int(mesh.triangles[t * 3 + $0]) }
                if corners.allSatisfy({ mesh.positions[$0].y - low < cut }) { removed += 1; continue }
                kept.append(contentsOf: corners.map { UInt32($0) })
            }
            parts[index].firstTriangle = start
            parts[index].triangleCount = kept.count / 3 - start
        }
        mesh.triangles = kept
        mesh.parts = parts.filter { $0.triangleCount > 0 }
        return removed
    }

    /// Phil, 2026-11-20: scraps of floor left round the feet after trimFloor (a ragged patch rises a few centimetres
    /// in places) pulled the joint finder off the feet. Low triangles away from where the legs come down are left out:
    /// anything under 6 % of the height that is not under a leg or just in front of or behind it, where the feet are.
    /// Stood up first (feet on y = 0, facing +Z). Returns the number of triangles taken away.
    static func trimAroundFeet(_ mesh: inout BodyMesh) -> Int {
        guard let first = mesh.positions.first else { return 0 }
        var low = first.y, high = first.y
        for p in mesh.positions { low = min(low, p.y); high = max(high, p.y) }
        let H = high - low
        guard H > 0.3 else { return 0 }
        // Where the legs are, just above the ankles.
        var legs: [SIMD2<Float>] = []
        for p in mesh.positions where p.y - low > 0.07 * H && p.y - low < 0.14 * H { legs.append(SIMD2(p.x, p.z)) }
        guard legs.count >= 8 else { return 0 }
        if legs.count > 1500 { legs = stride(from: 0, to: legs.count, by: legs.count / 1500 + 1).map { legs[$0] } }
        let side = 0.06 * H, back = 0.16 * H, ahead = 0.18 * H  // either way round: the front may not be known yet
        func underLegs(_ p: SIMD3<Float>) -> Bool {
            legs.contains { l in abs(p.x - l.x) < side && p.z - l.y > -back && p.z - l.y < ahead }
        }
        var removed = 0
        var keep = [Bool](repeating: true, count: mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.triangles[t * 3])], b = mesh.positions[Int(mesh.triangles[t * 3 + 1])], c = mesh.positions[Int(mesh.triangles[t * 3 + 2])]
            guard max(a.y, b.y, c.y) - low < 0.06 * H else { continue }
            if !underLegs((a + b + c) / 3) { keep[t] = false; removed += 1 }
        }
        guard removed > 0 else { return 0 }
        mesh = part(of: mesh) { t, _ in keep[t] }
        return removed
    }

    // MARK: 2. Inside the body

    /// The space round the body cut into cubes of `size`, each inside the body or not.
    final class Voxels {
        let size: Float
        let origin: SIMD3<Float>
        let nx: Int, ny: Int, nz: Int
        private(set) var solid: [Bool]
        private(set) var shellCount = 0
        private(set) var solidCount = 0
        /// True when the scan had holes and was closed with a thicker skin.
        private(set) var closed = false

        @inline(__always) func index(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }
        @inline(__always) func inside(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz && solid[index(i, j, k)]
        }
        func cell(_ p: SIMD3<Float>) -> SIMD3<Int> {
            let q = (p - origin) / size
            return SIMD3(Int(floor(q.x)), Int(floor(q.y)), Int(floor(q.z)))
        }
        func x(_ i: Float) -> Float { origin.x + (i + 0.5) * size }
        func y(_ j: Float) -> Float { origin.y + (j + 0.5) * size }
        func i(_ x: Float) -> Int { Int(floor((x - origin.x) / size)) }
        func j(_ y: Float) -> Int { Int(floor((y - origin.y) / size)) }

        /// Cubes a 150th of the height, or bigger when the scan is very wide (a big piece of floor or arms far out),
        /// so the box always fits in memory.
        static func fitting(_ mesh: BodyMesh, height: Float) -> Voxels? {
            guard let first = mesh.positions.first else { return nil }
            var lo = first, hi = first
            for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            let box = hi - lo
            var size = height / 150
            while size < height / 40 {
                let n = (box + SIMD3(repeating: 5 * size)) / size
                if (n.x + 1) * (n.y + 1) * (n.z + 1) < 11_500_000 { break }
                size *= 1.15
            }
            return Voxels(mesh, size: size)
        }

        init?(_ mesh: BodyMesh, size: Float) {
            guard size > 0, let first = mesh.positions.first else { return nil }
            var lo = first, hi = first
            for p in mesh.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            self.size = size
            origin = lo - SIMD3(repeating: 2.5 * size)
            let n = (hi + SIMD3(repeating: 2.5 * size) - origin) / size
            nx = Int(ceil(n.x)); ny = Int(ceil(n.y)); nz = Int(ceil(n.z))
            guard nx > 2, ny > 2, nz > 2, nx * ny * nz < 12_000_000 else { return nil }
            solid = []
            var shell = [Bool](repeating: false, count: nx * ny * nz)
            var t = 0
            let tris = mesh.triangles, pos = mesh.positions
            while t + 2 < tris.count {
                let a = pos[Int(tris[t])], b = pos[Int(tris[t + 1])], c = pos[Int(tris[t + 2])]
                t += 3
                let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
                let steps = max(1, min(64, Int(ceil(longest / (0.5 * size)))))
                let ab = b - a, ac = c - a
                for u in 0...steps {
                    for v in 0...(steps - u) {
                        let p = a + ab * (Float(u) / Float(steps)) + ac * (Float(v) / Float(steps))
                        let q = (p - origin) / size
                        let ci = Int(q.x), cj = Int(q.y), ck = Int(q.z)
                        if ci >= 0, cj >= 0, ck >= 0, ci < nx, cj < ny, ck < nz { shell[ci + nx * (cj + ny * ck)] = true }
                    }
                }
            }
            shellCount = shell.reduce(0) { $1 ? $0 + 1 : $0 }
            var filled = Self.notOutside(shell, nx, ny, nz)
            var count = filled.reduce(0) { $1 ? $0 + 1 : $0 }
            if Float(count) < 1.4 * Float(shellCount) {
                // The outside got in through holes in the scan: close them with a skin one cube thicker, then give
                // that cube back.
                let thick = Self.grow(shell, nx, ny, nz)
                let outside = Self.grow(Self.notOutside(thick, nx, ny, nz).map { !$0 }, nx, ny, nz)
                filled = outside.map { !$0 }
                count = filled.reduce(0) { $1 ? $0 + 1 : $0 }
                closed = true
            }
            solid = filled
            solidCount = count
            guard count > 0 else { return nil }
        }

        /// Everything the outside can't reach from the edge of the box without crossing `wall`.
        private static func notOutside(_ wall: [Bool], _ nx: Int, _ ny: Int, _ nz: Int) -> [Bool] {
            var outside = [Bool](repeating: false, count: wall.count)
            var queue: [Int32] = []
            queue.reserveCapacity(wall.count / 2)
            func push(_ i: Int, _ j: Int, _ k: Int) {
                let at = i + nx * (j + ny * k)
                if !wall[at], !outside[at] { outside[at] = true; queue.append(Int32(at)) }
            }
            for i in 0..<nx { for j in 0..<ny { push(i, j, 0); push(i, j, nz - 1) } }
            for i in 0..<nx { for k in 0..<nz { push(i, 0, k); push(i, ny - 1, k) } }
            for j in 0..<ny { for k in 0..<nz { push(0, j, k); push(nx - 1, j, k) } }
            var head = 0
            while head < queue.count {
                let at = Int(queue[head]); head += 1
                let i = at % nx, j = (at / nx) % ny, k = at / (nx * ny)
                if i > 0 { push(i - 1, j, k) }
                if i < nx - 1 { push(i + 1, j, k) }
                if j > 0 { push(i, j - 1, k) }
                if j < ny - 1 { push(i, j + 1, k) }
                if k > 0 { push(i, j, k - 1) }
                if k < nz - 1 { push(i, j, k + 1) }
            }
            return outside.map { !$0 }
        }

        /// One cube wider in the six directions.
        private static func grow(_ g: [Bool], _ nx: Int, _ ny: Int, _ nz: Int) -> [Bool] {
            var out = g
            for k in 0..<nz {
                for j in 0..<ny {
                    for i in 0..<nx where g[i + nx * (j + ny * k)] {
                        if i > 0 { out[i - 1 + nx * (j + ny * k)] = true }
                        if i < nx - 1 { out[i + 1 + nx * (j + ny * k)] = true }
                        if j > 0 { out[i + nx * (j - 1 + ny * k)] = true }
                        if j < ny - 1 { out[i + nx * (j + 1 + ny * k)] = true }
                        if k > 0 { out[i + nx * (j + ny * (k - 1))] = true }
                        if k < nz - 1 { out[i + nx * (j + ny * (k + 1))] = true }
                    }
                }
            }
            return out
        }

        /// The body seen from the front: x across, y up.
        lazy var front: [Bool] = {
            var out = [Bool](repeating: false, count: nx * ny)
            for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where solid[index(i, j, k)] { out[i + nx * j] = true } } }
            return out
        }()
        func seen(_ i: Int, _ j: Int) -> Bool { i >= 0 && j >= 0 && i < nx && j < ny && front[i + nx * j] }

        /// The middle of the body front to back at (x, y), looking a cube or two round it; nil when nothing is there.
        func middleDepth(_ x: Float, _ y: Float) -> Float? {
            let ci = i(x), cj = j(y)
            for (di, dj) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-2, 0), (2, 0), (0, -2), (0, 2)] {
                let a = ci + di, b = cj + dj
                guard a >= 0, b >= 0, a < nx, b < ny else { continue }
                var first = -1, last = -1
                for k in 0..<nz where solid[index(a, b, k)] {
                    if first < 0 { first = k }
                    last = k
                }
                if first >= 0 { return origin.z + Float(first + last + 1) / 2 * size }
            }
            return nil
        }

        /// The stretch of the front view's row through (x, y) that holds x, in metres; nil when x is outside.
        func run(_ x: Float, _ y: Float) -> (Float, Float)? {
            guard let r = ScanRig.run(self, i(x), j(y)) else { return nil }
            return (origin.x + Float(r.0) * size, origin.x + Float(r.1 + 1) * size)
        }
    }

    static func run(_ v: Voxels, _ i: Int, _ j: Int) -> (Int, Int)? {
        guard v.seen(i, j) else { return nil }
        var a = i, b = i
        while v.seen(a - 1, j) { a -= 1 }
        while v.seen(b + 1, j) { b += 1 }
        return (a, b)
    }

    // MARK: 3. The marks

    /// The points Mixamo asks people to place, seen from the front (x across, y up, metres).
    struct Marks: Equatable, Codable {
        var chin = SIMD2<Float>(0, 0)
        var groin = SIMD2<Float>(0, 0)
        var elbowL = SIMD2<Float>(0, 0), elbowR = SIMD2<Float>(0, 0)
        var wristL = SIMD2<Float>(0, 0), wristR = SIMD2<Float>(0, 0)
        var kneeL = SIMD2<Float>(0, 0), kneeR = SIMD2<Float>(0, 0)
        /// Phil, 2026-11-20: "I can't move the top of the skeleton". Zero: worked out from the chin and the chest.
        var shoulderL = SIMD2<Float>(0, 0), shoulderR = SIMD2<Float>(0, 0)

        enum Name: String, CaseIterable, Identifiable {
            case chin, shoulderL, shoulderR, groin, elbowL, elbowR, wristL, wristR, kneeL, kneeR
            var id: String { rawValue }
            /// What the dot says on screen.
            var word: String {
                switch self {
                case .chin: return "Chin"
                case .shoulderL, .shoulderR: return "Shoulder"
                case .groin: return "Groin"
                case .elbowL, .elbowR: return "Elbow"
                case .wristL, .wristR: return "Wrist"
                case .kneeL, .kneeR: return "Knee"
                }
            }
        }
        subscript(_ name: Name) -> SIMD2<Float> {
            get {
                switch name {
                case .chin: return chin
                case .shoulderL: return shoulderL
                case .shoulderR: return shoulderR
                case .groin: return groin
                case .elbowL: return elbowL
                case .elbowR: return elbowR
                case .wristL: return wristL
                case .wristR: return wristR
                case .kneeL: return kneeL
                case .kneeR: return kneeR
                }
            }
            set {
                switch name {
                case .chin: chin = newValue
                case .shoulderL: shoulderL = newValue
                case .shoulderR: shoulderR = newValue
                case .groin: groin = newValue
                case .elbowL: elbowL = newValue
                case .elbowR: elbowR = newValue
                case .wristL: wristL = newValue
                case .wristR: wristR = newValue
                case .kneeL: kneeL = newValue
                case .kneeR: kneeR = newValue
                }
            }
        }
    }

    struct Found {
        var marks: Marks
        var handsFound: Bool
        var groinFound: Bool
        /// The top of the head, the lowest point, and the middle of the body across, in metres.
        var top: Float
        var bottom: Float
        var middle: Float
    }

    /// A small binary heap of (distance, cell) for the shortest-path searches.
    struct Heap {
        private var keys: [Float] = []
        private var values: [Int32] = []
        var isEmpty: Bool { keys.isEmpty }
        mutating func push(_ key: Float, _ value: Int32) {
            keys.append(key); values.append(value)
            var c = keys.count - 1
            while c > 0 {
                let p = (c - 1) / 2
                guard keys[p] > keys[c] else { break }
                keys.swapAt(p, c); values.swapAt(p, c); c = p
            }
        }
        mutating func pop() -> (Float, Int32)? {
            guard let key = keys.first, let value = values.first else { return nil }
            let lastKey = keys.removeLast(), lastValue = values.removeLast()
            if !keys.isEmpty {
                keys[0] = lastKey; values[0] = lastValue
                var p = 0
                while true {
                    let l = 2 * p + 1, r = l + 1
                    var m = p
                    if l < keys.count, keys[l] < keys[m] { m = l }
                    if r < keys.count, keys[r] < keys[m] { m = r }
                    if m == p { break }
                    keys.swapAt(p, m); values.swapAt(p, m); p = m
                }
            }
            return (key, value)
        }
    }

    /// Shortest paths through the front view from `seeds`: distance in cubes, and the step back towards the seeds.
    static func paths(_ v: Voxels, from seeds: [Int]) -> (distance: [Float], back: [Int32]) {
        let nx = v.nx, ny = v.ny
        var distance = [Float](repeating: .infinity, count: nx * ny)
        var back = [Int32](repeating: -1, count: nx * ny)
        var heap = Heap()
        for s in seeds where s >= 0 && s < distance.count { distance[s] = 0; heap.push(0, Int32(s)) }
        let steps: [(Int, Int, Float)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1), (1, 1, 1.4142), (1, -1, 1.4142), (-1, 1, 1.4142), (-1, -1, 1.4142)]
        while let item = heap.pop() {
            let (d, at32) = item
            let at = Int(at32)
            if d > distance[at] { continue }
            let i = at % nx, j = at / nx
            for (di, dj, w) in steps {
                let a = i + di, b = j + dj
                guard v.seen(a, b) else { continue }
                let to = a + nx * b
                if d + w < distance[to] { distance[to] = d + w; back[to] = Int32(at); heap.push(d + w, Int32(to)) }
            }
        }
        return (distance, back)
    }

    /// Finds the chin, elbows, wrists, knees and groin from the body's outline, the way a person would mark them on
    /// Mixamo. Works best on a scan of someone standing with arms a little out from the body and feet apart.
    static func findMarks(_ v: Voxels) -> Found? {
        let nx = v.nx, ny = v.ny
        var top = -1, bottom = ny
        for j in 0..<ny { for i in 0..<nx where v.front[i + nx * j] { top = max(top, j); bottom = min(bottom, j); break } }
        guard top > bottom + 20 else { return nil }
        let tall = Float(top - bottom + 1)
        func row(_ share: Float) -> Int { bottom + Int(share * tall) }

        // The middle of the chest: the widest stretch near 62 % of the height, round the body's middle.
        let middleColumn = v.i(0)
        var chest: (j: Int, a: Int, b: Int)?
        for dj in -3...3 {
            let j = row(0.62) + dj
            var i = middleColumn
            if !v.seen(i, j) {
                // The middle is empty at this height (rare): the nearest filled cube on the row.
                var best = -1
                for k in 0..<nx where v.seen(k, j) && (best < 0 || abs(k - middleColumn) < abs(best - middleColumn)) { best = k }
                i = best
            }
            if let r = run(v, i, j), chest == nil || r.1 - r.0 > chest!.b - chest!.a { chest = (j, r.0, r.1) }
        }
        guard let chest else { return nil }
        let seed = (chest.a + chest.b) / 2 + nx * chest.j
        let fromChest = paths(v, from: [seed])
        var tops: [Int] = []
        for i in 0..<nx where v.seen(i, top) { tops.append(i) }
        let headColumn = tops.isEmpty ? seed % nx : tops[tops.count / 2]
        let headTop = headColumn + nx * top

        // The ends furthest along the body from the chest and head, and from each other: hands and feet. A few more
        // than four are found, so a loose bit (a scrap of floor, a strap) can't push a hand or foot out.
        var found = [seed, headTop]
        var ends: [Int] = []
        for _ in 0..<7 {
            let d = paths(v, from: found).distance
            var best = -1
            var far: Float = -1
            for (at, value) in d.enumerated() where value.isFinite && value > far { far = value; best = at }
            guard best >= 0 else { break }
            ends.append(best); found.append(best)
        }
        guard ends.count >= 4 else { return nil }
        let seedI = seed % nx
        func up(_ at: Int) -> Float { Float(at / nx - bottom) / tall }
        // Ends come furthest first. A hand is the furthest end on its side, up off the floor; a foot the furthest low
        // end on its side, near the body.
        let lowEnds = ends.filter { up($0) < 0.15 }
        let highEnds = ends.filter { up($0) > 0.3 }
        let chestWidth = Float(chest.b - chest.a + 1)
        let nearFeet = lowEnds.filter { abs(Float($0 % nx - seedI)) < 1.2 * chestWidth }
        var footR = nearFeet.first { $0 % nx < seedI }, footL = nearFeet.first { $0 % nx >= seedI }
        if footR == nil || footL == nil {
            // Feet together, or both one side of the middle: the two furthest low ends.
            let two = Array((nearFeet.isEmpty ? lowEnds : nearFeet).prefix(2)).sorted { $0 % nx < $1 % nx }
            if two.count == 2 { footR = two[0]; footL = two[1] }
        }
        var handR = highEnds.first { $0 % nx < seedI }, handL = highEnds.first { $0 % nx > seedI }
        let handsFound = handR != nil && handL != nil && footR != nil && footL != nil
        // A hand not found takes the other hand's place, mirrored across the middle of the chest.
        func mirrored(_ at: Int) -> Int { min(nx - 1, max(0, 2 * seedI - at % nx)) + nx * (at / nx) }
        if handR == nil, let other = handL, v.seen(mirrored(other) % nx, mirrored(other) / nx) { handR = mirrored(other) }
        if handL == nil, let other = handR, v.seen(mirrored(other) % nx, mirrored(other) / nx) { handL = mirrored(other) }
        guard let handRight = handR, let handLeft = handL, let footRight = footR, let footLeft = footL else { return nil }
        let feet = [footRight, footLeft]
        let hands = [handRight, handLeft]  // first on the image's left: the person's right

        func point(_ at: Int) -> SIMD2<Float> { SIMD2(Float(at % nx), Float(at / nx)) }
        func metres(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(v.x(p.x), v.y(p.y)) }
        func walkBack(_ end: Int) -> [SIMD2<Float>] {
            var out = [point(end)]
            var at = end
            var guardCount = 0
            while fromChest.back[at] >= 0, guardCount < nx * ny {
                at = Int(fromChest.back[at]); out.append(point(at)); guardCount += 1
            }
            return out
        }
        func along(_ line: [SIMD2<Float>], from start: Int, _ length: Float) -> Int {
            var total: Float = 0
            var i = start
            while i < line.count - 1 {
                total += simd_distance(line[i], line[i + 1])
                if total >= length { return i + 1 }
                i += 1
            }
            return max(0, line.count - 1)
        }
        /// The middle of the limb across its width at line[i].
        func centred(_ line: [SIMD2<Float>], _ i: Int) -> SIMD2<Float> {
            let a = line[max(0, i - 4)], b = line[min(line.count - 1, i + 4)]
            var d = b - a
            if simd_length(d) < 1e-6 { d = SIMD2(0, 1) }
            let n = simd_normalize(SIMD2(-d.y, d.x))
            func reach(_ sign: Float) -> Float {
                var t: Float = 0
                while t < 0.1 * tall {
                    let q = line[i] + n * (t + 0.5) * sign
                    if !v.seen(Int(q.x.rounded()), Int(q.y.rounded())) { break }
                    t += 0.5
                }
                return t
            }
            return line[i] + n * (reach(1) - reach(-1)) / 2
        }

        var marks = Marks()
        for (index, hand) in hands.enumerated() {
            let line = walkBack(hand)
            let wrist = along(line, from: 0, 0.105 * tall)
            let elbow = along(line, from: wrist, 0.15 * tall)
            if index == 0 {
                marks.wristR = metres(centred(line, wrist)); marks.elbowR = metres(centred(line, elbow))
            } else {
                marks.wristL = metres(centred(line, wrist)); marks.elbowL = metres(centred(line, elbow))
            }
        }

        // The groin: the top of the gap between the legs.
        let between = (feet[0] % nx + feet[1] % nx) / 2
        let waist = row(0.62)
        var groin = -1
        for j in bottom..<waist where (j..<waist).allSatisfy({ v.seen(between, $0) }) { groin = j; break }
        var groinFound = true
        if groin < 0 || Float(groin - bottom) < 0.38 * tall || Float(groin - bottom) > 0.56 * tall {
            groin = row(0.47)
            groinFound = false
        }
        marks.groin = metres(SIMD2(Float(between), Float(groin)))

        // The chin: just above the narrowest part of the neck.
        func width(_ j: Int) -> Int {
            if let r = run(v, seedI, j) ?? run(v, headColumn, j) { return r.1 - r.0 + 1 }
            return 0
        }
        var narrowest = Int.max, neck = row(0.85)
        for j in row(0.78)..<max(row(0.78) + 1, row(0.93)) {
            let w = width(j)
            if w > 0, w < narrowest { narrowest = w; neck = j }
        }
        var chin = neck
        if narrowest < Int.max {
            for j in neck..<min(row(0.93) + 1, neck + max(1, Int(0.06 * tall))) where Float(width(j)) > 1.25 * Float(narrowest) { chin = j; break }
        }
        marks.chin = metres(SIMD2(Float(headColumn), Float(chin)))

        // The knees: halfway between hip and ankle, in the middle of each leg.
        let hipRow = Float(groin) + 0.045 * tall, ankleRow = Float(bottom) + 0.048 * tall
        let kneeRow = Int((ankleRow + 0.5 * (hipRow - ankleRow)).rounded())
        for (index, foot) in feet.enumerated() {
            let right = index == 0
            var columns: [Int] = []
            for i in 0..<nx where v.seen(i, kneeRow) && (right ? i < between : i > between) { columns.append(i) }
            if columns.isEmpty { for i in 0..<nx where v.seen(i, kneeRow) { columns.append(i) } }
            var x = Float(foot % nx)
            if let nearest = columns.min(by: { abs($0 - foot % nx) < abs($1 - foot % nx) }), let r = run(v, nearest, kneeRow) {
                x = Float(r.0 + r.1) / 2
                if r.0 < between, between < r.1 { x = right ? Float(r.0 + between) / 2 : Float(between + r.1) / 2 }  // legs together
            }
            if right { marks.kneeR = metres(SIMD2(x, Float(kneeRow))) } else { marks.kneeL = metres(SIMD2(x, Float(kneeRow))) }
        }
        return Found(marks: marks, handsFound: handsFound, groinFound: groinFound, top: v.y(Float(top)) + v.size / 2,
                     bottom: v.y(Float(bottom)) - v.size / 2, middle: v.x(Float(seedI)))
    }

    /// Where the marks go on a body the outline gave nothing for: an average person's proportions.
    static func averageMarks(height: Float, middle: Float) -> Marks {
        var m = Marks()
        m.chin = SIMD2(middle, 0.87 * height)
        m.groin = SIMD2(middle, 0.47 * height)
        m.elbowL = SIMD2(middle + 0.19 * height, 0.66 * height); m.elbowR = SIMD2(middle - 0.19 * height, 0.66 * height)
        m.wristL = SIMD2(middle + 0.28 * height, 0.55 * height); m.wristR = SIMD2(middle - 0.28 * height, 0.55 * height)
        m.kneeL = SIMD2(middle + 0.05 * height, 0.29 * height); m.kneeR = SIMD2(middle - 0.05 * height, 0.29 * height)
        m.shoulderL = SIMD2(middle + 0.11 * height, 0.81 * height); m.shoulderR = SIMD2(middle - 0.11 * height, 0.81 * height)
        return m
    }

    // MARK: 4. The joints

    /// Every joint in boneNames order, in the stood-up scan's space.
    static func joints(_ marks: Marks, _ v: Voxels, height: Float) -> [SIMD3<Float>] {
        let H = height
        var J = [SIMD3<Float>](repeating: .zero, count: boneNames.count)
        func set(_ name: String, _ p: SIMD3<Float>) { J[bone(name)] = p }
        func get(_ name: String) -> SIMD3<Float> { J[bone(name)] }
        let gx = marks.groin.x, gy = marks.groin.y, cy = marks.chin.y
        let hipY = gy + 0.045 * H
        let middleZ = v.middleDepth(gx, hipY) ?? 0
        func depth(_ x: Float, _ y: Float, _ fallback: Float) -> Float { v.middleDepth(x, y) ?? fallback }
        set("Hips", SIMD3(gx, hipY + 0.03 * H, middleZ))

        // Legs.
        for (side, knee) in [("Left", marks.kneeL), ("Right", marks.kneeR)] {
            let sign: Float = side == "Left" ? 1 : -1
            var hipX = gx + sign * 0.055 * H
            if let r = v.run((gx + knee.x) / 2, gy - 0.03 * H), sign > 0 ? r.0 > gx - 0.01 : r.1 < gx + 0.01 { hipX = (r.0 + r.1) / 2 }
            let low = gx + sign * 0.035 * H, high = gx + sign * 0.08 * H
            hipX = min(max(hipX, min(low, high)), max(low, high))
            set(side + "UpLeg", SIMD3(hipX, hipY, middleZ))
            set(side + "Leg", SIMD3(knee.x, knee.y, depth(knee.x, knee.y, middleZ)))
            // The ankle: on down the thigh-to-knee line to ankle height, then in the middle of the leg.
            let ankleY = 0.048 * H
            let thigh = SIMD2(knee.x - hipX, knee.y - hipY)
            var ankleX = abs(thigh.y) > 1e-5 ? knee.x + thigh.x / thigh.y * (ankleY - knee.y) : knee.x
            if let r = v.run(ankleX, ankleY) { ankleX = (r.0 + r.1) / 2 }
            let ankleZ = depth(ankleX, ankleY, middleZ)
            set(side + "Foot", SIMD3(ankleX, ankleY, ankleZ))
            // The toes: the furthest forward the body reaches low down on this side.
            var front = -Float.greatestFiniteMagnitude
            let lowRows = max(1, v.j(0.03 * H))
            for k in 0..<v.nz {
                for j in 0..<min(lowRows, v.ny) {
                    for i in 0..<v.nx where v.solid[v.index(i, j, k)] {
                        let x = v.x(Float(i))
                        if sign > 0 ? x > gx : x < gx { front = max(front, v.origin.z + Float(k + 1) * v.size) }
                    }
                }
            }
            if front < ankleZ + 0.03 * H { front = ankleZ + 0.15 * H }
            set(side + "ToeBase", SIMD3(ankleX, 0.012 * H, ankleZ + 0.62 * (front - ankleZ)))
            set(side + "Toe_End", SIMD3(ankleX, 0.012 * H, front))
        }

        // Spine, neck and head.
        let hips = get("Hips")
        let shoulderY = cy - 0.06 * H
        for (name, share) in [("Spine", Float(0.25)), ("Spine1", 0.5), ("Spine2", 0.75)] {
            let y = hips.y + (shoulderY - hips.y) * share
            set(name, SIMD3(gx, y, depth(gx, y, middleZ)))
        }
        let neckY = cy - 0.035 * H
        set("Neck", SIMD3(gx, neckY, depth(gx, neckY, middleZ)))
        set("Head", SIMD3(marks.chin.x, cy + 0.01 * H, depth(marks.chin.x, cy + 0.02 * H, middleZ)))
        var headTop: Float = cy + 0.13 * H
        for j in stride(from: v.ny - 1, through: 0, by: -1) where (0..<v.nx).contains(where: { v.seen($0, j) }) {
            headTop = v.y(Float(j)) + v.size / 2
            break
        }
        let head = get("Head")
        set("HeadTop_End", SIMD3(head.x, max(headTop, head.y + 0.05 * H), head.z))

        // Arms.
        let across = v.run(gx, shoulderY - 0.02 * H)
        for side in ["Left", "Right"] {
            let sign: Float = side == "Left" ? 1 : -1
            let half = across.map { sign > 0 ? $0.1 - gx : gx - $0.0 } ?? 0.12 * H
            let reach = min(max(half - 0.035 * H, 0.06 * H), 0.13 * H)
            var shoulderX = gx + sign * reach
            var armY = shoulderY
            let given = side == "Left" ? marks.shoulderL : marks.shoulderR
            if given != .zero { shoulderX = given.x; armY = given.y }
            let elbow = side == "Left" ? marks.elbowL : marks.elbowR
            let wrist = side == "Left" ? marks.wristL : marks.wristR
            let chestZ = depth(gx, shoulderY, middleZ)
            set(side + "Shoulder", SIMD3(gx + 0.25 * (shoulderX - gx), armY + 0.005 * H, chestZ))
            let arm = SIMD3(shoulderX, armY, depth(shoulderX, armY, chestZ))
            set(side + "Arm", arm)
            let fore = SIMD3(elbow.x, elbow.y, depth(elbow.x, elbow.y, arm.z))
            set(side + "ForeArm", fore)
            let hand = SIMD3(wrist.x, wrist.y, depth(wrist.x, wrist.y, fore.z))
            set(side + "Hand", hand)
            let d = hand - fore
            set(side + "HandEnd", hand + (simd_length(d) > 1e-5 ? simd_normalize(d) : SIMD3(0, -1, 0)) * 0.09 * H)
        }
        return J
    }

    // MARK: 5. Skin weights

    struct Skin {
        /// Four per corner of the mesh: an index into skinBones, and how much it pulls (adding up to 1).
        var bones: [SIMD4<UInt16>]
        var weights: [SIMD4<Float>]
        /// Corners no bone could reach through the body (loose bits of the scan): they follow the hips.
        var loose: Int
        /// Which corners a bone reached.
        var reached: [Bool] = []
    }

    /// Phil, 2026-11-20: bits of floor left round the feet stayed behind as white shards. Triangles with a corner no
    /// bone could reach through the body are islands apart from the person: they are left out.
    static func withoutIslands(_ mesh: BodyMesh, _ skin: Skin) -> BodyMesh {
        guard skin.loose > 0, skin.reached.count == mesh.positions.count else { return mesh }
        let reached = skin.reached
        var keepTriangle = [Bool](repeating: true, count: mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            keepTriangle[t] = reached[Int(mesh.triangles[t * 3])] && reached[Int(mesh.triangles[t * 3 + 1])] && reached[Int(mesh.triangles[t * 3 + 2])]
        }
        return part(of: mesh) { t, _ in keepTriangle[t] }
    }

    /// Geodesic voxel binding: each bone's distance through the inside of the body to every cube, then each corner
    /// is pulled by the nearest bones, falling off with the fourth power of that distance.
    static func skin(_ mesh: BodyMesh, joints J: [SIMD3<Float>], _ v: Voxels) -> Skin {
        // Only the cubes inside the body take part.
        var compact = [Int32](repeating: -1, count: v.nx * v.ny * v.nz)
        var cells: [Int32] = []
        cells.reserveCapacity(v.solidCount)
        for (at, inside) in v.solid.enumerated() where inside { compact[at] = Int32(cells.count); cells.append(Int32(at)) }
        let count = cells.count
        let boneCount = skinBones.count
        var distance = [Float](repeating: .infinity, count: count * boneCount)
        var steps: [(Int, Int, Int, Float)] = []
        for dx in -1...1 { for dy in -1...1 { for dz in -1...1 where dx != 0 || dy != 0 || dz != 0 {
            steps.append((dx, dy, dz, Float(dx * dx + dy * dy + dz * dz).squareRoot()))
        } } }
        let nx = v.nx, ny = v.ny
        for (b, entry) in skinBones.enumerated() {
            var seeds = Set<Int32>()
            for (from, to) in entry.segments {
                let a = J[from], e = J[to]
                let pieces = max(2, Int(simd_distance(a, e) / (0.5 * v.size)) + 1)
                for s in 0...pieces {
                    let c = v.cell(a + (e - a) * (Float(s) / Float(pieces)))
                    if v.inside(c.x, c.y, c.z) { seeds.insert(compact[v.index(c.x, c.y, c.z)]) }
                }
            }
            if seeds.isEmpty {
                // The bone lies outside the body (a mark dragged off it): start from the nearest inside cube.
                let (from, to) = entry.segments[0]
                let middle = (J[from] + J[to]) / 2
                var best: Int32 = -1
                var bestDistance = Float.greatestFiniteMagnitude
                for (n, at) in cells.enumerated() {
                    let a = Int(at)
                    let p = v.origin + (SIMD3(Float(a % nx), Float((a / nx) % ny), Float(a / (nx * ny))) + 0.5) * v.size
                    let d = simd_distance_squared(p, middle)
                    if d < bestDistance { bestDistance = d; best = Int32(n) }
                }
                if best >= 0 { seeds.insert(best) }
            }
            var heap = Heap()
            for s in seeds { distance[Int(s) * boneCount + b] = 0; heap.push(0, s) }
            while let item = heap.pop() {
                let (d, n32) = item
                let n = Int(n32)
                if d > distance[n * boneCount + b] { continue }
                let at = Int(cells[n])
                let i = at % nx, j = (at / nx) % ny, k = at / (nx * ny)
                for (dx, dy, dz, w) in steps {
                    let a = i + dx, bb = j + dy, c = k + dz
                    guard v.inside(a, bb, c) else { continue }
                    let to = Int(compact[v.index(a, bb, c)])
                    let nd = d + w
                    if nd < distance[to * boneCount + b] { distance[to * boneCount + b] = nd; heap.push(nd, Int32(to)) }
                }
            }
        }

        var bones = [SIMD4<UInt16>](repeating: SIMD4(0, 0, 0, 0), count: mesh.positions.count)
        var weights = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 0), count: mesh.positions.count)
        var loose = 0
        var reached = [Bool](repeating: false, count: mesh.positions.count)
        let minimum = v.size
        for (corner, p) in mesh.positions.enumerated() {
            let c = v.cell(p)
            var found = -1
            if v.inside(c.x, c.y, c.z) {
                found = Int(compact[v.index(c.x, c.y, c.z)])
            } else {
                // A corner sits on the skin, so its own cube may be just outside: the nearest inside cube round it.
                var best = Int.max
                search: for r in 1...3 {
                    for dx in -r...r { for dy in -r...r { for dz in -r...r {
                        let a = c.x + dx, b = c.y + dy, cc = c.z + dz
                        if v.inside(a, b, cc) {
                            let q = dx * dx + dy * dy + dz * dz
                            if q < best { best = q; found = Int(compact[v.index(a, b, cc)]) }
                        }
                    } } }
                    if found >= 0 { break search }
                }
            }
            guard found >= 0 else { loose += 1; continue }
            var top: [(Float, Int)] = []
            for b in 0..<boneCount {
                let d = distance[found * boneCount + b]
                guard d.isFinite else { continue }
                let metres = max(d * v.size, minimum)
                let pull = 1 / (metres * metres * metres * metres)
                top.append((pull, b))
            }
            guard !top.isEmpty else { loose += 1; continue }
            top.sort { $0.0 > $1.0 }
            let kept = top.prefix(4)
            let total = kept.reduce(0) { $0 + $1.0 }
            var bi = SIMD4<UInt16>(0, 0, 0, 0), bw = SIMD4<Float>(0, 0, 0, 0)
            for (n, entry) in kept.enumerated() { bi[n] = UInt16(entry.1); bw[n] = entry.0 / total }
            bones[corner] = bi
            weights[corner] = bw
            reached[corner] = true
        }
        return Skin(bones: bones, weights: weights, loose: loose, reached: reached)
    }

    // MARK: 6. The FBX file

    /// The name of the node Reset looks for to show a scanned character's colours as photographed (unlit).
    static let scanMarker = "ResetScanCharacter"

    /// An ASCII FBX 7.4 file: the stood-up scan, its pictures (by file name, kept next to it), the Mixamo-named
    /// skeleton resting where the joints were found, and the skin. Metres, Y up, facing +Z.
    static func fbx(_ mesh: BodyMesh, joints J: [SIMD3<Float>], skin: Skin, name: String) -> Data {
        var out = FBXText()
        var nextID: Int64 = 1000
        func newID() -> Int64 { nextID += 1; return nextID }
        let geometry = newID(), model = newID(), skinID = newID(), pose = newID()
        let materials = mesh.parts.map { _ in newID() }
        let textures = mesh.parts.map { $0.texture == nil ? Int64(0) : newID() }
        let videos = mesh.parts.map { $0.texture == nil ? Int64(0) : newID() }
        let boneModels = boneNames.map { _ in newID() }
        let boneAttributes = boneNames.map { _ in newID() }
        let clusters = skinBones.map { _ in newID() }
        let safeName = name.replacingOccurrences(of: "\"", with: "'")

        out.line("; FBX 7.4.0 project file")
        out.line("; Made by Reset from a 3D scan")
        out.line("FBXHeaderExtension:  {")
        out.line("\tFBXHeaderVersion: 1003")
        out.line("\tFBXVersion: 7400")
        out.line("\tCreator: \"Reset\"")
        out.line("}")
        out.line("GlobalSettings:  {")
        out.line("\tVersion: 1000")
        out.line("\tProperties70:  {")
        for (key, value) in [("UpAxis", 1), ("UpAxisSign", 1), ("FrontAxis", 2), ("FrontAxisSign", 1), ("CoordAxis", 0), ("CoordAxisSign", 1)] {
            out.line("\t\tP: \"\(key)\", \"int\", \"Integer\", \"\",\(value)")
        }
        out.line("\t\tP: \"UnitScaleFactor\", \"double\", \"Number\", \"\",100")
        out.line("\t}")
        out.line("}")
        out.line("Objects:  {")

        // The shape.
        out.line("\tGeometry: \(geometry), \"Geometry::\(safeName)\", \"Mesh\" {")
        out.text("\t\tVertices: *\(mesh.positions.count * 3) {\n\t\t\ta: ")
        for (n, p) in mesh.positions.enumerated() {
            if n > 0 { out.comma() }
            out.number(p.x); out.comma(); out.number(p.y); out.comma(); out.number(p.z)
        }
        out.text("\n\t\t}\n")
        out.text("\t\tPolygonVertexIndex: *\(mesh.triangles.count) {\n\t\t\ta: ")
        for t in 0..<(mesh.triangles.count / 3) {
            if t > 0 { out.comma() }
            out.integer(Int(mesh.triangles[t * 3])); out.comma()
            out.integer(Int(mesh.triangles[t * 3 + 1])); out.comma()
            out.integer(-Int(mesh.triangles[t * 3 + 2]) - 1)
        }
        out.text("\n\t\t}\n")
        out.line("\t\tGeometryVersion: 124")
        out.line("\t\tLayerElementNormal: 0 {")
        out.line("\t\t\tVersion: 101")
        out.line("\t\t\tName: \"\"")
        out.line("\t\t\tMappingInformationType: \"ByVertice\"")
        out.line("\t\t\tReferenceInformationType: \"Direct\"")
        out.text("\t\t\tNormals: *\(mesh.normals.count * 3) {\n\t\t\t\ta: ")
        for (n, p) in mesh.normals.enumerated() {
            if n > 0 { out.comma() }
            out.number(p.x, digits: 4); out.comma(); out.number(p.y, digits: 4); out.comma(); out.number(p.z, digits: 4)
        }
        out.text("\n\t\t\t}\n\t\t}\n")
        if let uvs = mesh.uvs, uvs.count == mesh.positions.count {
            out.line("\t\tLayerElementUV: 0 {")
            out.line("\t\t\tVersion: 101")
            out.line("\t\t\tName: \"UVMap\"")
            out.line("\t\t\tMappingInformationType: \"ByVertice\"")
            out.line("\t\t\tReferenceInformationType: \"Direct\"")
            out.text("\t\t\tUV: *\(uvs.count * 2) {\n\t\t\t\ta: ")
            for (n, uv) in uvs.enumerated() {
                if n > 0 { out.comma() }
                // FBX counts pictures from the bottom.
                out.number(uv.x); out.comma(); out.number(1 - uv.y)
            }
            out.text("\n\t\t\t}\n\t\t}\n")
        }
        out.line("\t\tLayerElementMaterial: 0 {")
        out.line("\t\t\tVersion: 101")
        out.line("\t\t\tName: \"\"")
        out.line("\t\t\tMappingInformationType: \"ByPolygon\"")
        out.line("\t\t\tReferenceInformationType: \"IndexToDirect\"")
        out.text("\t\t\tMaterials: *\(mesh.triangleCount) {\n\t\t\t\ta: ")
        var partOf = [Int](repeating: 0, count: mesh.triangleCount)
        for (p, part) in mesh.parts.enumerated() {
            for t in part.firstTriangle..<min(mesh.triangleCount, part.firstTriangle + part.triangleCount) { partOf[t] = p }
        }
        for t in 0..<mesh.triangleCount {
            if t > 0 { out.comma() }
            out.integer(partOf[t])
        }
        out.text("\n\t\t\t}\n\t\t}\n")
        out.line("\t\tLayer: 0 {")
        out.line("\t\t\tVersion: 100")
        var layers = ["LayerElementNormal", "LayerElementMaterial"]
        if mesh.uvs != nil { layers.insert("LayerElementUV", at: 1) }
        for layer in layers {
            out.line("\t\t\tLayerElement:  {")
            out.line("\t\t\t\tType: \"\(layer)\"")
            out.line("\t\t\t\tTypedIndex: 0")
            out.line("\t\t\t}")
        }
        out.line("\t\t}")
        out.line("\t}")
        out.line("\tModel: \(model), \"Model::\(scanMarker)\", \"Mesh\" {")
        out.line("\t\tVersion: 232")
        out.line("\t\tProperties70:  {")
        out.line("\t\t}")
        out.line("\t\tShading: T")
        out.line("\t\tCulling: \"CullingOff\"")
        out.line("\t}")

        // The skeleton: each joint where it was found, turned the same way as the model (no rotation).
        for (b, boneName) in boneNames.enumerated() {
            let parent = parents[b]
            let local = J[b] - (parent >= 0 ? J[parent] : .zero)
            out.line("\tNodeAttribute: \(boneAttributes[b]), \"NodeAttribute::mixamorig:\(boneName)\", \"LimbNode\" {")
            out.line("\t\tTypeFlags: \"Skeleton\"")
            out.line("\t}")
            out.line("\tModel: \(boneModels[b]), \"Model::mixamorig:\(boneName)\", \"LimbNode\" {")
            out.line("\t\tVersion: 232")
            out.line("\t\tProperties70:  {")
            out.text("\t\t\tP: \"Lcl Translation\", \"Lcl Translation\", \"\", \"A\",")
            out.number(local.x); out.comma(); out.number(local.y); out.comma(); out.number(local.z)
            out.text("\n")
            out.line("\t\t}")
            out.line("\t\tShading: Y")
            out.line("\t\tCulling: \"CullingOff\"")
            out.line("\t}")
        }

        // Materials and pictures.
        for (p, part) in mesh.parts.enumerated() {
            out.line("\tMaterial: \(materials[p]), \"Material::Skin\(p)\", \"\" {")
            out.line("\t\tVersion: 102")
            out.line("\t\tShadingModel: \"lambert\"")
            out.line("\t\tProperties70:  {")
            let c = part.texture == nil ? part.color : SIMD3<Float>(1, 1, 1)
            out.text("\t\t\tP: \"DiffuseColor\", \"Color\", \"\", \"A\",")
            out.number(c.x, digits: 4); out.comma(); out.number(c.y, digits: 4); out.comma(); out.number(c.z, digits: 4)
            out.text("\n")
            out.line("\t\t}")
            out.line("\t}")
            if let file = part.texture {
                let clean = file.replacingOccurrences(of: "\"", with: "")
                out.line("\tVideo: \(videos[p]), \"Video::Skin\(p)\", \"Clip\" {")
                out.line("\t\tType: \"Clip\"")
                out.line("\t\tFileName: \"\(clean)\"")
                out.line("\t\tRelativeFilename: \"\(clean)\"")
                out.line("\t}")
                out.line("\tTexture: \(textures[p]), \"Texture::Skin\(p)\", \"\" {")
                out.line("\t\tType: \"TextureVideoClip\"")
                out.line("\t\tVersion: 202")
                out.line("\t\tTextureName: \"Texture::Skin\(p)\"")
                out.line("\t\tMedia: \"Video::Skin\(p)\"")
                out.line("\t\tFileName: \"\(clean)\"")
                out.line("\t\tRelativeFilename: \"\(clean)\"")
                out.line("\t}")
            }
        }

        // The skin: one cluster per bone, with the corners it pulls.
        out.line("\tDeformer: \(skinID), \"Deformer::Skin\", \"Skin\" {")
        out.line("\t\tVersion: 101")
        out.line("\t\tLink_DeformAcuracy: 50")
        out.line("\t}")
        var pulled = [[(Int, Float)]](repeating: [], count: skinBones.count)
        for corner in 0..<min(skin.bones.count, mesh.positions.count) {
            for n in 0..<4 where skin.weights[corner][n] > 1e-4 {
                let b = Int(skin.bones[corner][n])
                if b < pulled.count { pulled[b].append((corner, skin.weights[corner][n])) }
            }
        }
        func matrix(_ t: SIMD3<Float>) {
            out.text("\t\t\ta: 1,0,0,0,0,1,0,0,0,0,1,0,")
            out.number(t.x); out.comma(); out.number(t.y); out.comma(); out.number(t.z); out.text(",1\n")
        }
        for (b, entry) in skinBones.enumerated() {
            out.line("\tDeformer: \(clusters[b]), \"SubDeformer::mixamorig:\(boneNames[entry.bone])\", \"Cluster\" {")
            out.line("\t\tVersion: 100")
            out.line("\t\tUserData: \"\", \"\"")
            out.text("\t\tIndexes: *\(pulled[b].count) {\n\t\t\ta: ")
            for (n, item) in pulled[b].enumerated() {
                if n > 0 { out.comma() }
                out.integer(item.0)
            }
            out.text("\n\t\t}\n")
            out.text("\t\tWeights: *\(pulled[b].count) {\n\t\t\ta: ")
            for (n, item) in pulled[b].enumerated() {
                if n > 0 { out.comma() }
                out.number(item.1, digits: 4)
            }
            out.text("\n\t\t}\n")
            out.line("\t\tTransform: *16 {")
            matrix(-J[entry.bone])
            out.line("\t\t}")
            out.line("\t\tTransformLink: *16 {")
            matrix(J[entry.bone])
            out.line("\t\t}")
            out.line("\t}")
        }
        out.line("\tPose: \(pose), \"Pose::BIND_POSES\", \"Pose\" {")
        out.line("\t\tType: \"BindPose\"")
        out.line("\t\tVersion: 100")
        out.line("\t\tNbPoseNodes: \(boneNames.count + 1)")
        for (node, at) in [(model, SIMD3<Float>.zero)] + boneNames.indices.map({ (boneModels[$0], J[$0]) }) {
            out.line("\t\tPoseNode:  {")
            out.line("\t\t\tNode: \(node)")
            out.line("\t\t\tMatrix: *16 {")
            out.text("\t")
            matrix(at)
            out.line("\t\t\t}")
            out.line("\t\t}")
        }
        out.line("\t}")
        out.line("}")

        out.line("Connections:  {")
        out.line("\tC: \"OO\",\(model),0")
        out.line("\tC: \"OO\",\(geometry),\(model)")
        for p in mesh.parts.indices {
            out.line("\tC: \"OO\",\(materials[p]),\(model)")
            if mesh.parts[p].texture != nil {
                out.line("\tC: \"OP\",\(textures[p]),\(materials[p]), \"DiffuseColor\"")
                out.line("\tC: \"OO\",\(videos[p]),\(textures[p])")
            }
        }
        for b in boneNames.indices {
            out.line("\tC: \"OO\",\(boneModels[b]),\(parents[b] >= 0 ? boneModels[parents[b]] : 0)")
            out.line("\tC: \"OO\",\(boneAttributes[b]),\(boneModels[b])")
        }
        out.line("\tC: \"OO\",\(skinID),\(geometry)")
        for (b, entry) in skinBones.enumerated() {
            out.line("\tC: \"OO\",\(clusters[b]),\(skinID)")
            out.line("\tC: \"OO\",\(boneModels[entry.bone]),\(clusters[b])")
        }
        out.line("}")
        return Data(out.bytes)
    }

    /// Fast text for big FBX files (a scan has hundreds of thousands of numbers).
    struct FBXText {
        var bytes: [UInt8] = []
        init() { bytes.reserveCapacity(8_000_000) }
        mutating func text(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
        mutating func line(_ s: String) { text(s); bytes.append(10) }
        mutating func comma() { bytes.append(44) }
        mutating func integer(_ value: Int) {
            if value < 0 { bytes.append(45) }
            var v = value.magnitude
            if v == 0 { bytes.append(48); return }
            var digits: [UInt8] = []
            while v > 0 { digits.append(UInt8(48 + v % 10)); v /= 10 }
            bytes.append(contentsOf: digits.reversed())
        }
        /// Fixed point with `digits` decimals ("-0.12345").
        mutating func number(_ value: Float, digits: Int = 5) {
            guard value.isFinite else { bytes.append(48); return }
            var scale: Int64 = 1
            for _ in 0..<digits { scale *= 10 }
            let scaled = Int64((Double(value) * Double(scale)).rounded())
            if scaled < 0 { bytes.append(45) }
            let m = scaled.magnitude
            integer(Int(m / UInt64(scale)))
            bytes.append(46)
            var fraction = m % UInt64(scale)
            var out = [UInt8](repeating: 48, count: digits)
            var i = digits - 1
            while i >= 0 { out[i] = UInt8(48 + fraction % 10); fraction /= 10; i -= 1 }
            bytes.append(contentsOf: out)
        }
    }
}
