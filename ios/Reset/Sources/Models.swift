import ARKit
import Foundation
import SceneKit
import UIKit

/// A 3D model (USDZ) placed in a reference's room, for example a Polycam scan of a prop, kept in
/// the reference's room coordinates so it comes back in the same place.
struct PlacedModel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var file: String  // relative to the reference folder
    var transform: [Float]  // model-to-world, 16 values, column major
}

extension Restorer: UIGestureRecognizerDelegate {
    /// Copies a USDZ into the reference and places it at real size where the camera is pointing.
    func addModel(from source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let file = "models/\(id.uuidString).usdz"
        let destination = ReferenceStore.folder(for: reference.id).appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            modelError = "Could not copy the model: \(error.localizedDescription)"
            return
        }
        let model = PlacedModel(
            id: id, name: source.deletingPathExtension().lastPathComponent, file: file,
            transform: flatten(placementTransform()))
        guard loadNode(for: model) != nil else {
            try? FileManager.default.removeItem(at: destination)
            modelError = "Could not open \(source.lastPathComponent) as a 3D model."
            return
        }
        models.append(model)
        selectedModel = id
    }

    func loadSavedModels() {
        for model in models where modelNodes[model.id] == nil {
            _ = loadNode(for: model)
        }
    }

    var selectedModelName: String? {
        models.first { $0.id == selectedModel }?.name
    }

    /// Back to the size it was made at (USDZ files are in metres).
    func resetSelectedModelSize() {
        guard let id = selectedModel, let node = modelNodes[id] else { return }
        node.simdScale = SIMD3(repeating: 1)
        commit(id)
    }

    func deleteSelectedModel() {
        guard let id = selectedModel, let index = models.firstIndex(where: { $0.id == id }) else { return }
        modelNodes[id]?.removeFromParentNode()
        modelNodes[id] = nil
        try? FileManager.default.removeItem(at: ReferenceStore.folder(for: reference.id).appendingPathComponent(models[index].file))
        models.remove(at: index)
        selectedModel = nil
    }

    /// Tap a model to select it; drag moves it over surfaces, pinch scales, twist turns.
    func attachGestures(to view: ARSCNView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        for gesture in [tap, pan, pinch, rotate] as [UIGestureRecognizer] {
            gesture.delegate = self
            view.addGestureRecognizer(gesture)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? ARSCNView else { return }
        let hits = view.hitTest(gesture.location(in: view), options: nil)
        selectedModel = hits.lazy.compactMap { self.modelID(of: $0.node) }.first
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let id = selectedModel, let node = modelNodes[id], let view = gesture.view as? ARSCNView,
            let query = view.raycastQuery(from: gesture.location(in: view), allowing: .estimatedPlane, alignment: .any),
            let hit = session.raycast(query).first
        else { return }
        node.simdWorldPosition = hit.worldTransform.columns.3.xyz
        if gesture.state == .ended { commit(id) }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let id = selectedModel, let node = modelNodes[id] else { return }
        node.simdScale *= Float(gesture.scale)
        gesture.scale = 1
        if gesture.state == .ended { commit(id) }
    }

    @objc private func handleRotate(_ gesture: UIRotationGestureRecognizer) {
        guard let id = selectedModel, let node = modelNodes[id] else { return }
        node.simdEulerAngles.y -= Float(gesture.rotation)
        gesture.rotation = 0
        if gesture.state == .ended { commit(id) }
    }

    private func commit(_ id: UUID) {
        guard let node = modelNodes[id], let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].transform = flatten(node.simdTransform)
    }

    private func modelID(of node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let candidate = current {
            if candidate.parent === modelsNode, let name = candidate.name { return UUID(uuidString: name) }
            current = candidate.parent
        }
        return nil
    }

    @discardableResult
    private func loadNode(for model: PlacedModel) -> SCNNode? {
        let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(model.file)
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
        let node = SCNNode()
        node.name = model.id.uuidString
        for child in scene.rootNode.childNodes {
            node.addChildNode(child)
        }
        node.simdTransform = matrix4(model.transform)
        modelsNode.addChildNode(node)
        modelNodes[model.id] = node
        return node
    }

    /// On the surface in the middle of the screen, or a metre ahead if there is none.
    private func placementTransform() -> simd_float4x4 {
        var transform = matrix_identity_float4x4
        guard let frame = session.currentFrame else { return transform }
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .any)
        if let hit = session.raycast(query).first {
            transform.columns.3 = hit.worldTransform.columns.3
        } else {
            let camera = frame.camera.transform
            transform.columns.3 = SIMD4(camera.columns.3.xyz - camera.columns.2.xyz, 1)
        }
        return transform
    }
}
