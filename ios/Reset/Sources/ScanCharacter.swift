import ModelIO
import SceneKit
import SwiftUI
import UIKit
import simd

/// Makes a posable person from a 3D scan (Phil, 2026-11-20): finds the joints (ScanRig.swift), lets the crew drag
/// any that are off, then saves an FBX character with Mixamo bones into the gallery, where it is placed and posed
/// like any other character.
final class ScanCharacterMaker: @unchecked Sendable {
    let title: String
    private let original: BodyMesh
    private let pictures: [UIImage?]
    private(set) var stance: ScanRig.Stance
    private(set) var body: BodyMesh
    private(set) var voxels: ScanRig.Voxels
    private(set) var found: ScanRig.Found?
    private(set) var floorTrimmed = 0
    /// The front view of the stood-up scan, and the stretch of the body (metres) its edges show.
    private(set) var picture: UIImage
    private(set) var shown: (minX: Float, maxX: Float, minY: Float, maxY: Float)
    var height: Float { stance.height }

    private init(title: String, original: BodyMesh, pictures: [UIImage?], stance: ScanRig.Stance, body: BodyMesh, voxels: ScanRig.Voxels,
                 found: ScanRig.Found?, floorTrimmed: Int, picture: UIImage, shown: (Float, Float, Float, Float)) {
        self.title = title
        self.original = original
        self.pictures = pictures
        self.stance = stance
        self.body = body
        self.voxels = voxels
        self.found = found
        self.floorTrimmed = floorTrimmed
        self.picture = picture
        self.shown = (shown.0, shown.1, shown.2, shown.3)
    }

    enum Failure: Error {
        case unreadable, notAPerson, tooBig
        var words: String {
            switch self {
            case .unreadable: return "This scan couldn't be opened."
            case .notAPerson: return "This scan doesn't look like a standing person. Scan someone standing, arms a little out from the body."
            case .tooBig: return "This scan is too big to turn into a person."
            }
        }
    }

    /// Reads the scan, stands it up and finds the joints. Slow (a second or two): call off the main thread.
    static func prepare(_ folder: ScanFolder, turned: Bool? = nil) -> Result<ScanCharacterMaker, Failure> {
        // The person built again in more detail (ScanPersonDetail), when there is one.
        let source = ScanPersonDetail.has(folder) ? ScanPersonDetail.file(folder) : folder.model
        guard let loaded = read(source) else { return .failure(.unreadable) }
        let (mesh, pictures) = loaded
        guard mesh.triangleCount >= 100 else { return .failure(.unreadable) }
        guard mesh.triangleCount < 1_500_000 else { return .failure(.tooBig) }
        // Stray bits away from the person, and points nothing uses, are left out first.
        let (main, stray) = ScanRig.mainPiece(mesh)
        if stray > 0 { Diagnostics.log("Scan person: \(folder.title): \(stray) stray triangles away from the person left out") }
        guard main.triangleCount >= 100 else { return .failure(.unreadable) }
        return build(title: folder.title, original: main, pictures: pictures, turned: turned)
    }

    /// The same scan turned round (when the picture shows the person's back).
    func turnedRound() -> Result<ScanCharacterMaker, Failure> {
        Self.build(title: title, original: original, pictures: pictures, turned: !stance.turned)
    }

    private static func build(title: String, original: BodyMesh, pictures: [UIImage?], turned: Bool?) -> Result<ScanCharacterMaker, Failure> {
        let started = Date()
        guard var stance = ScanRig.stance(of: original) else {
            Diagnostics.log("Scan person: \(title) refused: no standing shape found (\(original.positions.count) points)")
            return .failure(.notAPerson)
        }
        if let turned { stance.turned = turned }
        var body = ScanRig.stood(original, stance)
        var trimmed = ScanRig.trimFloor(&body)
        trimmed += ScanRig.trimAroundFeet(&body)
        // Bits the cut left apart from the person.
        body = ScanRig.mainPiece(body).0
        if trimmed > 0 {
            // Stand it on its feet again, without the floor piece.
            let low = body.positions.map(\.y).min() ?? 0
            body.positions = body.positions.map { SIMD3($0.x, $0.y - low, $0.z) }
            stance.height = (body.positions.map(\.y).max() ?? stance.height)
        }
        guard stance.height > 0.3, let voxels = ScanRig.Voxels.fitting(body, height: stance.height) else {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for p in body.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            Diagnostics.log(String(format: "Scan person: %@ refused: %.2f m tall, box %.2f x %.2f x %.2f m", title, stance.height, hi.x - lo.x, hi.y - lo.y, hi.z - lo.z))
            return .failure(.notAPerson)
        }
        let found = ScanRig.findMarks(voxels)
        // What the front view shows: the whole body with a margin.
        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude), high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for p in body.positions { low = simd_min(low, SIMD2(p.x, p.y)); high = simd_max(high, SIMD2(p.x, p.y)) }
        let margin = 0.06 * stance.height
        let shown = (low.x - margin, high.x + margin, low.y - margin, high.y + margin)
        let picture = drawFront(body, pictures: pictures, shown: shown)
        Diagnostics.log(String(format: "Scan person: %@, %d points, %d triangles, %.2f m tall, turned %.0f°%@ (feet %.3f), floor triangles cut %d, voxels %d inside / %d skin%@, %@, %.1f s",
                               title, body.positions.count, body.triangleCount, stance.height, stance.yaw * 180 / .pi, stance.turned ? " and round" : "",
                               stance.feetSignal, trimmed, voxels.solidCount, voxels.shellCount, voxels.closed ? " (holes closed)" : "",
                               found.map { "hands \($0.handsFound ? "found" : "not found"), groin \($0.groinFound ? "found" : "guessed")" } ?? "outline not read",
                               Date().timeIntervalSince(started)))
        return .success(ScanCharacterMaker(title: title, original: original, pictures: pictures, stance: stance, body: body, voxels: voxels,
                                           found: found, floorTrimmed: trimmed, picture: picture, shown: shown))
    }

    /// The person's box in the scan's own space (as Reset shows it), with a margin.
    var modelBox: (SIMD3<Float>, SIMD3<Float>) {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for p in original.positions { low = simd_min(low, p); high = simd_max(high, p) }
        return (low - SIMD3(0.06, 0.02, 0.06), high + SIMD3(0.06, 0.06, 0.06))
    }

    /// Where the dots start.
    var startingMarks: ScanRig.Marks {
        var marks = found?.marks ?? ScanRig.averageMarks(height: height, middle: 0)
        // The shoulders start where the joints would put them, so the dots sit on the skeleton.
        if marks.shoulderL == .zero || marks.shoulderR == .zero || marks.ankleL == .zero || marks.ankleR == .zero {
            let J = ScanRig.joints(marks, voxels, height: height)
            func at(_ name: String) -> SIMD2<Float> { let p = J[ScanRig.bone(name)]; return SIMD2(p.x, p.y) }
            if marks.shoulderL == .zero { marks.shoulderL = at("LeftArm") }
            if marks.shoulderR == .zero { marks.shoulderR = at("RightArm") }
            if marks.ankleL == .zero { marks.ankleL = at("LeftFoot") }
            if marks.ankleR == .zero { marks.ankleR = at("RightFoot") }
        }
        return marks
    }

    func joints(_ marks: ScanRig.Marks) -> [SIMD3<Float>] { ScanRig.joints(marks, voxels, height: height) }

    /// Skins the scan to the joints and saves it in the gallery as "<scan> person.fbx". With `smoothHead`, the head
    /// and shoulders lose their scanning lumps; the rest stays exactly as scanned (ScanRigClean.swift). Slow: off the
    /// main thread.
    func make(_ marks: ScanRig.Marks, smoothHead: Bool, headFrom donor: ScanCharacterMaker? = nil) throws -> URL {
        let started = Date()
        let joints = joints(marks)
        var shape = body
        var inside = voxels
        var extraPictures: [String: UIImage] = [:]
        if let donor {
            // Phil, 2026-11-20: swap heads between bodies. The other scan's head goes on this body's neck.
            let donorJoints = donor.joints(donor.startingMarks)
            shape = ScanRig.swapHead(body: shape, joints: joints, donor: donor.body, donorJoints: donorJoints, rename: { "head-" + $0 })
            for (index, part) in donor.body.parts.enumerated() {
                if let name = part.texture, index < donor.pictures.count, let picture = donor.pictures[index] { extraPictures["head-" + name] = picture }
            }
            if let filled = ScanRig.Voxels.fitting(shape, height: height) { inside = filled }
        }
        var smoothed = 0
        if smoothHead { smoothed = ScanRig.smooth(&shape, ScanRig.headAndShoulders(joints: joints, height: height)) }
        var skin = ScanRig.skin(shape, joints: joints, inside)
        var islands = 0
        if skin.loose > 0 {
            let before = shape.triangleCount
            shape = ScanRig.withoutIslands(shape, skin)
            islands = before - shape.triangleCount
            skin = ScanRig.skin(shape, joints: joints, inside)
        }
        let folder = ModelLibrary.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var named: String = title
        if let donor { named += " with \(donor.title)'s head" }
        let base: String = named.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces) + " person"
        var target = folder.appendingPathComponent("\(base).fbx")
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(number).fbx")
            number += 1
        }
        let textures = FBXImport.texturesFolder(for: target)
        try? FileManager.default.removeItem(at: textures)
        var mesh = shape
        // Each picture by its file name.
        var byName = extraPictures
        for (index, part) in body.parts.enumerated() {
            if let name = part.texture, index < pictures.count, let picture = pictures[index] { byName[name] = picture }
        }
        var written = Set<String>()
        for (index, part) in mesh.parts.enumerated() {
            guard let name = part.texture else { continue }
            guard let picture = byName[name], let data = Self.jpeg(picture) else {
                Diagnostics.log("Scan person: picture \(name) \(byName[name] == nil ? "not read from the scan" : "could not be saved"), shown plain")
                mesh.parts[index].texture = nil
                continue
            }
            guard !written.contains(name) else { continue }
            try FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)
            try data.write(to: textures.appendingPathComponent(name), options: .atomic)
            written.insert(name)
            Diagnostics.log(String(format: "Scan person: picture %@ saved, %.0f x %.0f, %.1f MB", name, picture.size.width * picture.scale, picture.size.height * picture.scale, Double(data.count) / 1_000_000))
        }
        if islands > 0 { Diagnostics.log("Scan person: \(islands) triangles apart from the body left out (floor bits)") }
        let file = ScanRig.fbx(mesh, joints: joints, skin: skin, name: target.deletingPathExtension().lastPathComponent)
        try file.write(to: target, options: .atomic)
        Diagnostics.log(String(format: "Scan person saved: %@ (%d head and shoulder points smoothed, head %@), %d triangles, %.1f MB, %d bones pull the skin, %d loose points, %.1f s",
                               target.lastPathComponent, smoothed, donor?.title ?? "own", mesh.triangleCount,
                               Double(file.count) / 1_000_000, ScanRig.skinBones.count, skin.loose, Date().timeIntervalSince(started)))
        return target
    }

    /// Phil, 2026-11-20: "And swap to any of my imported mixamo fbx". A copy of an imported character, named
    /// "<character> with <scan>'s head", with this scan's head kept beside it (ScanRig.headFile in its pictures
    /// folder) for FBXImport to put on its head bone. The head is exactly as scanned, never smoothed: the face
    /// must stay true to the actor. The character's own file is not changed.
    func putHead(on character: URL) throws -> URL {
        let head = ScanRig.headPiece(of: body, joints: joints(startingMarks))
        guard head.triangleCount > 50 else { throw Failure.notAPerson }
        let folder = character.deletingLastPathComponent()
        let base = (character.deletingPathExtension().lastPathComponent + " with \(title)'s head").replacingOccurrences(of: "/", with: "-")
        var target = folder.appendingPathComponent("\(base).fbx")
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(number).fbx")
            number += 1
        }
        let manager = FileManager.default
        let textures = FBXImport.texturesFolder(for: target)
        try manager.copyItem(at: character, to: target)
        if manager.fileExists(atPath: FBXImport.texturesFolder(for: character).path) {
            try manager.copyItem(at: FBXImport.texturesFolder(for: character), to: textures)
        }
        try manager.createDirectory(at: textures, withIntermediateDirectories: true)
        var mesh = head
        var byName: [String: UIImage] = [:]
        for (index, part) in body.parts.enumerated() {
            if let name = part.texture, index < pictures.count, let picture = pictures[index] { byName[name] = picture }
        }
        var written = Set<String>()
        for (index, part) in mesh.parts.enumerated() {
            guard let name = part.texture else { continue }
            let saved = "scanned-head-" + name
            guard let picture = byName[name], let data = Self.jpeg(picture) else { mesh.parts[index].texture = nil; continue }
            mesh.parts[index].texture = saved
            guard !written.contains(saved) else { continue }
            try data.write(to: textures.appendingPathComponent(saved), options: .atomic)
            written.insert(saved)
        }
        try ScanRig.headData(mesh).write(to: textures.appendingPathComponent(ScanRig.headFile), options: .atomic)
        Diagnostics.log("Scan person: \(title)'s head (\(mesh.triangleCount) triangles) put on \(character.lastPathComponent) as \(target.lastPathComponent)")
        return target
    }

    private static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > 0 else { return nil }
        // A picture with no bitmap behind it yet is drawn first.
        guard longest > 4096 else { return image.jpegData(compressionQuality: 0.9) ?? redrawn(image, CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)) }
        let factor = 4096 / longest
        let size = CGSize(width: (image.size.width * image.scale * factor).rounded(), height: (image.size.height * image.scale * factor).rounded())
        return redrawn(image, size)
    }

    private static func redrawn(_ image: UIImage, _ size: CGSize) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.9)
    }

    // MARK: Reading the scan

    /// The scan's triangles in metres (as Reset shows it), with one picture per part. ModelIO's numbering is used when it
    /// matches, as in the Trim screen: SceneKit's own picture coordinates can be numbered apart from its points.
    static func read(_ url: URL) -> (BodyMesh, [UIImage?])? {
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
        let unified = ScanTrimmer.unifiedMeshes(of: url)
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        var allHaveUVs = true
        var triangles: [UInt32] = []
        var parts: [BodyMesh.Part] = []
        var pictures: [UIImage?] = []
        var meshNumber = 0
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            defer { meshNumber += 1 }
            guard var points = ScanTrimmer.positions(of: geometry), var elements = ScanTrimmer.triangles(of: geometry) else { return }
            var ownNormals: [SIMD3<Float>] = []
            var ownUVs: [SIMD2<Float>] = []
            if let unified, meshNumber < unified.count, unified[meshNumber].triangles == elements.reduce(0, { $0 + $1.count / 3 }) {
                let mesh = unified[meshNumber]
                points = mesh.positions
                elements = mesh.elements
                if mesh.normals.count == points.count { ownNormals = mesh.normals }
                if mesh.uvs.count == points.count {
                    var flip = true
                    if let own = ScanTrimmer.pictureHeights(of: geometry), own.count == mesh.uvs.count {
                        let mine = mesh.uvs.map(\.y).sorted(), theirs = own.sorted()
                        var plain: Float = 0, flipped: Float = 0
                        for i in mine.indices {
                            plain += abs(mine[i] - theirs[i])
                            flipped += abs((1 - mine[mine.count - 1 - i]) - theirs[i])
                        }
                        flip = flipped < plain
                    }
                    ownUVs = mesh.uvs.map { SIMD2($0.x, flip ? 1 - $0.y : $0.y) }
                }
            } else {
                // SceneKit's own numbers, used only when every source has one entry per point.
                if let source = geometry.sources(for: .normal).first, source.vectorCount == points.count { ownNormals = Self.vectors(source) }
                if let source = geometry.sources(for: .texcoord).first, source.vectorCount == points.count {
                    ownUVs = Self.vectors(source).map { SIMD2($0.x, $0.y) }
                }
            }
            let world = node.simdWorldTransform
            let turn = simd_float3x3(world.columns.0.xyz, world.columns.1.xyz, world.columns.2.xyz)
            let base = UInt32(positions.count)
            positions += points.map { (world * SIMD4($0, 1)).xyz }
            if ownNormals.count == points.count {
                normals += ownNormals.map { let n = turn * $0; return simd_length(n) > 1e-9 ? simd_normalize(n) : SIMD3(0, 1, 0) }
            } else {
                normals += [SIMD3<Float>](repeating: .zero, count: points.count)  // made below
            }
            if ownUVs.count == points.count { uvs += ownUVs } else { allHaveUVs = false; uvs += [SIMD2<Float>](repeating: .zero, count: points.count) }
            for (e, list) in elements.enumerated() {
                let first = triangles.count / 3
                var count = 0
                var t = 0
                while t + 2 < list.count {
                    if Int(list[t]) < points.count, Int(list[t + 1]) < points.count, Int(list[t + 2]) < points.count {
                        triangles += [base + list[t], base + list[t + 1], base + list[t + 2]]
                        count += 1
                    }
                    t += 3
                }
                guard count > 0 else { continue }
                let material = geometry.materials.isEmpty ? nil : geometry.materials[e % geometry.materials.count]
                let image = ownUVs.count == points.count ? material.flatMap { Self.image(from: $0.diffuse.contents) } : nil
                parts.append(BodyMesh.Part(firstTriangle: first, triangleCount: count, texture: image == nil ? nil : "skin\(parts.count).jpg",
                                           color: material.map { Self.color(from: $0.diffuse.contents) } ?? SIMD3(0.7, 0.7, 0.7)))
                pictures.append(image)
            }
        }
        guard !positions.isEmpty, !triangles.isEmpty else { return nil }
        // A picture SceneKit kept inside the file: ModelIO's copy of the first one.
        if pictures.allSatisfy({ $0 == nil }), allHaveUVs, let picture = modelIOPicture(url) {
            pictures = parts.map { _ in picture }
            for i in parts.indices { parts[i].texture = "skin\(i).jpg" }
        }
        if normals.contains(where: { $0 == .zero }) {
            let made = BodyMesh.smoothNormals(positions, triangles)
            for i in normals.indices where normals[i] == .zero { normals[i] = made[i] }
        }
        let textured = parts.filter { $0.texture != nil }.count
        Diagnostics.log("Scan person read: \(url.lastPathComponent), \(meshNumber) meshes, \(positions.count) points, \(triangles.count / 3) triangles, \(parts.count) parts, \(textured) with pictures")
        return (BodyMesh(positions: positions, normals: normals, uvs: allHaveUVs ? uvs : nil, triangles: triangles, parts: parts), pictures)
    }

    private static func vectors(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
        guard source.usesFloatComponents, source.bytesPerComponent == 4 else { return [] }
        let count = source.vectorCount, stride = source.dataStride, offset = source.dataOffset, parts = min(3, source.componentsPerVector)
        let data = source.data
        guard count > 0, stride > 0, data.count >= offset + (count - 1) * stride + parts * 4 else { return [] }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                var v = SIMD3<Float>(0, 0, 0)
                for p in 0..<parts { v[p] = raw.loadUnaligned(fromByteOffset: offset + i * stride + p * 4, as: Float.self) }
                out.append(v)
            }
        }
        return out
    }

    private static func image(from contents: Any?) -> UIImage? {
        guard let contents else { return nil }
        if let image = contents as? UIImage { return image }
        if let url = contents as? URL {
            return UIImage(contentsOfFile: url.path) ?? (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
        }
        if let path = contents as? String { return UIImage(contentsOfFile: path) }
        if let texture = contents as? MDLTexture, let cg = texture.imageFromTexture()?.takeUnretainedValue() { return UIImage(cgImage: cg) }
        let object = contents as AnyObject
        if CFGetTypeID(object) == CGImage.typeID { return UIImage(cgImage: object as! CGImage) }
        return nil
    }

    private static func color(from contents: Any?) -> SIMD3<Float> {
        guard let color = contents as? UIColor else { return SIMD3(0.7, 0.7, 0.7) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }

    private static func modelIOPicture(_ url: URL) -> UIImage? {
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            for submesh in (mesh.submeshes as? [MDLSubmesh]) ?? [] {
                guard let property = submesh.material?.property(with: .baseColor), property.type == .texture,
                      let cg = property.textureSamplerValue?.texture?.imageFromTexture()?.takeUnretainedValue()
                else { continue }
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    // MARK: The front view

    /// The stood-up scan seen from the front, drawn triangle by triangle from the back forwards with its photo's
    /// colours. Drawn here, not by SceneKit, so the dots sit exactly where the body is.
    private static func drawFront(_ mesh: BodyMesh, pictures: [UIImage?], shown: (Float, Float, Float, Float)) -> UIImage {
        let (minX, maxX, minY, maxY) = shown
        let tall: CGFloat = 1400
        let scale = tall / CGFloat(maxY - minY)
        let size = CGSize(width: max(200, (CGFloat(maxX - minX) * scale).rounded()), height: tall)
        let samplers = pictures.map { $0.flatMap(Sampler.init) }
        var partOf = [Int](repeating: 0, count: mesh.triangleCount)
        for (p, part) in mesh.parts.enumerated() {
            for t in part.firstTriangle..<min(mesh.triangleCount, part.firstTriangle + part.triangleCount) { partOf[t] = p }
        }
        let order = (0..<mesh.triangleCount).sorted {
            let a = mesh.positions[Int(mesh.triangles[$0 * 3])].z + mesh.positions[Int(mesh.triangles[$0 * 3 + 1])].z + mesh.positions[Int(mesh.triangles[$0 * 3 + 2])].z
            let b = mesh.positions[Int(mesh.triangles[$1 * 3])].z + mesh.positions[Int(mesh.triangles[$1 * 3 + 1])].z + mesh.positions[Int(mesh.triangles[$1 * 3 + 2])].z
            return a < b
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor(white: 0.12, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.setShouldAntialias(false)
            func point(_ p: SIMD3<Float>) -> CGPoint { CGPoint(x: CGFloat(p.x - minX) * scale, y: CGFloat(maxY - p.y) * scale) }
            for t in order {
                let a = Int(mesh.triangles[t * 3]), b = Int(mesh.triangles[t * 3 + 1]), c = Int(mesh.triangles[t * 3 + 2])
                let pa = mesh.positions[a], pb = mesh.positions[b], pc = mesh.positions[c]
                var colour = mesh.parts.isEmpty ? SIMD3<Float>(0.7, 0.7, 0.7) : mesh.parts[partOf[t]].color
                if let uvs = mesh.uvs, partOf[t] < samplers.count, let sampler = samplers[partOf[t]] {
                    colour = (sampler.color(uvs[a]) + sampler.color(uvs[b]) + sampler.color(uvs[c])) / 3
                }
                // A little shading, so the shape reads.
                let n = simd_cross(pb - pa, pc - pa)
                let facing = simd_length(n) > 1e-12 ? abs(simd_normalize(n).z) : 1
                colour *= 0.72 + 0.28 * facing
                context.setFillColor(red: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1)
                context.beginPath()
                context.move(to: point(pa))
                context.addLine(to: point(pb))
                context.addLine(to: point(pc))
                context.closePath()
                context.fillPath()
            }
        }
    }

    /// A photo's colours, read at 512 pixels.
    private struct Sampler {
        let side = 512
        let pixels: [UInt8]

        init?(_ image: UIImage) {
            guard let cg = image.cgImage else { return nil }
            var buffer = [UInt8](repeating: 0, count: 512 * 512 * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.interpolationQuality = .medium
                context.draw(cg, in: CGRect(x: 0, y: 0, width: 512, height: 512))
                return true
            }
            guard drawn else { return nil }
            pixels = buffer
        }

        /// (0, 0) is the top left, as SceneKit counts.
        func color(_ uv: SIMD2<Float>) -> SIMD3<Float> {
            let u = uv.x - floor(uv.x), v = uv.y - floor(uv.y)
            let x = min(side - 1, max(0, Int(u * Float(side)))), y = min(side - 1, max(0, Int(v * Float(side))))
            let at = (y * side + x) * 4
            return SIMD3(Float(pixels[at]), Float(pixels[at + 1]), Float(pixels[at + 2])) / 255
        }
    }
}

/// The screen: the scan from the front with a dot on each joint Mixamo asks for. Drag a dot that is off; the
/// skeleton follows. "Make person" saves it in the gallery.
struct ScanCharacterScreen: View {
    let folder: ScanFolder
    /// Turns the room camera off (false) while the person is built again, and on again (true) after.
    var roomCamera: ((Bool) -> Void)? = nil
    /// Called on closing, with the saved character when one was made, and true to place it in the room straight away.
    let done: (URL?, Bool) -> Void
    @State private var maker: ScanCharacterMaker?
    @State private var marks = ScanRig.Marks()
    @State private var working: String? = "Finding the joints…"
    @State private var problem: String?
    @State private var saved: URL?
    /// Phil, 2026-11-20: smooth the head and shoulders, keep the body and costume as scanned. Remembered.
    @AppStorage("scanPersonSmoothHead") private var smoothHead = true
    /// Phil, 2026-11-20: another scan's head on this body.
    @State private var donor: ScanCharacterMaker?
    /// Phil, 2026-11-20: facial feature accuracy. Building just the person again, 0 to 1, while it runs.
    @State private var detailProgress: Double?
    @State private var detailTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
            if let maker {
                editor(maker)
            }
            if let detailProgress, working == nil {
                VStack(spacing: 12) {
                    ProgressView(value: detailProgress).tint(Theme.accent).frame(width: 220)
                    Text("Building just the person again from the scan's photos, for a sharper face. \(Int(detailProgress * 100)) %")
                        .font(Theme.subheadline).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Skip") {
                        ScanPersonDetail.skip(folder)
                        detailTask?.cancel()
                        self.detailProgress = nil
                        Diagnostics.log("Scan person: more detail skipped")
                    }
                    .font(Theme.body.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .padding(20)
                .frame(maxWidth: 320)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            }
            if let working {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(working).font(Theme.subheadline).foregroundStyle(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) {
            // Phil, 2026-11-20: words over the head made the chin dot hard to reach. They sit low, above the
            // buttons, and fingers go through them.
            VStack(spacing: 8) {
                if let problem {
                    Text(problem).font(Theme.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).shadow(color: .black, radius: 3)
                        .allowsHitTesting(false)
                } else if maker != nil, saved == nil, working == nil {
                    Text("Drag any dot that's off its joint").font(Theme.footnote).foregroundStyle(.white).shadow(color: .black, radius: 3)
                        .allowsHitTesting(false)
                }
                bottomBar
            }
            .padding(.horizontal, 12)
        }
        .preferredColorScheme(.dark)
        .task { await start() }
    }

    private var topBar: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Cancel") { detailTask?.cancel(); done(nil, false) }
                    .font(Theme.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .disabled(working != nil && maker != nil)
                Spacer()
                if maker != nil, saved == nil {
                    Button { smoothHead.toggle() } label: {
                        Text(smoothHead ? "Smooth head" : "Head as scanned")
                            .font(Theme.subheadline.weight(.semibold)).foregroundStyle(smoothHead ? Theme.onAccent : .white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(smoothHead ? Theme.accent : Color.black.opacity(0.55), in: Capsule())
                    }
                    .disabled(working != nil)
                }
            }
            if maker != nil, saved == nil, working == nil {
                headChooser
                Text(smoothHead ? "Head and shoulders smoothed, the rest as scanned" : "The whole scan, as it is")
                    .font(Theme.caption).foregroundStyle(.white.opacity(0.85)).shadow(color: .black, radius: 3)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Whose head goes on the body: its own, or another person scan's.
    private var headChooser: some View {
        Menu {
            Button { donor = nil } label: { Label("Own head", systemImage: donor == nil ? "checkmark" : "person") }
            ForEach(ScanFolder.all().filter { $0.hasModel && $0 != folder }) { other in
                Button { takeHead(from: other) } label: {
                    Label("Head from \(other.title)", systemImage: donor?.title == other.title ? "checkmark" : "person.crop.circle")
                }
            }
        } label: {
            Text(donor.map { "Head from \($0.title)" } ?? "Own head")
                .font(Theme.subheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().stroke(Theme.accent, lineWidth: donor == nil ? 0 : 2))
        }
    }

    private func takeHead(from other: ScanFolder) {
        working = "Reading the other head…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { ScanCharacterMaker.prepare(other) }.value
            working = nil
            switch result {
            case .success(let made):
                donor = made
                problem = made.found?.handsFound == true ? nil : "The other scan's joints are a guess, so its head may sit a little off."
                Diagnostics.log("Scan person: head from \(made.title)")
            case .failure(let failure):
                problem = "Couldn't take that head: " + failure.words
            }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if let saved {
            VStack(spacing: 10) {
                Text("Saved as “\(saved.deletingPathExtension().lastPathComponent)”. It's first in 3D models, marked New.")
                    .font(Theme.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button { done(saved, false) } label: {
                        Text("Show in 3D models").font(Theme.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10).background(Color.white.opacity(0.15), in: Capsule())
                    }
                    Button { done(saved, true) } label: {
                        Text("Place it now").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 20).padding(.vertical, 10).background(Theme.accent, in: Capsule())
                    }
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 12)
        } else if maker != nil, working == nil, detailProgress == nil {
            HStack {
                Button { turnRound() } label: {
                    Label("Turn round", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(Theme.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10).background(Color.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                Button { make() } label: {
                    Text("Make person").font(Theme.body.weight(.semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 20).padding(.vertical, 10).background(Theme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func editor(_ maker: ScanCharacterMaker) -> some View {
        GeometryReader { geometry in
            let frame = Self.fit(maker.picture.size, in: geometry.size)
            let map = Mapping(frame: frame, shown: maker.shown)
            ZStack(alignment: .topLeading) {
                Image(uiImage: maker.picture)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                // The skeleton the dots make, so a wrong one shows.
                Canvas { context, _ in
                    let joints = maker.joints(marks)
                    var path = Path()
                    for (bone, parent) in ScanRig.parents.enumerated() where parent >= 0 {
                        path.move(to: map.point(joints[parent].x, joints[parent].y))
                        path.addLine(to: map.point(joints[bone].x, joints[bone].y))
                    }
                    context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4)
                    context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 2)
                }
                .allowsHitTesting(false)
                if saved == nil {
                    ForEach(ScanRig.Marks.Name.allCases) { name in
                        dot(name, map: map)
                    }
                }
            }
            .coordinateSpace(name: "person")
        }
        .ignoresSafeArea(edges: .bottom)
        .padding(.top, 56)
        .padding(.bottom, 64)
    }

    private func dot(_ name: ScanRig.Marks.Name, map: Mapping) -> some View {
        let at = map.point(marks[name].x, marks[name].y)
        return ZStack {
            Circle().fill(Theme.accent).frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
            Text(name.word)
                .font(Theme.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
                .fixedSize()
                .offset(x: [ScanRig.Marks.Name.shoulderR, .elbowR, .wristR, .kneeR, .ankleR].contains(name) ? -34 : 34)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .position(at)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("person")).onChanged { value in
            marks[name] = map.metres(value.location)
        })
    }

    /// From the picture's metres to the screen's points and back.
    private struct Mapping {
        let frame: CGRect
        let shown: (minX: Float, maxX: Float, minY: Float, maxY: Float)
        func point(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(x: frame.minX + CGFloat((x - shown.minX) / (shown.maxX - shown.minX)) * frame.width,
                    y: frame.minY + CGFloat((shown.maxY - y) / (shown.maxY - shown.minY)) * frame.height)
        }
        func metres(_ p: CGPoint) -> SIMD2<Float> {
            let u = Float((p.x - frame.minX) / max(frame.width, 1)), v = Float((p.y - frame.minY) / max(frame.height, 1))
            let x = shown.minX + min(max(u, 0), 1) * (shown.maxX - shown.minX)
            let y = shown.maxY - min(max(v, 0), 1) * (shown.maxY - shown.minY)
            return SIMD2(x, y)
        }
    }

    private static func fit(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func start() async {
        let folder = folder
        let result = await Task.detached(priority: .userInitiated) { ScanCharacterMaker.prepare(folder) }.value
        show(result)
        if ScanPersonDetail.crashedLastTime(folder) {
            problem = "Building just the person again stopped the app last time, so this uses the scan as it is."
        } else if case .success(let made) = result, ScanPersonDetail.canRebuild(folder) {
            buildInDetail(made)
        }
    }

    /// Builds just the person again from the scan's photos, then reads that instead. Skip keeps the scan as it is.
    private func buildInDetail(_ made: ScanCharacterMaker) {
        let folder = folder
        let (low, high) = made.modelBox
        // Only a box the size of one person: an untrimmed room would be the whole room built again, for nothing.
        let size = high - low
        guard size.y < 2.4, max(size.x, size.z) < 1.9 else {
            Diagnostics.log(String(format: "Scan person: no more detail, the scan is %.1f x %.1f x %.1f m, more than one person", size.x, size.y, size.z))
            problem = "For a sharper face, trim the scan to just the person first (••• → Trim), then make the person again."
            return
        }
        guard let box = ScanPersonDetail.builderBox(folder, low: low, high: high) else {
            Diagnostics.log("Scan person: no box for more detail")
            return
        }
        detailProgress = 0
        roomCamera?(false)
        detailTask = Task {
            defer { roomCamera?(true) }
            // Let the room camera let go of its memory before the builder starts.
            try? await Task.sleep(for: .seconds(0.7))
            do {
                try await ScanPersonDetail.rebuild(folder, box: box) { fraction in
                    Task { @MainActor in if detailProgress != nil { detailProgress = fraction } }
                }
                detailProgress = nil
                working = "Finding the joints…"
                let result = await Task.detached(priority: .userInitiated) { ScanCharacterMaker.prepare(folder) }.value
                if case .failure = result {
                    // The detailed build didn't read as a person: back to the scan as it was.
                    try? FileManager.default.removeItem(at: ScanPersonDetail.file(folder))
                    ScanPersonDetail.skip(folder)
                    Diagnostics.log("Scan person: the detailed build didn't read as a person, using the scan as it is")
                    show(await Task.detached(priority: .userInitiated) { ScanCharacterMaker.prepare(folder) }.value)
                } else {
                    show(result)
                }
            } catch {
                detailProgress = nil
                if !(error is CancellationError) {
                    Diagnostics.log("Scan person: more detail failed: \(error)")
                    ScanPersonDetail.skip(folder)
                }
            }
        }
    }

    private func turnRound() {
        guard let maker else { return }
        working = "Turning round…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { maker.turnedRound() }.value
            show(result)
        }
    }

    private func show(_ result: Result<ScanCharacterMaker, ScanCharacterMaker.Failure>) {
        working = nil
        switch result {
        case .failure(let failure):
            problem = failure.words
            Diagnostics.log("Scan person: \(failure)")
        case .success(let made):
            maker = made
            marks = made.startingMarks
            if made.found?.handsFound != true {
                problem = "Couldn't find both hands, so some dots are a guess. Drag them onto the joints, or scan again with the arms held a little out from the body."
            } else if made.stance.feetSignal < 0.01 {
                problem = "If you see the person's back, tap Turn round."
            } else {
                problem = nil
            }
        }
    }

    private func make() {
        guard let maker else { return }
        working = "Making the person…"
        let chosen = marks
        let smooth = smoothHead
        let head = donor
        let moved = ScanRig.Marks.Name.allCases.filter { simd_distance(chosen[$0], maker.startingMarks[$0]) > 0.01 }.map(\.rawValue)
        Diagnostics.log("Scan person: making, dots moved: \(moved.isEmpty ? "none" : moved.joined(separator: ", "))")
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do { return .success(try maker.make(chosen, smoothHead: smooth, headFrom: head)) } catch { return .failure(error) }
            }.value
            working = nil
            switch result {
            case .success(let url):
                saved = url
                problem = nil
                Haptics.success()
            case .failure(let error):
                problem = "Couldn't save the person: \(error.localizedDescription)"
                Diagnostics.log("Scan person save failed: \(error)")
                Haptics.warning()
            }
        }
    }
}
