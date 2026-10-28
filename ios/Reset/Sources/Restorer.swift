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
    @Published var matched = false
    /// Where to aim and move, updated every frame for the guidance graphic.
    let aim = AimState()
    @Published var lockedKeyframe: Keyframe?
    @Published var showDifferences = true
    /// The 3D ghost, built from the reference's LiDAR depth and photos, instead of the photo ghost.
    @Published var show3D = false {
        didSet { cloudNode.isHidden = !show3D }
    }
    @Published var cloudReady = false
    /// Set when the reference has nothing to build the 3D ghost from.
    @Published var cloudFailed = false
    /// How many points of the 3D ghost the live LiDAR finds gone from where they were.
    @Published var missingPoints = 0
    /// Added to the AR scene; sits in the reference's room coordinates once relocalised.
    let cloudNode = SCNNode()
    /// Placed USDZ models, shown once the room is recognised so they appear in the right place.
    let modelsNode = SCNNode()
    /// Everything this screen draws in 3D.
    let sceneContent = SCNNode()
    lazy var placer = ModelPlacer(session: session, root: modelsNode, folder: ReferenceStore.folder(for: reference.id))

    let session = ARSession()
    let reference: Reference
    var viewport: CGSize = .zero
    /// How the screen is turned, so the ghost, highlights and directions follow it.
    var orientation: UIInterfaceOrientation = .portrait

    private var current: Keyframe?
    /// The decoded photo of the keyframe the ghost shows, kept so each redraw only warps it.
    private var ghostSource: (id: String, image: CIImage)?
    private var lastGhostPose: simd_float4x4?
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
    private var ghostDisplay: Ghost3D.Display?
    private var checker: Ghost3D.Checker?
    private var checkBusy = false
    private var lastCheck = Date.distantPast
    private let checkQueue = DispatchQueue(label: "ghost-check")
    private var faintOpacity: CGFloat = 0.5

    var usesDepth: Bool { reference.hasDepth && Recorder.lidarAvailable }

    init(reference: Reference) {
        self.reference = reference
        super.init()
        cloudNode.isHidden = true
        modelsNode.isHidden = true
        sceneContent.addChildNode(cloudNode)
        sceneContent.addChildNode(modelsNode)
    }

    /// Whether the reference has LiDAR depth, which the 3D ghost is built from. Viewing it works on
    /// any ARKit device.
    var can3D: Bool { reference.hasDepth }

    func setGhostOpacity(_ value: Double) {
        faintOpacity = CGFloat(value)
        ghostDisplay?.faintOpacity = faintOpacity
    }

    private func buildCloud() {
        guard can3D, !cloudReady else { return }
        let saved = reference
        let check = usesDepth
        Task {
            let (cloud, checker) = await Task.detached(priority: .utility) {
                var cloud = Ghost3D.build(reference: saved)
                Diagnostics.log("3D ghost from depth: \(cloud.note)")
                if cloud.positions.isEmpty {
                    cloud = Ghost3D.mapPoints(reference: saved)
                    Diagnostics.log("3D ghost from the room map: \(cloud.note)")
                }
                return (cloud, check && !cloud.positions.isEmpty ? Ghost3D.Checker(cloud: cloud) : nil)
            }.value
            guard !cloud.positions.isEmpty else {
                cloudFailed = true
                return
            }
            let display = Ghost3D.Display(cloud: cloud)
            display.faintOpacity = faintOpacity
            cloudNode.addChildNode(display.node)
            ghostDisplay = display
            self.checker = checker
            cloudReady = true
            Diagnostics.log("3D ghost: \(cloud.positions.count) points, live check \(checker != nil)")
        }
    }

    func start() {
        if reference.photoOnly {
            // An imported photo has no room map: show it as the ghost over the live camera.
            let config = ARWorldTrackingConfiguration()
            session.delegate = self
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            loadStartPhoto()
            placer.load(reference.models)
            modelsNode.isHidden = false
            status = .ready
            Diagnostics.log("Reset start: photo \(reference.title)")
            return
        }
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
            placer.load(reference.models)
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
        if reference.photoOnly { return }
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
        // Read every frame: during a rotation the new orientation arrives after the size change.
        let screen = Screen.orientation
        if orientation != screen { orientation = screen }
        if !show3D, let target = lockedKeyframe ?? current { updateAim(frame: frame, target: target) }
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 0.1, viewport != .zero else { return }
        lastUpdate = now

        let camera = frame.camera.transform
        let keyframe = lockedKeyframe ?? Guidance.closest(to: camera, in: reference.keyframes)
        guard let keyframe else { return }
        current = keyframe
        if show3D {
            checkCloud(frame: frame)
        } else {
            updateGhost(keyframe, frame: frame)
        }
        // Less often when the phone is hot, so it does not throttle or shut the camera down.
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if usesDepth && showDifferences && (!hot || now.timeIntervalSince(lastDiff) > 0.5) {
            lastDiff = now
            updateDifferences(frame: frame, around: camera)
        } else if differences != nil {
            differences = nil
        }
    }

    /// From ARKit's tracking (camera plus motion sensors): where the reference camera was aiming,
    /// on screen; how far to turn the phone about its own axis; and how far to step.
    private func updateAim(frame: ARFrame, target: Keyframe) {
        guard viewport != .zero else { return }
        let camera = frame.camera.transform
        let move = Guidance.offset(from: camera, to: target, orientation: orientation)
        let (right, up) = Guidance.screenAxes(camera, orientation: orientation)
        // The spot 1.5 m in front of where the reference photo was taken.
        let spot = target.position + target.forward * 1.5
        let local = camera.inverse * SIMD4<Float>(spot, 1)
        let point: CGPoint
        if local.z < -0.05 {
            point = frame.camera.projectPoint(spot, orientation: orientation, viewportSize: viewport)
        } else {
            // Behind the phone: far off screen on the side to turn towards.
            let direction = spot - camera.columns.3.xyz
            let dx = CGFloat(simd_dot(direction, right))
            let dy = CGFloat(-simd_dot(direction, up))
            let length = max(hypot(dx, dy), 0.001)
            point = CGPoint(x: viewport.width / 2 + dx / length * 5000, y: viewport.height / 2 + dy / length * 5000)
        }
        let (_, targetUp) = Guidance.screenAxes(target.cameraToWorld, orientation: orientation)
        let roll = atan2(simd_dot(targetUp, right), simd_dot(targetUp, up))
        aim.update(point: point, roll: Double(roll), offset: move)
        if matched != move.isMatched { matched = move.isMatched }
    }

    // MARK: Ghost photo

    /// Redraws the ghost for where the phone is now: the reference photo is turned to match how
    /// the phone is held and pointed (a rotation re-projection, exact for anything more than a
    /// few metres away and close for nearer props), then laid out like the live camera.
    private func updateGhost(_ keyframe: Keyframe, frame: ARFrame) {
        guard !ghostBusy else { return }
        let camera = frame.camera.transform
        if let last = lastGhostPose, ghostSource?.id == keyframe.id, ghost != nil,
            Restorer.angle(between: last, and: camera) < 0.002, simd_distance(last.columns.3, camera.columns.3) < 0.002
        { return }
        if ghostSource?.id != keyframe.id {
            let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(keyframe.imageFile)
            guard let cg = UIImage(contentsOfFile: url.path)?.cgImage else { return }
            ghostSource = (keyframe.id, CIImage(cgImage: cg))
        }
        guard let source = ghostSource?.image else { return }
        let resolution = frame.camera.imageResolution
        let warp = Warp(
            reference: keyframe.cameraToWorld, referenceIntrinsics: keyframe.cameraIntrinsics,
            referenceSize: CGSize(width: keyframe.imageWidth, height: keyframe.imageHeight),
            live: camera, liveIntrinsics: frame.camera.intrinsics, liveSize: resolution)
        let placement = Placement(display: frame.displayTransform(for: orientation, viewportSize: viewport), viewport: viewport)
        let context = ciContext
        lastGhostPose = camera
        ghostBusy = true
        ghostQueue.async {
            let image = warp.apply(to: source).flatMap { Restorer.render($0, placement: placement, context: context) }
            Task { @MainActor in
                self.ghostBusy = false
                // Nil when the phone faces away from where the photo was taken; the aim ring guides back.
                self.ghost = image
            }
        }
    }

    private static func angle(between a: simd_float4x4, and b: simd_float4x4) -> Float {
        let forward = simd_dot(simd_normalize(a.columns.2.xyz), simd_normalize(b.columns.2.xyz))
        let side = simd_dot(simd_normalize(a.columns.0.xyz), simd_normalize(b.columns.0.xyz))
        return acos(min(1, max(-1, min(forward, side))))
    }

    /// Moves a reference photo into the live camera's image as if only the camera's rotation had
    /// changed: each corner's viewing direction is projected through the live camera.
    struct Warp: @unchecked Sendable {
        let reference: simd_float4x4
        let referenceIntrinsics: simd_float3x3
        let referenceSize: CGSize
        let live: simd_float4x4
        let liveIntrinsics: simd_float3x3
        let liveSize: CGSize

        /// The photo in the live camera's sensor image layout, the size of the live image, or nil
        /// when the photo was taken facing away from where the camera points now.
        func apply(to image: CIImage) -> CIImage? {
            let w = Float(referenceSize.width)
            let h = Float(referenceSize.height)
            // Top left, top right, bottom right, bottom left, in reference image pixels.
            let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h)]
            var projected: [CGPoint] = []
            for corner in corners {
                guard let point = project(corner) else { return nil }
                // Core Image counts y from the bottom.
                projected.append(CGPoint(x: CGFloat(point.x), y: liveSize.height - CGFloat(point.y)))
            }
            guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return nil }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(CIVector(cgPoint: projected[0]), forKey: "inputTopLeft")
            filter.setValue(CIVector(cgPoint: projected[1]), forKey: "inputTopRight")
            filter.setValue(CIVector(cgPoint: projected[2]), forKey: "inputBottomRight")
            filter.setValue(CIVector(cgPoint: projected[3]), forKey: "inputBottomLeft")
            guard let warped = filter.outputImage else { return nil }
            let canvas = CGRect(origin: .zero, size: liveSize)
            return warped.cropped(to: canvas).composited(over: CIImage(color: .clear).cropped(to: canvas))
        }

        private func project(_ pixel: SIMD2<Float>) -> SIMD2<Float>? {
            let k = referenceIntrinsics
            // ARKit camera space: x right, y up, looking down -z.
            let ray = SIMD3<Float>((pixel.x - k[2][0]) / k[0][0], -(pixel.y - k[2][1]) / k[1][1], -1)
            let world = simd_float3x3(reference.columns.0.xyz, reference.columns.1.xyz, reference.columns.2.xyz) * ray
            let liveRotation = simd_float3x3(live.columns.0.xyz, live.columns.1.xyz, live.columns.2.xyz)
            let local = liveRotation.transpose * world
            guard local.z < -0.05 else { return nil }
            let z = -local.z
            let l = liveIntrinsics
            return SIMD2(l[0][0] * local.x / z + l[2][0], -l[1][1] * local.y / z + l[2][1])
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

    // MARK: 3D ghost

    /// A few times a second: which parts of the 3D ghost the live LiDAR still finds in place
    /// (hidden), and which are gone (shown solid, ringed in blue), from wherever the phone is.
    private func checkCloud(frame: ARFrame) {
        guard let checker, let display = ghostDisplay, !checkBusy, Date().timeIntervalSince(lastCheck) > 0.25,
            let live = liveDepth(frame)
        else { return }
        lastCheck = Date()
        checkBusy = true
        checkQueue.async {
            let result = checker.update(live: live)
            Task { @MainActor in
                self.checkBusy = false
                guard let result else { return }
                display.show(faint: result.faint, missing: result.missing)
                if self.missingPoints != result.missing.count { self.missingPoints = result.missing.count }
            }
        }
    }

    /// The live LiDAR depth and the camera that took it.
    private func liveDepth(_ frame: ARFrame) -> DepthView? {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        return DepthView(
            depth: DepthMap.floats(DepthMap.copy(depthMap)),
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap),
            cameraToWorld: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
            confidence: depthData.confidenceMap.map(DepthMap.bytes))
    }

    // MARK: LiDAR differences

    private func updateDifferences(frame: ARFrame, around camera: simd_float4x4) {
        guard !diffBusy, let live = liveDepth(frame) else { return }
        let liveValues = live.depth
        let width = live.width
        let height = live.height
        // Use the reference views that saw what the camera is pointing at, from the most similar
        // direction, so the check works from off camera and from other distances too.
        let withDepth = reference.keyframes.filter { $0.depthFile != nil }
        let nearby: [Keyframe]
        if let target = Guidance.target(camera: camera, depth: liveValues, width: width, height: height) {
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
