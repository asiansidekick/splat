import ARKit
import Foundation
import SceneKit
import SwiftUI
import UIKit

/// Places USDZ models at real size in an AR session and lets the person move, scale and turn
/// them. Used while recording (models then go into each saved reference) and while resetting.
@MainActor
final class ModelPlacer: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    @Published var models: [PlacedModel] = []
    @Published var selectedModel: UUID? {
        didSet { updateSize() }
    }
    @Published var modelError: String?
    /// The selected model's real size, for example "62 × 40 × 75 cm · 100%".
    @Published private(set) var sizeText = ""
    /// True while a pinch is changing the size, to show it large.
    @Published private(set) var pinching = false
    /// Height, width and depth arrows with lengths drawn on every model (Phil, 2026-10-30).
    @Published var showDimensions = UserDefaults.standard.object(forKey: "showModelDimensions") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showDimensions, forKey: "showModelDimensions")
            modelNodes.keys.forEach(refreshDimensions)
        }
    }
    private var modelNodes: [UUID: SCNNode] = [:]
    /// Each model's box in its own coordinates, measured on loading, before any arrows are hung
    /// on it (they would make it look bigger).
    private var boxes: [UUID: (low: SIMD3<Float>, high: SIMD3<Float>)] = [:]
    /// While dragging: from where the finger's ray meets the model's floor height to the model,
    /// so the model keeps its place under the finger instead of jumping to it.
    private var dragOffset: SIMD3<Float>?
    /// One-finger drags move the selected model up and down instead of across (Phil, 2026-10-31).
    @Published var lifting = false
    private weak var cameraView: ARSCNView?
    private var depthCache: (time: TimeInterval, depth: Measurer.Depth)?
    /// True while something else (measuring) uses one-finger drags on the camera view.
    var isSuspended: () -> Bool = { false }
    let session: ARSession
    /// Models are added under this node, in the session's world coordinates.
    let root: SCNNode
    /// Model files are stored here, at each model's `file` path.
    let folder: URL

    init(session: ARSession, root: SCNNode, folder: URL) {
        self.session = session
        self.root = root
        self.folder = folder
    }

    /// Copies the USDZ files in and places them side by side where the camera is pointing.
    func add(from sources: [URL]) {
        guard let frame = session.currentFrame else {
            modelError = "Point the camera at the set first, then add the models."
            return
        }
        let base = placementTransform(frame)
        var right = frame.camera.transform.columns.0.xyz
        right.y = 0
        right = simd_length(right) > 0.01 ? simd_normalize(right) : SIMD3(1, 0, 0)
        var added: UUID?
        var failed: [String] = []
        for (index, source) in sources.enumerated() {
            // 40 cm apart along the floor, so several models do not land on top of each other.
            let offset = (Float(index) - Float(sources.count - 1) / 2) * 0.4
            var transform = base
            transform.columns.3 += SIMD4(right * offset, 0)
            if let id = add(source, at: transform) { added = id } else { failed.append(source.lastPathComponent) }
        }
        if !failed.isEmpty { modelError = "Could not open \(failed.joined(separator: ", ")) as a 3D model." }
        if let added { selectedModel = added }
        Diagnostics.log("Models added: \(sources.count - failed.count), failed \(failed.count)")
    }

    private func add(_ source: URL, at transform: simd_float4x4) -> UUID? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let file = "models/\(id.uuidString).usdz"
        let destination = folder.appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }
        let model = PlacedModel(id: id, name: source.deletingPathExtension().lastPathComponent, file: file, transform: flatten(transform))
        guard loadNode(for: model) != nil else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        models.append(model)
        return id
    }

    /// Shows models saved with a reference.
    func load(_ saved: [PlacedModel]) {
        models = saved
        for model in saved where modelNodes[model.id] == nil {
            loadNode(for: model)
        }
    }

    /// Takes every model out of the scene (the files stay).
    func removeAll() {
        modelNodes.values.forEach { $0.removeFromParentNode() }
        modelNodes = [:]
        boxes = [:]
        models = []
        selectedModel = nil
    }

    /// Copies the model files into another folder, for example a newly saved reference.
    func copyFiles(to destination: URL) throws {
        for model in models {
            let target = destination.appendingPathComponent(model.file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: folder.appendingPathComponent(model.file), to: target)
            }
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
        updateSize()
        refreshDimensions(id)
    }

    func deleteSelectedModel() {
        guard let id = selectedModel, let index = models.firstIndex(where: { $0.id == id }) else { return }
        modelNodes[id]?.removeFromParentNode()
        modelNodes[id] = nil
        boxes[id] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(models[index].file))
        models.remove(at: index)
        selectedModel = nil
    }

    /// Tap a model to select it; drag moves it over surfaces, pinch scales, twist turns.
    func attachGestures(to view: ARSCNView) {
        cameraView = view
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

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? ARSCNView else { return }
        let hits = view.hitTest(gesture.location(in: view), options: nil)
        selectedModel = hits.lazy.compactMap { self.modelID(of: $0.node) }.first
    }

    /// Drags the model across the room. Where the LiDAR sees a surface under the finger (the floor, a
    /// table), the model stands on it; with none, it slides across the level plane at its own height,
    /// which works with no surface found, unlike a raycast. With Lift on, a drag moves it up and down.
    /// Picks up the model under the finger (or the only one) when none is selected.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isSuspended(), let view = gesture.view as? ARSCNView else { return }
        let location = gesture.location(in: view)
        if gesture.state == .began {
            let touched = view.hitTest(location, options: nil).lazy.compactMap { self.modelID(of: $0.node) }.first
            if let touched {
                selectedModel = touched
            } else if selectedModel == nil, models.count == 1 {
                selectedModel = models[0].id
            }
            dragOffset = nil
        }
        guard let id = selectedModel, let node = modelNodes[id] else { return }
        if lifting {
            switch gesture.state {
            case .changed:
                let delta = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                let camera = session.currentFrame?.camera.transform.columns.3.xyz ?? node.simdWorldPosition
                // About a millimetre and a half per point for each metre away.
                node.simdWorldPosition.y -= Float(delta.y) * 0.0016 * max(simd_distance(camera, node.simdWorldPosition), 0.3)
            case .ended, .cancelled:
                commit(id)
            default:
                break
            }
            return
        }
        guard let point = floorPoint(location, in: view, height: node.simdWorldPosition.y) else { return }
        let hit = surface(at: location, in: view)
        switch gesture.state {
        case .began:
            let anchor = hit ?? point
            dragOffset = SIMD3(node.simdWorldPosition.x - anchor.x, 0, node.simdWorldPosition.z - anchor.z)
            if hit == nil { dragOffset?.y = node.simdWorldPosition.y - point.y }
        case .changed:
            move(node, id: id, level: point, surface: hit)
        case .ended, .cancelled:
            if gesture.state == .ended { move(node, id: id, level: point, surface: hit) }
            dragOffset = nil
            commit(id)
        default:
            break
        }
    }

    private func move(_ node: SCNNode, id: UUID, level: SIMD3<Float>, surface: SIMD3<Float>?) {
        let offset = dragOffset ?? .zero
        guard let surface else {
            node.simdWorldPosition = level + offset
            return
        }
        // The lowest point of the model rests on the surface, eased so a noisy reading doesn't shake it.
        let bottom = (boxes[id]?.low.y ?? 0) * node.simdScale.y
        let wanted = surface.y - bottom
        let y = node.simdWorldPosition.y * 0.6 + wanted * 0.4
        node.simdWorldPosition = SIMD3(surface.x + offset.x, y, surface.z + offset.z)
    }

    /// The surface the LiDAR sees under a place on the screen, in the room's coordinates.
    private func surface(at location: CGPoint, in view: ARSCNView) -> SIMD3<Float>? {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState else { return nil }
        let depth: Measurer.Depth
        if let cache = depthCache, cache.time == frame.timestamp {
            depth = cache.depth
        } else if let fresh = Measurer.depth(of: frame) {
            depthCache = (frame.timestamp, fresh)
            depth = fresh
        } else {
            return nil
        }
        return Measurer.point(in: frame, depth: depth, at: location, view: view)
    }

    /// Stands the selected model on the floor under it: looks down the screen from the model for the
    /// LiDAR surface nearest to straight beneath it, and sets the model's lowest point on that.
    func dropToFloor() {
        guard let id = selectedModel, let node = modelNodes[id], let view = cameraView else { return }
        let base = node.simdWorldPosition
        let shown = view.projectPoint(SCNVector3(base.x, base.y, base.z))
        guard shown.z > 0, shown.z < 1, view.bounds.height > 0 else {
            modelError = "Keep the model on the screen, with the floor under it in view."
            return
        }
        var best: SIMD3<Float>?
        var bestDistance = Float.infinity
        var y = CGFloat(shown.y)
        while y < view.bounds.height - 8 {
            if let p = surface(at: CGPoint(x: CGFloat(shown.x), y: y), in: view), p.y <= base.y + 0.05 {
                let d = hypot(p.x - base.x, p.z - base.z)
                if d < bestDistance {
                    bestDistance = d
                    best = p
                }
            }
            y += 14
        }
        guard let floor = best else {
            modelError = "Couldn't see the floor under the model. Tilt the phone down a little and try again."
            return
        }
        node.simdWorldPosition.y = floor.y - (boxes[id]?.low.y ?? 0) * node.simdScale.y
        Haptics.success()
        commit(id)
    }

    /// Where the finger's ray meets the level plane at `height`, nil when it points above it
    /// or the meeting point is very far off.
    private func floorPoint(_ location: CGPoint, in view: ARSCNView, height: Float) -> SIMD3<Float>? {
        let near = SIMD3<Float>(view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0)))
        let far = SIMD3<Float>(view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1)))
        let direction = far - near
        guard abs(direction.y) > 1e-6 else { return nil }
        let t = (height - near.y) / direction.y
        guard t > 0 else { return nil }
        let point = near + direction * t
        guard simd_distance(point, near) < 15 else { return nil }
        return point
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard !isSuspended(), let id = selectedModel, let node = modelNodes[id] else { return }
        node.simdScale *= Float(gesture.scale)
        gesture.scale = 1
        updateSize()
        refreshDimensions(id)
        let active = gesture.state == .began || gesture.state == .changed
        if pinching != active { pinching = active }
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
        models[index].moved = Date()
    }

    /// Width × depth × height of the selected model as it stands, and its scale.
    private func updateSize() {
        guard let id = selectedModel, let node = modelNodes[id] else {
            sizeText = ""
            return
        }
        guard let box = boxes[id] else {
            sizeText = ""
            return
        }
        let scale = node.simdScale
        let size = (box.high - box.low) * scale
        let percent = Int((scale.x * 100).rounded())
        sizeText = "\(ModelPlacer.length(size.x)) × \(ModelPlacer.length(size.z)) × \(ModelPlacer.length(size.y)) · \(percent)%"
    }

    /// Centimetres up to 2 m, metres above.
    static func length(_ metres: Float) -> String {
        metres < 2 ? "\(Int((metres * 100).rounded())) cm" : String(format: "%.2f m", metres)
    }

    private func modelID(of node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let candidate = current {
            if candidate.parent === root, let name = candidate.name { return UUID(uuidString: name) }
            current = candidate.parent
        }
        return nil
    }

    @discardableResult
    private func loadNode(for model: PlacedModel) -> SCNNode? {
        let url = folder.appendingPathComponent(model.file)
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
        let node = SCNNode()
        node.name = model.id.uuidString
        for child in scene.rootNode.childNodes {
            node.addChildNode(child)
        }
        let (low, high) = node.boundingBox
        boxes[model.id] = (SIMD3<Float>(low), SIMD3<Float>(high))
        node.simdTransform = matrix4(model.transform)
        root.addChildNode(node)
        modelNodes[model.id] = node
        refreshDimensions(model.id)
        return node
    }

    /// Hangs fresh arrows on the model for its size now, or takes them off when turned off.
    private func refreshDimensions(_ id: UUID) {
        guard let node = modelNodes[id] else { return }
        node.childNode(withName: ModelDimensions.nodeName, recursively: false)?.removeFromParentNode()
        guard showDimensions, let box = boxes[id] else { return }
        node.addChildNode(ModelDimensions.make(low: box.low, high: box.high, scale: node.simdScale.x))
    }

    /// On the surface in the middle of the screen, or a metre ahead if there is none.
    private func placementTransform(_ frame: ARFrame) -> simd_float4x4 {
        var transform = matrix_identity_float4x4
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

/// Over the camera: the selected model's controls, and any error adding models.
struct ModelOverlay: View {
    @ObservedObject var placer: ModelPlacer

    var body: some View {
        Group {
            if let name = placer.selectedModelName {
                VStack(alignment: .leading, spacing: 4) {
                    Text(placer.lifting ? "\(name): drag up or down to lift it" : "\(name): drag to move (it stands on surfaces), pinch to scale, twist to turn").font(.caption2)
                    Text("W × D × H  \(placer.sizeText)").font(.caption.bold().monospacedDigit())
                    HStack {
                        Button {
                            placer.showDimensions.toggle()
                        } label: {
                            Image(systemName: placer.showDimensions ? "ruler.fill" : "ruler")
                        }
                        .accessibilityLabel(placer.showDimensions ? "Hide size arrows" : "Show size arrows")
                        Button {
                            placer.lifting.toggle()
                        } label: {
                            Image(systemName: "arrow.up.and.down")
                        }
                        .tint(placer.lifting ? .yellow : nil)
                        .accessibilityLabel(placer.lifting ? "Drag moves it across again" : "Drag lifts it up and down")
                        Button("Floor") { placer.dropToFloor() }
                        Button("True size") { placer.resetSelectedModelSize() }
                        Button("Delete", role: .destructive) { placer.deleteSelectedModel() }
                        Spacer()
                        Button("Done") { placer.selectedModel = nil }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 420)
            }
        }
        .alert("3D model", isPresented: Binding(get: { placer.modelError != nil }, set: { if !$0 { placer.modelError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(placer.modelError ?? "")
        }
    }
}

/// The selected model's size, large in the middle of the screen while pinching, so it can be read
/// at a glance.
struct ModelSizeBadge: View {
    @ObservedObject var placer: ModelPlacer

    var body: some View {
        if placer.pinching {
            Text(placer.sizeText)
                .font(.title2.bold().monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .allowsHitTesting(false)
        }
    }
}
