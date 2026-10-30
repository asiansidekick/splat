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
    /// All four edge guides are in their slots.
    @Published var matched = false
    /// Where to aim and move, updated every frame: the arrow when the reference is off screen.
    let aim = AimState()
    /// The edge guides, updated every frame.
    let edges = EdgeGuideState()
    /// The last picture check, while it is fresh: the edge guides follow it, carried on between
    /// checks by how the phone has turned since.
    private var lastMatch: (id: String, result: ImageMatch.Result, size: CGSize, time: TimeInterval)?
    /// The pictures' correction to the attitude, for the reference view it was found for.
    private var correction = AlignmentCorrection()
    private var correctionID: String?
    /// The picture check last added to the correction.
    private var correctedTime: TimeInterval?
    /// Paused: the live picture frozen, with the reference stretched onto that same frame.
    @Published private(set) var paused = false
    @Published private(set) var held: HeldFrame?
    /// While paused: the reference photo exactly as shot, upright, to compare with the frozen frame.
    @Published private(set) var heldPhoto: UIImage?
    /// What the held pictures are made from, kept so turning the phone while paused lays them
    /// out again for the new screen shape instead of stretching them.
    private var heldParts: (frame: ARFrame, live: CIImage, placed: CIImage?, registered: Bool)?
    private var heldLayout: (orientation: UIInterfaceOrientation, viewport: CGSize)?
    private var heldBusy = false
    /// Counts pauses, so a slow build from an earlier pause never lands on a later one.
    private var pauseCount = 0
    private let holdQueue = DispatchQueue(label: "held-frame")
    /// The two-sphere alignment guide, in 3D.
    @Published var lockedKeyframe: Keyframe?
    /// The LiDAR change colours over the photo ghost. Off at first: on device they flickered and
    /// hid the ghost, and the 3D ghost shows what has gone as outlines instead.
    @Published var showDifferences = false
    /// The 3D ghost, built from the reference's LiDAR depth and photos, instead of the photo ghost.
    /// The 3D ghost is set aside for now (Phil, 2026-10-29) while the photo ghost is perfected:
    /// not offered on screen and its cloud not built.
    static let offers3D = false
    @Published var show3D = false {
        didSet { if !show3D { ghost3D = nil } }
    }
    /// The 3D ghost drawn for where the phone is now, laid over the screen like the photo ghost.
    @Published var ghost3D: UIImage?
    @Published var cloudReady = false
    /// Set when the reference has nothing to build the 3D ghost from.
    @Published var cloudFailed = false
    /// How many points of the 3D ghost the live LiDAR finds gone from where they were.
    @Published var missingPoints = 0
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
    /// How the screen was turned and sized for the ghost on screen: turning the phone lays it
    /// out again even when the phone has not moved.
    private var lastGhostLayout: (orientation: UIInterfaceOrientation, viewport: CGSize)?
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
    /// When the ghost last moved to another reference view.
    private var lastSwitch = Date.distantPast
    private var imageBusy = false
    private var lastImageCheck = Date.distantPast
    private let imageQueue = DispatchQueue(label: "image-match")
    private var viewer: Ghost3D.Viewer?
    private var viewerBusy = false
    private let viewerQueue = DispatchQueue(label: "ghost-3d")
    private var ghostStrength: Float = 0.5
    /// The room map's tracked points, for a 3D ghost when the reference has no usable depth.
    private var mapPoints: [SIMD3<Float>] = []

    var usesDepth: Bool { reference.hasDepth && Recorder.lidarAvailable }

    init(reference: Reference) {
        self.reference = reference
        super.init()
        modelsNode.isHidden = true
        sceneContent.addChildNode(modelsNode)
    }

    /// Whether the reference has LiDAR depth, which the 3D ghost is built from. Viewing it works on
    /// any ARKit device.
    var can3D: Bool { reference.hasDepth }

    func setGhostOpacity(_ value: Double) {
        ghostStrength = Float(value)
    }

    private func buildCloud() {
        guard can3D, !cloudReady else { return }
        let saved = reference
        let points = mapPoints
        Task {
            let viewer = await Task.detached(priority: .utility) { () -> Ghost3D.Viewer? in
                var built = Ghost3D.build(reference: saved)
                Diagnostics.log("3D ghost from depth: \(built.note)")
                if built.cloud.positions.count < 500 {
                    built = Ghost3D.mapPoints(points)
                    Diagnostics.log("3D ghost from the room map instead: \(built.note)")
                }
                return built.cloud.positions.isEmpty ? nil : Ghost3D.Viewer(cloud: built.cloud, views: built.views)
            }.value
            guard let viewer else {
                cloudFailed = true
                return
            }
            self.viewer = viewer
            cloudReady = true
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
            mapPoints = map.rawFeaturePoints.points
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
            if Restorer.offers3D { buildCloud() }
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
        if paused { relayoutHeld() }
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
        if show3D {
            // As often as drawing keeps up, so the ghost follows the phone closely.
            draw3D(frame: frame)
        } else if let target = lockedKeyframe ?? current {
            updateAim(frame: frame, target: target)
        }
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 0.1, viewport != .zero else { return }
        lastUpdate = now

        let camera = frame.camera.transform
        let keyframe = lockedKeyframe ?? steadyClosest(to: camera, now: now)
        guard let keyframe else { return }
        if current?.id != keyframe.id { lastMatch = nil }
        current = keyframe
        if !show3D { updateGhost(keyframe, frame: frame) }
        // Less often when the phone is hot, so it does not throttle or shut the camera down.
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if usesDepth && showDifferences && !show3D && (!hot || now.timeIntervalSince(lastDiff) > 0.5) {
            lastDiff = now
            updateDifferences(frame: frame, around: camera)
        } else if differences != nil {
            differences = nil
        }
    }

    /// From ARKit's tracking (camera plus motion sensors): where the reference camera was aiming,
    /// on screen, for the arrow when it is off screen; and the edge guides.
    private func updateAim(frame: ARFrame, target: Keyframe) {
        guard viewport != .zero else { return }
        let camera = frame.camera.transform
        let move = Guidance.offset(from: camera, to: target, orientation: orientation)
        let (right, up) = Guidance.screenAxes(camera, orientation: orientation)
        // Close: within 35 cm and pointing within 20°. Then the pictures decide, since the
        // position ARKit found the room at can be a few centimetres out. The ghost is turned
        // with the phone, so this works however the phone is held.
        let close = simd_length(move.vector) < 0.35 && move.turn < 20 * .pi / 180
        if close {
            checkImage(frame: frame, keyframe: target)
        } else {
            lastMatch = nil
        }
        let spot = (target.cameraToWorld * SIMD4<Float>(0, 0, -1, 1)).xyz
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
        guard !paused else { return }
        if correctionID != target.id || !close {
            correctionID = target.id
            correction.reset()
            correctedTime = nil
        }
        var match = lastMatch
        if let m = match, m.id != target.id || frame.timestamp - m.time > 1.5 { match = nil }
        let middle = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let level = GhostAlignment(centre: middle, roll: 0, scale: 1)
        // Each new picture check adds once: where the ghost's crosshair really shows live.
        if let match, match.time != correctedTime {
            correctedTime = match.time
            if let measured = alignment(frame: frame, match: match) {
                correction.add(pictures: measured, attitude: level)
            }
        }
        // The guides show how far the ghost is off what the camera sees: from the pictures
        // (the middle of the last five checks) when close, otherwise from ARKit's position.
        let shown = match != nil && correction.ready ? correction.apply(to: level) : EdgeGuide.fromPosition(
            right: CGFloat(move.right), up: CGFloat(move.up), forward: CGFloat(move.forward), middle: middle)
        // Only the pictures can say it is lined up, so a stroke seats only while checks are
        // fresh and agree.
        edges.update(shown, canSeat: close && match != nil && correction.ready, time: frame.timestamp)
        if matched != edges.all { matched = edges.all }
    }

    /// Where the ghost's crosshair shows in the live picture, from a picture check of the ghost
    /// (the reference as drawn on screen, turned with the phone) against the live picture.
    private func alignment(frame: ARFrame, match: (id: String, result: ImageMatch.Result, size: CGSize, time: TimeInterval)) -> GhostAlignment? {
        let display = frame.displayTransform(for: orientation, viewportSize: viewport)
        let toImage = display.inverted()
        let size = viewport
        func land(_ screen: CGPoint) -> CGPoint? {
            let unit = CGPoint(x: screen.x / size.width, y: screen.y / size.height).applying(toImage)
            let pixel = CGPoint(x: unit.x * match.size.width, y: unit.y * match.size.height)
            guard let live = match.result.toLive(pixel, reference: match.size, live: match.size) else { return nil }
            let shown = CGPoint(x: live.x / match.size.width, y: live.y / match.size.height).applying(display)
            return CGPoint(x: shown.x * size.width, y: shown.y * size.height)
        }
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let arm = size.width * 0.25
        guard let c = land(middle),
            let l = land(CGPoint(x: middle.x - arm, y: middle.y)),
            let r = land(CGPoint(x: middle.x + arm, y: middle.y))
        else { return nil }
        return GhostAlignment(centre: c, left: l, right: r, arm: arm)
    }

    /// The closest reference view, but sticky: small adjustments of the phone between two views
    /// taken close together must not flip the ghost back and forth. Another view takes over only
    /// when it is clearly closer (by a fifth, and at least 8 cm or the like in turn) and the
    /// current one has shown for over a second.
    private func steadyClosest(to camera: simd_float4x4, now: Date) -> Keyframe? {
        guard let best = Guidance.closest(to: camera, in: reference.keyframes) else { return nil }
        guard let shown = current, shown.id != best.id else { return best }
        let shownScore = Guidance.score(camera, shown)
        let bestScore = Guidance.score(camera, best)
        let clearlyBetter = bestScore < shownScore * 0.8 && bestScore < shownScore - 0.08
        guard clearlyBetter, now.timeIntervalSince(lastSwitch) > 1 else { return shown }
        lastSwitch = now
        return best
    }

    /// Compares the live picture with the ghost as it is drawn (the reference turned to how the
    /// phone points now) on a background queue, a few times a second: what is left over is how
    /// far the ghost is off, which the edge guides show.
    private func checkImage(frame: ARFrame, keyframe: Keyframe) {
        guard !imageBusy, Date().timeIntervalSince(lastImageCheck) > 0.3,
            let source = ghostSource, source.id == keyframe.id
        else { return }
        lastImageCheck = Date()
        imageBusy = true
        let live = CIImage(cvPixelBuffer: frame.capturedImage)
        let reference = source.image
        let resolution = frame.camera.imageResolution
        let warp = Warp(
            reference: keyframe.cameraToWorld, referenceIntrinsics: keyframe.cameraIntrinsics,
            referenceSize: CGSize(width: keyframe.imageWidth, height: keyframe.imageHeight),
            live: frame.camera.transform, liveIntrinsics: frame.camera.intrinsics, liveSize: resolution)
        let time = frame.timestamp
        imageQueue.async {
            let result = warp.apply(to: reference).flatMap { ImageMatch.compare(live: live, reference: $0) }
            Task { @MainActor in
                self.imageBusy = false
                guard let result, self.current?.id == keyframe.id else { return }
                // A wild answer means Vision paired the wrong things: leave it out.
                if result.error < ImageMatch.guideLimit {
                    self.lastMatch = (keyframe.id, result, resolution, time)
                }
            }
        }
    }

    // MARK: Pause and compare

    /// Freezes the live picture and stretches the reference onto that same frame (from its own
    /// picture check, or by the phone's turn when the pictures cannot be paired).
    func pause() {
        guard !paused, let frame = session.currentFrame, viewport != .zero else {
            Diagnostics.log("Pause ignored: paused \(paused), frame \(session.currentFrame != nil), viewport \(viewport)")
            return
        }
        paused = true
        held = nil
        edges.update(nil, canSeat: false, time: frame.timestamp)
        let live = CIImage(cvPixelBuffer: frame.capturedImage)
        let placement = Placement(display: frame.displayTransform(for: orientation, viewportSize: viewport), viewport: viewport)
        let keyframe = lockedKeyframe ?? current
        // THEN is the ghost exactly as it was on screen when paused: the same photo turned the
        // same way for this frame's camera, so what was lined up live stays lined up. (Showing
        // the photo as shot instead left it offset, Phil, 2026-10-30.)
        var source: CIImage?
        var warp: Warp?
        heldPhoto = nil
        if let keyframe {
            // Shown only when the ghost cannot be drawn (none yet, or the phone faces away).
            let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(keyframe.imageFile)
            heldPhoto = UIImage(contentsOfFile: url.path)?.cgImage.map {
                UIImage(cgImage: $0, scale: 1, orientation: keyframe.uprightOrientation)
            }
        }
        if let keyframe, let ghostSource, ghostSource.id == keyframe.id {
            source = ghostSource.image
            warp = Warp(
                reference: keyframe.cameraToWorld, referenceIntrinsics: keyframe.cameraIntrinsics,
                referenceSize: CGSize(width: keyframe.imageWidth, height: keyframe.imageHeight),
                live: frame.camera.transform, liveIntrinsics: frame.camera.intrinsics, liveSize: frame.camera.imageResolution)
        }
        let context = ciContext
        let layout = (orientation, viewport)
        pauseCount += 1
        let count = pauseCount
        heldBusy = true
        holdQueue.async {
            let placed = HeldFrame.place(live: live, reference: source, fallback: warp)
            let built = HeldFrame.render(live: live, placed: placed.image, registered: placed.registered, placement: placement, context: context)
            Task { @MainActor in
                guard self.pauseCount == count else { return }
                self.heldBusy = false
                guard self.paused else { return }
                self.heldParts = (frame, live, placed.image, placed.registered)
                self.heldLayout = layout
                self.held = built
                Diagnostics.log("Paused: reference \(built.reference != nil ? "as the ghost was" : self.heldPhoto != nil ? "photo as shot" : "none")")
            }
        }
    }

    /// While paused, lays the held pictures out again once the phone has turned.
    private func relayoutHeld() {
        let screen = Screen.orientation
        if orientation != screen { orientation = screen }
        guard !heldBusy, let parts = heldParts, let layout = heldLayout, viewport != .zero,
            layout.orientation != orientation || layout.viewport != viewport
        else { return }
        let placement = Placement(display: parts.frame.displayTransform(for: orientation, viewportSize: viewport), viewport: viewport)
        let context = ciContext
        let newLayout = (orientation, viewport)
        let count = pauseCount
        heldBusy = true
        holdQueue.async {
            let built = HeldFrame.render(live: parts.live, placed: parts.placed, registered: parts.registered, placement: placement, context: context)
            Task { @MainActor in
                guard self.pauseCount == count else { return }
                self.heldBusy = false
                guard self.paused else { return }
                self.heldLayout = newLayout
                self.held = built
            }
        }
    }

    func resume() {
        paused = false
        heldPhoto = nil
        heldBusy = false
        held = nil
        heldParts = nil
        heldLayout = nil
    }

    // MARK: Ghost photo

    /// Redraws the ghost for where the phone is now: the reference photo is turned to match how
    /// the phone is held and pointed (a rotation re-projection, exact for anything more than a
    /// few metres away and close for nearer props), then laid out like the live camera.
    private func updateGhost(_ keyframe: Keyframe, frame: ARFrame) {
        guard !ghostBusy, !paused else { return }
        let camera = frame.camera.transform
        if let last = lastGhostPose, ghostSource?.id == keyframe.id, ghost != nil,
            let layout = lastGhostLayout, layout.orientation == orientation, layout.viewport == viewport,
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
        lastGhostLayout = (orientation, viewport)
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

    static func angle(between a: simd_float4x4, and b: simd_float4x4) -> Float {
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

        /// Where a reference pixel shows in the live picture, both counted from the top left.
        func project(_ pixel: SIMD2<Float>) -> SIMD2<Float>? {
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

    /// Checks the 3D ghost against the live LiDAR (parts still in place dim, parts gone turn
    /// blue) and draws it for where the phone is, as often as it keeps up.
    private func draw3D(frame: ARFrame) {
        guard let viewer, !viewerBusy else { return }
        let live = usesDepth ? liveDepth(frame) : nil
        let resolution = frame.camera.imageResolution
        // A third of the camera's resolution: sharp enough on screen and quick to draw.
        let camera = PinholeCamera(
            cameraToWorld: frame.camera.transform, intrinsics: frame.camera.intrinsics,
            imageWidth: Int(resolution.width), width: Int(resolution.width) / 3, height: Int(resolution.height) / 3)
        let placement = Placement(display: frame.displayTransform(for: orientation, viewportSize: viewport), viewport: viewport)
        let strength = ghostStrength
        let context = ciContext
        viewerBusy = true
        viewerQueue.async {
            let image = viewer.draw(live: live, camera: camera, strength: strength)
                .flatMap { Restorer.render($0, placement: placement, context: context) }
            let gone = viewer.goneCount
            Task { @MainActor in
                self.viewerBusy = false
                guard self.show3D else { return }
                self.ghost3D = image
                if self.missingPoints != gone { self.missingPoints = gone }
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
            confidence: DepthMap.confidence(depthData.confidenceMap))
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
