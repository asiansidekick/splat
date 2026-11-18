import ARKit
import Foundation
import ImageIO
import SceneKit
import SwiftUI
import UIKit

/// Places USDZ models at real size in an AR session and lets the person move, scale and turn
/// them. Used while recording (models then go into each saved reference) and while resetting.
@MainActor
final class ModelPlacer: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    @Published var models: [PlacedModel] = []
    @Published var selectedModel: UUID? {
        didSet {
            updateSize()
            updateTilted()
            refreshGizmo()
            if selectedModel != oldValue, selectedModel != nil { Haptics.bump() }
            if selectedModel != oldValue {
                stopCarrying()
                cancelPin()
                cutoutJob = .move
            }
        }
    }
    @Published var modelError: String?
    /// Pinning the selected model's distance from two views (PinMath): step aside, then drag it back onto its spot.
    enum PinStep: Equatable { case stepAside, dragBack, done }
    @Published private(set) var pinStep: PinStep?
    /// Models whose distance has been pinned since they were last moved.
    @Published private(set) var pinned: Set<UUID> = []
    private struct PinLine {
        let id: UUID
        let origin: SIMD3<Float>
        let direction: SIMD3<Float>
        let distance: Float
        let scale: SIMD3<Float>
        let scales: Bool
    }
    private var pinLine: PinLine?
    private var pinTimer: Timer?
    /// From the finger to the model's place on the screen, kept through a drag so the model doesn't jump.
    private var pinGrip = CGPoint.zero
    /// While copying an actor's pose (PoseCopy.swift).
    @Published var poseCopier: PoseCopier?
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
    /// How large the figures are: 0 small to 3 extra large (see ModelDimensions.textSteps).
    @Published var dimensionStep = UserDefaults.standard.object(forKey: "dimensionStep") as? Int ?? 1 {
        didSet {
            UserDefaults.standard.set(dimensionStep, forKey: "dimensionStep")
            modelNodes.keys.forEach(refreshDimensions)
        }
    }
    /// A word or two that shows for a moment after the Sizes tool is tapped.
    @Published var dimensionHint: String?

    /// Sizes steps off, small, medium, large, extra large, then off again.
    func cycleDimensions() {
        if !showDimensions {
            dimensionStep = 0
            showDimensions = true
        } else if dimensionStep < ModelDimensions.textSteps.count - 1 {
            dimensionStep += 1
        } else {
            showDimensions = false
        }
        let words = showDimensions ? "Figures: " + ModelDimensions.textStepNames[dimensionStep] : "Figures off"
        let teach = HintStore.shouldShow("sizesTip")
        if teach, !showDimensions { HintStore.shown("sizesTip") }
        let hint = teach ? words + " · tap Sizes again to change" : words
        dimensionHint = hint
        Haptics.tap()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if dimensionHint == hint { dimensionHint = nil }
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
    /// The colour cut-outs are multiplied by to sit in the room's light, eased from frame to frame.
    private var lightTint = SIMD3<Float>(1, 1, 1)
    private var tintApplied = false
    /// Phil, 2026-11-09: cut-outs take on the room's brightness and warmth (Help, Cut-outs). On unless turned off.
    static var matchesLight: Bool { UserDefaults.standard.object(forKey: "cutoutMatchLight") as? Bool ?? true }
    /// Each model's box in its own coordinates, measured on loading, before any arrows are hung
    /// on it (they would make it look bigger).
    private var boxes: [UUID: (low: SIMD3<Float>, high: SIMD3<Float>)] = [:]
    /// The bones of imported characters that can be posed.
    private var rigs: [UUID: FBXRig] = [:]
    /// While dragging: from where the finger's ray meets the model's floor height to the model,
    /// so the model keeps its place under the finger instead of jumping to it.
    private var dragTarget: SIMD3<Float>?
    private var lastDimensionRefresh = Date.distantPast
    /// One-finger drags move the selected model up and down instead of across (Phil, 2026-10-31).
    @Published var lifting = false
    /// Phil, 2026-11-09: cut-outs are handled one job at a time, each with one finger, and carried by holding a finger on the object (2026-11-18).
    enum CutoutJob: String, CaseIterable { case move = "Move", turn = "Turn", size = "Size", tilt = "Tilt", lift = "Lift" }
    @Published var cutoutJob: CutoutJob = .move { didSet { if cutoutJob != oldValue { refreshGizmo() } } }
    @Published private(set) var carrying = false
    /// The selected 3D model has been tipped or leant (not just turned), so Upright is offered.
    @Published private(set) var selectedTilted = false
    private var carryTimer: Timer?
    private var carryDistance: Float = 1.5
    private var carried: UUID?
    /// The room is dim enough that the phone may lose its place, so cut-outs can drift (Phil, 2026-11-07).
    @Published private(set) var dimLight = false
    private weak var cameraView: SCNView?
    private var depthCache: (time: TimeInterval, depth: Measurer.Depth)?
    /// True while something else (measuring) uses one-finger drags on the camera view.
    var isSuspended: () -> Bool = { false }
    /// Whether a tap may pick a model (the Reset screen's EDIT section only).
    var selectionAllowed: () -> Bool = { true }
    /// Simple touch mode: a one-finger drag moves a model only when it starts on one; elsewhere it moves the view.
    var strictTouch: () -> Bool = { false }
    private var ignoringPan = false

    /// Whether a model is under the finger.
    func modelAt(_ point: CGPoint, in view: SCNView) -> Bool {
        view.hitTest(point, options: ReviewPick.options).contains { modelID(of: $0.node) != nil }
    }
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
    func add(from sources: [URL], keep: Bool = false) {
        guard let frame = session.currentFrame else {
            modelError = "Point the camera at the set first, then add the models."
            return
        }
        var right = frame.camera.transform.columns.0.xyz
        right.y = 0
        right = simd_length(right) > 0.01 ? simd_normalize(right) : SIMD3(1, 0, 0)
        add(from: sources, at: placementTransform(frame), right: right, keep: keep)
    }

    /// Adds models facing the camera (the examples): at `base` when given (Review), else where the camera points.
    func addFacingCamera(from sources: [URL], base: simd_float4x4?) {
        if let base {
            add(from: sources, at: base, right: base.columns.0.xyz)
            return
        }
        guard let frame = session.currentFrame else {
            modelError = "Point the camera at the set first, then add the models."
            return
        }
        var transform = placementTransform(frame)
        let facing = Cutout.frontFacing(camera: frame.camera.transform.columns.3.xyz, position: transform.columns.3.xyz)
        transform.columns.0 = facing.columns.0
        transform.columns.2 = facing.columns.2
        add(from: sources, at: transform, right: facing.columns.0.xyz)
    }

    /// Places the models side by side from `base`, spread along `right` (also used with a saved frame, with no live camera).
    /// `keep` is for files the crew picked themselves: a copy goes into the gallery (ModelLibrary).
    func add(from sources: [URL], at base: simd_float4x4, right: SIMD3<Float>, keep: Bool = false) {
        var added: UUID?
        var failed: [String] = []
        let sources = ModelImport.gather(sources)
        guard !sources.isEmpty else {
            modelError = "Pick a USDZ, OBJ, STL or FBX file. For an OBJ, pick its .mtl and pictures with it."
            return
        }
        for (index, source) in sources.enumerated() {
            // 40 cm apart along the floor, so several models do not land on top of each other.
            let offset = (Float(index) - Float(sources.count - 1) / 2) * 0.4
            var transform = base
            transform.columns.3 += SIMD4(right * offset, 0)
            if let id = add(source, at: transform, keep: keep) { added = id } else { failed.append(source.lastPathComponent) }
        }
        if !failed.isEmpty { modelError = "Could not open \(failed.joined(separator: ", ")) as a 3D model." }
        if let added { selectedModel = added }
        Diagnostics.log("Models added: \(sources.count - failed.count), failed \(failed.count)")
    }

    private func add(_ source: URL, at transform: simd_float4x4, keep: Bool) -> UUID? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        // An FBX is kept as it is (its bones are read each time it is shown); everything else becomes a USDZ.
        let fbx = source.pathExtension.lowercased() == "fbx"
        let file = "models/\(id.uuidString).\(fbx ? "fbx" : "usdz")"
        let destination = folder.appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fbx {
                try FileManager.default.copyItem(at: source, to: destination)
                FBXImport.keepTextures(from: source, for: destination)
            } else {
                try ModelImport.store(source, at: destination)
            }
        } catch {
            Diagnostics.log("Model import failed: \(source.lastPathComponent), \(error)")
            return nil
        }
        let model = PlacedModel(id: id, name: source.deletingPathExtension().lastPathComponent, file: file, transform: flatten(transform))
        guard loadNode(for: model) != nil else {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: FBXImport.texturesFolder(for: destination))
            return nil
        }
        if keep, !fbx { ModelLibrary.keep(destination, name: model.name) }
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
        rigs = [:]
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
            // The pictures picked along with an FBX.
            let pictures = FBXImport.texturesFolder(for: folder.appendingPathComponent(model.file))
            let picturesTarget = FBXImport.texturesFolder(for: target)
            if model.file.hasSuffix(".fbx"), FileManager.default.fileExists(atPath: pictures.path), !FileManager.default.fileExists(atPath: picturesTarget.path) {
                try? FileManager.default.copyItem(at: pictures, to: picturesTarget)
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

    /// Where the viewer is: the live camera, or in Review (no live session) the saved frame's camera.
    /// Phil, 2026-11-10: Move did nothing over a saved frame because it waited for a live camera.
    private var eye: simd_float4x4? {
        if let frame = session.currentFrame { return frame.camera.transform }
        return cameraView?.pointOfView?.simdWorldTransform
    }

    /// Brings the selected model (or the newest, when none is selected) back to the middle of the view at its
    /// normal size, for when it has been lost off screen, very far away, or scaled tiny or huge.
    func bringToView() {
        guard let id = selectedModel ?? models.last?.id, let node = modelNodes[id] else { return }
        node.simdScale = SIMD3(repeating: 1)
        var spot: SIMD3<Float>
        if let frame = session.currentFrame {
            spot = placementTransform(frame).columns.3.xyz
            spot.y -= boxes[id]?.low.y ?? 0
        } else if let eye = self.eye {
            // Over a saved frame: two metres ahead of its camera, at the height the model already stands.
            var forward = -eye.columns.2.xyz
            forward.y = 0
            forward = simd_length(forward) > 0.01 ? simd_normalize(forward) : SIMD3(0, 0, -1)
            spot = eye.columns.3.xyz + forward * 2
            spot.y = node.simdWorldPosition.y
        } else {
            modelError = "Point the camera at the set first."
            return
        }
        node.simdWorldPosition = spot
        cancelPin()
        pinned.remove(id)
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

    /// The selected model's mannequin, if it is one.
    var selectedMannequin: MannequinSpec? {
        guard let id = selectedModel else { return nil }
        return models.first { $0.id == id }?.mannequin
    }

    /// What the Pose screen starts from: a mannequin's own pose, or for an imported character a stand-in of
    /// its height in the pose it has now.
    var selectedPoseSpec: MannequinSpec? {
        guard let id = selectedModel, let model = models.first(where: { $0.id == id }) else { return nil }
        if let mannequin = model.mannequin { return mannequin }
        guard let rig = rigs[id] else { return nil }
        return MannequinSpec(body: .man, height: max(0.3, min(rig.height, 3)), pose: model.rigPose ?? rig.poser.restPose)
    }

    func setMannequin(_ spec: MannequinSpec, for id: UUID) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].mannequin = spec
    }

    /// Rebuilds a mannequin in a new pose, in the same place.
    func repose(_ id: UUID, as spec: MannequinSpec) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        if models[index].mannequin == nil {
            // An imported character: its own bones take the pose.
            guard let rig = rigs[id] else { return }
            rig.apply(spec.pose)
            models[index].rigPose = spec.pose
            models[index].moved = Date()
            Diagnostics.log("Character posed: \(models[index].name), \(spec.pose.summary)")
            return
        }
        let scene = SCNScene()
        scene.rootNode.addChildNode(Mannequin.make(spec.body, pose: spec.pose, height: spec.height))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("repose-\(UUID().uuidString).usdz")
        guard scene.write(to: temporary, options: nil, delegate: nil, progressHandler: nil) else {
            modelError = "Could not change the pose."
            return
        }
        let destination = folder.appendingPathComponent(models[index].file)
        _ = try? FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        models[index].mannequin = spec
        models[index].moved = Date()
        let transform = modelNodes[id]?.simdTransform
        modelNodes[id]?.removeFromParentNode()
        modelNodes[id] = nil
        loadNode(for: models[index])
        if let transform { modelNodes[id]?.simdTransform = transform }
        Diagnostics.log("Mannequin posed again: \(spec.pose.summary)")
    }

    func deleteSelectedModel() {
        guard let id = selectedModel, let index = models.firstIndex(where: { $0.id == id }) else { return }
        modelNodes[id]?.removeFromParentNode()
        modelNodes[id] = nil
        boxes[id] = nil
        rigs[id] = nil
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
        // Hold a finger on an object, then drag up or down to raise or lower it (Phil, 2026-11-18: "hold to lift").
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.45
        hold.allowableMovement = 14
        hold.name = "hold"
        // Two fingers dragging tips and slants a cut-out: up and down tilts it, sideways slants it.
        let pose = UIPanGestureRecognizer(target: self, action: #selector(handlePose(_:)))
        pose.minimumNumberOfTouches = 2
        pose.maximumNumberOfTouches = 2
        pose.name = "pose"
        pinch.name = "pinch"
        rotate.name = "rotate"
        for gesture in [tap, pan, pinch, rotate, pose, hold] as [UIGestureRecognizer] {
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
        // Cut-outs tilt with the Tilt job and one finger now; two fingers no longer do it.
        if selectedIsCutout { return }
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

    // MARK: Frame meter (Phil, 2026-11-18: "moving objects is a bit laggy"). While an object is dragged, how often the screen
    // really redraws, so the log says whether the phone's main thread is the bottleneck.
    private var meter: CADisplayLink?
    private var meterLast: CFTimeInterval = 0
    /// Counts drags and holds on objects, so a hint can tell whether the person has tried anything yet.
    @Published var touches = 0
    private var meterGaps: [Double] = []

    private func startMeter() {
        guard meter == nil else { return }
        meterGaps = []
        meterLast = 0
        let link = CADisplayLink(target: self, selector: #selector(meterTick(_:)))
        link.add(to: .main, forMode: .common)
        meter = link
    }

    @objc private func meterTick(_ link: CADisplayLink) {
        if meterLast > 0 { meterGaps.append((link.timestamp - meterLast) * 1000) }
        meterLast = link.timestamp
    }

    private func stopMeter(_ what: String) {
        meter?.invalidate()
        meter = nil
        guard meterGaps.count > 5 else { return }
        let average = meterGaps.reduce(0, +) / Double(meterGaps.count)
        let slow = meterGaps.filter { $0 > 25 }.count
        Diagnostics.log(String(format: "Frames while %@: %d, average %.1f ms, worst %.0f ms, %d slower than 25 ms", what, meterGaps.count, average, meterGaps.max() ?? 0, slow))
    }

    /// While a hold is lifting: the model, and where the finger last was.
    private var holdLift: (id: UUID, last: CGPoint)?
    /// The height the finger has asked for; the model eases to it.
    private var holdTarget: Float = 0
    private var holdHint: UIView?

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        guard let view = gesture.view as? SCNView else { return }
        let finger = gesture.location(in: view)
        switch gesture.state {
        case .began:
            touches += 1
            HintStore.learned("objectFirst"); HintStore.learned("objectIdle")
            guard selectionAllowed(), !isSuspended(), !carrying,
                  let touched = view.hitTest(finger, options: ReviewPick.options).lazy.compactMap({ self.modelID(of: $0.node) }).first,
                  let node = modelNodes[touched]
            else { return }
            selectedModel = touched
            cancelPin()
            pinned.remove(touched)
            holdLift = (touched, finger)
            holdTarget = node.simdWorldPosition.y
            showHoldHint(in: view, at: finger)
            startMeter()
            Haptics.firm()
        case .changed:
            guard let lift = holdLift, let node = modelNodes[lift.id] else { return }
            // Up the screen is up in the room, one for one: how far a point on the screen is at the model's depth.
            let at = node.worldPosition
            let shown = view.projectPoint(at)
            var metresPerPoint: Float
            if shown.z > 0, shown.z < 1 {
                let a = SIMD3<Float>(view.unprojectPoint(SCNVector3(shown.x, shown.y, shown.z)))
                let b = SIMD3<Float>(view.unprojectPoint(SCNVector3(shown.x, shown.y + 1, shown.z)))
                metresPerPoint = simd_distance(a, b)
            } else {
                let camera = eye?.columns.3.xyz ?? node.simdWorldPosition
                metresPerPoint = 0.0016 * max(simd_distance(camera, node.simdWorldPosition), 0.3)
            }
            holdTarget -= Float(finger.y - lift.last.y) * metresPerPoint
            node.simdWorldPosition.y += (holdTarget - node.simdWorldPosition.y) * 0.8
            holdLift = (lift.id, finger)
            holdHint?.center = hintCenter(for: finger, in: view)
        case .ended, .cancelled, .failed:
            if let lift = holdLift {
                modelNodes[lift.id]?.simdWorldPosition.y = holdTarget
                commit(lift.id)
            }
            holdLift = nil
            hideHoldHint()
            stopMeter("lift")
        default:
            break
        }
    }

    /// Up and down for the finger, drawn beside it (not under it) while a hold is lifting.
    private func showHoldHint(in view: UIView, at point: CGPoint) {
        holdHint?.removeFromSuperview()
        func icon(_ name: String, _ size: CGFloat) -> UIImageView {
            let picture = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .heavy)))
            picture.tintColor = UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
            return picture
        }
        let stack = UIStackView(arrangedSubviews: [icon("hand.thumbsup.fill", 26), icon("arrow.up.and.down", 22), icon("hand.thumbsdown.fill", 26)])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.layer.shadowColor = UIColor.black.cgColor
        stack.layer.shadowOpacity = 0.85
        stack.layer.shadowRadius = 3
        stack.layer.shadowOffset = CGSize(width: 0, height: 1)
        stack.isUserInteractionEnabled = false
        stack.frame.size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        stack.center = hintCenter(for: point, in: view)
        stack.alpha = 0
        view.addSubview(stack)
        UIView.animate(withDuration: 0.15) { stack.alpha = 1 }
        holdHint = stack
    }

    private func hintCenter(for finger: CGPoint, in view: UIView) -> CGPoint {
        // Left of the finger, or right of it near the left edge.
        CGPoint(x: finger.x < 80 ? finger.x + 56 : finger.x - 56, y: finger.y)
    }

    private func hideHoldHint() {
        guard let hint = holdHint else { return }
        holdHint = nil
        UIView.animate(withDuration: 0.2, animations: { hint.alpha = 0 }, completion: { _ in hint.removeFromSuperview() })
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard selectionAllowed(), let view = gesture.view as? SCNView else { return }
        let hits = view.hitTest(gesture.location(in: view), options: ReviewPick.options)
        selectedModel = hits.lazy.compactMap { self.modelID(of: $0.node) }.first
    }

    /// Drags the model (a USDZ or a cut-out) across the room at its own height: sideways with the finger, and
    /// further or nearer as the finger goes up or down the screen. With Lift on, a drag moves it up and down.
    /// Picks up the model under the finger (or the only one) when none is selected.

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isSuspended(), holdLift == nil, let view = gesture.view as? SCNView else { return }
        let location = gesture.location(in: view)
        if gesture.state == .began {
            let touched = view.hitTest(location, options: ReviewPick.options).lazy.compactMap { self.modelID(of: $0.node) }.first
            ignoringPan = strictTouch() && touched == nil
            if ignoringPan { return }
            if let touched {
                selectedModel = touched
            } else if selectedModel == nil, models.count == 1 {
                selectedModel = models[0].id
            }
        }
        if ignoringPan { return }
        guard let id = selectedModel, let node = modelNodes[id] else { return }
        if pinStep != nil {
            pinDrag(gesture, in: view, node: node)
            return
        }
        // Phil, 2026-11-10: USDZ and other models use the cut-out way too: one job at a time for one finger.
        if cutoutJob != .move, !carrying {
            doCutoutJob(gesture, id: id, node: node)
            return
        }
        if carrying { return }
        if lifting {
            switch gesture.state {
            case .changed:
                let delta = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                let camera = eye?.columns.3.xyz ?? node.simdWorldPosition
                // About a millimetre and a half per point for each metre away.
                node.simdWorldPosition.y -= Float(delta.y) * 0.0016 * max(simd_distance(camera, node.simdWorldPosition), 0.3)
            case .ended, .cancelled:
                commit(id)
            default:
                break
            }
            return
        }
        // Build 1237: the finger used to point at a spot on the level floor, so far away (where the line of sight
        // is nearly level) a tiny finger move threw the model metres. Now the drag is by steps: sideways follows
        // the finger on the screen, and up or down the screen pushes it away or pulls it in by a share of its
        // distance (about double or half for a third of the screen), eased so it glides instead of twitching.
        switch gesture.state {
        case .began:
            touches += 1
            gesture.setTranslation(.zero, in: view)
            dragTarget = node.simdWorldPosition
            startMeter()
        case .changed:
            let delta = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            guard var target = dragTarget, let eye = self.eye?.columns.3.xyz else { return }
            // Phil, 2026-11-18: moving became possible in one direction only. Far objects (and big ones pushed out
            // to hundreds of metres) fell outside the depth range the screen maths works in, or one finger step
            // came to over a metre, and the sideways move was dropped. Now the step is measured at a point on the
            // same line of sight at most 20 m away and scaled up to the object's real distance.
            let toTarget = target - eye
            let range = simd_length(toTarget)
            if range > 0.05 {
                let near = min(range, 20)
                let reference = eye + toTarget / range * near
                let shown = view.projectPoint(SCNVector3(reference.x, reference.y, reference.z))
                if shown.z > 0, shown.z < 1 {
                    let moved = SIMD3<Float>(view.unprojectPoint(SCNVector3(shown.x + Float(delta.x), shown.y, shown.z)))
                    var sideways = (moved - reference) * (range / near)
                    sideways.y = 0
                    if simd_length(sideways) < max(1, range) { target += sideways }
                }
            }
            var away = target - eye
            away.y = 0
            let distance = simd_length(away)
            if distance > 0.05 {
                let wanted = min(max(distance * exp(-Float(delta.y) * 0.0022), 0.3), 500)
                target += away / distance * (wanted - distance)
            }
            dragTarget = target
            node.simdWorldPosition = simd_mix(node.simdWorldPosition, target, SIMD3(repeating: 0.75))
        case .ended, .cancelled:
            if let target = dragTarget { node.simdWorldPosition = target }
            dragTarget = nil
            stopMeter("drag")
            pinned.remove(id)
            commit(id)
        default:
            break
        }
    }

    /// Starts pinning the selected model: remembers the line of sight to it, then waits for a step to the side.
    func startPin() {
        if pinStep != nil {
            cancelPin()
            return
        }
        guard let id = selectedModel, let node = modelNodes[id], let eye = self.eye?.columns.3.xyz else { return }
        let away = node.simdWorldPosition - eye
        let distance = simd_length(away)
        guard distance > 0.1 else { return }
        stopCarrying()
        cutoutJob = .move
        pinLine = PinLine(id: id, origin: eye, direction: away / distance, distance: distance, scale: node.simdScale, scales: cutoutPackages[id] != nil)
        pinStep = .stepAside
        Haptics.tap()
        pinTimer?.invalidate()
        pinTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinWatch() }
        }
    }

    func cancelPin() {
        pinTimer?.invalidate()
        pinTimer = nil
        guard pinStep != nil else { return }
        // Given up before the drag back was finished: the model goes back to where it stood.
        if pinStep != .done, let line = pinLine, let node = modelNodes[line.id] {
            node.simdWorldPosition = line.origin + line.direction * line.distance
            node.simdScale = line.scale
            commit(line.id)
        }
        pinStep = nil
        pinLine = nil
    }

    /// Far enough to the side for the two lines of sight to tell the distance.
    private func pinWatch() {
        guard pinStep == .stepAside, let line = pinLine, let eye = self.eye?.columns.3.xyz else { return }
        if PinMath.aside(origin: line.origin, direction: line.direction, camera: eye) >= PinMath.stepNeeded(distance: line.distance) {
            pinStep = .dragBack
            Haptics.tap()
            pinTimer?.invalidate()
            pinTimer = nil
        }
    }

    /// The drag back: the model slides along the first line of sight to where the finger's line meets it. A cut-out
    /// (sized by eye) grows or shrinks with its distance, so it still looks the same from where it was first set.
    private func pinDrag(_ gesture: UIPanGestureRecognizer, in view: SCNView, node: SCNNode) {
        guard pinStep == .dragBack, let line = pinLine, line.id == selectedModel else { return }
        let finger = gesture.location(in: view)
        switch gesture.state {
        case .began:
            let shown = view.projectPoint(node.worldPosition)
            pinGrip = CGPoint(x: CGFloat(shown.x) - finger.x, y: CGFloat(shown.y) - finger.y)
        case .changed:
            let x = Float(finger.x + pinGrip.x), y = Float(finger.y + pinGrip.y)
            let near = SIMD3<Float>(view.unprojectPoint(SCNVector3(x, y, 0)))
            let far = SIMD3<Float>(view.unprojectPoint(SCNVector3(x, y, 1)))
            guard simd_distance(near, far) > 0.001,
                  let found = PinMath.along(origin: line.origin, direction: line.direction, from: near, toward: simd_normalize(far - near))
            else { return }
            let t = min(max(found, 0.2), 500)
            let target = line.origin + line.direction * t
            node.simdWorldPosition = simd_mix(node.simdWorldPosition, target, SIMD3(repeating: 0.75))
            if line.scales { node.simdScale = line.scale * (simd_distance(node.simdWorldPosition, line.origin) / line.distance) }
        case .ended, .cancelled:
            let now = simd_distance(node.simdWorldPosition, line.origin)
            commit(line.id)
            updateSize()
            refreshDimensions(line.id)
            pinned.insert(line.id)
            pinStep = .done
            Haptics.success()
            Diagnostics.log(String(format: "Pin: distance %.2f m became %.2f m", line.distance, now))
            // "Pinned" shows for a moment, then the tools are as before.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.pinStep == .done else { return }
                self.pinStep = nil
                self.pinLine = nil
            }
        default:
            break
        }
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

    /// One finger doing the chosen job on a cut-out: Turn (sideways), Size (up grows), Tilt (up tips, sideways slants).
    private func doCutoutJob(_ gesture: UIPanGestureRecognizer, id: UUID, node: SCNNode) {
        let moved = gesture.translation(in: gesture.view)
        gesture.setTranslation(.zero, in: gesture.view)
        switch cutoutJob {
        case .turn:
            let step = Float(moved.x) * 0.012
            node.simdEulerAngles.y += step
            if let package = cutoutPackages[id], let plane = cutouts[id]?.plane {
                let turn = (cutoutTurn[id] ?? 0) + step
                let wrapped = atan2(sin(turn), cos(turn))
                cutoutTurn[id] = wrapped
                plane.simdTransform = Self.poseMatrix(tilt: package.tilt, skew: package.skew, turn: wrapped)
            }
        case .size:
            let factor = exp(-Float(moved.y) * 0.004)
            let next = node.simdScale * factor
            if next.x > 0.005, next.x < 2000 { node.simdScale = next }
            updateSize()
            // The arrows are rebuilt from text each time: at most about 8 times a second while sizing (Phil, 2026-11-16: laggy).
            if Date().timeIntervalSince(lastDimensionRefresh) > 0.12 || gesture.state == .ended {
                lastDimensionRefresh = Date()
                refreshDimensions(id)
            }
        case .tilt:
            // A 3D model (not a flat cut-out) is tipped and leant as a whole, about its middle.
            if cutoutPackages[id] == nil {
                guard let view = gesture.view as? SCNView else { return }
                let finger = gesture.location(in: view)
                if gesture.state == .began { gizmoPick(at: finger, in: view, node: node, id: id) }
                if gizmoRing != nil {
                    gizmoDrag(by: moved, in: view, node: node, id: id)
                } else {
                    tipModel(node, id: id, by: moved)
                }
                if gesture.state == .ended || gesture.state == .cancelled { gizmoRing = nil; gizmoGrab = nil; refreshGizmo() }
                break
            }
            guard var package = cutoutPackages[id], let plane = cutouts[id]?.plane, let model = models.first(where: { $0.id == id }) else { return }
            package.tilt = min(max(package.tilt - Float(moved.y) * 0.3, -80), 80)
            package.skew = min(max(package.skew + Float(moved.x) * 0.2, -60), 60)
            cutoutPackages[id] = package
            plane.simdTransform = Self.poseMatrix(tilt: package.tilt, skew: package.skew, turn: cutoutTurn[id] ?? 0)
            if gesture.state == .ended { savePose(package, id: id, file: model.file, plane: plane) }
        case .lift:
            let camera = eye?.columns.3.xyz ?? node.simdWorldPosition
            // About a millimetre and a half per point for each metre away.
            node.simdWorldPosition.y -= Float(moved.y) * 0.0016 * max(simd_distance(camera, node.simdWorldPosition), 0.3)
        case .move:
            break
        }
        if gesture.state == .ended || gesture.state == .cancelled { commit(id) }
    }

    /// While Carry is held the selected cut-out (or model) stays in front of the phone at the distance it was
    /// picked up from, at its own height, so walking and turning take it along; letting go drops it there.
    func startCarrying() {
        guard !carrying, let id = selectedModel, let node = modelNodes[id], let camera = session.currentFrame?.camera.transform else { return }
        var away = node.simdWorldPosition - camera.columns.3.xyz
        away.y = 0
        carryDistance = min(max(simd_length(away), 0.5), 500)
        carrying = true
        carried = id
        cancelPin()
        pinned.remove(id)
        Haptics.tap()
        Diagnostics.log(String(format: "Carry started at %.1f m", carryDistance))
        carryTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.carryStep() }
        }
    }

    func stopCarrying() {
        guard carrying else { return }
        carryTimer?.invalidate()
        carryTimer = nil
        carrying = false
        if let id = carried {
            commit(id)
            Haptics.success()
        }
        carried = nil
    }

    private func carryStep() {
        guard let id = carried, let node = modelNodes[id], let camera = session.currentFrame?.camera.transform else { return }
        var forward = -camera.columns.2.xyz
        forward.y = 0
        guard simd_length(forward) > 0.05 else { return }
        forward = simd_normalize(forward)
        var target = camera.columns.3.xyz + forward * carryDistance
        target.y = node.simdWorldPosition.y
        node.simdWorldPosition = simd_mix(node.simdWorldPosition, target, SIMD3(repeating: 0.25))
    }

    // Phil, 2026-11-18: scale and turn got mixed when both fingers moved, but pinch and twist stay the same gestures.
    // The first clear move decides: a pinch locks to Size, a twist locks to Turn (Roll under Rotate), and the other
    // is ignored until the fingers lift. Until then nothing moves, and the whole move so far is applied at once.
    private enum TwoFinger { case undecided, scale, turn }
    private var twoFinger = TwoFinger.undecided
    private var twoFingerCount = 0
    private var pinchSize: Float = 0
    private var twistSize: Float = 0

    private func twoFingerState(_ gesture: UIGestureRecognizer) {
        switch gesture.state {
        case .began:
            if twoFingerCount == 0 { twoFinger = .undecided; pinchSize = 0; twistSize = 0 }
            twoFingerCount += 1
        case .ended, .cancelled, .failed:
            twoFingerCount = max(0, twoFingerCount - 1)
            if twoFingerCount == 0 { twoFinger = .undecided; pinchSize = 0; twistSize = 0 }
        default:
            break
        }
    }

    private func twoFingerAllows(_ mode: TwoFinger) -> Bool {
        if twoFinger == .undecided {
            // A 5% change of size, or about 4 degrees of twist, makes the call; whichever is further past its mark wins.
            let pinch = pinchSize / 0.05
            let twist = twistSize / 0.07
            if max(pinch, twist) >= 1 {
                twoFinger = pinch >= twist ? .scale : .turn
                Haptics.tap()
            }
        }
        return twoFinger == mode
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        twoFingerState(gesture)
        let ended = gesture.state == .ended || gesture.state == .cancelled
        guard !isSuspended(), let id = selectedModel, let node = modelNodes[id] else { gesture.scale = 1; return }
        if twoFinger == .undecided { pinchSize = max(pinchSize, abs(log(max(Float(gesture.scale), 0.01)))) }
        guard twoFingerAllows(.scale) else {
            if twoFinger != .undecided { gesture.scale = 1 }
            return
        }
        node.simdScale *= Float(gesture.scale)
        gesture.scale = 1
        updateSize()
        refreshDimensions(id)
        let active = gesture.state == .began || gesture.state == .changed
        if pinching != active { pinching = active }
        if ended { commit(id) }
    }

    @objc private func handleRotate(_ gesture: UIRotationGestureRecognizer) {
        twoFingerState(gesture)
        guard let id = selectedModel, let node = modelNodes[id] else { gesture.rotation = 0; return }
        if twoFinger == .undecided { twistSize = max(twistSize, abs(Float(gesture.rotation))) }
        guard twoFingerAllows(.turn) else {
            if twoFinger != .undecided { gesture.rotation = 0 }
            return
        }
        if cutoutJob == .tilt, cutoutPackages[id] == nil, let eye = self.eye {
            rollModel(node, id: id, axis: -simd_normalize(eye.columns.2.xyz), by: -Float(gesture.rotation))
            gesture.rotation = 0
            if gesture.state == .ended { commit(id) }
            return
        }
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

    /// Moves every model by `change`, for a camera that started again with new coordinates.
    func rebase(_ change: simd_float4x4) {
        for index in models.indices {
            guard let node = modelNodes[models[index].id] else { continue }
            node.simdTransform = change * node.simdTransform
            models[index].transform = flatten(node.simdTransform)
        }
    }

    private func commit(_ id: UUID) {
        guard let node = modelNodes[id], let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].transform = flatten(node.simdTransform)
        models[index].moved = Date()
        if id == selectedModel { updateTilted() }
    }

    /// Free rotation about the model's own middle, like turning an object in your hands (Phil, 2026-11-18: rotate in
    /// all axes): drag sideways turns it about the way up on your screen, drag up or down tips it about the way
    /// across your screen, and a two-finger twist rolls it about the line of sight (see handleRotate).
    private func tipModel(_ node: SCNNode, id: UUID, by moved: CGPoint) {
        guard let eye = self.eye else { return }
        let up = simd_normalize(eye.columns.1.xyz)
        let right = simd_normalize(eye.columns.0.xyz)
        let turn = simd_quatf(angle: Float(moved.y) * 0.008, axis: right) * simd_quatf(angle: Float(moved.x) * 0.008, axis: up)
        let box = boxes[id]
        let middle = ((box?.low ?? .zero) + (box?.high ?? .zero)) / 2
        let before = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        node.simdWorldOrientation = simd_normalize(turn * node.simdWorldOrientation)
        let after = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        node.simdWorldPosition += before - after
        updateTilted()
    }

    // MARK: Axis handles (Phil, 2026-11-18: handles like a CAD program, the picked axis shows a long fading line)

    /// Three axes through the middle of the selected 3D model while Rotate is picked: red across (X), green up (Y),
    /// blue along (Z), each ending in a knob at both ends. Drag a knob to turn the model about that axis only; the
    /// axis picked then stretches out as a long line that fades away, so the turn's direction reads clearly.
    private var gizmoNode: SCNNode?
    private var gizmoRing: Int?
    private var gizmoGrab: SIMD3<Float>?
    private static let ringAxes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
    private var gizmoCentre = SIMD3<Float>.zero
    private var gizmoRadius: Float = 0.3

    private func gizmoGeometry() -> (centre: SIMD3<Float>, radius: Float)? {
        guard let id = selectedModel, cutoutPackages[id] == nil, let node = modelNodes[id], let box = boxes[id] else { return nil }
        let middle = ((box.low + box.high) / 2)
        let centre = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        let size = (box.high - box.low) * node.simdScale
        return (centre, max(simd_length(size) * 0.5 * 0.9, 0.12))
    }

    private static func gizmoMaterial(_ colour: UIColor, alpha: CGFloat = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = colour.withAlphaComponent(alpha)
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        return material
    }

    func refreshGizmo() {
        guard cutoutJob == .tilt, let (centre, radius) = gizmoGeometry() else {
            gizmoNode?.removeFromParentNode()
            gizmoNode = nil
            return
        }
        gizmoCentre = centre
        gizmoRadius = radius
        gizmoNode?.removeFromParentNode()
        let holder = SCNNode()
        holder.name = "gizmo"
        holder.renderingOrder = 2000
        let colours: [UIColor] = [.systemRed, .systemGreen, .systemBlue]
        // A cylinder stands along its own Y: tip it to lie along X or Z.
        let tips: [SCNVector4] = [SCNVector4(0, 0, 1, -Float.pi / 2), SCNVector4(0, 0, 0, 0), SCNVector4(1, 0, 0, Float.pi / 2)]
        for index in 0..<3 {
            let axis = SCNNode()
            axis.rotation = tips[index]
            axis.renderingOrder = 2000
            let line = SCNCylinder(radius: 0.012, height: 2)
            line.radialSegmentCount = 8
            line.materials = [Self.gizmoMaterial(colours[index])]
            axis.addChildNode(SCNNode(geometry: line))
            for end: Float in [1, -1] {
                let knob = SCNSphere(radius: end > 0 ? 0.11 : 0.07)
                knob.segmentCount = 16
                knob.materials = [Self.gizmoMaterial(colours[index])]
                let node = SCNNode(geometry: knob)
                node.position = SCNVector3(0, end, 0)
                node.renderingOrder = 2001
                axis.addChildNode(node)
            }
            // The picked axis stretches far out both ways, fading with distance.
            if gizmoRing == index {
                let pieces = 24
                let reach: Float = 7
                for end: Float in [1, -1] {
                    for piece in 0..<pieces {
                        let fade = 1 - Float(piece) / Float(pieces)
                        let length = reach / Float(pieces)
                        let segment = SCNCylinder(radius: 0.009, height: CGFloat(length))
                        segment.radialSegmentCount = 6
                        segment.materials = [Self.gizmoMaterial(colours[index], alpha: CGFloat(0.75 * fade * fade))]
                        let node = SCNNode(geometry: segment)
                        node.position = SCNVector3(0, end * (1 + (Float(piece) + 0.5) * length), 0)
                        node.renderingOrder = 1999
                        axis.addChildNode(node)
                    }
                }
            }
            axis.opacity = gizmoRing == nil || gizmoRing == index ? 1 : 0.25
            holder.addChildNode(axis)
        }
        holder.simdWorldPosition = centre
        holder.simdScale = SIMD3(repeating: radius)
        root.addChildNode(holder)
        gizmoNode = holder
    }

    /// Both knob ends of an axis, in the world.
    private func handlePoints(_ index: Int) -> [SIMD3<Float>] {
        let axis = Self.ringAxes[index]
        return [gizmoCentre + axis * gizmoRadius, gizmoCentre - axis * gizmoRadius]
    }

    /// Chooses the knob nearest the finger (within about a thumb's width) and remembers which end was grabbed.
    private func gizmoPick(at finger: CGPoint, in view: SCNView, node: SCNNode, id: UUID) {
        gizmoRing = nil
        gizmoGrab = nil
        guard gizmoNode != nil else { return }
        var best: (ring: Int, distance: CGFloat, point: SIMD3<Float>)?
        for ring in 0..<3 {
            for point in handlePoints(ring) {
                let shown = view.projectPoint(SCNVector3(point.x, point.y, point.z))
                guard shown.z > 0, shown.z < 1 else { continue }
                let distance = hypot(CGFloat(shown.x) - finger.x, CGFloat(shown.y) - finger.y)
                if distance < (best?.distance ?? 50) { best = (ring, distance, point) }
            }
        }
        guard let best else { return }
        gizmoRing = best.ring
        gizmoGrab = best.point
        Haptics.firm()
        refreshGizmo()
    }

    /// Dragging a knob across the line it sits on turns the model about that line.
    private func gizmoDrag(by moved: CGPoint, in view: SCNView, node: SCNNode, id: UUID) {
        guard let ring = gizmoRing, let grab = gizmoGrab else { return }
        let axis = Self.ringAxes[ring]
        let middle = view.projectPoint(SCNVector3(gizmoCentre.x, gizmoCentre.y, gizmoCentre.z))
        let knob = view.projectPoint(SCNVector3(grab.x, grab.y, grab.z))
        let along = CGPoint(x: CGFloat(knob.x - middle.x), y: CGFloat(knob.y - middle.y))
        let length = hypot(along.x, along.y)
        let angle: Float
        if length > 12 {
            // Across the line on the screen; the other end of the line turns the other way, so it feels like holding the knob.
            angle = Float((moved.x * -along.y + moved.y * along.x) / length) * 0.012
        } else {
            // The axis points at you: sideways drag turns it.
            angle = Float(moved.x) * 0.012
        }
        rollModel(node, id: id, axis: axis, by: angle)
    }

    /// Rolls the model about `axis` (the line of sight), through its own middle.
    private func rollModel(_ node: SCNNode, id: UUID, axis: SIMD3<Float>, by angle: Float) {
        let box = boxes[id]
        let middle = ((box?.low ?? .zero) + (box?.high ?? .zero)) / 2
        let before = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        node.simdWorldOrientation = simd_normalize(simd_quatf(angle: angle, axis: axis) * node.simdWorldOrientation)
        let after = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        node.simdWorldPosition += before - after
        updateTilted()
        refreshGizmo()
    }

    /// Stands the selected model upright again, keeping the way it faces.
    func makeUpright() {
        guard let id = selectedModel, let node = modelNodes[id], cutoutPackages[id] == nil else { return }
        let box = boxes[id]
        let middle = ((box?.low ?? .zero) + (box?.high ?? .zero)) / 2
        let before = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        let side = node.simdWorldOrientation.act(SIMD3<Float>(1, 0, 0))
        node.simdWorldOrientation = simd_quatf(angle: atan2(-side.z, side.x), axis: SIMD3<Float>(0, 1, 0))
        let after = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        node.simdWorldPosition += before - after
        Haptics.success()
        commit(id)
        refreshGizmo()
    }

    private func updateTilted() {
        var tilted = false
        if let id = selectedModel, cutoutPackages[id] == nil, let node = modelNodes[id] {
            tilted = node.simdWorldOrientation.act(SIMD3<Float>(0, 1, 0)).y < 0.9995
        }
        if selectedTilted != tilted { selectedTilted = tilted }
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

    /// Phil, 2026-11-18: dragging scans ran at 25-45 ms a frame and one scan held 400-500 MB. A scan's picture is often
    /// 8192 pixels square (256 MB loaded), far more than a phone screen can show: pictures over 2048 pixels are read
    /// down to 2048 with ImageIO (never fully decoded) and mipmapped.
    private static func shrinkTextures(of node: SCNNode, longest: Int = 2048) {
        var shrunk = 0
        node.enumerateHierarchy { child, _ in
            for material in child.geometry?.materials ?? [] {
                for property in [material.diffuse, material.normal, material.emission, material.roughness, material.metalness, material.ambientOcclusion] {
                    var source: CGImageSource?
                    if let url = property.contents as? URL {
                        source = CGImageSourceCreateWithURL(url as CFURL, nil)
                    } else if let path = property.contents as? String, path.hasPrefix("/") {
                        source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                    }
                    guard let source,
                          let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = info[kCGImagePropertyPixelWidth] as? Int,
                          let height = info[kCGImagePropertyPixelHeight] as? Int,
                          max(width, height) > longest
                    else { continue }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: longest,
                    ]
                    if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                        property.contents = image
                        property.mipFilter = .linear
                        shrunk += 1
                    }
                }
            }
        }
        if shrunk > 0 { Diagnostics.log("Pictures shrunk to \(longest) pixels: \(shrunk)") }
    }

    @discardableResult
    private func loadNode(for model: PlacedModel) -> SCNNode? {
        if model.file.hasSuffix("." + Cutout.fileExtension) { return loadCutoutNode(for: model) }
        if model.file.hasSuffix(".fbx") { return loadFBXNode(for: model) }
        let url = folder.appendingPathComponent(model.file)
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
        let node = SCNNode()
        node.name = model.id.uuidString
        for child in scene.rootNode.childNodes {
            node.addChildNode(child)
        }
        // A scan's colours are photographs, with the light of the day already in them: shown as they are, not lit a
        // second time (Phil's first scan, 2026-11-17: a white bin came out grey beside the real one).
        if model.name.hasPrefix("Scan ") {
            node.enumerateHierarchy { child, _ in
                child.geometry?.materials.forEach { $0.lightingModel = .constant }
            }
        }
        Self.shrinkTextures(of: node)
        let (low, high) = node.boundingBox
        var geometries = 0
        node.enumerateHierarchy { child, _ in if child.geometry != nil { geometries += 1 } }
        Diagnostics.log(String(format: "Model loaded (" + Diagnostics.memory() + "): %@, %d geometries, box %.2f x %.2f x %.2f m",
                               model.name, geometries, high.x - low.x, high.y - low.y, high.z - low.z))
        boxes[model.id] = (SIMD3<Float>(low), SIMD3<Float>(high))
        node.simdTransform = matrix4(model.transform)
        root.addChildNode(node)
        modelNodes[model.id] = node
        refreshDimensions(model.id)
        return node
    }

    /// An FBX file, read with its bones so a character can be posed (FBXImport.swift).
    private func loadFBXNode(for model: PlacedModel) -> SCNNode? {
        guard let loaded = FBXImport.load(folder.appendingPathComponent(model.file), name: model.name) else { return nil }
        let node = SCNNode()
        node.name = model.id.uuidString
        node.addChildNode(loaded.node)
        boxes[model.id] = (loaded.low, loaded.high)
        rigs[model.id] = loaded.rig
        if let pose = model.rigPose { loaded.rig?.apply(pose) }
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
        plane.renderingOrder = 1
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
        node.addChildNode(Self.shadow(width: max(widest, height * 0.3)))
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
        // Over a saved frame (Review) there is no live camera: the frame's camera picks the side to show.
        guard !cutouts.isEmpty, let camera = eye?.columns.3.xyz else {
            if dimLight { dimLight = false }
            return
        }
        // ARKit's ambient light reading is about 1000 in a lit room; under 250 is dim.
        let estimate = session.currentFrame?.lightEstimate
        let dim = estimate.map { $0.ambientIntensity < 250 } ?? false
        if dim != dimLight { dimLight = dim }
        let wanted = Self.matchesLight ? Self.tint(intensity: Float(estimate?.ambientIntensity ?? 1000),
                                                    kelvin: Float(estimate?.ambientColorTemperature ?? 6500)) : SIMD3<Float>(1, 1, 1)
        let before = lightTint
        lightTint += (wanted - lightTint) * 0.15
        // Setting a material's colour makes SceneKit redo it: only when the tint has really moved.
        if simd_length(lightTint - before) > 0.002 || !tintApplied {
            tintApplied = true
            let colour = UIColor(red: CGFloat(lightTint.x), green: CGFloat(lightTint.y), blue: CGFloat(lightTint.z), alpha: 1)
            for state in cutouts.values { state.plane.geometry?.firstMaterial?.multiply.contents = colour }
        }
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
            if showDimensions { refreshDimensions(id) }
        }
    }

    /// How to colour a cut-out for the room: darker in dim light, warmer under tungsten, cooler in shade. Gentle,
    /// so a photo never turns black or orange.
    static func tint(intensity: Float, kelvin: Float) -> SIMD3<Float> {
        let bright = min(max(intensity / 1000, 0.45), 1)
        let t = min(max(kelvin, 2500), 10000)
        var colour = SIMD3<Float>(1, 1, 1)
        if t < 6500 {
            let warm = (6500 - t) / 4000
            colour = SIMD3(1, 1 - 0.12 * warm, 1 - 0.3 * warm)
        } else {
            let cool = (t - 6500) / 3500
            colour = SIMD3(1 - 0.15 * cool, 1 - 0.05 * cool, 1)
        }
        return colour * bright
    }

    /// A soft dark patch on the ground under a cut-out, so it stands on the floor instead of floating over it.
    private static func shadow(width: Float) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(width * 1.3), height: CGFloat(width * 0.55))
        let material = SCNMaterial()
        material.diffuse.contents = shadowImage
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.name = "cutout-shadow"
        node.eulerAngles.x = -.pi / 2
        node.position.y = 0.003
        node.renderingOrder = 0
        return node
    }

    private static let shadowImage: UIImage = {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colours = [UIColor.black.withAlphaComponent(0.5).cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 1]) else { return }
            let middle = CGPoint(x: 64, y: 64)
            context.cgContext.drawRadialGradient(gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: 64, options: [])
        }
    }()

    /// Hangs fresh arrows on the model for its size now, or takes them off when turned off.
    private func refreshDimensions(_ id: UUID) {
        guard let node = modelNodes[id] else { return }
        node.childNode(withName: ModelDimensions.nodeName, recursively: false)?.removeFromParentNode()
        if let state = cutouts[id], let holder = state.plane.parent {
            // A cut-out: width and height of the photo shown now, on the card's holder so they face the camera with it.
            holder.childNode(withName: ModelDimensions.nodeName, recursively: false)?.removeFromParentNode()
            guard showDimensions else { return }
            let w = state.height * state.aspects[state.shown]
            holder.addChildNode(ModelDimensions.make(low: SIMD3(-w / 2, 0, 0), high: SIMD3(w / 2, state.height, 0), scale: node.simdScale.x))
            return
        }
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
    /// Opens the add menu. On its side the 3D models button gives its corner to these tools, so the way to add
    /// another model is the first of them (Phil, 2026-11-11: could not add cut-outs in landscape).
    var onAdd: (() -> Void)? = nil
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var showsCutoutHelp = true
    @State private var posing = false

    private static func symbol(_ job: ModelPlacer.CutoutJob) -> String {
        switch job {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .turn: return "arrow.triangle.2.circlepath"
        case .size: return "arrow.up.left.and.arrow.down.right"
        case .tilt: return "rotate.3d"
        case .lift: return "arrow.up.and.down"
        }
    }

    /// The tools for the model itself: bring it here, pin its distance, stand it, size it.
    @ViewBuilder private func modelTools(cutout: Bool) -> some View {
        CutoutTool(word: "Place here", symbol: "scope") { placer.bringToView() }
        // Sets its true distance from two views, so it stays put as the camera moves. Live camera only.
        if showsFloor {
            let isPinned = placer.selectedModel.map { placer.pinned.contains($0) } ?? false
            CutoutTool(word: isPinned ? "Pinned" : "Pin", symbol: "pin", tint: isPinned ? .white : Theme.accent, on: placer.pinStep != nil) { placer.startPin() }
        }
        if cutout {
            CutoutTool(word: "Straighten", symbol: "arrow.uturn.backward") { placer.resetPose() }
        } else {
            if showsFloor { CutoutTool(word: "Floor", symbol: "arrow.down.to.line") { placer.dropToFloor() } }
            CutoutTool(word: "True size", symbol: "1.square") { placer.resetSelectedModelSize() }
            if placer.selectedTilted { CutoutTool(word: "Upright", symbol: "arrow.up.to.line", tint: Theme.accent) { placer.makeUpright() } }
        }
    }

    /// The tools for the list of models: add another, show sizes, delete, finish.
    @ViewBuilder private func listTools(onAdd: (() -> Void)?) -> some View {
        if let onAdd {
            CutoutTool(word: "Add", symbol: "plus", tint: Theme.accent, action: onAdd)
        }
        CutoutTool(word: placer.showDimensions ? "Sizes " + ModelDimensions.textStepNames[min(max(placer.dimensionStep, 0), 3)] : "Sizes", symbol: "ruler") { placer.cycleDimensions() }
        CutoutTool(word: "Delete", symbol: "trash", tint: .red) { placer.deleteSelectedModel() }
        CutoutTool(word: "Done", symbol: "checkmark") { placer.selectedModel = nil }
    }

    var body: some View {
        VStack(spacing: 6) {
            if let copier = placer.poseCopier {
                PoseCopyBar(copier: copier)
            }
            if placer.dimLight {
                Text("Dim light: cut-outs may drift. Try the torch.")
                    .font(Theme.footnote)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }
            if placer.selectedModelName == nil, !placer.models.isEmpty {
                Button("Find model") { TapGate.run("Find model") { placer.bringToView() } }
                    .caughtTap("Find model") { placer.bringToView() }
                    .buttonStyle(.bordered)
                    .font(Theme.headline)
                    .controlSize(.small)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            else if placer.selectedModelName != nil {
                // Phil, 2026-11-08: the cut-out controls covered too much of the middle of the picture. One slim row
                // along the bottom, a small picture with its word under it (the words stay whole), no panel; the
                // help line shows for a few seconds when a model is picked, then goes.
                // Phil, 2026-11-09: gestures were not intuitive. Pick one job and one finger does only that; hold the object
                // and walk to take it along. Phil, 2026-11-10: the same for USDZ and every other model, with Lift
                // in place of Tilt (only a flat cut-out tips).
                // Phil, 2026-11-10: tools pushed to the screen's edges, jobs down the left and actions down the right,
                // so the middle stays clear; the help is a small picture of the finger's move, not a sentence.
                let cutout = placer.selectedIsCutout
                HStack(alignment: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        // Phil, 2026-11-11: Lift for cut-outs too. 2026-11-17: Tilt for every model ("rotate any object"): tip and lean.
                        ForEach(ModelPlacer.CutoutJob.allCases, id: \.self) { job in
                            CutoutTool(word: job == .tilt && !cutout ? "Rotate" : job.rawValue, symbol: Self.symbol(job), on: placer.cutoutJob == job) { placer.cutoutJob = job }
                        }
                        // Carry walks it along with the live camera, so not over a saved frame (Review).
                        if showsFloor {
                            CutoutTool(word: placer.carrying ? "Carrying" : "Carry", symbol: "figure.walk", on: placer.carrying) {}
                                .simultaneousGesture(DragGesture(minimumDistance: 0)
                                    .onChanged { _ in placer.startCarrying() }
                                    .onEnded { _ in placer.stopCarrying() })
                        }
                        if placer.selectedPoseSpec != nil {
                            CutoutTool(word: "Pose", symbol: "figure.arms.open", tint: Theme.accent) { posing = true }
                        }
                    }
                    // Phil's 1275 screenshot: "Place here" and "Straighten" ran off the screen's edge. The columns keep
                    // the width of their longest word whatever sits between them.
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    if showsCutoutHelp || placer.carrying || placer.pinStep != nil {
                        MoveHint(job: placer.cutoutJob, carrying: placer.carrying, size: cutout ? nil : placer.sizeText, pin: placer.pinStep, cutout: cutout)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    // Phil, 2026-11-17: eight tools in one column ran up into the top row. On its side they stand in two
                    // short columns instead (the first column's tools about the model, the second's about the list).
                    if verticalSize == .compact {
                        HStack(alignment: .bottom, spacing: 0) {
                            VStack(spacing: 0) { modelTools(cutout: cutout) }
                                .fixedSize(horizontal: true, vertical: false)
                            VStack(spacing: 0) { listTools(onAdd: onAdd) }
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .layoutPriority(1)
                    } else {
                        VStack(spacing: 0) {
                            modelTools(cutout: cutout)
                            listTools(onAdd: nil)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .center) { ObjectNudge(placer: placer).offset(y: -110) }
                .task(id: "\(placer.selectedModel?.uuidString ?? "")-\(placer.cutoutJob.rawValue)") {
                    withAnimation { showsCutoutHelp = true }
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { showsCutoutHelp = false }
                }
            }
        }
        .fullScreenCover(isPresented: $posing) {
            if let id = placer.selectedModel, let spec = placer.selectedPoseSpec {
                MannequinPoseEditor(spec: spec) { placer.repose(id, as: $0) }
            }
        }
        .alert("3D model", isPresented: Binding(get: { placer.modelError != nil }, set: { if !$0 { placer.modelError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(placer.modelError ?? "")
        }
    }
}

/// The help as a picture: a finger and the way to drag it, with a word or two at most.
private struct MoveHint: View {
    let job: ModelPlacer.CutoutJob
    let carrying: Bool
    let size: String?
    var pin: ModelPlacer.PinStep?
    var cutout = false

    private var parts: (arrow: String, words: String) {
        switch pin {
        case .stepAside: return ("arrow.left.and.right", "1 of 2: step sideways, keep it in view")
        case .dragBack: return ("hand.draw", "2 of 2: drag it back onto its spot")
        case .done: return ("checkmark", "pinned: its distance is fixed")
        case nil: break
        }
        if carrying { return ("figure.walk", "walk, let go to drop") }
        switch job {
        case .move: return ("arrow.up.and.down.and.arrow.left.and.right", "↑ further · hold: lift")
        case .turn: return ("arrow.left.and.right", "drag or twist: turn")
        case .size: return ("arrow.up.and.down.circle", "pinch, or drag ↕, to scale · the figures follow")
        case .tilt: return ("rotate.3d", cutout ? "↕ tip  ↔ slant" : "drag a knob to turn about its line · or anywhere · twist: roll")
        case .lift: return ("arrow.up.and.down", "↑ higher")
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: pin == .stepAside ? "figure.walk" : pin == .done ? "pin.fill" : carrying ? "iphone.gen3" : "hand.point.up.left.fill")
                Image(systemName: parts.arrow).font(.system(size: 16, weight: .bold))
            }
            .font(.system(size: 22, weight: .semibold))
            Text(parts.words).font(.system(size: 12, weight: .semibold))
            if pin == nil, let size, !size.isEmpty { Text(size).font(.system(size: 11, weight: .semibold).monospacedDigit()) }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.5), radius: 6)
        .padding(.bottom, 6)
        .allowsHitTesting(false)
    }
}

/// One small control for a cut-out: a picture with its word under it, white with a soft shadow, no box.
private struct CutoutTool: View {
    let word: String
    let symbol: String
    var tint: Color = .white
    var on = false
    let action: () -> Void

    /// The button and the window's tap watcher can both fire for one tap (see WindowTapCatcher): once is enough.
    @MainActor private static var lastFired: [String: Date] = [:]

    private func fire() {
        let now = Date()
        if let last = Self.lastFired[symbol], now.timeIntervalSince(last) < 0.5 { return }
        Self.lastFired[symbol] = now
        action()
    }

    var body: some View {
        Button(action: fire) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(word).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(on ? Theme.accent : tint)
            .fontWeight(on ? .heavy : .semibold)
            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.5), radius: 6)
            .frame(minWidth: 58, minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On its side, taps near the screen's edges can miss SwiftUI buttons; the window's tap watcher catches them.
        .modifier(WindowFrame { frame in WindowTapCatcher.current?.targets["Tool \(symbol)"] = (frame, { fire() }) })
        .onDisappear { WindowTapCatcher.current?.targets["Tool \(symbol)"] = nil }
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
