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
            refreshPoseDots()
            refreshLightSun()
            if selectedModel != oldValue, selectedModel != nil { Haptics.bump() }
            if selectedModel != oldValue {
                pickingInFront = false
                stopCarrying()
                cancelPin()
                cutoutJob = .move
                // A model already in the group becomes the main one and the group stays; any other choice ends it.
                if let picked = selectedModel, let old = oldValue, group.contains(picked) {
                    group.remove(picked)
                    group.insert(old)
                } else if !group.isEmpty || pickingGroup {
                    group = []
                    pickingGroup = false
                }
                refreshGroupMarks()
            }
        }
    }
    /// Phil, 2026-11-21: "selecting multiple highlighted models and moving them all". Models picked with "Select more"
    /// go along with the selected one: drag, hold-to-lift, Lift, Turn (round the selected one) and Carry move them
    /// all. Each gets a yellow ring on the floor under it while the group is on.
    @Published private(set) var group: Set<UUID> = []
    /// While on, a tap on another model adds it to the group (or takes it out again).
    @Published var pickingGroup = false {
        didSet {
            guard pickingGroup != oldValue else { return }
            // The tap on "Select more" itself can reach the camera view too: it neither picks nor lets go of the model.
            pickingGroupSince = Date()
            if pickingGroup { pickingInFront = false }
            refreshGroupMarks()
        }
    }
    private var pickingGroupSince = Date.distantPast
    private var groupMarks: [UUID: SCNNode] = [:]
    @Published var modelError: String?
    /// Phil, 2026-11-20: "selecting what is foreground": after "In front", the next tap on the camera picture picks the
    /// real thing that goes in front of the models (LiveOcclusion.swift). Tapping a picked thing again takes it out.
    @Published var pickingInFront = false {
        didSet { if pickingInFront { pickingSince = Date(); pickingGroup = false } }
    }
    private var pickingSince = Date.distantPast
    /// How many real things are in front of the models now.
    @Published var inFrontCount = 0
    /// Set by the live view's occluder: the tap that picks a thing.
    var onPickInFront: ((CGPoint, ARSCNView) -> Void)?
    /// Phil, 2026-11-20: "Push back a layer", "And bring forward", "line up a row of posed people and look down that
    /// row". The picked real things are layers, nearest the camera in front. Each model is behind the picked things
    /// nearer than it (`nearerThings`, from the live view's occluder), moved by Push back / Bring forward (`layerShift`).
    @Published private(set) var layerShift: [UUID: Int] = [:]
    @Published var nearerThings: [UUID: Int] = [:]

    /// How many picked real things the model is behind.
    /// Whether "Hide models behind anything nearer" is hiding models now: the room is then the furthest layer, and a
    /// model brought forward past it shows in front of everything real that wasn't picked (Phil's 1424 recording: a
    /// glass balustrade hid a scan placed down in the alley).
    @Published var roomLayer = false { didSet { if roomLayer != oldValue { applyLayers() } } }
    /// Layers a model can be behind: the picked things, and the room when it hides models.
    var layerCount: Int { inFrontCount + (roomLayer ? 1 : 0) }
    /// Where real distance puts a model: behind the picked things nearer than it, and behind the room.
    private func baseLayer(of id: UUID) -> Int { (nearerThings[id] ?? inFrontCount) + (roomLayer ? 1 : 0) }

    func layer(of id: UUID) -> Int { min(max(0, baseLayer(of: id) + (layerShift[id] ?? 0)), layerCount) }

    /// Moves the selected model one picked thing back (+1) or forward (-1).
    func moveSelectedLayer(by step: Int) {
        guard let id = selectedModel else { return }
        let now = layer(of: id)
        let next = min(max(0, now + step), layerCount)
        guard next != now else { return }
        layerShift[id] = next - baseLayer(of: id)
        Haptics.tap()
        applyLayers()
        Diagnostics.log("In front: model moved \(step > 0 ? "back" : "forward"), now behind \(next) of \(layerCount) layers (\(inFrontCount) picked\(roomLayer ? " + the room" : ""))")
    }

    /// Whether the selected model was moved by Push back / Bring forward away from where real distance puts it.
    var selectedLayerChanged: Bool { selectedModel.map { (layerShift[$0] ?? 0) != 0 } ?? false }

    /// Back to the order real distance gives (Phil, 2026-11-21: distance arranges the scene; your own order is separate).
    func resetSelectedLayer() {
        guard let id = selectedModel, layerShift[id] != nil else { return }
        layerShift[id] = nil
        Haptics.tap()
        applyLayers()
        Diagnostics.log("In front: model back to the order real distance gives")
    }

    /// Draws each model just after the picked things in front of it and before those behind it (LiveOcclusion.swift
    /// draws the k-th nearest picked thing at 10k + 5), so only the things in front hide it. Handles and dots (1000 and up) stay on top.
    func applyLayers() {
        for (id, node) in modelNodes {
            let base = 10 * layer(of: id)
            node.enumerateHierarchy { child, _ in
                guard child.renderingOrder < 1000 else { return }
                let own = ((child.renderingOrder % 10) + 10) % 10
                if child.renderingOrder != base + own { child.renderingOrder = base + own }
            }
        }
    }
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
    /// Copying a person's pose from the live camera onto the selected character (Phil, 2026-11-22).
    @Published var poseTaker: PoseTaker?
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
    /// A figure tapped to type its real length (Phil, 2026-11-18: "type a real length to scale").
    struct DimensionEdit: Identifiable, Equatable {
        let id = UUID()
        let model: UUID
        let letter: String
        let current: Float
        var name: String { letter == "W" ? "Width" : letter == "D" ? "Depth" : "Height" }
    }
    @Published var editingDimension: DimensionEdit?

    /// The figure nearest the finger (within a thumb's width), if one is shown for the selected model.
    private func dimensionTap(at point: CGPoint, in view: SCNView) -> Bool {
        guard showDimensions, let id = selectedModel, let node = modelNodes[id] else { return false }
        var holders: [SCNNode] = []
        if let inside = node.childNode(withName: ModelDimensions.nodeName, recursively: false) { holders.append(inside) }
        if let beside = cutouts[id]?.plane.parent?.childNode(withName: ModelDimensions.nodeName, recursively: false) { holders.append(beside) }
        var best: (letter: String, distance: CGFloat)?
        for holder in holders {
            for tag in holder.childNodes {
                guard let name = tag.name, name.hasPrefix(ModelDimensions.tagPrefix) else { continue }
                let place = tag.presentation.worldPosition
                let shown = view.projectPoint(place)
                guard shown.z > 0, shown.z < 1 else { continue }
                let distance = hypot(CGFloat(shown.x) - point.x, CGFloat(shown.y) - point.y)
                if distance < (best?.distance ?? 48) { best = (String(name.dropFirst(ModelDimensions.tagPrefix.count)), distance) }
            }
        }
        guard let best, let current = dimensionLength(best.letter, of: id) else { return false }
        Haptics.tap()
        editingDimension = DimensionEdit(model: id, letter: best.letter, current: current)
        return true
    }

    /// Width, depth or height now, in metres, for a model or a cut-out.
    private func dimensionLength(_ letter: String, of id: UUID) -> Float? {
        guard let node = modelNodes[id] else { return nil }
        let scale = node.simdScale.x
        if let state = cutouts[id] {
            switch letter {
            case "W": return state.height * state.aspects[state.shown] * scale
            case "H": return state.height * scale
            default: return nil
            }
        }
        guard cutoutPackages[id] == nil, let box = boxes[id] else { return nil }
        switch letter {
        case "W": return (box.high.x - box.low.x) * scale
        case "D": return (box.high.z - box.low.z) * scale
        default: return (box.high.y - box.low.y) * scale
        }
    }

    /// Scales the whole model so the tapped figure reads the length typed.
    func applyTypedLength(_ edit: DimensionEdit, text: String) {
        guard let real = LengthText.parse(text), edit.current > 0.0001, let node = modelNodes[edit.model] else {
            modelError = "That length didn't make sense. Try 120, 1.2 m, or 4 ft."
            Haptics.warning()
            return
        }
        let factor = real / edit.current
        let next = node.simdScale.x * factor
        guard next > 0.005, next < 2000 else {
            modelError = "That would make it too small or too large."
            Haptics.warning()
            return
        }
        node.simdScale *= factor
        pinned.remove(edit.model)
        updateSize()
        refreshDimensions(edit.model)
        commit(edit.model)
        Haptics.success()
        Diagnostics.log(String(format: "Typed length: %@ %.0f cm became %.0f cm (x%.2f)", edit.letter, edit.current * 100, real * 100, factor))
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
        let hint = teach ? words + " · tap Sizes again to change\nTap a figure to type its real length" : words
        dimensionHint = hint
        Haptics.tap()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if dimensionHint == hint { dimensionHint = nil }
        }
    }
    private(set) var modelNodes: [UUID: SCNNode] = [:]
    /// Where each placed model stands in the room now, for the log of what hides it (LiveOcclusion.swift).
    /// Where each placed model stands in the room, by id.
    var modelPlaces: [UUID: SIMD3<Float>] {
        modelNodes.mapValues { $0.presentation.simdWorldPosition }
    }
    var worldPositions: [(name: String, position: SIMD3<Float>)] {
        models.compactMap { model in modelNodes[model.id].map { (model.name, $0.presentation.simdWorldPosition) } }
    }
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
    enum CutoutJob: String, CaseIterable { case move = "Move", turn = "Turn", size = "Size", tilt = "Tilt", lift = "Lift", pose = "Pose", light = "Light" }
    @Published var cutoutJob: CutoutJob = .move { didSet { if cutoutJob != oldValue { refreshGizmo(); refreshPoseDots(); refreshLightSun() } } }
    /// Phil, 2026-11-21: each model's light (ModelLighting.swift). What one finger changes while Light is on.
    @Published var lightPart: ModelLight.Part = .brightness
    /// The light being dragged, saved into `models` when the finger lifts; the sun that shows where it comes from.
    var lightDraft: (id: UUID, light: ModelLight)?
    /// Phil, 2026-11-26: soft edges on cropped scans (SoftEdgeModels.swift). Each softened model's meshes and distances
    /// from its cut edges; models being worked out; models found to have no cut edges.
    var softEdgeCaches: [UUID: SoftEdgeCache] = [:]
    var softEdgeWorking: Set<UUID> = []
    var softEdgeClosed: Set<UUID> = []
    var lightSun: SCNNode?
    var lastLightShown = Date.distantPast
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
        var model = PlacedModel(id: id, name: ScanFolder.title(ofModelAt: source) ?? source.deletingPathExtension().lastPathComponent, file: file, transform: flatten(transform))
        if source.path.contains("/Scans/") { model.scan = true }
        guard loadNode(for: model) != nil else {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: FBXImport.texturesFolder(for: destination))
            return nil
        }
        if keep, model.scan != true { ModelLibrary.keep(destination, name: model.name) }
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
        group = []
        pickingGroup = false
        refreshGroupMarks()
        forgetUndo()
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
            // A scanned head worn by a mannequin.
            if let worn = model.mannequin?.head {
                let from = folder.appendingPathComponent(worn, isDirectory: true), to = destination.appendingPathComponent(worn, isDirectory: true)
                if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
                    try? FileManager.default.copyItem(at: from, to: to)
                }
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
    var eye: simd_float4x4? {
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
        record(id)
    }

    // MARK: Posing an imported character in live view (Phil, 2026-11-18)

    private var poseDots: [(node: SCNNode, joint: PoseDrag.Joint)] = []
    private var poseHandle: PoseDrag.Joint? { didSet { if poseHandle != oldValue { showHeldDot() } } }
    /// Each dot's own colour, and the line from an offset dot to its joint.
    private var poseDotColour: [SCNNode: UIColor] = [:]
    private var poseLines: [SCNNode: SCNNode] = [:]
    /// What the held dot works, in a few words, for the hint at the bottom (nil when none is held).
    @Published private(set) var heldPoseWord: String?

    /// The held dot white and solid with a soft halo, its line white; the others back to see-through.
    private func showHeldDot() {
        let chosen = poseHandle ?? poseSelected
        for (node, joint) in poseDots {
            let held = joint == chosen
            let colour = poseDotColour[node] ?? .white
            node.geometry?.firstMaterial?.diffuse.contents = held ? UIColor.white : colour.withAlphaComponent(0.6)
            node.childNode(withName: "posehalo", recursively: false)?.removeFromParentNode()
            if held, let sphere = node.geometry as? SCNSphere {
                let halo = SCNNode(geometry: SCNSphere(radius: sphere.radius * 1.9))
                halo.name = "posehalo"
                halo.geometry?.materials = [ModelDimensions.flat(colour.withAlphaComponent(0.3))]
                halo.renderingOrder = 1998
                node.addChildNode(halo)
            }
            poseLines[node]?.childNodes.first?.geometry?.firstMaterial?.diffuse.contents = held ? UIColor.white : colour.withAlphaComponent(0.7)
        }
        showPoseWord()
    }

    /// The hint: what the turning wheel does, or the held dot, or the selected one with its wheels.
    private func showPoseWord() {
        if let words = poseWheels.turningWords {
            heldPoseWord = words
        } else if let joint = poseHandle {
            heldPoseWord = Self.poseWord(joint)
        } else if let joint = poseSelected {
            heldPoseWord = poseWheels.wheels.isEmpty ? Self.poseWord(joint) : Self.poseWord(joint) + " · or turn an arrow"
        } else {
            heldPoseWord = nil
        }
    }

    /// What each dot does, as the hint says it while it is held.
    static func poseWord(_ joint: PoseDrag.Joint) -> String {
        switch joint {
        case .hand: return "Hand: reach, the arm follows"
        case .elbow: return "Elbow: swing the bend"
        case .foot: return "Foot: step, the leg follows"
        case .knee: return "Knee: swing the bend"
        case .wrist: return "Wrist: bend the hand"
        case .ankle: return "Ankle: point the foot"
        case .shoulder: return "Shoulder: shrug and roll"
        case .head: return "Neck: lean the body"
        case .headLook: return "Top of head: turn and nod"
        case .headTilt: return "Ear: tilt the head"
        case .hips: return "Hips: turn and tilt"
        }
    }
    /// Phil, 2026-11-20: curved arrows on the floor under a character in Pose; drag them left or right to turn it round.
    private var poseTurnIcon: SCNNode?
    private var poseTurnReach: Float = 0
    private var poseTurning = false
    private var poseTurnLast: Float = 0
    private var poseDepth: Float = 1
    private var poseStartFinger: CGPoint = .zero
    private var poseStartPose: MannequinPose?
    /// What each character was posed like before each drag, for Undo and Redo (nil: as the file rests).
    private var poseUndo: [UUID: [MannequinPose?]] = [:]
    private var poseRedo: [UUID: [MannequinPose?]] = [:]
    @Published private(set) var poseHistory = 0
    /// Phil, 2026-11-21: a dot stays selected when the finger lifts, with a wheel round its joint for each way the
    /// joint turns; and the dots that turn a joint (yellow) move it the way the finger goes, like the others.
    private let poseWheels = PoseWheelSet()
    private var poseSelected: PoseDrag.Joint? { didSet { if poseSelected != oldValue { showHeldDot() } } }
    private var poseWheelGrab = false

    /// The dots that turn a joint, rather than reach with it.
    private static func turnsJoint(_ joint: PoseDrag.Joint) -> Bool {
        switch joint {
        case .wrist, .ankle, .shoulder, .headLook, .headTilt, .hips: return true
        default: return false
        }
    }

    /// Where a point in the world shows on the screen (nil behind the camera).
    private static func onScreen(_ view: SCNView) -> (SIMD3<Float>) -> SIMD2<Float>? {
        { p in
            let shown = view.projectPoint(SCNVector3(p.x, p.y, p.z))
            return shown.z > 0 && shown.z < 1 ? SIMD2(Float(shown.x), Float(shown.y)) : nil
        }
    }

    /// The wheels round the selected dot's joint, worked out from the character as it is posed now.
    private func buildPoseWheels(id: UUID) {
        guard let joint = poseSelected, let rig = rigs[id], let node = modelNodes[id],
              let model = models.first(where: { $0.id == id }) else {
            poseWheels.clear()
            showPoseWord()
            return
        }
        let map = rig.poser.map
        let pose = model.rigPose ?? rig.poser.restPose
        let h = max(rig.height * node.simdScale.x, 0.2)
        let up = node.simdWorldOrientation.act(SIMD3(0, 1, 0))
        let ahead = node.simdWorldOrientation.act(SIMD3(0, 0, map.facing))
        func at(_ index: Int?) -> SIMD3<Float>? { index.flatMap { rig.joint($0)?.simdWorldPosition } }
        /// A point fixed to a bone where it is now, read again wherever the bone goes.
        func riding(_ bone: Int?, _ world: SIMD3<Float>) -> () -> SIMD3<Float> {
            guard let n = bone.flatMap({ rig.joint($0) }) else { return { world } }
            let local = n.simdConvertPosition(world, from: nil)
            return { n.simdConvertPosition(local, to: nil) }
        }
        func chain(_ side: Int, arm: Bool) -> [Int] { arm ? (side == 0 ? map.armL : map.armR) : (side == 0 ? map.legL : map.legR) }
        let ratio: Float = {
            var c: [Int]?
            switch joint {
            case .elbow(let s), .hand(let s), .wrist(let s), .shoulder(let s): c = chain(s, arm: true)
            case .knee(let s), .foot(let s), .ankle(let s): c = chain(s, arm: false)
            default: c = nil
            }
            guard let c, c.count > 2, let a = at(c[0]), let b = at(c[1]), let e = at(c[2]), simd_distance(a, b) > 1e-5 else { return 1 }
            return simd_distance(b, e) / simd_distance(a, b)
        }()
        let anchor: (PoseAxis) -> PoseWheelSet.Anchor? = { axis in
            switch axis {
            case .headTurn, .headNod:
                let head = map.head ?? map.neck
                guard let c = at(head) else { return nil }
                return .init(pivot: riding(head, c), probe: riding(head, c + ahead * (h * 0.1)))
            case .headTilt:
                let head = map.head ?? map.neck
                guard let c = at(head) else { return nil }
                return .init(pivot: riding(head, c), probe: riding(head, c + up * (h * 0.12)))
            case .shrug(let s), .roll(let s):
                let upper = chain(s, arm: true)[0]
                let collar = s < rig.poser.collars.count ? rig.poser.collars[s] : nil
                guard let collar, let c = at(collar), let u = at(upper) else { return nil }
                return .init(pivot: riding(collar, c), probe: riding(upper, u))
            case .wristBend(let s), .wristSide(let s):
                let c = chain(s, arm: true)
                guard let w = at(c[2]), let e = at(c[1]), simd_distance(w, e) > 1e-5 else { return nil }
                return .init(pivot: riding(c[2], w), probe: riding(c[2], w + simd_normalize(w - e) * (h * 0.08)))
            case .anklePoint(let s), .ankleTurn(let s):
                let c = chain(s, arm: false)
                guard let a = at(c[2]) else { return nil }
                return .init(pivot: riding(c[2], a), probe: riding(c[2], a + ahead * (h * 0.08)))
            case .hipTurn, .hipTilt:
                guard let c = at(map.hips), let leg = at(map.legL[0]) else { return nil }
                return .init(pivot: riding(map.hips, c), probe: riding(map.legL[0], leg))
            case .leanForward, .leanSide:
                guard let c = at(map.hips), let neck = map.neck ?? map.head ?? map.spine.last, let n = at(neck) else { return nil }
                return .init(pivot: riding(map.hips, c), probe: riding(neck, n))
            case .swivel(let arm, let s):
                // About the line from shoulder to hand (hip to foot), which the swing keeps where it is.
                let c = chain(s, arm: arm)
                guard let t = at(c[0]), let m = at(c[1]), let e = at(c[2]), simd_distance(t, e) > 1e-4 else { return nil }
                let line = simd_normalize(e - t)
                let foot = t + line * simd_dot(m - t, line)
                return .init(pivot: { foot }, probe: riding(c[1], m))
            case .bend(let arm, let s):
                let c = chain(s, arm: arm)
                guard let m = at(c[1]), let e = at(c[2]) else { return nil }
                return .init(pivot: riding(c[1], m), probe: riding(c[2], e))
            }
        }
        poseWheels.build(joint, pose: pose, ratio: ratio, smallest: h * 0.05, colours: [Theme.accentUI, .systemYellow],
                         show: { rig.apply($0) }, anchor: anchor, parent: node)
        rig.apply(model.rigPose)
        showPoseWord()
    }

    /// Lets go of the selected dot and its wheels.
    private func deselectPoseDot() {
        poseWheels.clear()
        poseSelected = nil
        showPoseWord()
    }

    /// The selected model is an imported character that can be posed by its joints.
    var selectedHasRig: Bool {
        guard let id = selectedModel else { return false }
        return rigs[id] != nil
    }

    var canUndoPose: Bool { selectedModel.map { !(poseUndo[$0]?.isEmpty ?? true) } ?? false }
    var canRedoPose: Bool { selectedModel.map { !(poseRedo[$0]?.isEmpty ?? true) } ?? false }

    /// Dots on the character's hands, feet, elbows, knees, head and hips, riding on its own bones so they follow it.
    /// Mint dots reach (the limb follows); yellow dots articulate (hips turn and tilt, wrists and ankles bend).
    func refreshPoseDots() {
        for dot in poseDots { dot.node.removeFromParentNode() }
        for line in poseLines.values { line.removeFromParentNode() }
        poseDots = []
        poseLines = [:]
        poseDotColour = [:]
        poseWheels.clear()
        poseWheelGrab = false
        poseSelected = nil
        heldPoseWord = nil
        poseHandle = nil
        poseTurnIcon?.removeFromParentNode()
        poseTurnIcon = nil
        poseTurning = false
        guard cutoutJob == .pose, let id = selectedModel, let rig = rigs[id], let node = modelNodes[id] else { return }
        let map = rig.poser.map
        let worldHeight = max(rig.height * node.simdScale.x, 0.2)
        // Where along the hand or foot its own dot goes: beyond the wrist or ankle, in the way the limb points on.
        func beyond(_ end: Int, from before: Int, share: Float, forward: Bool) -> SIMD3<Float>? {
            guard let bone = rig.joint(end), let prior = rig.joint(before) else { return nil }
            let at = bone.simdWorldPosition
            if forward {
                let ahead = node.simdWorldOrientation.act(SIMD3(0, 0, map.facing))
                return at + ahead * (simd_distance(at, prior.simdWorldPosition) * share)
            }
            let along = at - prior.simdWorldPosition
            guard simd_length(along) > 1e-5 else { return nil }
            return at + simd_normalize(along) * (simd_length(along) * share)
        }
        var wanted: [(Int, PoseDrag.Joint, Float, SIMD3<Float>?, UIColor)] = []
        let mint = Theme.accentUI, yellow = UIColor.systemYellow
        for side in 0..<2 {
            let arm = side == 0 ? map.armL : map.armR, leg = side == 0 ? map.legL : map.legR
            wanted.append((arm[2], .hand(side), 0.032, nil, mint))
            wanted.append((arm[1], .elbow(side), 0.022, nil, mint))
            wanted.append((leg[2], .foot(side), 0.032, nil, mint))
            wanted.append((leg[1], .knee(side), 0.022, nil, mint))
            wanted.append((arm[0], .shoulder(side), 0.022, rig.joint(arm[0]).map { $0.simdWorldPosition + node.simdWorldOrientation.act(SIMD3(0, 1, 0)) * (worldHeight * 0.04) }, yellow))
            wanted.append((arm[2], .wrist(side), 0.02, beyond(arm[2], from: arm[1], share: 0.45, forward: false), yellow))
            wanted.append((leg[2], .ankle(side), 0.02, beyond(leg[2], from: leg[1], share: 0.5, forward: true), yellow))
        }
        if let neck = map.neck ?? map.head { wanted.append((neck, .head, 0.04, nil, mint)) }
        // Head and neck (Phil, 2026-11-19): the crown turns and nods the head, the ear tilts it.
        if let head = map.head ?? map.neck, let bone = rig.joint(head) {
            let up = node.simdWorldOrientation.act(SIMD3(0, 1, 0))
            let side = node.simdWorldOrientation.act(SIMD3(map.facing, 0, 0))
            let at = bone.simdWorldPosition
            wanted.append((head, .headLook, 0.025, at + up * (worldHeight * 0.12), yellow))
            wanted.append((head, .headTilt, 0.02, at + up * (worldHeight * 0.06) + side * (worldHeight * 0.055), yellow))
        }
        wanted.append((map.hips, .hips, 0.04, nil, yellow))
        // Phil, 2026-11-20: the dots were big and solid, it was hard to tell which was held and what each one moved.
        // Now a little smaller and see-through; a held dot turns white with a halo; and a dot that sits off its joint
        // (wrist, ankle, shoulder, the two head dots) has a thin line to the joint it works.
        for (index, joint, share, place, colour) in wanted {
            guard let bone = rig.joint(index) else { continue }
            let scale = max(simd_length(bone.simdWorldTransform.columns.0.xyz), 1e-6)
            let radius = worldHeight * share * 0.75
            let sphere = SCNSphere(radius: CGFloat(radius))
            sphere.segmentCount = 16
            sphere.materials = [ModelDimensions.flat(colour.withAlphaComponent(0.6))]
            let dot = SCNNode(geometry: sphere)
            dot.name = "posedot"
            dot.simdScale = SIMD3(repeating: 1 / scale)
            dot.renderingOrder = 2000
            bone.addChildNode(dot)
            if let place {
                dot.simdPosition = SIMD3(bone.convertPosition(SCNVector3(place.x, place.y, place.z), from: nil))
                // The line, in world-sized units (its node undoes the bone's scale), from the joint to the dot's edge.
                let offset = dot.simdPosition * scale
                let length = simd_length(offset) - radius
                if length > radius * 0.5 {
                    let rod = SCNCylinder(radius: CGFloat(max(worldHeight * 0.0018, 0.0012)), height: CGFloat(length))
                    rod.radialSegmentCount = 6
                    rod.materials = [ModelDimensions.flat(colour.withAlphaComponent(0.7))]
                    let line = SCNNode(geometry: rod)
                    line.name = "posedot"
                    line.renderingOrder = 1999
                    let holder = SCNNode()
                    holder.name = "posedot"
                    holder.simdScale = SIMD3(repeating: 1 / scale)
                    let along = simd_normalize(offset)
                    line.simdPosition = along * (length / 2)
                    line.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: along)
                    holder.addChildNode(line)
                    bone.addChildNode(holder)
                    poseLines[dot] = holder
                }
            }
            poseDotColour[dot] = colour
            poseDots.append((dot, joint))
        }
        // The turning arrows lie on the floor under the feet, on the side nearest the phone.
        let scale = max(node.simdScale.x, 1e-6)
        let reach = worldHeight * 0.3 / scale
        let icon = TurnIcon.node(radius: reach)
        icon.simdPosition = SIMD3(0, (boxes[id]?.low.y ?? 0) + 0.004 / scale, 0)
        if let eye = self.eye?.columns.3.xyz {
            let away = (node.simdWorldTransform.inverse * SIMD4(eye, 1)).xyz
            icon.eulerAngles.y = atan2(away.x, away.z)
        }
        node.addChildNode(icon)
        poseTurnIcon = icon
        poseTurnReach = reach
    }

    /// Where the middle of the turning arrows is now, in the world.
    private func turnKnobPoint() -> SIMD3<Float>? {
        guard let icon = poseTurnIcon else { return nil }
        return (icon.simdWorldTransform * SIMD4(0, 0, poseTurnReach, 1)).xyz
    }

    /// The finger's place on the floor under the character, as an angle round it.
    private func turnAngle(at finger: CGPoint, in view: SCNView) -> Float? {
        guard let icon = poseTurnIcon, let eye = self.eye?.columns.3.xyz else { return nil }
        let far = SIMD3<Float>(view.unprojectPoint(SCNVector3(Float(finger.x), Float(finger.y), 1)))
        let direction = simd_normalize(far - eye)
        let floor = icon.simdWorldPosition
        guard abs(direction.y) > 0.02 else { return nil }
        let t = (floor.y - eye.y) / direction.y
        guard t > 0 else { return nil }
        let hit = eye + direction * t
        return atan2(hit.x - floor.x, hit.z - floor.z)
    }

    /// The dot nearest the finger, within about a thumb's width.
    private func nearestPoseDot(to finger: CGPoint, in view: SCNView, eye: SIMD3<Float>) -> (joint: PoseDrag.Joint, distance: CGFloat, depth: Float)? {
        var best: (joint: PoseDrag.Joint, distance: CGFloat, depth: Float)?
        for dot in poseDots {
            let world = dot.node.simdWorldPosition
            let shown = view.projectPoint(SCNVector3(world.x, world.y, world.z))
            guard shown.z > 0, shown.z < 1 else { continue }
            let distance = hypot(CGFloat(shown.x) - finger.x, CGFloat(shown.y) - finger.y)
            if distance < (best?.distance ?? 50) { best = (dot.joint, distance, simd_distance(world, eye)) }
        }
        return best
    }

    /// A tap in Pose: on a dot selects it and shows its wheels; anywhere else lets go of the selected dot first.
    private func poseTap(at finger: CGPoint, in view: SCNView) -> Bool {
        guard cutoutJob == .pose, let id = selectedModel, rigs[id] != nil, let eye = self.eye?.columns.3.xyz else { return false }
        if let best = nearestPoseDot(to: finger, in: view, eye: eye) {
            poseSelected = best.joint
            buildPoseWheels(id: id)
            Haptics.tap()
            return true
        }
        guard poseSelected != nil else { return false }
        deselectPoseDot()
        return true
    }

    private func posePick(at finger: CGPoint, in view: SCNView, id: UUID) {
        poseHandle = nil
        poseTurning = false
        poseWheelGrab = false
        guard let eye = self.eye?.columns.3.xyz else { return }
        let here = SIMD2(Float(finger.x), Float(finger.y))
        // A wheel of the selected dot first: the joint turns as the wheel does.
        if let rig = rigs[id], let model = models.first(where: { $0.id == id }),
           poseWheels.pick(here, pose: model.rigPose ?? rig.poser.restPose, project: Self.onScreen(view)) {
            poseWheelGrab = true
            poseUndo[id, default: []].append(model.rigPose)
            poseRedo[id] = []
            poseHistory += 1
            showPoseWord()
            Haptics.firm()
            return
        }
        let best = nearestPoseDot(to: finger, in: view, eye: eye)
        if let knob = turnKnobPoint() {
            let shown = view.projectPoint(SCNVector3(knob.x, knob.y, knob.z))
            let distance = hypot(CGFloat(shown.x) - finger.x, CGFloat(shown.y) - finger.y)
            if shown.z > 0, shown.z < 1, distance < (best?.distance ?? 50), let angle = turnAngle(at: finger, in: view) {
                poseTurning = true
                poseTurnLast = angle
                Haptics.firm()
                return
            }
        }
        guard let best, let rig = rigs[id], let model = models.first(where: { $0.id == id }) else {
            // A drag that starts on nothing lets go of the selected dot.
            deselectPoseDot()
            return
        }
        poseHandle = best.joint
        poseDepth = best.depth
        poseStartFinger = finger
        poseStartPose = model.rigPose ?? rig.poser.restPose
        if Self.turnsJoint(best.joint) {
            if poseSelected != best.joint || poseWheels.joint != best.joint { poseSelected = best.joint; buildPoseWheels(id: id) }
            poseWheels.beginHandle(model.rigPose ?? rig.poser.restPose, finger: here)
        } else {
            // The limb reaches: its wheels come back where it ends up.
            poseSelected = best.joint
            poseWheels.clear()
        }
        // One undo step per drag.
        poseUndo[id, default: []].append(model.rigPose)
        poseRedo[id] = []
        poseHistory += 1
        Haptics.firm()
    }

    /// The joint under the finger follows it (at the depth it was picked at) and the limb is solved to match.
    private func poseDrag(to finger: CGPoint, in view: SCNView, node: SCNNode, id: UUID) {
        if poseTurning {
            // The character turns about its own spot, following the finger round the floor.
            guard let angle = turnAngle(at: finger, in: view) else { return }
            var delta = angle - poseTurnLast
            if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
            poseTurnLast = angle
            node.simdWorldOrientation = simd_normalize(simd_quatf(angle: delta, axis: SIMD3(0, 1, 0)) * node.simdWorldOrientation)
            return
        }
        if poseWheelGrab {
            guard let rig = rigs[id], let model = models.first(where: { $0.id == id }),
                  let pose = poseWheels.turnWheel(to: SIMD2(Float(finger.x), Float(finger.y)), project: Self.onScreen(view)) else { return }
            if pose != (model.rigPose ?? rig.poser.restPose) { applyDragPose(pose, rig: rig, id: id) }
            return
        }
        if let joint = poseHandle, Self.turnsJoint(joint), let rig = rigs[id], !poseWheels.wheels.isEmpty {
            // The joint turns so the point it moves goes the way the finger goes (Phil: head and shoulder went the
            // other way to everything else). After a long drag the wheels are measured again from where it is now.
            let here = SIMD2(Float(finger.x), Float(finger.y))
            guard let moved = poseWheels.dragHandle(to: here, project: Self.onScreen(view)) else { return }
            applyDragPose(moved.pose, rig: rig, id: id)
            if moved.far {
                buildPoseWheels(id: id)
                poseWheels.beginHandle(moved.pose, finger: here)
            }
            return
        }
        guard let joint = poseHandle, let rig = rigs[id], let eye = self.eye?.columns.3.xyz,
              let model = models.first(where: { $0.id == id }) else { return }
        let far = SIMD3<Float>(view.unprojectPoint(SCNVector3(Float(finger.x), Float(finger.y), 1)))
        guard simd_length(far - eye) > 0.001 else { return }
        let world = eye + simd_normalize(far - eye) * poseDepth
        let map = rig.poser.map
        let inverse = node.simdWorldTransform.inverse
        // Into the model's own space, turned round if the file has the character facing -Z.
        func local(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = (inverse * SIMD4(p, 1)).xyz
            return map.facing < 0 ? SIMD3(-q.x, q.y, -q.z) : q
        }
        func at(_ index: Int) -> SIMD3<Float> { local(rig.joint(index)?.simdWorldPosition ?? .zero) }
        let chain: [Int]
        switch joint {
        case .hand(let s), .elbow(let s), .wrist(let s): chain = s == 0 ? map.armL : map.armR
        case .foot(let s), .knee(let s), .ankle(let s): chain = s == 0 ? map.legL : map.legR
        case .head, .hips, .headLook, .headTilt: chain = map.armL
        case .shoulder(let s): chain = s == 0 ? map.armL : map.armR
        }
        let before = model.rigPose ?? rig.poser.restPose
        // Hips, wrists and ankles go by how far the finger has dragged from where it landed.
        var basis = before
        var screen = SIMD2<Float>.zero
        switch joint {
        case .hips, .wrist, .ankle, .headLook, .headTilt, .shoulder:
            basis = poseStartPose ?? before
            screen = SIMD2(Float(finger.x - poseStartFinger.x), Float(finger.y - poseStartFinger.y))
        default: break
        }
        // Phil, 2026-11-20: limbs hang from the character's own chest and pelvis, and its arms keep out of its torso.
        let poser = rig.poser
        let frames = PoseDrag.Frames(arm: { poser.armFrame($0, side: $1) }, leg: { poser.legFrame($0) })
        var body: BodyVolume?
        if let torso = poser.torso {
            let flip = map.facing < 0 ? simd_float4x4(diagonal: SIMD4(-1, 1, -1, 1)) : matrix_identity_float4x4
            var scale: Float = 1
            let slabs = torso.slabs.compactMap { slab -> BodySlab? in
                guard let bone = rig.joint(slab.bone), slab.bone < poser.nodes.count else { return nil }
                let m = flip * inverse * bone.simdWorldTransform * poser.nodes[slab.bone].world.inverse
                scale = simd_length(m.columns.0.xyz)
                return slab.moved(by: m)
            }
            body = BodyVolume(slabs: slabs, upperArm: torso.upperArm * scale, forearm: torso.forearm * scale)
        }
        let pose = PoseDrag.solve(joint, target: local(world), top: at(chain[0]), middle: at(chain[1]), end: at(chain[2]),
                                  hips: at(map.hips), from: basis, screen: screen, frames: frames, body: body)
        guard pose != before else { return }
        applyDragPose(pose, rig: rig, id: id)
    }

    private func applyDragPose(_ pose: MannequinPose, rig: FBXRig, id: UUID) {
        rig.apply(pose)
        if let index = models.firstIndex(where: { $0.id == id }) { models[index].rigPose = pose }
    }

    /// The finger is lifted: the selected dot keeps its wheels, measured again for the pose now.
    private func poseLetGo(id: UUID) {
        let wasPosing = poseHandle != nil || poseWheelGrab || poseTurning
        poseHandle = nil
        poseTurning = false
        poseWheelGrab = false
        poseWheels.letGo()
        if wasPosing, poseSelected != nil { buildPoseWheels(id: id) } else { showPoseWord() }
    }

    private func setRigPose(_ pose: MannequinPose?, id: UUID) {
        guard let rig = rigs[id], let index = models.firstIndex(where: { $0.id == id }) else { return }
        rig.apply(pose)
        models[index].rigPose = pose
        models[index].moved = Date()
        poseHistory += 1
        if poseSelected != nil { buildPoseWheels(id: id) }
    }

    func undoPose() {
        guard let id = selectedModel, var stack = poseUndo[id], let last = stack.popLast(),
              let model = models.first(where: { $0.id == id }) else { return }
        poseUndo[id] = stack
        poseRedo[id, default: []].append(model.rigPose)
        setRigPose(last, id: id)
        Haptics.tap()
    }

    func redoPose() {
        guard let id = selectedModel, var stack = poseRedo[id], let next = stack.popLast(),
              let model = models.first(where: { $0.id == id }) else { return }
        poseRedo[id] = stack
        poseUndo[id, default: []].append(model.rigPose)
        setRigPose(next, id: id)
        Haptics.tap()
    }

    /// Left and right swapped, like Magic Poser's flip.
    func mirrorPose() {
        guard let id = selectedModel, let rig = rigs[id], let model = models.first(where: { $0.id == id }) else { return }
        poseUndo[id, default: []].append(model.rigPose)
        poseRedo[id] = []
        setRigPose((model.rigPose ?? rig.poser.restPose).mirrored, id: id)
        Haptics.tap()
    }

    /// The character has finger bones, so hand presets work.
    var selectedHasFingers: Bool {
        guard let id = selectedModel, let rig = rigs[id] else { return false }
        return rig.poser.fingers.contains { $0.contains { !$0.isEmpty } }
    }

    /// Curls the fingers of one hand (nil: both) like a ready-made hand.
    func setFingers(_ side: Int?, _ preset: HandPreset) {
        guard let id = selectedModel, let rig = rigs[id], let model = models.first(where: { $0.id == id }) else { return }
        var pose = model.rigPose ?? rig.poser.restPose
        if side != 1 { pose.detail.leftFingers = preset.curls }
        if side != 0 { pose.detail.rightFingers = preset.curls }
        poseUndo[id, default: []].append(model.rigPose)
        poseRedo[id] = []
        setRigPose(pose, id: id)
        Haptics.tap()
    }

    /// The selected character's pose now (its rest pose if never posed).
    var currentCharacterPose: MannequinPose? {
        guard let id = selectedModel, let rig = rigs[id], let model = models.first(where: { $0.id == id }) else { return nil }
        return model.rigPose ?? rig.poser.restPose
    }

    /// Takes a saved or ready-made pose, as one undo step.
    func applyCharacterPose(_ pose: MannequinPose) {
        guard let id = selectedModel, let model = models.first(where: { $0.id == id }) else { return }
        poseUndo[id, default: []].append(model.rigPose)
        poseRedo[id] = []
        setRigPose(pose, id: id)
        Haptics.tap()
    }

    /// Phil, 2026-11-22: a person's pose, read from the camera or a photo, onto a character (one undo step) or a
    /// mannequin (rebuilt in the new pose). The fingers keep their curl: the reading has none.
    func applyCopiedPose(_ pose: MannequinPose, to id: UUID) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        if let rig = rigs[id] {
            let before = models[index].rigPose
            var copied = pose
            let now = before ?? rig.poser.restPose
            copied.detail.leftFingers = now.detail.leftFingers
            copied.detail.rightFingers = now.detail.rightFingers
            poseUndo[id, default: []].append(before)
            poseRedo[id] = []
            setRigPose(copied, id: id)
            Diagnostics.log("Pose copied onto \(models[index].name): \(copied.summary)")
        } else if var spec = models[index].mannequin {
            spec.pose = pose
            repose(id, as: spec)
        }
    }

    /// Starts copying from the live camera onto the selected character.
    func startPoseTaker() {
        // The other copier has the camera tracking a body for a new mannequin: one at a time.
        guard poseCopier == nil, let id = selectedModel, let model = models.first(where: { $0.id == id }) else { return }
        poseTaker?.finish()
        poseTaker = PoseTaker(placer: self, target: id, name: model.name)
    }

    /// Back to the pose the file has.
    func resetCharacterPose() {
        guard let id = selectedModel, let model = models.first(where: { $0.id == id }), model.rigPose != nil else { return }
        poseUndo[id, default: []].append(model.rigPose)
        poseRedo[id] = []
        setRigPose(nil, id: id)
        Haptics.tap()
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
        scene.rootNode.addChildNode(Mannequin.make(spec.body, pose: spec.pose, height: spec.height, proportion: spec.proportion))
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
        if let worn = models[index].mannequin?.head { try? FileManager.default.removeItem(at: folder.appendingPathComponent(worn, isDirectory: true)) }
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
        hold.minimumPressDuration = 0.35
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
                  modelNodes[touched] != nil
            else { return }
            if selectedModel != touched, !group.contains(touched) {
                if pickingGroup, selectedModel != nil { addToGroup(touched) } else { selectedModel = touched }
            }
            // Holding any model of the group lifts the whole group with the selected one leading.
            let lead = group.contains(touched) ? (selectedModel ?? touched) : touched
            guard let node = modelNodes[lead] else { return }
            cancelPin()
            pinned.remove(lead)
            holdLift = (lead, finger)
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
            // Phil, 2026-11-21: "make the lift a bit faster": a quarter more than the finger, and less easing behind it.
            holdTarget -= Float(finger.y - lift.last.y) * metresPerPoint * 1.25
            let before = node.simdWorldPosition
            node.simdWorldPosition.y += (holdTarget - node.simdWorldPosition.y) * 0.9
            moveGroup(by: node.simdWorldPosition - before)
            holdLift = (lift.id, finger)
            holdHint?.center = hintCenter(for: finger, in: view)
        case .ended, .cancelled, .failed:
            if let lift = holdLift, let node = modelNodes[lift.id] {
                let before = node.simdWorldPosition
                node.simdWorldPosition.y = holdTarget
                moveGroup(by: node.simdWorldPosition - before)
                commit(lift.id)
                commitGroup()
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
        // The tap on "In front" itself can reach the camera view too: picking starts with the next one.
        if pickingInFront, Date().timeIntervalSince(pickingSince) > 0.4, let view = gesture.view as? ARSCNView, let pick = onPickInFront {
            pickingInFront = false
            pick(gesture.location(in: view), view)
            return
        }
        guard selectionAllowed(), let view = gesture.view as? SCNView else { return }
        // Picking the group: a tap on another model adds it, a tap on one in the group takes it out, and a tap on
        // nothing does nothing (so a missed tap never loses the picks).
        if Date().timeIntervalSince(pickingGroupSince) < 0.4 { return }
        if pickingGroup, let main = selectedModel {
            let hits = view.hitTest(gesture.location(in: view), options: ReviewPick.options)
            if let id = hits.lazy.compactMap({ self.modelID(of: $0.node) }).first, id != main {
                if group.contains(id) {
                    group.remove(id)
                    Haptics.tap()
                } else {
                    addToGroup(id)
                }
                refreshGroupMarks()
            }
            return
        }
        if dimensionTap(at: gesture.location(in: view), in: view) { return }
        if poseTap(at: gesture.location(in: view), in: view) { return }
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
                // A drag on any model of the group moves the group; while picking, a drag on another adds it first.
                if touched != selectedModel, !group.contains(touched) {
                    if pickingGroup, selectedModel != nil { addToGroup(touched) } else { selectedModel = touched }
                }
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
                // About two millimetres per point for each metre away (1.6 until Phil asked for a bit faster, 2026-11-21).
                let rise = -Float(delta.y) * 0.002 * max(simd_distance(camera, node.simdWorldPosition), 0.3)
                node.simdWorldPosition.y += rise
                moveGroup(by: SIMD3(0, rise, 0))
            case .ended, .cancelled:
                commit(id)
                commitGroup()
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
                    // Phil, 2026-11-21: "move just a tiny bit faster": a fifth more than the finger sideways.
                    var sideways = (moved - reference) * (range / near) * 1.2
                    sideways.y = 0
                    if simd_length(sideways) < max(1, range) { target += sideways }
                }
            }
            var away = target - eye
            away.y = 0
            let distance = simd_length(away)
            if distance > 0.05 {
                let wanted = min(max(distance * exp(-Float(delta.y) * 0.0027), 0.3), 500)
                target += away / distance * (wanted - distance)
            }
            dragTarget = target
            let before = node.simdWorldPosition
            node.simdWorldPosition = simd_mix(node.simdWorldPosition, target, SIMD3(repeating: 0.85))
            moveGroup(by: node.simdWorldPosition - before)
        case .ended, .cancelled:
            if let target = dragTarget {
                let before = node.simdWorldPosition
                node.simdWorldPosition = target
                moveGroup(by: node.simdWorldPosition - before)
            }
            dragTarget = nil
            stopMeter("drag")
            pinned.remove(id)
            commit(id)
            commitGroup()
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
            turnOne(id, node: node, by: step)
            turnGroup(about: node.simdWorldPosition, by: step)
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
                if gesture.state == .ended || gesture.state == .cancelled { gizmoRing = nil; gizmoEnd = nil; refreshGizmo() }
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
            // About two millimetres per point for each metre away (1.6 until Phil asked for a bit faster, 2026-11-21).
            let rise = -Float(moved.y) * 0.002 * max(simd_distance(camera, node.simdWorldPosition), 0.3)
            node.simdWorldPosition.y += rise
            moveGroup(by: SIMD3(0, rise, 0))
        case .pose:
            guard let view = gesture.view as? SCNView else { return }
            let finger = gesture.location(in: view)
            if gesture.state == .began { posePick(at: finger, in: view, id: id) }
            poseDrag(to: finger, in: view, node: node, id: id)
            if gesture.state == .ended || gesture.state == .cancelled { poseLetGo(id: id) }
        case .light:
            lightDrag(moved, id: id, ended: gesture.state == .ended || gesture.state == .cancelled)
        case .move:
            break
        }
        if gesture.state == .ended || gesture.state == .cancelled {
            commit(id)
            if cutoutJob == .turn || cutoutJob == .lift { commitGroup() }
        }
    }

    // MARK: Moving several together

    /// Adds a model to the group (with a bump, so the finger feels it was taken).
    private func addToGroup(_ id: UUID) {
        guard id != selectedModel, modelNodes[id] != nil else { return }
        group.insert(id)
        pinned.remove(id)
        Haptics.bump()
        refreshGroupMarks()
    }

    /// Moves the other models of the group by the same step as the selected one.
    private func moveGroup(by step: SIMD3<Float>) {
        guard !group.isEmpty else { return }
        if simd_length(step) > 0 {
            for id in group { modelNodes[id]?.simdWorldPosition += step }
        }
        positionGroupMarks()
    }

    /// Turns one model about its own upright, the way the Turn job and the twist always have.
    private func turnOne(_ id: UUID, node: SCNNode, by step: Float) {
        node.simdEulerAngles.y += step
        if let package = cutoutPackages[id], let plane = cutouts[id]?.plane {
            let turn = (cutoutTurn[id] ?? 0) + step
            let wrapped = atan2(sin(turn), cos(turn))
            cutoutTurn[id] = wrapped
            plane.simdTransform = Self.poseMatrix(tilt: package.tilt, skew: package.skew, turn: wrapped)
        }
    }

    /// Swings the rest of the group round the selected one (like turning a tray they all stand on), each turning too.
    private func turnGroup(about centre: SIMD3<Float>, by step: Float) {
        guard !group.isEmpty, step != 0 else { return }
        let swing = simd_quatf(angle: step, axis: SIMD3(0, 1, 0))
        for id in group {
            guard let node = modelNodes[id] else { continue }
            node.simdWorldPosition = centre + swing.act(node.simdWorldPosition - centre)
            turnOne(id, node: node, by: step)
        }
        positionGroupMarks()
    }

    private func commitGroup() {
        for id in group {
            pinned.remove(id)
            commit(id)
        }
        positionGroupMarks()
    }

    /// The yellow rings: under the selected model and each one in the group, while picking or while there is a group.
    private func refreshGroupMarks() {
        var wanted = group
        if let main = selectedModel, pickingGroup || !group.isEmpty { wanted.insert(main) }
        for (id, mark) in groupMarks where !wanted.contains(id) {
            mark.removeFromParentNode()
            groupMarks[id] = nil
        }
        for id in wanted where groupMarks[id] == nil {
            let ring = SCNTube(innerRadius: 0.84, outerRadius: 1, height: 0.006)
            ring.radialSegmentCount = 48
            ring.materials = [Self.gizmoMaterial(UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1), alpha: 0.85)]
            let mark = SCNNode(geometry: ring)
            mark.name = "groupMark"
            mark.renderingOrder = 1900
            root.addChildNode(mark)
            groupMarks[id] = mark
        }
        positionGroupMarks()
    }

    /// Each ring lies at the foot of its model, a little wider than the model.
    private func positionGroupMarks() {
        for (id, mark) in groupMarks {
            guard let node = modelNodes[id], let box = boxes[id] else {
                mark.isHidden = true
                continue
            }
            let transform = node.simdWorldTransform
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for corner in 0..<8 {
                let local = SIMD3<Float>(corner & 1 == 0 ? box.low.x : box.high.x,
                                         corner & 2 == 0 ? box.low.y : box.high.y,
                                         corner & 4 == 0 ? box.low.z : box.high.z)
                let world = (transform * SIMD4(local, 1)).xyz
                low = simd_min(low, world)
                high = simd_max(high, world)
            }
            let radius = min(max(max(high.x - low.x, high.z - low.z) * 0.6, 0.08), 20)
            mark.isHidden = false
            mark.simdPosition = SIMD3((low.x + high.x) / 2, low.y + 0.004, (low.z + high.z) / 2)
            mark.simdScale = SIMD3(radius, 1, radius)
        }
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
            commitGroup()
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
        let before = node.simdWorldPosition
        node.simdWorldPosition = simd_mix(node.simdWorldPosition, target, SIMD3(repeating: 0.25))
        moveGroup(by: node.simdWorldPosition - before)
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
        turnOne(id, node: node, by: -Float(gesture.rotation))
        turnGroup(about: node.simdWorldPosition, by: -Float(gesture.rotation))
        gesture.rotation = 0
        if gesture.state == .ended {
            commit(id)
            commitGroup()
        }
    }

    /// Moves every model by `change`, for a camera that started again with new coordinates.
    func rebase(_ change: simd_float4x4) {
        for index in models.indices {
            guard let node = modelNodes[models[index].id] else { continue }
            node.simdTransform = change * node.simdTransform
            models[index].transform = flatten(node.simdTransform)
        }
        // The old places are in the old coordinates: undoing to them would throw the models away.
        forgetUndo()
    }

    private func commit(_ id: UUID) {
        guard let node = modelNodes[id], let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].transform = flatten(node.simdTransform)
        models[index].moved = Date()
        if id == selectedModel { updateTilted() }
        if groupMarks[id] != nil { positionGroupMarks() }
        record(id)
    }

    // MARK: Undo and redo (Phil, 2026-11-21: "an undo function for movement, scale etc like there is in pose")

    /// Where a model stands, how big and which way round, and for a cut-out its tip, slant and twist.
    private struct ModelState: Equatable {
        var transform: [Float]
        var tilt: Float?
        var skew: Float?
        var turn: Float?
    }
    /// One step back: the models it changed, as they were before it. A group move is one step.
    private typealias UndoStep = [UUID: ModelState]
    private var undoSteps: [UndoStep] = []
    private var redoSteps: [UndoStep] = []
    @Published private(set) var canUndoModel = false
    @Published private(set) var canRedoModel = false
    /// Each model as it was after its last finished change.
    private var settled: [UUID: ModelState] = [:]
    /// Changes finished in this pass of the main loop (a group's models are committed one after another), made one step.
    private var pendingStep: UndoStep?

    private func state(of id: UUID) -> ModelState? {
        guard let node = modelNodes[id] else { return nil }
        let package = cutoutPackages[id]
        return ModelState(transform: flatten(node.simdTransform), tilt: package?.tilt, skew: package?.skew,
                          turn: package == nil ? nil : (cutoutTurn[id] ?? 0))
    }

    /// Notes a finished change: what the model was before goes on the undo list.
    private func record(_ id: UUID) {
        guard let now = state(of: id) else { return }
        guard let before = settled[id] else {
            settled[id] = now
            return
        }
        guard before != now else { return }
        settled[id] = now
        if pendingStep == nil {
            pendingStep = [:]
            DispatchQueue.main.async { [weak self] in self?.finishStep() }
        }
        if pendingStep?[id] == nil { pendingStep?[id] = before }
    }

    private func finishStep() {
        guard let step = pendingStep else { return }
        pendingStep = nil
        guard !step.isEmpty else { return }
        undoSteps.append(step)
        if undoSteps.count > 60 { undoSteps.removeFirst() }
        redoSteps = []
        refreshUndo()
    }

    private func refreshUndo() {
        if canUndoModel != !undoSteps.isEmpty { canUndoModel = !undoSteps.isEmpty }
        if canRedoModel != !redoSteps.isEmpty { canRedoModel = !redoSteps.isEmpty }
    }

    func undoModel() {
        // Anything still under way is finished first (it lands on the list like any other change).
        cancelPin()
        stopCarrying()
        finishStep()
        guard let step = undoSteps.popLast() else { return }
        if let back = apply(step) { redoSteps.append(back) }
        Haptics.tap()
        refreshUndo()
    }

    func redoModel() {
        // Anything still under way is finished first (it lands on the list like any other change).
        cancelPin()
        stopCarrying()
        finishStep()
        guard let step = redoSteps.popLast() else { return }
        if let back = apply(step) { undoSteps.append(back) }
        Haptics.tap()
        refreshUndo()
    }

    /// Puts the models of a step back as it has them, and gives the step that would put them back again
    /// (nil when none of them is still here, for example after Delete).
    private func apply(_ step: UndoStep) -> UndoStep? {
        var back: UndoStep = [:]
        for (id, wanted) in step {
            guard let node = modelNodes[id], let index = models.firstIndex(where: { $0.id == id }), let now = state(of: id) else { continue }
            back[id] = now
            node.simdTransform = matrix4(wanted.transform)
            if var package = cutoutPackages[id], let plane = cutouts[id]?.plane, let tilt = wanted.tilt, let skew = wanted.skew {
                package.tilt = tilt
                package.skew = skew
                cutoutTurn[id] = wanted.turn ?? 0
                cutoutPackages[id] = package
                plane.simdTransform = Self.poseMatrix(tilt: tilt, skew: skew, turn: cutoutTurn[id] ?? 0)
                try? JSONEncoder().encode(package).write(to: folder.appendingPathComponent(models[index].file), options: .atomic)
            }
            models[index].transform = wanted.transform
            models[index].moved = Date()
            pinned.remove(id)
            settled[id] = wanted
            refreshDimensions(id)
        }
        updateSize()
        updateTilted()
        positionGroupMarks()
        refreshGizmo()
        refreshPoseDots()
        return back.isEmpty ? nil : back
    }

    private func forgetUndo() {
        undoSteps = []
        redoSteps = []
        pendingStep = nil
        settled = [:]
        for id in modelNodes.keys { settled[id] = state(of: id) }
        refreshUndo()
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

    // MARK: Levers (Phil, 2026-11-18: imaginary physical levers that move with the object's orientation)

    /// Three levers stick out of the middle of the selected 3D model while Rotate is picked, in the model's own
    /// directions (so they turn with it): red, green and blue, each with a knob at both ends. Push a knob and the
    /// model swings like a handle, the knob following your finger. The lever picked stretches into a long line that
    /// fades away, so you can see which way it points.
    private var gizmoNode: SCNNode?
    private var gizmoRing: Int?
    private var gizmoEnd: Float?
    private var gizmoKey = ""
    private static let ringAxes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
    private var gizmoCentre = SIMD3<Float>.zero
    private var gizmoRadius: Float = 0.3

    private func gizmoGeometry() -> (centre: SIMD3<Float>, radius: Float)? {
        guard let id = selectedModel, cutoutPackages[id] == nil, let node = modelNodes[id], let box = boxes[id] else { return nil }
        let middle = ((box.low + box.high) / 2)
        let centre = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        let size = (box.high - box.low) * node.simdScale
        // Short levers (Phil, 2026-11-18): about the model's own half-size, so a near knob doesn't swell over the screen.
        return (centre, max(max(size.x, size.y, size.z) * 0.5 * 0.7, 0.08))
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

    /// Shows, moves or takes away the levers. They are built again only when the picked lever changes; while one is
    /// being turned they just follow the model.
    func refreshGizmo() {
        guard cutoutJob == .tilt, let id = selectedModel, let node = modelNodes[id], let (centre, radius) = gizmoGeometry() else {
            gizmoNode?.removeFromParentNode()
            gizmoNode = nil
            gizmoKey = ""
            return
        }
        gizmoCentre = centre
        gizmoRadius = radius
        let key = "\(id.uuidString)-\(gizmoRing.map(String.init) ?? "none")"
        if gizmoNode == nil || key != gizmoKey {
            gizmoNode?.removeFromParentNode()
            gizmoKey = key
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
                let line = SCNCylinder(radius: 0.01, height: 2)
                line.radialSegmentCount = 8
                line.materials = [Self.gizmoMaterial(colours[index])]
                axis.addChildNode(SCNNode(geometry: line))
                for end: Float in [1, -1] {
                    let knob = SCNSphere(radius: end > 0 ? 0.075 : 0.05)
                    knob.segmentCount = 16
                    knob.materials = [Self.gizmoMaterial(colours[index])]
                    let ball = SCNNode(geometry: knob)
                    ball.position = SCNVector3(0, end, 0)
                    ball.renderingOrder = 2001
                    axis.addChildNode(ball)
                }
                // The picked lever stretches far out both ways, fading with distance.
                if gizmoRing == index {
                    let pieces = 10
                    let reach: Float = 3
                    for end: Float in [1, -1] {
                        for piece in 0..<pieces {
                            let fade = 1 - Float(piece) / Float(pieces)
                            let length = reach / Float(pieces)
                            let segment = SCNCylinder(radius: 0.009, height: CGFloat(length))
                            segment.radialSegmentCount = 6
                            segment.materials = [Self.gizmoMaterial(colours[index], alpha: CGFloat(0.75 * fade * fade))]
                            let part = SCNNode(geometry: segment)
                            part.position = SCNVector3(0, end * (1 + (Float(piece) + 0.5) * length), 0)
                            part.renderingOrder = 1999
                            axis.addChildNode(part)
                        }
                    }
                }
                axis.opacity = gizmoRing == nil || gizmoRing == index ? 1 : 0.25
                holder.addChildNode(axis)
            }
            // On the model itself, so the levers go wherever it goes: moved, carried, lifted or turned.
            node.addChildNode(holder)
            gizmoNode = holder
        }
        if let box = boxes[id] {
            gizmoNode?.simdPosition = (box.low + box.high) / 2
            gizmoNode?.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            // The model's own scale is part of its node, so the levers are shrunk to stay `radius` metres long.
            gizmoNode?.simdScale = SIMD3(repeating: radius / max(node.simdScale.x, 0.0001))
        }
    }

    /// Where a lever's knob is now, in the world.
    private func knobPoint(_ index: Int, end: Float, node: SCNNode) -> SIMD3<Float> {
        // The model may have moved since the levers were last shown, so the middle is read again.
        if let now = gizmoGeometry() {
            gizmoCentre = now.centre
            gizmoRadius = now.radius
        }
        return gizmoCentre + node.simdWorldOrientation.act(Self.ringAxes[index]) * (gizmoRadius * end)
    }

    /// Chooses the knob nearest the finger (within about a thumb's width) and remembers which end was grabbed.
    private func gizmoPick(at finger: CGPoint, in view: SCNView, node: SCNNode, id: UUID) {
        gizmoRing = nil
        gizmoEnd = nil
        guard gizmoNode != nil else { return }
        var best: (ring: Int, end: Float, distance: CGFloat)?
        for ring in 0..<3 {
            for end: Float in [1, -1] {
                let point = knobPoint(ring, end: end, node: node)
                let shown = view.projectPoint(SCNVector3(point.x, point.y, point.z))
                guard shown.z > 0, shown.z < 1 else { continue }
                let distance = hypot(CGFloat(shown.x) - finger.x, CGFloat(shown.y) - finger.y)
                if distance < (best?.distance ?? 50) { best = (ring, end, distance) }
            }
        }
        guard let best else { return }
        gizmoRing = best.ring
        gizmoEnd = best.end
        Haptics.firm()
        refreshGizmo()
    }

    /// The knob follows the finger on the screen, swinging the model about its middle like a handle.
    private func gizmoDrag(by moved: CGPoint, in view: SCNView, node: SCNNode, id: UUID) {
        guard let ring = gizmoRing, let end = gizmoEnd else { return }
        let knob = knobPoint(ring, end: end, node: node)
        let shown = view.projectPoint(SCNVector3(knob.x, knob.y, knob.z))
        guard shown.z > 0, shown.z < 1, let eye = self.eye?.columns.3.xyz else { return }
        // The finger's line of sight, and the point on it as far from the camera as the knob is: steadier than
        // unprojecting at the knob's own depth, which jumps when a knob comes close to the camera.
        let far = SIMD3<Float>(view.unprojectPoint(SCNVector3(shown.x + Float(moved.x), shown.y + Float(moved.y), 1)))
        guard simd_length(far - eye) > 0.001 else { return }
        let target = eye + simd_normalize(far - eye) * simd_distance(knob, eye)
        let from = knob - gizmoCentre
        let to = target - gizmoCentre
        guard simd_length(from) > 0.001, simd_length(to) > 0.001 else { return }
        let a = simd_normalize(from), b = simd_normalize(to)
        // Never straight back through the middle in one step.
        guard simd_dot(a, b) > -0.95 else { return }
        swingModel(node, id: id, by: simd_quatf(from: a, to: b))
    }

    /// Turns the model about its middle by a turn given in the world.
    private func swingModel(_ node: SCNNode, id: UUID, by turn: simd_quatf) {
        let box = boxes[id]
        let middle = ((box?.low ?? .zero) + (box?.high ?? .zero)) / 2
        let before = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        node.simdWorldOrientation = simd_normalize(turn * node.simdWorldOrientation)
        let after = (node.simdWorldTransform * SIMD4(middle, 1)).xyz
        node.simdWorldPosition += before - after
        updateTilted()
        refreshGizmo()
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
        let node = loadNodeNow(for: model)
        if node != nil { settled[model.id] = state(of: model.id) }
        return node
    }

    private func loadNodeNow(for model: PlacedModel) -> SCNNode? {
        if model.file.hasSuffix("." + Cutout.fileExtension) { return loadCutoutNode(for: model) }
        if model.file.hasSuffix(".fbx") { return loadFBXNode(for: model) }
        let url = folder.appendingPathComponent(model.file)
        let node = SCNNode()
        node.name = model.id.uuidString
        if let spec = model.mannequin, let worn = spec.head, let head = Self.scannedHead(folder.appendingPathComponent(worn, isDirectory: true), on: spec) {
            // Phil, 2026-11-22: a mannequin wearing a scanned head is made here, with the head, rather than read from
            // its file (which has the plain head): the head's photographs show unlit, like the scan.
            node.addChildNode(Mannequin.make(spec.body, pose: spec.pose, height: spec.height, proportion: spec.proportion, head: head))
        } else {
            guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
            for child in scene.rootNode.childNodes {
                node.addChildNode(child)
            }
        }
        // A scan's colours are photographs, with the light of the day already in them: shown as they are, not lit a
        // second time (Phil's first scan, 2026-11-17: a white bin came out grey beside the real one).
        if model.scan == true || model.name.hasPrefix("Scan ") {
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
        Self.applyLight(model.light, to: node)
        if model.softEdge != nil { applySoftEdge(model.id) }
        return node
    }

    /// A scanned head kept in a folder (HeadScan.swift), as a node. Nil when the folder or its head is missing (a
    /// reference synced from a phone that had the head, say): the mannequin then wears its plain head.
    /// Phil, 2026-11-22: "it's too small, needs adjustment". Sized and placed as set on the Put on a body screen
    /// (HeadFit beside the head), or else sized to the mannequin's own head.
    static func scannedHead(_ place: URL, on spec: MannequinSpec) -> SCNNode? {
        guard let data = try? Data(contentsOf: place.appendingPathComponent(ScanRig.headFile)), let mesh = ScanRig.head(from: data) else { return nil }
        let fit = HeadFit.load(place) ?? Mannequin.headFit(mesh, info: HeadInfo.load(place), body: spec.body, height: spec.height, proportion: spec.proportion)
        return HeadFit.wrap(mesh, pictures: place, fit: fit)
    }

    /// Phil, 2026-11-22: "have that as an option to place on any character". A mannequin standing where the camera
    /// points (or at `base`), wearing a scanned head. The head's files are copied in beside the mannequin, so the
    /// reference keeps it. Returns false, with `modelError` set, if it could not.
    @discardableResult
    func addMannequin(_ body: MannequinBody, head: HeadFolder, fit: HeadFit? = nil, base: simd_float4x4?) -> Bool {
        let height = Mannequin.defaultHeight(body)
        let pose = MannequinPose.standing
        guard let url = Examples.file(for: Mannequin.make(body, pose: pose, height: height), name: "\(body.rawValue) with \(head.title)'s head") else {
            modelError = "Could not make the mannequin."
            return false
        }
        let before = models.count
        addFacingCamera(from: [url], base: base)
        guard models.count > before, let index = models.indices.last else { return false }
        let id = models[index].id
        let worn = "models/\(id.uuidString).head"
        let target = folder.appendingPathComponent(worn, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for file in head.headFiles { try FileManager.default.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent)) }
            try fit?.save(to: target)
        } catch {
            Diagnostics.log("Head scan: could not copy \(head.title) beside the mannequin: \(error)")
            modelError = "Could not put the head on."
            return false
        }
        var spec = MannequinSpec(body: body, height: height, pose: pose)
        spec.head = worn
        models[index].mannequin = spec
        let transform = modelNodes[id]?.simdTransform
        modelNodes[id]?.removeFromParentNode()
        modelNodes[id] = nil
        loadNode(for: models[index])
        if let transform { modelNodes[id]?.simdTransform = transform }
        selectedModel = id
        Diagnostics.log("Head scan: \(head.title) worn by a \(body.rawValue.lowercased()) mannequin")
        return true
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
        Self.applyLight(model.light, to: node)
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
        Self.applyLight(model.light, to: node)
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
/// What shows over the picture while models are out: the find button, and for a picked model the finger picture
/// and the pose bar in the middle of the bottom. The model's tools themselves stand round the edges (ModelEdgeTools).
struct ModelOverlay: View {
    @ObservedObject var placer: ModelPlacer
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var showsCutoutHelp = true

    var body: some View {
        VStack(spacing: 6) {
            if let copier = placer.poseCopier {
                PoseCopyBar(copier: copier)
            }
            if let taker = placer.poseTaker {
                PoseTakeLayer(taker: taker)
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
                // Phil, 2026-11-10: the help is a small picture of the finger's move, not a sentence, and it goes after a few seconds.
                let cutout = placer.selectedIsCutout
                VStack(spacing: 4) {
                    if showsCutoutHelp || placer.carrying || placer.pinStep != nil || placer.pickingInFront || placer.pickingGroup || placer.heldPoseWord != nil {
                        MoveHint(job: placer.cutoutJob, carrying: placer.carrying, size: cutout ? nil : placer.sizeText, pin: placer.pinStep, cutout: cutout,
                                 picking: placer.pickingInFront, grouping: placer.pickingGroup, held: placer.heldPoseWord)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .bottom)
                // Above the pose buttons, which hold the middle of the bottom edge while posing.
                .padding(.bottom, placer.cutoutJob == .pose && placer.selectedHasRig && verticalSize == .compact ? 44 : 0)
                .task(id: "\(placer.selectedModel?.uuidString ?? "")-\(placer.cutoutJob.rawValue)") {
                    withAnimation { showsCutoutHelp = true }
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { showsCutoutHelp = false }
                }
            }
        }
        .alert("3D model", isPresented: Binding(get: { placer.modelError != nil }, set: { if !$0 { placer.modelError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(placer.modelError ?? "")
        }
    }

}

/// The picked model's tools, round the edges of the picture so the middle stays clear (Phil, 2026-11-20: "fill more
/// of the edge of the screen and not obscure as much of the centre as possible ... open to the UI being a ring").
/// The jobs run down the left edge and the actions down the right; when a side is too short for its tools, the rest
/// turn the corner and carry on along the bottom toward the middle, which stays free for the finger picture.
/// Lay it over the whole picture (same insets as the other overlays): it fills the space and lets taps through
/// everywhere but on its buttons.
struct ModelEdgeTools: View {
    @ObservedObject var placer: ModelPlacer
    /// While the ruler is on, its buttons hold the bottom edge (upright) or the left edge (on its side): the tools
    /// stand clear of them (Phil, 2026-11-21: "these icons clash").
    @ObservedObject var measurer: Measurer
    /// Off in Review, where there is no live LiDAR to find the floor with.
    var showsFloor = true
    /// Opens the add menu, where the screen's own add button gives way to these tools.
    var onAdd: (() -> Void)? = nil
    /// Room left free at the top of the sides, upright, for the instruction line and the Storyboard bar.
    var uprightTop: CGFloat = 90
    /// The same on its side, where the top row is shorter.
    var sidewaysTop: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var posing = false
    @State private var showsPoses = false
    @State private var savingPose = false
    @State private var showsHands = false
    @State private var poseName = ""
    @State private var copyingPose = false

    private static func symbol(_ job: ModelPlacer.CutoutJob) -> String {
        switch job {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .turn: return "arrow.triangle.2.circlepath"
        case .size: return "arrow.up.left.and.arrow.down.right"
        case .tilt: return "rotate.3d"
        case .lift: return "arrow.up.and.down"
        case .pose: return "figure.arms.open"
        case .light: return "sun.max"
        }
    }

    var body: some View {
        if placer.selectedModelName != nil {
            let cutout = placer.selectedIsCutout
            let top = verticalSize == .compact ? sidewaysTop : uprightTop
            let posingRig = placer.cutoutJob == .pose && placer.selectedHasRig
            // The middle of the bottom edge stays free for the finger picture (about 240 points), and on its side for the
            // pose buttons in one row (about 380); tools that would run into it go along the top instead.
            let middle: CGFloat = posingRig && verticalSize == .compact ? 196 : 124
            HStack(spacing: 0) {
                EdgeColumn(leading: true, top: top, middle: middle) { jobTools(cutout: cutout) }
                EdgeColumn(leading: false, top: top, middle: middle) { actionTools(cutout: cutout) }
            }
            .padding(.bottom, measurer.active && verticalSize != .compact ? 78 : 0)
            .padding(.leading, measurer.active && verticalSize == .compact ? 66 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Phil, 2026-11-20 (the ring): the "hold, then drag" bubble and the size hints stand at the top edge, not
            // over the middle of the picture.
            .overlay(alignment: .top) {
                VStack(spacing: 4) {
                    // Phil, 2026-11-21 (drawing on 1398, upright): the pose buttons spread out along the top edge, corner
                    // to corner, as the top of the ring.
                    if posingRig, verticalSize != .compact { poseRow }
                    ObjectNudge(placer: placer).padding(.top, verticalSize == .compact ? 0 : 36)
                    if placer.cutoutJob == .light { ModelLightBar(placer: placer) }
                }
            }
            // Phil, 2026-11-21: "an undo function for movement, scale etc like there is in pose". Upright, in the top
            // corners where Pose keeps its Undo and Redo; on its side, in the middle of the bottom edge.
            .overlay(alignment: verticalSize == .compact ? .bottom : .top) {
                if !posingRig, placer.canUndoModel || placer.canRedoModel {
                    HStack(spacing: 0) {
                        CutoutTool(word: "Undo", symbol: "arrow.uturn.backward", tint: placer.canUndoModel ? .white : .gray, width: 46) { placer.undoModel() }
                        if verticalSize != .compact { Spacer(minLength: 0) }
                        CutoutTool(word: "Redo", symbol: "arrow.uturn.forward", tint: placer.canRedoModel ? .white : .gray, width: 46) { placer.redoModel() }
                    }
                    .frame(maxWidth: verticalSize == .compact ? nil : .infinity)
                }
            }
            // Phil, 2026-11-21 (drawing on 1397, on its side): one row along the bottom edge, between Pose and Delete.
            .overlay(alignment: .bottom) {
                if posingRig, verticalSize == .compact { poseBar }
            }
            .sheet(isPresented: $showsHands) { HandsSheet { placer.setFingers($0, $1) } }
            .sheet(isPresented: $showsPoses) { PoseLibrarySheet { placer.applyCharacterPose($0) } }
            .alert("Save pose", isPresented: $savingPose) {
                TextField("Name", text: $poseName)
                Button("Save") {
                    if let pose = placer.currentCharacterPose { PoseLibrary.shared.save(pose, name: poseName) }
                    poseName = ""
                }
                Button("Cancel", role: .cancel) { poseName = "" }
            } message: {
                Text("Keep this pose to use again on any character.")
            }
            .modifier(CopyPoseChooser(placer: placer, isPresented: $copyingPose, live: showsFloor))
            .fullScreenCover(isPresented: $posing) {
                if let id = placer.selectedModel, let spec = placer.selectedPoseSpec {
                    MannequinPoseEditor(spec: spec) { placer.repose(id, as: $0) }
                }
            }
        }
    }

    /// Phil, 2026-11-19 (Magic Poser): undo, redo, flip left and right, and back to the file's pose.
    @ViewBuilder private var poseBar: some View {
        if verticalSize == .compact {
            HStack(spacing: 0) { undoTools; keepTools }.fixedSize()
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) { undoTools }.fixedSize()
                HStack(spacing: 0) { keepTools }.fixedSize()
            }
        }
    }

    /// The pose buttons spread across the whole top edge, the first and last in the corners.
    private var poseRow: some View {
        HStack(spacing: 0) {
            CutoutTool(word: "Undo", symbol: "arrow.uturn.backward", tint: placer.canUndoPose ? .white : .gray, width: 46) { placer.undoPose() }
            Spacer(minLength: 0)
            CutoutTool(word: "Redo", symbol: "arrow.uturn.forward", tint: placer.canRedoPose ? .white : .gray, width: 46) { placer.redoPose() }
            Spacer(minLength: 0)
            CutoutTool(word: "Mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", width: 46) { placer.mirrorPose() }
            Spacer(minLength: 0)
            CutoutTool(word: "Reset", symbol: "arrow.counterclockwise", width: 46) { placer.resetCharacterPose() }
            Spacer(minLength: 0)
            CutoutTool(word: "Save", symbol: "square.and.arrow.down", width: 46) { savingPose = true }
            Spacer(minLength: 0)
            CutoutTool(word: "Poses", symbol: "list.bullet", width: 46) { showsPoses = true }
            if placer.selectedHasFingers {
                Spacer(minLength: 0)
                CutoutTool(word: "Hands", symbol: "hand.raised", width: 46) { showsHands = true }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var undoTools: some View {
        CutoutTool(word: "Undo", symbol: "arrow.uturn.backward", tint: placer.canUndoPose ? .white : .gray, width: 52) { placer.undoPose() }
        CutoutTool(word: "Redo", symbol: "arrow.uturn.forward", tint: placer.canRedoPose ? .white : .gray, width: 52) { placer.redoPose() }
        CutoutTool(word: "Mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", width: 52) { placer.mirrorPose() }
    }

    @ViewBuilder private var keepTools: some View {
        CutoutTool(word: "Reset", symbol: "arrow.counterclockwise", width: 52) { placer.resetCharacterPose() }
        CutoutTool(word: "Save", symbol: "square.and.arrow.down", width: 52) { savingPose = true }
        CutoutTool(word: "Poses", symbol: "list.bullet", width: 52) { showsPoses = true }
        if placer.selectedHasFingers { CutoutTool(word: "Hands", symbol: "hand.raised", width: 52) { showsHands = true } }
    }

    /// Down the left edge: what one finger does to the model (pick one), then Carry, Floor and Pose.
    @ViewBuilder private func jobTools(cutout: Bool) -> some View {
        // Phil, 2026-11-11: Lift for cut-outs too. 2026-11-17: Tilt for every model ("rotate any object"): tip and lean.
        ForEach(ModelPlacer.CutoutJob.allCases.filter { $0 != .pose && $0 != .light }, id: \.self) { job in
            CutoutTool(word: job == .tilt && !cutout ? "Rotate" : job.rawValue, symbol: Self.symbol(job), on: placer.cutoutJob == job) { placer.cutoutJob = job }
        }
        // Carry walks it along with the live camera, so not over a saved frame (Review).
        if showsFloor {
            CutoutTool(word: placer.carrying ? "Carrying" : "Carry", symbol: "figure.walk", on: placer.carrying) {}
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in placer.startCarrying() }
                    .onEnded { _ in placer.stopCarrying() })
        }
        if showsFloor, !cutout { CutoutTool(word: "Floor", symbol: "arrow.down.to.line") { placer.dropToFloor() } }
        if placer.selectedHasRig {
            // Phil, 2026-11-18: pose it right in the live view, by its joints.
            CutoutTool(word: "Pose", symbol: "figure.arms.open", on: placer.cutoutJob == .pose) { placer.cutoutJob = .pose }
        } else if placer.selectedPoseSpec != nil {
            CutoutTool(word: "Pose", symbol: "figure.arms.open", tint: Theme.accent) { posing = true }
        }
        // Phil, 2026-11-22: take the pose of a person in the camera or in a photo.
        if placer.selectedHasRig || placer.selectedMannequin != nil {
            CutoutTool(word: "Copy pose", symbol: "figure.stand.line.dotted.figure.stand", on: placer.poseTaker != nil) { copyingPose = true }
        }
        // Phil, 2026-11-21: each model's own light (ModelLighting.swift).
        CutoutTool(word: "Light", symbol: "sun.max", on: placer.cutoutJob == .light) { placer.cutoutJob = .light }
    }

    /// Down the right edge: add another, bring it here, pin it, stand it, size it, show sizes, finish, delete.
    /// Delete comes last, so it is the one furthest from the others when the column turns the corner.
    @ViewBuilder private func actionTools(cutout: Bool) -> some View {
        if let onAdd {
            CutoutTool(word: "Add", symbol: "plus", tint: Theme.accent, action: onAdd)
        }
        // Phil, 2026-11-21: pick several and move them together. The word says how many are picked.
        if placer.models.count > 1 {
            CutoutTool(word: placer.group.isEmpty ? "Select more" : "\(placer.group.count + 1) selected", symbol: "square.on.square",
                       on: placer.pickingGroup) { placer.pickingGroup.toggle() }
        }
        CutoutTool(word: "Place here", symbol: "scope") { placer.bringToView() }
        // Sets its true distance from two views, so it stays put as the camera moves. Live camera only.
        if showsFloor {
            let isPinned = placer.selectedModel.map { placer.pinned.contains($0) } ?? false
            CutoutTool(word: isPinned ? "Pinned" : "Pin", symbol: "pin", tint: isPinned ? .white : Theme.accent, on: placer.pinStep != nil) { placer.startPin() }
            if placer.onPickInFront != nil {
                CutoutTool(word: placer.inFrontCount > 0 ? "In front \(placer.inFrontCount)" : "In front", symbol: "square.3.layers.3d.top.filled",
                           on: placer.pickingInFront) { placer.pickingInFront.toggle() }
                if let id = placer.selectedModel, placer.layerCount > 0 {
                    let layer = placer.layer(of: id)
                    if layer > 0 { CutoutTool(word: "Bring forward", symbol: "square.2.layers.3d.top.filled") { placer.moveSelectedLayer(by: -1) } }
                    if layer < placer.layerCount { CutoutTool(word: "Push back", symbol: "square.2.layers.3d.bottom.filled") { placer.moveSelectedLayer(by: 1) } }
                    if placer.selectedLayerChanged { CutoutTool(word: "Real order", symbol: "ruler.fill", tint: Theme.accent) { placer.resetSelectedLayer() } }
                }
            }
        }
        if cutout {
            CutoutTool(word: "Straighten", symbol: "arrow.uturn.backward") { placer.resetPose() }
        } else {
            CutoutTool(word: "True size", symbol: "1.square") { placer.resetSelectedModelSize() }
            if placer.selectedTilted { CutoutTool(word: "Upright", symbol: "arrow.up.to.line", tint: Theme.accent) { placer.makeUpright() } }
        }
        // Phil, 2026-11-26: a cropped scan fades out toward its cut edges. Hard edge, Soft edge, Softer edge.
        if placer.selectedCanSoften {
            CutoutTool(word: placer.softEdgeWord, symbol: "square.dashed", on: placer.selectedSoftEdge > 0) { placer.cycleSoftEdge() }
        }
        CutoutTool(word: placer.showDimensions ? "Sizes " + ModelDimensions.textStepNames[min(max(placer.dimensionStep, 0), 3)] : "Sizes", symbol: "ruler") { placer.cycleDimensions() }
        CutoutTool(word: "Done", symbol: "checkmark") { placer.selectedModel = nil }
        CutoutTool(word: "Delete", symbol: "trash", tint: .red) { placer.deleteSelectedModel() }
    }
}

/// Tools down one side of the picture, spread out along it from the bottom corner up, a little apart so they are
/// easy to hit. Those that do not fit on the side turn the corner and carry on along the bottom toward the middle,
/// stopping `middle` points short of it. Each tool keeps its own width, so no word is ever cut short.
struct EdgeColumn: Layout {
    /// The left side (otherwise the right).
    var leading: Bool
    /// Room left free at the top of the side.
    var top: CGFloat = 0
    /// Room left free along the bottom at the inner edge (the middle of the screen).
    var middle: CGFloat = 0
    /// The most room between two tools.
    var maxGap: CGFloat = 18

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 200, height: 400))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let points = EdgeLayoutMath.places(sizes: sizes, width: bounds.width, height: bounds.height, leading: leading, top: top, middle: middle, maxGap: maxGap)
        for (index, subview) in subviews.enumerated() where index < points.count {
            let point = points[index]
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .center, proposal: ProposedViewSize(sizes[index]))
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
    var picking = false
    /// Picking models to move together.
    var grouping = false
    /// The posing dot held now, in a few words.
    var held: String? = nil

    private var parts: (arrow: String, words: String) {
        if let held { return ("hand.draw", held) }
        if picking { return ("square.3.layers.3d.top.filled", "tap the real thing that goes in front · tap it again to take it out") }
        if grouping { return ("square.on.square", "tap others to move them together · tap again to leave out") }
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
        case .tilt: return ("rotate.3d", cutout ? "↕ tip  ↔ slant" : "push a lever's knob to swing it · or drag anywhere · twist: roll")
        case .lift: return ("arrow.up.and.down", "↑ higher")
        case .pose: return ("hand.draw", "drag a dot · tap one for its turning arrows · white arrows: turn round")
        case .light: return ("arrow.up.and.down.and.arrow.left.and.right", "drag: change what is picked at the top · Direction: ↔ round, ↕ height")
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: picking ? "hand.tap.fill" : pin == .stepAside ? "figure.walk" : pin == .done ? "pin.fill" : carrying ? "iphone.gen3" : "hand.point.up.left.fill")
                Image(systemName: parts.arrow).font(.system(size: 16, weight: .bold))
            }
            .font(.system(size: 22, weight: .semibold))
            // Phil, 2026-11-20: the middle stays clear, so the help wraps into a narrow block rather than one wide line.
            Text(parts.words).font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
                .fixedSize(horizontal: false, vertical: true)
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
    /// Narrower in the pose row along the bottom, so its seven fit between the corners.
    var width: CGFloat = 58
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
            .frame(minWidth: width, minHeight: 42)
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
