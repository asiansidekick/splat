import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import UniformTypeIdentifiers

/// STL and OBJ files next to USDZ (Phil, 2026-11-10). Each is turned into a USDZ when it comes in, so placing,
/// moving and syncing a model work exactly as before.
enum ModelImport {
    /// What the file picker offers: USDZ, OBJ, STL and FBX (plus the textures and .mtl an OBJ needs, picked with it).
    static let pickerTypes: [UTType] = {
        var types: [UTType] = [.usdz, .usd]
        for ending in ["obj", "stl", "mtl", "fbx"] { if let type = UTType(filenameExtension: ending) { types.append(type) } }
        types += [.png, .jpeg, .image]
        return types
    }()

    static let modelEndings: Set<String> = ["usdz", "usd", "usdc", "usda", "obj", "stl", "fbx"]

    /// Copies everything picked into one folder, so an OBJ finds the .mtl and pictures picked with it,
    /// and returns the model files among them.
    static func gather(_ picked: [URL]) -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModelImport-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var models: [URL] = []
        for url in picked {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else {
                // Not copyable (already ours, for example): use it where it is.
                if modelEndings.contains(url.pathExtension.lowercased()) { models.append(url) }
                continue
            }
            if modelEndings.contains(copy.pathExtension.lowercased()) { models.append(copy) }
        }
        return models
    }

    /// Writes `source` as a USDZ at `destination`. USDZ is copied as it is; anything else goes through Model I/O.
    static func store(_ source: URL, at destination: URL) throws {
        let ending = source.pathExtension.lowercased()
        if ending == "usdz" {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        let asset = MDLAsset(url: source)
        asset.loadTextures()
        let loaded = SCNScene(mdlAsset: asset)
        let holder = SCNNode()
        for child in loaded.rootNode.childNodes { holder.addChildNode(child) }
        var geometries = 0
        holder.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            geometries += 1
            // STL carries no colour: a plain grey that still shows its shape under the room's light.
            if ending == "stl" || geometry.materials.isEmpty {
                let grey = SCNMaterial()
                grey.lightingModel = .physicallyBased
                grey.diffuse.contents = UIColor(white: 0.62, alpha: 1)
                grey.roughness.contents = 0.7
                geometry.materials = [grey]
            }
        }
        guard geometries > 0 else { throw ImportError.empty }
        // STL and OBJ have no units. Most are millimetres (3D printing, CAD); something over 10 units big
        // would be over 10 m in metres, so it is read as millimetres. Size can be corrected in the app.
        let (low, high) = holder.boundingBox
        let largest = max(high.x - low.x, high.y - low.y, high.z - low.z)
        let scale: Float = largest > 10 ? 0.001 : 1
        holder.simdScale = SIMD3(repeating: scale)
        if ending == "stl" {
            // STL files are nearly always Z-up (3D printing): stand them up for ARKit's Y-up.
            holder.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        }
        let scene = SCNScene()
        scene.rootNode.addChildNode(holder)
        Diagnostics.log(String(format: "Model import: %@, %d geometries, largest side %.2f units, scale %.3f",
                               source.lastPathComponent, geometries, largest, scale))
        guard scene.write(to: destination, options: nil, delegate: nil, progressHandler: nil),
              FileManager.default.fileExists(atPath: destination.path) else { throw ImportError.notWritten }
    }

    enum ImportError: Error { case empty, notWritten }
}
