import SceneKit
import UIKit
import simd

/// FBX files, rigged characters among them (Phil, 2026-11-11). The file is kept as it is and read with ufbx
/// (FBX/FBXShim.c) each time it is shown: its shapes, colours and pictures, and for a character its bones and
/// skin, so it can be posed like the example mannequins.
enum FBXImport {
    struct Loaded {
        var node: SCNNode
        var low: SIMD3<Float>
        var high: SIMD3<Float>
        var rig: FBXRig?
    }

    /// Where pictures picked along with the file are kept: "models/<id>.textures" for "models/<id>.fbx".
    static func texturesFolder(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("textures")
    }

    private static func fileName(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    }

    private static func floats<T>(_ tuple: T) -> [Float] {
        withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Float.self)) }
    }

    private static func matrix<T>(_ tuple: T) -> simd_float4x4 {
        let f = floats(tuple)
        guard f.count >= 16 else { return matrix_identity_float4x4 }
        return matrix4(f)
    }

    /// Copies the pictures the file asks for by name, if they were picked with it (they sit next to `source`).
    static func keepTextures(from source: URL, for stored: URL) {
        let opened: UnsafeMutablePointer<rs_scene>? = rs_fbx_load(source.path)
        defer { rs_fbx_free(opened) }
        guard let scene = opened, scene.pointee.mesh_count > 0 else { return }
        let manager = FileManager.default
        let folder = texturesFolder(for: stored)
        for m in 0..<Int(scene.pointee.mesh_count) {
            let mesh = scene.pointee.meshes[m]
            for p in 0..<Int(mesh.part_count) {
                let part = mesh.parts[p]
                let pointer: UnsafePointer<CChar>? = part.texture_name
                guard part.texture_size == 0, let name = pointer else { continue }
                let file = fileName(String(cString: name))
                let from = source.deletingLastPathComponent().appendingPathComponent(file)
                let to = folder.appendingPathComponent(file)
                guard !file.isEmpty, manager.fileExists(atPath: from.path), !manager.fileExists(atPath: to.path) else { continue }
                try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try? manager.copyItem(at: from, to: to)
            }
        }
    }

    static func load(_ url: URL, name: String) -> Loaded? {
        let opened: UnsafeMutablePointer<rs_scene>? = rs_fbx_load(url.path)
        defer { rs_fbx_free(opened) }
        guard let scene = opened else { return nil }
        let file = scene.pointee
        guard file.node_count > 0, file.mesh_count > 0 else {
            let reason = withUnsafeBytes(of: file.error) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
            Diagnostics.log("FBX: could not read \(name): \(reason)")
            return nil
        }

        // The nodes, as the file has them.
        var rigNodes: [RigNode] = []
        var nodes: [SCNNode] = []
        for i in 0..<Int(file.node_count) {
            let n = file.nodes[i]
            let made = SCNNode()
            let namePointer: UnsafePointer<CChar>? = n.name
            made.name = namePointer.map { String(cString: $0) } ?? ""
            let local = matrix(n.local)
            made.simdTransform = local
            nodes.append(made)
            rigNodes.append(RigNode(name: made.name ?? "", parent: Int(n.parent), isBone: n.is_bone != 0, local: local, world: matrix(n.world)))
        }
        let top = SCNNode()
        top.name = "fbx"
        for (i, n) in rigNodes.enumerated() {
            if n.parent >= 0, n.parent < nodes.count, n.parent != i { nodes[n.parent].addChildNode(nodes[i]) } else { top.addChildNode(nodes[i]) }
        }

        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var pictures: [String: UIImage] = [:]
        let textures = texturesFolder(for: url)
        var vertices = 0, skinned = 0, bones = 0
        for m in 0..<Int(file.mesh_count) {
            let mesh = file.meshes[m]
            let count = Int(mesh.vertex_count)
            let positionPointer: UnsafeMutablePointer<Float>? = mesh.positions, normalPointer: UnsafeMutablePointer<Float>? = mesh.normals
            guard count >= 3, let positions = positionPointer, let normals = normalPointer else { continue }
            vertices += count
            var sources = [
                SCNGeometrySource(data: Data(bytes: positions, count: count * 12), semantic: .vertex, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
                SCNGeometrySource(data: Data(bytes: normals, count: count * 12), semantic: .normal, vectorCount: count, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12),
            ]
            let uvPointer: UnsafeMutablePointer<Float>? = mesh.uvs
            if let uvs = uvPointer {
                sources.append(SCNGeometrySource(data: Data(bytes: uvs, count: count * 8), semantic: .texcoord, vectorCount: count, usesFloatComponents: true,
                                                 componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8))
            }
            var elements: [SCNGeometryElement] = []
            var materials: [SCNMaterial] = []
            for p in 0..<Int(mesh.part_count) {
                let part = mesh.parts[p]
                let start = Int(part.vertex_start), length = Int(part.vertex_count) / 3 * 3
                guard length >= 3, start + length <= count else { continue }
                elements.append(SCNGeometryElement(indices: (start..<(start + length)).map { UInt32($0) }, primitiveType: .triangles))
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.roughness.contents = 0.7
                material.isDoubleSided = true
                var picture: UIImage?
                if uvPointer != nil {
                    let pointer: UnsafePointer<CChar>? = part.texture_name
                    let key = pointer.map { fileName(String(cString: $0)) } ?? ""
                    let embedded: UnsafeRawPointer? = part.texture_data
                    if let data = embedded, part.texture_size > 0 {
                        let cacheKey = "embedded-\(UInt(bitPattern: data))"
                        picture = pictures[cacheKey] ?? UIImage(data: Data(bytes: data, count: part.texture_size))
                        pictures[cacheKey] = picture
                    } else if !key.isEmpty {
                        picture = pictures[key] ?? UIImage(contentsOfFile: textures.appendingPathComponent(key).path)
                        pictures[key] = picture
                    }
                }
                if let picture {
                    material.diffuse.contents = picture
                } else {
                    let c = floats(part.color)
                    material.diffuse.contents = c.count >= 3 ? UIColor(red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1) : UIColor(white: 0.62, alpha: 1)
                }
                materials.append(material)
            }
            guard !elements.isEmpty else { continue }
            let geometry = SCNGeometry(sources: sources, elements: elements)
            geometry.materials = materials
            let holder = SCNNode()
            holder.name = "fbx.mesh"
            holder.geometry = geometry
            var toModel = matrix_identity_float4x4
            let boneCount = Int(mesh.bone_count)
            let boneNodePointer: UnsafeMutablePointer<Int32>? = mesh.bone_nodes, bindPointer: UnsafeMutablePointer<Float>? = mesh.bone_inverse_bind
            let indexPointer: UnsafeMutablePointer<UInt16>? = mesh.bone_indices, weightPointer: UnsafeMutablePointer<Float>? = mesh.bone_weights
            if boneCount > 0, let boneNodes = boneNodePointer, let binds = bindPointer, let indices = indexPointer, let weights = weightPointer {
                // Skinned: the shape is already standing in the model's space; the bones carry it from there.
                var joints: [SCNNode] = []
                var inverse: [NSValue] = []
                for b in 0..<boneCount {
                    let index = Int(boneNodes[b])
                    joints.append(index >= 0 && index < nodes.count ? nodes[index] : top)
                    let bind = index >= 0 && index < nodes.count
                        ? matrix4((0..<16).map { binds[b * 16 + $0] }) : matrix_identity_float4x4
                    inverse.append(NSValue(scnMatrix4: SCNMatrix4(bind)))
                }
                let weightSource = SCNGeometrySource(data: Data(bytes: weights, count: count * 16), semantic: .boneWeights, vectorCount: count, usesFloatComponents: true,
                                                     componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
                let indexSource = SCNGeometrySource(data: Data(bytes: indices, count: count * 8), semantic: .boneIndices, vectorCount: count, usesFloatComponents: false,
                                                    componentsPerVector: 4, bytesPerComponent: 2, dataOffset: 0, dataStride: 8)
                let skinner = SCNSkinner(baseGeometry: geometry, bones: joints, boneInverseBindTransforms: inverse, boneWeights: weightSource, boneIndices: indexSource)
                skinner.skeleton = top
                holder.skinner = skinner
                top.addChildNode(holder)
                skinned += 1
                bones = max(bones, boneCount)
            } else {
                let index = Int(mesh.node)
                if index >= 0, index < nodes.count {
                    nodes[index].addChildNode(holder)
                    toModel = rigNodes[index].world
                } else {
                    top.addChildNode(holder)
                }
            }
            // Its box in the model's space, from a spread of its points.
            for v in stride(from: 0, to: count, by: max(1, count / 4000)) {
                let p = toModel * SIMD4(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2], 1)
                low = simd_min(low, p.xyz)
                high = simd_max(high, p.xyz)
            }
        }
        guard vertices > 0, low.x <= high.x else {
            Diagnostics.log("FBX: nothing to show in \(name)")
            return nil
        }
        // A file that says metres but was made in centimetres stands over 10 m tall: read it as centimetres.
        let largest = max(high.x - low.x, high.y - low.y, high.z - low.z)
        let scale: Float = largest > 10 ? 0.01 : 1
        let lift = SCNNode()
        lift.name = "fbx.lift"
        lift.addChildNode(top)
        let sized = SCNNode()
        sized.name = "fbx.size"
        sized.simdScale = SIMD3(repeating: scale)
        sized.addChildNode(lift)

        var rig: FBXRig?
        var found = "no skeleton to pose"
        if skinned > 0, let map = RigFinder.find(rigNodes) {
            rig = FBXRig(nodes: nodes, lift: lift, poser: RigPoser(nodes: rigNodes, map: map), height: (high.y - low.y) * scale)
            found = "joints from " + (map.fromNames ? "bone names" : "the skeleton's shape") + (map.facing < 0 ? ", facing back" : "")
                + ", arm \(rigNodes[map.armL[0]].name) > \(rigNodes[map.armL[1]].name), leg \(rigNodes[map.legL[0]].name) > \(rigNodes[map.legL[1]].name)"
        } else if skinned > 0 {
            found = "joints not found"
        }
        Diagnostics.log(String(format: "FBX: %@, %d nodes, %d shapes (%d skinned, %d bones), %d corners, %.2f x %.2f x %.2f m, %@",
                               name, Int(file.node_count), Int(file.mesh_count), skinned, bones, vertices,
                               (high.x - low.x) * scale, (high.y - low.y) * scale, (high.z - low.z) * scale, found))
        return Loaded(node: sized, low: low * scale, high: high * scale, rig: rig)
    }
}

/// An imported character's bones in the scene, and how to pose them.
final class FBXRig {
    private let nodes: [SCNNode]
    private let lift: SCNNode
    let poser: RigPoser
    let height: Float

    init(nodes: [SCNNode], lift: SCNNode, poser: RigPoser, height: Float) {
        self.nodes = nodes
        self.lift = lift
        self.poser = poser
        self.height = height
    }

    /// Nil puts it back as the file has it.
    func apply(_ pose: MannequinPose?) {
        let posed = poser.locals(for: pose)
        for (i, node) in nodes.enumerated() where i < posed.locals.count { node.simdTransform = posed.locals[i] }
        lift.simdPosition = SIMD3(0, posed.lift, 0)
    }
}
