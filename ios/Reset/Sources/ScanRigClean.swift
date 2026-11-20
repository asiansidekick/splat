import Foundation
import simd

// Phil, 2026-11-20: "My scan turned out a little unflattering… Keep the body, as is, there may be costume elements I
// don't want smoothed. Improve head and shoulders." The head and shoulders are smoothed of the small lumps
// photogrammetry leaves (Taubin smoothing, which does not shrink), fading out to nothing below the shoulders, so the
// body and costume stay exactly as scanned. The photo is untouched. Kept free of SceneKit and UIKit for CI.

extension ScanRig {
    struct Smoothing {
        /// Full strength from here up.
        var fullFrom: Float
        /// No smoothing from here down; in between it fades.
        var noneBelow: Float
        var rounds: Int
        /// No point moves further than this (metres), so the eyes, nose and mouth stay true to the actor
        /// (Phil, 2026-11-20: "Facial feature accuracy is important"). Only the small lumps go.
        var maxMove: Float = .greatestFiniteMagnitude
    }

    /// Head and shoulders: full from the neck up, fading to nothing a little below the shoulder joints.
    static func headAndShoulders(joints J: [SIMD3<Float>], height H: Float) -> Smoothing {
        let shoulders = (J[bone("LeftArm")].y + J[bone("RightArm")].y) / 2
        let neck = J[bone("Neck")].y
        return Smoothing(fullFrom: max(neck, shoulders + 0.01 * H), noneBelow: shoulders - 0.07 * H, rounds: 8, maxMove: 0.0012 * H)
    }

    /// How much a point at height y is smoothed, 0 to 1.
    static func strength(_ y: Float, _ s: Smoothing) -> Float {
        if y >= s.fullFrom { return 1 }
        if y <= s.noneBelow { return 0 }
        let t = (y - s.noneBelow) / max(1e-4, s.fullFrom - s.noneBelow)
        return t * t * (3 - 2 * t)
    }

    /// Taubin smoothing (shrink, then grow back) where `s` says, leaving every other point exactly where it was.
    /// Points at the same place (a scan splits them where its photo is cut) move together, so no seams open; points on
    /// an open edge stay put. Normals are made again where points moved. Returns how many points moved.
    @discardableResult
    static func smooth(_ mesh: inout BodyMesh, _ s: Smoothing) -> Int {
        guard s.rounds > 0, !mesh.positions.isEmpty else { return 0 }
        // One shared point per place (to a tenth of a millimetre).
        var key: [SIMD3<Int32>: Int] = [:]
        var welded = [Int](repeating: 0, count: mesh.positions.count)
        var places: [SIMD3<Float>] = []
        for (i, p) in mesh.positions.enumerated() {
            let k = SIMD3<Int32>(Int32((p.x * 10_000).rounded()), Int32((p.y * 10_000).rounded()), Int32((p.z * 10_000).rounded()))
            if let found = key[k] { welded[i] = found } else { key[k] = places.count; welded[i] = places.count; places.append(p) }
        }
        let weight = places.map { strength($0.y, s) }
        guard weight.contains(where: { $0 > 0 }) else { return 0 }
        // Neighbours, and edges used once (an open edge).
        var neighbours = [Set<Int>](repeating: [], count: places.count)
        var edgeUse: [SIMD2<Int32>: Int] = [:]
        var t = 0
        while t + 2 < mesh.triangles.count {
            let c = (0..<3).map { welded[Int(mesh.triangles[t + $0])] }
            t += 3
            guard weight[c[0]] > 0 || weight[c[1]] > 0 || weight[c[2]] > 0 else { continue }
            for (a, b) in [(c[0], c[1]), (c[1], c[2]), (c[2], c[0])] where a != b {
                neighbours[a].insert(b); neighbours[b].insert(a)
                edgeUse[SIMD2(Int32(min(a, b)), Int32(max(a, b))), default: 0] += 1
            }
        }
        var pinned = [Bool](repeating: false, count: places.count)
        for (edge, uses) in edgeUse where uses == 1 { pinned[Int(edge.x)] = true; pinned[Int(edge.y)] = true }
        let moving = places.indices.filter { weight[$0] > 0 && !pinned[$0] && !neighbours[$0].isEmpty }
        let lists = neighbours.map { Array($0) }
        func step(_ factor: Float) {
            var moved = places
            for i in moving {
                var mean = SIMD3<Float>(0, 0, 0)
                for n in lists[i] { mean += places[n] }
                mean /= Float(lists[i].count)
                moved[i] = places[i] + weight[i] * factor * (mean - places[i])
            }
            places = moved
        }
        let start = places
        for _ in 0..<s.rounds {
            step(0.5); step(-0.53)
            // Held to within maxMove of where it was scanned, every round, so features can't drift.
            for i in moving {
                let d = places[i] - start[i], length = simd_length(d)
                if length > s.maxMove { places[i] = start[i] + d * (s.maxMove / length) }
            }
        }
        // Normals from the welded shape, so they agree across the photo's seams; only where something moved.
        var weldedTriangles: [UInt32] = []
        weldedTriangles.reserveCapacity(mesh.triangles.count)
        for corner in mesh.triangles { weldedTriangles.append(UInt32(welded[Int(corner)])) }
        let normals = BodyMesh.smoothNormals(places, weldedTriangles)
        var changed = 0
        for i in mesh.positions.indices where weight[welded[i]] > 0 {
            let p = places[welded[i]]
            if p != mesh.positions[i] { changed += 1 }
            mesh.positions[i] = p
            if i < mesh.normals.count { mesh.normals[i] = normals[welded[i]] }
        }
        return changed
    }

    // MARK: Swapping heads (Phil, 2026-11-20: "Swapping heads between bodies is desirable")

    /// Where a person's head is cut from the body: a little above the neck joint, round the head's middle.
    static func neckCut(joints J: [SIMD3<Float>]) -> SIMD3<Float> {
        neckCut(neck: J[bone("Neck")], head: J[bone("Head")])
    }

    /// The same for any skeleton, from its neck and head joints.
    static func neckCut(neck: SIMD3<Float>, head: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(head.x, neck.y + 0.45 * max(0.005, head.y - neck.y), head.z)
    }

    /// This person's head, cut at its neck cut and moved so the cut is at 0,0,0. Metres, facing +Z, exactly as
    /// scanned otherwise: the face is never reshaped (Phil, 2026-11-20: "Facial feature accuracy is important").
    static func headPiece(of mesh: BodyMesh, joints: [SIMD3<Float>]) -> BodyMesh {
        let cut = neckCut(joints: joints)
        var head = part(of: mesh) { corners in corners.allSatisfy { $0.y > cut.y } }
        head.positions = head.positions.map { $0 - cut }
        return head
    }

    /// The triangles `keep` says yes to, with their points renumbered. `keep` is given the triangle's three corners.
    static func part(of mesh: BodyMesh, keep: ([SIMD3<Float>]) -> Bool) -> BodyMesh {
        var newIndex = [Int32](repeating: -1, count: mesh.positions.count)
        var out = BodyMesh(positions: [], normals: [], uvs: mesh.uvs == nil ? nil : [], triangles: [], parts: [])
        for part in mesh.parts {
            let first = out.triangles.count / 3
            for t in part.firstTriangle..<min(mesh.triangleCount, part.firstTriangle + part.triangleCount) {
                let corners = (0..<3).map { Int(mesh.triangles[t * 3 + $0]) }
                guard keep(corners.map { mesh.positions[$0] }) else { continue }
                for c in corners {
                    if newIndex[c] < 0 {
                        newIndex[c] = Int32(out.positions.count)
                        out.positions.append(mesh.positions[c])
                        out.normals.append(c < mesh.normals.count ? mesh.normals[c] : SIMD3(0, 1, 0))
                        if let source = mesh.uvs { out.uvs!.append(c < source.count ? source[c] : .zero) }
                    }
                    out.triangles.append(UInt32(newIndex[c]))
                }
            }
            let count = out.triangles.count / 3 - first
            if count > 0 { out.parts.append(BodyMesh.Part(firstTriangle: first, triangleCount: count, texture: part.texture, color: part.color)) }
        }
        return out
    }

    /// One mesh from two. Picture coordinates are kept when both have them (a plain mesh gets zeros).
    static func joined(_ a: BodyMesh, _ b: BodyMesh) -> BodyMesh {
        var out = a
        let offset = UInt32(a.positions.count), firstTriangle = a.triangleCount
        out.positions += b.positions
        out.normals += b.normals
        if a.uvs != nil || b.uvs != nil {
            out.uvs = (a.uvs ?? [SIMD2<Float>](repeating: .zero, count: a.positions.count)) + (b.uvs ?? [SIMD2<Float>](repeating: .zero, count: b.positions.count))
        }
        out.triangles += b.triangles.map { $0 + offset }
        out.parts += b.parts.map { BodyMesh.Part(firstTriangle: $0.firstTriangle + firstTriangle, triangleCount: $0.triangleCount, texture: $0.texture, color: $0.color) }
        return out
    }

    /// `body` with its own head taken off and the head of `donor` put on, its neck cut standing on this body's neck cut.
    /// Both stand facing +Z (stood up by ScanRig.stood). The donor head keeps its own size: it is that person's head.
    /// `rename` gives the donor's pictures their new file names, so they don't clash with the body's.
    static func swapHead(body: BodyMesh, joints: [SIMD3<Float>], donor: BodyMesh, donorJoints: [SIMD3<Float>],
                         rename: (String) -> String) -> BodyMesh {
        let cut = neckCut(joints: joints)
        // The body keeps every triangle that reaches below its cut; the head is the donor's triangles wholly above its.
        let headless = part(of: body) { corners in corners.contains { $0.y <= cut.y } }
        var head = headPiece(of: donor, joints: donorJoints)
        head.positions = head.positions.map { $0 + cut }
        for i in head.parts.indices { head.parts[i].texture = head.parts[i].texture.map(rename) }
        return joined(headless, head)
    }

    // MARK: A scanned head on an imported character (Phil, 2026-11-20: "And swap to any of my imported mixamo fbx")

    /// The file kept in an FBX character's pictures folder, so it travels wherever the character's pictures go.
    static let headFile = "scanned-head.bin"

    /// Where a head piece (cut at 0,0,0, metres, facing +Z) goes in a character's own space: its neck cut on the
    /// character's, turned round for a character facing -Z, in the file's units. The head keeps its real size.
    static func headPlacement(neck: SIMD3<Float>, head: SIMD3<Float>, facing: Float, metresPerUnit: Float) -> simd_float4x4 {
        let cut = neckCut(neck: neck, head: head)
        let k = 1 / max(1e-6, metresPerUnit), turn: Float = facing < 0 ? -1 : 1
        let side: Float = turn * k
        return simd_float4x4(SIMD4<Float>(side, 0, 0, 0), SIMD4<Float>(0, k, 0, 0), SIMD4<Float>(0, 0, side, 0), SIMD4<Float>(cut.x, cut.y, cut.z, 1))
    }

    private struct SavedPart: Codable {
        var first: Int, count: Int, texture: String?, color: [Float]
    }

    /// A head piece as a small file: points, normals, picture coordinates and triangles as they are, parts at the end.
    static func headData(_ m: BodyMesh) -> Data {
        var d = Data("RSH1".utf8)
        func put<T>(_ values: [T]) {
            var count = UInt32(values.count)
            withUnsafeBytes(of: &count) { d.append(contentsOf: $0) }
            values.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        put(m.positions.flatMap { [$0.x, $0.y, $0.z] })
        put(m.normals.flatMap { [$0.x, $0.y, $0.z] })
        put((m.uvs ?? []).flatMap { [$0.x, $0.y] })
        put(m.triangles)
        let parts = m.parts.map { SavedPart(first: $0.firstTriangle, count: $0.triangleCount, texture: $0.texture, color: [$0.color.x, $0.color.y, $0.color.z]) }
        put(Array((try? JSONEncoder().encode(parts)) ?? Data("[]".utf8)))
        return d
    }

    static func head(from data: Data) -> BodyMesh? {
        let data = Data(data)
        guard data.count >= 4, data.prefix(4) == Data("RSH1".utf8) else { return nil }
        var at = 4
        func take<T>(_: T.Type) -> [T]? {
            guard at + 4 <= data.count else { return nil }
            var count32: UInt32 = 0
            withUnsafeMutableBytes(of: &count32) { _ = data.copyBytes(to: $0, from: at..<(at + 4)) }
            at += 4
            let count = Int(count32), bytes = count * MemoryLayout<T>.stride
            guard bytes >= 0, at + bytes <= data.count else { return nil }
            let out = [T](unsafeUninitializedCapacity: count) { buffer, made in
                if bytes > 0 { _ = data.copyBytes(to: buffer, from: at..<(at + bytes)) }
                made = count
            }
            at += bytes
            return out
        }
        guard let p = take(Float.self), let n = take(Float.self), let u = take(Float.self), let t = take(UInt32.self),
              let partBytes = take(UInt8.self), let parts = try? JSONDecoder().decode([SavedPart].self, from: Data(partBytes)) else { return nil }
        let count = p.count / 3
        guard count > 0, n.count == p.count, u.isEmpty || u.count == count * 2, t.allSatisfy({ Int($0) < count }) else { return nil }
        return BodyMesh(positions: (0..<count).map { SIMD3(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) },
                        normals: (0..<count).map { SIMD3(n[$0 * 3], n[$0 * 3 + 1], n[$0 * 3 + 2]) },
                        uvs: u.isEmpty ? nil : (0..<count).map { SIMD2(u[$0 * 2], u[$0 * 2 + 1]) },
                        triangles: t,
                        parts: parts.map { BodyMesh.Part(firstTriangle: $0.first, triangleCount: $0.count, texture: $0.texture,
                                                         color: $0.color.count == 3 ? SIMD3($0.color[0], $0.color[1], $0.color[2]) : SIMD3(0.8, 0.8, 0.8)) })
    }
}
