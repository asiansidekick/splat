import ARKit
import CoreImage
import Foundation
import SceneKit
import UIKit

/// Restores a set to a saved reference. ARKit finds the room again from the saved map (offline),
/// then the closest reference photo is shown as a see-through ghost over the live camera, with
/// directions to stand where it was taken. With LiDAR, anything nearer or further than in the
/// reference is highlighted.
@MainActor
final class Restorer: NSObject, ObservableObject, ARSessionDelegate {
    enum Status: Equatable {
        case loading, relocalizing, ready, failed(String)
    }

    @Published var status: Status = .loading
    @Published var ghost: UIImage?
    @Published var differences: UIImage?
    @Published var guidance = ""
    @Published var matched = false
    @Published var lockedKeyframe: Keyframe?
    @Published var showDifferences = true
    /// The 3D ghost, built from the reference's LiDAR depth and photos, instead of the photo ghost.
    @Published var show3D = false {
        didSet { cloudNode.isHidden = !show3D }
    }
    @Published var cloudReady = false
    /// Added to the AR scene; sits in the reference's room coordinates once relocalised.
    let cloudNode = SCNNode()
    /// Placed USDZ models, shown once the room is recognised so they appear in the right place.
    let modelsNode = SCNNode()
    /// Everything this screen draws in 3D.
    let sceneContent = SCNNode()
    @Published var models: [PlacedModel] = []
    @Published var selectedModel: UUID?
    @Published var modelError: String?
    var modelNodes: [UUID: SCNNode] = [:]

    let session = ARSession()
    let reference: Reference
    var viewport: CGSize = .zero
    /// How the screen is turned, so the ghost, highlights and directions follow it.
    var orientation: UIInterfaceOrientation = .portrait

    private var current: Keyframe?
    private var ghostSource: CIImage?
    private var renderedFor: (id: String, viewport: CGSize, orientation: UIInterfaceOrientation)?
    private var lastUpdate = Date.distantPast
    private var diffBusy = false
    private let ciContext = CIContext()
    private let diffQueue = DispatchQueue(label: "depth-diff")
    private let writeQueue = DispatchQueue(label: "snapshot-writer")
    private let ghostQueue = DispatchQueue(label: "ghost-render")
    private var ghostBusy = false
    private var lastDiff = Date.distantPast
    /// When the app started looking for the room, for hints if it takes a while.
    @Published var relocalizingSince: Date?
    @Published var startPhoto: UIImage?
    /// Set after 20 seconds without finding the room, to show tips.
    @Published var slowToFind = false
    private var depthCache: [String: [Float]] = [:]

    var usesDepth: Bool { reference.hasDepth && Recorder.lidarAvailable }

    init(reference: Reference) {
        self.reference = reference
        super.init()
        cloudNode.isHidden = true
        cloudNode.opacity = 0.5
        modelsNode.isHidden = true
        sceneContent.addChildNode(cloudNode)
        sceneContent.addChildNode(modelsNode)
        models = reference.models
    }

    /// Whether the reference has LiDAR depth, which the 3D ghost is built from. Viewing it works on
    /// any ARKit device.
    var can3D: Bool { reference.hasDepth }

    func setGhostOpacity(_ value: Double) {
        cloudNode.opacity = CGFloat(value)
    }

    private func buildCloud() {
        guard can3D, !cloudReady else { return }
        let saved = reference
        Task {
            let cloud = await Task.detached(priority: .utility) { Ghost3D.build(reference: saved) }.value
            cloudNode.addChildNode(Ghost3D.node(for: cloud))
            cloudReady = !cloud.positions.isEmpty
        }
    }

    func start() {
        do {
            let map = try ReferenceStore.loadWorldMap(for: reference.id)
            let config = ARWorldTrackingConfiguration()
            config.initialWorldMap = map
            if usesDepth {
                config.frameSemantics.insert(.sceneDepth)
                // Temporally smoothed depth is steadier for spotting changes (Apple's advice).
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                    config.frameSemantics.insert(.smoothedSceneDepth)
                }
            }
            session.delegate = self
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            status = .relocalizing
            relocalizingSince = Date()
            buildCloud()
            loadSavedModels()
            loadStartPhoto()
            Diagnostics.log("Reset start: \(reference.title), \(reference.keyframes.count) keyframes, depth \(usesDepth)")
        } catch {
            status = .failed("Could not open this reference: \(error.localizedDescription)")
            Diagnostics.log("Reset open failed: \(error)")
        }
    }

    func stop() {
        session.pause()
    }

    /// Saves what the camera sees now (and LiDAR depth) into the reference, in the reference's own
    /// room coordinates, so it can be compared with the reference or other snapshots later.
    func takeSnapshot(label: String) -> Snapshot? {
        guard status == .ready, let frame = session.currentFrame else { return nil }
        let shot = FrameSnapshot(frame)
        let stem = "snap_" + UUID().uuidString.prefix(8)
        let keyframe = shot.keyframe(imageFile: stem + ".jpg", depthFile: stem + ".bin", transform: frame.camera.transform)
        let folder = ReferenceStore.folder(for: reference.id)
        let context = ciContext
        writeQueue.async { shot.write(keyframe, to: folder, context: context) }
        return Snapshot(label: label, taken: Date(), frame: keyframe)
    }

    /// Keep showing one reference view instead of following the camera to the closest one.
    func toggleLock() {
        lockedKeyframe = lockedKeyframe == nil ? current : nil
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // The session delivers frames on the main queue (no delegateQueue is set).
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { self.handle(frame) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = ARErrors.message(for: error)
        Diagnostics.log("Reset session failed: \(error)")
        Task { @MainActor in self.status = .failed(message) }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Diagnostics.log("Reset interrupted")
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Diagnostics.log("Reset interruption ended")
    }

    /// Find the saved room again after an interruption instead of starting a new one.
    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    /// The first reference photo, shown while the room is being found: start from there.
    private func loadStartPhoto() {
        guard let first = reference.keyframes.first else { return }
        let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(first.imageFile)
        guard let cg = UIImage(contentsOfFile: url.path)?.cgImage else { return }
        startPhoto = UIImage(cgImage: cg, scale: 1, orientation: first.uprightOrientation)
    }

    private func handle(_ frame: ARFrame) {
        // ARKit reports normal tracking once it has recognised the saved room.
        if case .failed = status { return }
        guard case .normal = frame.camera.trackingState else {
            if status == .ready {
                status = .relocalizing
                relocalizingSince = Date()
                Diagnostics.log("Reset lost tracking: \(frame.camera.trackingState)")
            }
            modelsNode.isHidden = true
            if !slowToFind, let since = relocalizingSince, Date().timeIntervalSince(since) > 20 {
                slowToFind = true
                Diagnostics.log("Reset still looking for the room after 20 s: \(frame.camera.trackingState)")
            }
            return
        }
        if status != .ready {
            status = .ready
            let seconds = relocalizingSince.map { Date().timeIntervalSince($0) } ?? 0
            Diagnostics.log("Reset found the room after \(Int(seconds)) s")
            relocalizingSince = nil
            slowToFind = false
        }
        modelsNode.isHidden = false
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 0.1, viewport != .zero else { return }
        lastUpdate = now

        let camera = frame.camera.transform
        let keyframe = lockedKeyframe ?? Guidance.closest(to: camera, in: reference.keyframes)
        guard let keyframe else { return }
        current = keyframe
        updateGuidance(camera: camera, target: keyframe)
        updateGhost(keyframe, frame: frame)
        // Less often when the phone is hot, so it does not throttle or shut the camera down.
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if usesDepth && showDifferences && (!hot || now.timeIntervalSince(lastDiff) > 0.5) {
            lastDiff = now
            updateDifferences(frame: frame, around: camera)
        } else if differences != nil {
            differences = nil
        }
    }

    private func updateGuidance(camera: simd_float4x4, target: Keyframe) {
        let move = Guidance.offset(from: camera, to: target, orientation: orientation)
        matched = move.isMatched
        guidance = move.description
    }

    // MARK: Ghost photo

    private func updateGhost(_ keyframe: Keyframe, frame: ARFrame) {
        if let done = renderedFor, done.id == keyframe.id, done.viewport == viewport, done.orientation == orientation { return }
        guard !ghostBusy else { return }
        // Loading and drawing the photo happens off the main thread so camera frames keep flowing.
        let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(keyframe.imageFile)
        let placement = Placement(display: frame.displayTransform(for: orientation, viewportSize: viewport), viewport: viewport)
        let key = (keyframe.id, viewport, orientation)
        let context = ciContext
        ghostBusy = true
        ghostQueue.async {
            let image = CIImage(contentsOf: url).flatMap { Restorer.render($0, placement: placement, context: context) }
            Task { @MainActor in
                self.ghostBusy = false
                guard let image else { return }
                self.ghost = image
                self.renderedFor = key
            }
        }
    }

    /// Where the camera image sits on screen, captured on the main thread for background drawing.
    struct Placement: @unchecked Sendable {
        let display: CGAffineTransform
        let viewport: CGSize
    }

    /// Lays an image in the camera's sensor orientation over the screen exactly like the live
    /// camera feed is laid out.
    private func render(_ image: CIImage, frame: ARFrame) -> UIImage? {
        let placement = Placement(display: frame.displayTransform(for: orientation, viewportSize: viewport), viewport: viewport)
        return Restorer.render(image, placement: placement, context: ciContext)
    }

    nonisolated static func render(_ image: CIImage, placement: Placement, context: CIContext) -> UIImage? {
        let size = image.extent.size
        let viewport = placement.viewport
        guard size.width > 0, size.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let toUnit = CGAffineTransform(scaleX: 1 / size.width, y: 1 / size.height)
        // Core Image puts the origin bottom left; ARKit's display transform expects top left.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        let toView = CGAffineTransform(scaleX: viewport.width, y: viewport.height)
        let placed = image
            .transformed(by: toUnit.concatenating(flip).concatenating(placement.display).concatenating(flip).concatenating(toView))
            .cropped(to: CGRect(origin: .zero, size: viewport))
        guard let cg = context.createCGImage(placed, from: CGRect(origin: .zero, size: viewport)) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: LiDAR differences

    private func updateDifferences(frame: ARFrame, around camera: simd_float4x4) {
        guard !diffBusy, let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let depthMap = depthData.depthMap
        let liveDepth = DepthMap.floats(DepthMap.copy(depthMap))
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        // Use the reference views that saw what the camera is pointing at, from the most similar
        // direction, so the check works from off camera and from other distances too.
        let withDepth = reference.keyframes.filter { $0.depthFile != nil }
        let nearby: [Keyframe]
        if let target = Guidance.target(camera: camera, depth: liveDepth, width: width, height: height) {
            let seeing = Guidance.views(seeing: target, from: camera.columns.3.xyz, in: withDepth, count: 3)
            nearby = seeing.isEmpty ? Guidance.closest(to: camera, in: withDepth, count: 3) : seeing
        } else {
            nearby = Guidance.closest(to: camera, in: withDepth, count: 3)
        }
        let references = nearby.compactMap { keyframe -> (Keyframe, [Float])? in
            guard let depth = depth(for: keyframe) else { return nil }
            return (keyframe, depth)
        }
        guard !references.isEmpty else { return }
        let live = DepthView(
            depth: liveDepth,
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap),
            cameraToWorld: camera,
            intrinsics: frame.camera.intrinsics,
            imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
            confidence: depthData.confidenceMap.map(DepthMap.bytes))
        let refs = references.map { keyframe, depth in
            DepthView(
                depth: depth, width: keyframe.depthWidth, height: keyframe.depthHeight,
                cameraToWorld: keyframe.cameraToWorld, intrinsics: keyframe.cameraIntrinsics,
                imageWidth: keyframe.imageWidth)
        }
        diffBusy = true
        diffQueue.async {
            let mask = DepthDiff.mask(live: live, references: refs)
            Task { @MainActor in
                self.diffBusy = false
                guard self.showDifferences, let mask, let latest = self.session.currentFrame else { return }
                self.differences = self.render(mask, frame: latest)
            }
        }
    }

    private func depth(for keyframe: Keyframe) -> [Float]? {
        if let cached = depthCache[keyframe.id] { return cached }
        guard let file = keyframe.depthFile,
            let data = try? Data(contentsOf: ReferenceStore.folder(for: reference.id).appendingPathComponent(file))
        else { return nil }
        let floats = DepthMap.floats(data)
        guard floats.count == keyframe.depthWidth * keyframe.depthHeight else { return nil }
        depthCache[keyframe.id] = floats
        return floats
    }
}
