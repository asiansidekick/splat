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
    /// Scrapbook cut-outs on show: each turns to the photo that matches the side the camera sees.
    private struct CutoutState {
        let plane: SCNNode
        let height: Float
        let angles: [Float]
        let aspects: [Float]
        let images: [UIImage]
        var shown: Int
    }
    private var cutouts: [UUID: CutoutState] = [:]
    /// The saved description of each cut-out, kept so a new pose can be written back to its file.
    private var cutoutPackages: [UUID: CutoutPackage] = [:]
    private var cutoutTimer: Timer?
    /// Each model's box in its own coordinates, measured on loading, before any arrows are hung
    /// on it (they would make it look bigger).
    private var boxes: [UUID: (low: SIMD3<Float>, high: SIMD3<Float>)] = [:]
    /// While dragging: from where the finger's ray meets the model's floor height to the model,
    /// so the model keeps its place under the finger instead of jumping to it.
    private var dragOffset: SIMD3<Float>?
    /// One-finger drags move the selected model up and down instead of across (Phil, 2026-10-31).
    @Published var lifting = false
    /// The room is dim enough that the phone may lose its place, so cut-outs can drift (Phil, 2026-11-07).
    @Published private(set) var dimLight = false
    private weak var cameraView: SCNView?
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
        var right = frame.camera.transform.columns.0.xyz
        right.y = 0
        right = simd_length(right) > 0.01 ? simd_normalize(right) : SIMD3(1, 0, 0)
        add(from: sources, at: placementTransform(frame), right: right)
    }

    /// Places the models side by side from `base`, spread along `right` (also used with a saved frame, with no live camera).
    func add(from sources: [URL], at base: simd_float4x4, right: SIMD3<Float>) {
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
        cutouts = [:]
        stopCutoutTimer()
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

    /// Brings the selected model (or the newest, when none is selected) back to the middle of the view at its
    /// normal size, for when it has been lost off screen, very far away, or scaled tiny or huge.
    func bringToView() {
        guard let id = selectedModel ?? models.last?.id, let node = modelNodes[id] else { return }
        guard let frame = session.currentFrame else {
            modelError = "Point the camera at the set first."
            return
        }
        node.simdScale = SIMD3(repeating: 1)
        var spot = placementTransform(frame).columns.3.xyz
        spot.y -= boxes[id]?.low.y ?? 0
        node.simdWorldPosition = spot
        selectedModel = id
        Haptics.success()
        commit(id)
        updateSize()
        refreshDimensions(id)
    }

    /// Tipped back or forward, and slanted sideways, about the card's foot.
    private static func poseMatrix(tilt: Float, skew: Float, turn: Float = 0) -> simd_float4x4 {
        let t = tilt * .pi / 180
        var shear = matrix_identity_float4x4
        shear.columns.1.x = tan(min(max(skew, -60), 60) * .pi / 180)  // x grows with height
        let rotation = simd_float4x4(simd_quatf(angle: -t, axis: SIMD3(1, 0, 0)))
        // The card also swings round its upright axis as the person twists it, up to 70 degrees (the holder always
        // faces the camera, so without this a twist changed only the photo and nothing seemed to turn).
        let swing = simd_float4x4(simd_quatf(angle: min(max(turn, -1.22), 1.22), axis: SIMD3(0, 1, 0)))
        return swing * rotation * shear
    }

    /// How far each cut-out has been twisted this session, in radians (wrapped to -pi...pi).
    private var cutoutTurn: [UUID: Float] = [:]

    var selectedIsCutout: Bool { selectedModel.map { cutoutPackages[$0] != nil } ?? false }

    /// Tips or slants the selected cut-out a step (degrees), and keeps the pose in its file.
    func nudgePose(tilt: Float = 0, skew: Float = 0) {
        guard let id = selectedModel, var package = cutoutPackages[id], let model = models.first(where: { $0.id == id }),
              let plane = cutouts[id]?.plane else { return }
        package.tilt = min(max(package.tilt + tilt, -80), 80)
        package.skew = min(max(package.skew + skew, -60), 60)
        savePose(package, id: id, file: model.file, plane: plane)
    }

    func resetPose() {
        guard let id = selectedModel, var package = cutoutPackages[id], let model = models.first(where: { $0.id == id }),
              let plane = cutouts[id]?.plane else { return }
        package.tilt = 0
        package.skew = 0
        cutoutTurn[id] = 0
        savePose(package, id: id, file: model.file, plane: plane)
    }

    private func savePose(_ package: CutoutPackage, id: UUID, file: String, plane: SCNNode) {
        cutoutPackages[id] = package
        plane.simdTransform = Self.poseMatrix(tilt: package.tilt, skew: package.skew, turn: cutoutTurn[id] ?? 0)
        try? JSONEncoder().encode(package).write(to: folder.appendingPathComponent(file), options: .atomic)
        if let index = models.firstIndex(where: { $0.id == id }) { models[index].moved = Date() }
    }

    func deleteSelectedModel() {
        guard let id = selectedModel, let index = models.firstIndex(where: { $0.id == id }) else { return }
        modelNodes[id]?.removeFromParentNode()
        modelNodes[id] = nil
        boxes[id] = nil
        cutouts[id] = nil
        cutoutPackages[id] = nil
        if cutouts.isEmpty { stopCutoutTimer() }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(models[index].file))
        models.remove(at: index)
        selectedModel = nil
    }

    /// Tap a model to select it; drag moves it over surfaces, pinch scales, twist turns.
    func attachGestures(to view: SCNView) {
        cameraView = view
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        // Two fingers dragging tips and slants a cut-out: up and down tilts it, sideways slants it.
        let pose = UIPanGestureRecognizer(target: self, action: #selector(handlePose(_:)))
        pose.minimumNumberOfTouches = 2
        pose.maximumNumberOfTouches = 2
        pose.name = "pose"
        pinch.name = "pinch"
        rotate.name = "rotate"
        for gesture in [tap, pan, pinch, rotate, pose] as [UIGestureRecognizer] {
            gesture.delegate = self
            view.addGestureRecognizer(gesture)
        }
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Tilting with two fingers must not also pinch or twist (and the other way round): whichever starts first wins.
        let names = Set([gestureRecognizer.name, other.name])
        if names.contains("pose") && (names.contains("pinch") || names.contains("rotate")) { return false }
        return true
    }

    @objc private func handlePose(_ gesture: UIPanGestureRecognizer) {
        let moved = gesture.translation(in: gesture.view)
        gesture.setTranslation(.zero, in: gesture.view)
        guard !pinching, let id = selectedModel, var package = cutoutPackages[id], let plane = cutouts[id]?.plane,
              let model = models.first(where: { $0.id == id }) else { return }
        // Pushing up on the card tips its top away from you.
        package.tilt = min(max(package.tilt - Float(moved.y) * 0.3, -80), 80)
        package.skew = min(max(package.skew + Float(moved.x) * 0.2, -60), 60)
        cutoutPackages[id] = package
        plane.simdTransform = Self.poseMatrix(tilt: package.tilt, skew: package.skew, turn: cutoutTurn[id] ?? 0)
        if gesture.state == .ended { savePose(package, id: id, file: model.file, plane: plane) }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view as? SCNView else { return }
        let hits = view.hitTest(gesture.location(in: view), options: nil)
        selectedModel = hits.lazy.compactMap { self.modelID(of: $0.node) }.first
    }

    /// Drags the model across the room. Where the LiDAR sees a surface under the finger (the floor, a
    /// table), the model stands on it; with none, it slides across the level plane at its own height,
    /// which works with no surface found, unlike a raycast. With Lift on, a drag moves it up and down.
    /// Picks up the model under the finger (or the only one) when none is selected.
    static let snapsToSurface = false

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isSuspended(), let view = gesture.view as? SCNView else { return }
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
        // Sliding on a level plane at the model's own height felt right (build 78); snapping to the
        // LiDAR surface under the finger (build 114) made it jumpy, so it is off. Floor does that on demand.
        let hit: SIMD3<Float>? = Self.snapsToSurface ? surface(at: location, in: view) : nil
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
    private func surface(at location: CGPoint, in view: SCNView) -> SIMD3<Float>? {
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
    private func floorPoint(_ location: CGPoint, in view: SCNView, height: Float) -> SIMD3<Float>? {
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
        if let package = cutoutPackages[id], let plane = cutouts[id]?.plane {
            let turn = (cutoutTurn[id] ?? 0) - Float(gesture.rotation)
            let wrapped = atan2(sin(turn), cos(turn))
            cutoutTurn[id] = wrapped
            plane.simdTransform = Self.poseMatrix(tilt: package.tilt, skew: package.skew, turn: wrapped)
        }
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
        if model.file.hasSuffix("." + Cutout.fileExtension) { return loadCutoutNode(for: model) }
        let url = folder.appendingPathComponent(model.file)
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
        let node = SCNNode()
        node.name = model.id.uuidString
        for child in scene.rootNode.childNodes {
            node.addChildNode(child)
        }
        let (low, high) = node.boundingBox
        var geometries = 0
        node.enumerateHierarchy { child, _ in if child.geometry != nil { geometries += 1 } }
        Diagnostics.log(String(format: "Model loaded: %@, %d geometries, box %.2f x %.2f x %.2f m",
                               model.name, geometries, high.x - low.x, high.y - low.y, high.z - low.z))
        boxes[model.id] = (SIMD3<Float>(low), SIMD3<Float>(high))
        node.simdTransform = matrix4(model.transform)
        root.addChildNode(node)
        modelNodes[model.id] = node
        refreshDimensions(model.id)
        return node
    }

    // MARK: Scrapbook cut-outs

    /// Saves a cut-out into the reference's models and stands it up where the camera points (or at `base`),
    /// turned to face the camera. Returns false, with `modelError` set, if it could not.
    @discardableResult
    func addCutout(_ package: CutoutPackage, at base: simd_float4x4? = nil) -> Bool {
        var transform: simd_float4x4
        if let base {
            transform = base
        } else if let frame = session.currentFrame {
            transform = placementTransform(frame)
            let facing = Cutout.frontFacing(camera: frame.camera.transform.columns.3.xyz, position: transform.columns.3.xyz)
            transform.columns.0 = facing.columns.0
            transform.columns.2 = facing.columns.2
        } else {
            modelError = "Point the camera at the set first, then add the cut-out."
            return false
        }
        let id = UUID()
        let file = "models/\(id.uuidString).\(Cutout.fileExtension)"
        let destination = folder.appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(package).write(to: destination, options: .atomic)
        } catch {
            modelError = "Could not save the cut-out."
            return false
        }
        let model = PlacedModel(id: id, name: package.name, file: file, transform: flatten(transform))
        guard loadNode(for: model) != nil else {
            try? FileManager.default.removeItem(at: destination)
            modelError = "Could not show the cut-out."
            return false
        }
        models.append(model)
        selectedModel = id
        Diagnostics.log("Cut-out added: \(package.views.count) views, \(package.height) m")
        return true
    }

    /// A flat card that always turns to face the camera about the vertical axis, standing on the spot,
    /// showing the photo nearest to the side the camera is on.
    @discardableResult
    private func loadCutoutNode(for model: PlacedModel) -> SCNNode? {
        let url = folder.appendingPathComponent(model.file)
        guard let data = try? Data(contentsOf: url), let package = try? JSONDecoder().decode(CutoutPackage.self, from: data) else { return nil }
        var angles: [Float] = [], aspects: [Float] = [], images: [UIImage] = []
        for view in package.views {
            guard let image = UIImage(data: view.png) else { continue }
            angles.append(view.angle)
            aspects.append(max(view.aspect, 0.05))
            images.append(image)
        }
        guard !images.isEmpty, package.height > 0.01 else { return nil }
        let first = Cutout.nearest(angles, to: 0) ?? 0
        let height = package.height
        let geometry = SCNPlane(width: CGFloat(height * aspects[first]), height: CGFloat(height))
        let material = SCNMaterial()
        material.diffuse.contents = images[first]
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        let plane = SCNNode(geometry: geometry)
        plane.name = "cutout-plane"
        // The card's origin is the middle of its foot.
        plane.pivot = SCNMatrix4MakeTranslation(0, -Float(height) / 2, 0)
        plane.simdTransform = Self.poseMatrix(tilt: package.tilt, skew: package.skew)
        // The holder turns to face the camera; the card inside it is tipped and slanted from there.
        let holder = SCNNode()
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        holder.constraints = [billboard]
        holder.addChildNode(plane)
        let node = SCNNode()
        node.name = model.id.uuidString
        node.addChildNode(holder)
        cutoutPackages[model.id] = package
        let widest = (aspects.max() ?? 1) * height
        boxes[model.id] = (SIMD3(-widest / 2, 0, -0.01), SIMD3(widest / 2, height, 0.01))
        node.simdTransform = matrix4(model.transform)
        root.addChildNode(node)
        modelNodes[model.id] = node
        cutouts[model.id] = CutoutState(plane: plane, height: height, angles: angles, aspects: aspects, images: images, shown: first)
        refreshDimensions(model.id)
        startCutoutTimer()
        Diagnostics.log(String(format: "Cut-out loaded: %@, %d views, %.2f m tall", model.name, images.count, height))
        return node
    }

    private func startCutoutTimer() {
        guard cutoutTimer == nil else { return }
        cutoutTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCutouts() }
        }
    }

    private func stopCutoutTimer() {
        cutoutTimer?.invalidate()
        cutoutTimer = nil
    }

    /// Turns each cut-out to the photo for the side the camera sees now.
    private func updateCutouts() {
        guard !cutouts.isEmpty, let camera = session.currentFrame?.camera.transform.columns.3.xyz else {
            if dimLight { dimLight = false }
            return
        }
        // ARKit's ambient light reading is about 1000 in a lit room; under 250 is dim.
        let dim = (session.currentFrame?.lightEstimate?.ambientIntensity ?? 1000) < 250
        if dim != dimLight { dimLight = dim }
        for (id, state) in cutouts {
            guard let node = modelNodes[id] else { continue }
            let transform = node.simdWorldTransform
            let angle = Cutout.viewAngle(camera: camera, position: transform.columns.3.xyz, front: transform.columns.2.xyz)
            guard let best = Cutout.nearest(state.angles, to: angle), best != state.shown else { continue }
            cutouts[id]?.shown = best
            if let plane = state.plane.geometry as? SCNPlane {
                plane.width = CGFloat(state.height * state.aspects[best])
                plane.firstMaterial?.diffuse.contents = state.images[best]
            }
        }
    }

    /// Hangs fresh arrows on the model for its size now, or takes them off when turned off.
    private func refreshDimensions(_ id: UUID) {
        guard let node = modelNodes[id] else { return }
        node.childNode(withName: ModelDimensions.nodeName, recursively: false)?.removeFromParentNode()
        guard showDimensions, cutoutPackages[id] == nil, let box = boxes[id] else { return }
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
    /// Off in Review, where there is no live LiDAR to find the floor with.
    var showsFloor = true

    var body: some View {
        VStack(spacing: 6) {
            if placer.dimLight {
                Text("Dim light: cut-outs may drift. Try the torch.")
                    .font(Theme.footnote)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }
            if placer.selectedModelName == nil, !placer.models.isEmpty {
                Button("Find model") { placer.bringToView() }
                    .buttonStyle(.bordered)
                    .font(Theme.headline)
                    .controlSize(.small)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            else if placer.selectedIsCutout {
                // Phil, 2026-11-08: the cut-out panel took too much of the screen. One short line of help with a soft
                // shadow, and one row of buttons, no panel behind.
                VStack(spacing: 4) {
                    Text("Drag, pinch, twist. Two fingers to tilt or slant.")
                        .font(Theme.caption)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .allowsHitTesting(false)
                    HStack(spacing: 6) {
                        Button("Place here") { placer.bringToView() }
                        Button("Straighten") { placer.resetPose() }
                        Button("Delete", role: .destructive) { placer.deleteSelectedModel() }
                        Button("Done") { placer.selectedModel = nil }
                    }
                    .buttonStyle(.bordered)
                    .font(Theme.caption)
                    .controlSize(.small)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: 420)
            }
            else if let name = placer.selectedModelName {
                VStack(alignment: .leading, spacing: 8) {
                    if placer.selectedIsCutout {
                        // A cut-out is handled with the fingers: nothing to read, nothing to press but these four.
                        Text("Drag to move. Pinch to resize. Twist to turn. Two fingers up or down to tilt, sideways to slant.")
                            .font(Theme.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Place here") { placer.bringToView() }
                            Button("Straighten") { placer.resetPose() }
                            Spacer(minLength: 0)
                        }
                        .buttonStyle(.bordered)
                        .font(Theme.subheadline)
                        .lineLimit(1)
                    } else {
                        Text(placer.lifting ? "\(name): drag up or down to lift it" : "\(name): drag to move (it stands on surfaces), pinch to scale, twist to turn")
                            .font(Theme.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("W × D × H  \(placer.sizeText)").font(Theme.subheadline.bold().monospacedDigit())
                        HStack(spacing: 8) {
                            Button {
                                placer.showDimensions.toggle()
                            } label: {
                                Image(systemName: placer.showDimensions ? "ruler.fill" : "ruler")
                            }
                            Button {
                                placer.lifting.toggle()
                            } label: {
                                Image(systemName: "arrow.up.and.down")
                            }
                            .tint(placer.lifting ? Theme.accent : nil)
                            if showsFloor { Button("Floor") { placer.dropToFloor() } }
                            Button("True size") { placer.resetSelectedModelSize() }
                            Button("Place here") { placer.bringToView() }
                            Spacer(minLength: 0)
                        }
                        .buttonStyle(.bordered)
                        .font(Theme.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                    HStack {
                        Button("Delete", role: .destructive) { placer.deleteSelectedModel() }
                        Spacer()
                        Button("Done") { placer.selectedModel = nil }
                    }
                    .buttonStyle(.bordered)
                    .font(Theme.subheadline)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                .font(Theme.title2.bold().monospacedDigit())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .allowsHitTesting(false)
        }
    }
}
