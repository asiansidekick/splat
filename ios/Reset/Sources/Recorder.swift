import ARKit
import CoreImage
import ImageIO
import SceneKit
import Foundation

/// Records a reference: walk around the set and the recorder keeps a photo (plus LiDAR depth when
/// switched on) every time the camera has moved a little, then saves ARKit's map of the room so
/// the reference can be found again later, offline.
@MainActor
final class Recorder: NSObject, ObservableObject, ARSessionDelegate {
    @Published var keyframeCount = 0
    @Published var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    @Published var trackingNormal = false
    @Published var saving = false
    @Published var error: String?
    /// Off for a quick snapshot: keyframes are only kept when the shutter is tapped.
    @Published var autoCapture = true

    let session = ARSession()
    /// 3D models placed before recording; each reference saved afterwards keeps them.
    let modelsNode = SCNNode()
    lazy var placer: ModelPlacer = {
        let placer = ModelPlacer(session: session, root: modelsNode, folder: Recorder.staging)
        // One-finger drags draw measurements while measuring, instead of moving models.
        placer.isSuspended = { [unowned self] in self.measurer.active }
        return placer
    }()
    /// Measurements and notes made while recording go into each reference saved.
    lazy var measurer = Measurer(session: session, parent: modelsNode)

    /// Where model files wait until a reference is saved.
    static var staging: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Staging", isDirectory: true)
    }
    private var reference: Reference?
    private var lastSaved: (position: SIMD3<Float>, forward: SIMD3<Float>)?
    private let writeQueue = DispatchQueue(label: "keyframe-writer")
    private let ciContext = CIContext()
    private var pendingWrites = 0
    private var captureNext = false

    /// A new keyframe is kept after the camera moves this far or turns this much.
    private let minMove: Float = 0.2  // metres
    private let minTurn: Float = 12 * .pi / 180
    private let maxKeyframes = 300

    nonisolated static var lidarAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// Called with each reference once it is saved.
    var onSaved: ((Reference) -> Void)?
    /// Set when the person has asked to save; the save happens as soon as ARKit's map is ready.
    @Published var pendingSave = false
    /// How far ARKit has got mapping the room, 0 to 1, for the scanning overlay.
    @Published var scanProgress = 0.0
    /// Points of the room ARKit is tracking now, shown on the scanning overlay.
    @Published var pointCount = 0
    /// Whether a reference is being captured (the shutter was tapped and it is not saved yet).
    @Published var capturing = false
    /// Dots on everything the scan has covered, laid over the screen and building up as you
    /// walk round: dense from the LiDAR when it is on, from ARKit's tracked points otherwise.
    @Published private(set) var scanDots: UIImage?
    /// Set by the screen: dots are drawn only while this is on, and start afresh each scan.
    var showDots = false {
        didSet {
            guard showDots != oldValue else { return }
            if !showDots, scanDots != nil { scanDots = nil }
            let cloud = scanCloud
            dotsQueue.async { cloud.reset() }
        }
    }
    /// The camera view's size, for laying the dots over it.
    var viewport: CGSize = .zero
    private var dotsBusy = false
    private var lastDots = Date.distantPast
    private let dotsQueue = DispatchQueue(label: "scan-dots")
    private let scanCloud = ScanCloud()

    /// Starts the camera and mapping the room, before any reference exists, so the map is
    /// usually ready by the time the shutter is tapped.
    func prepare(useLiDAR: Bool) {
        // A new session has new coordinates, so models placed in the old one are cleared.
        placer.removeAll()
        measurer.load(measurements: [], notes: [], removed: [])
        try? FileManager.default.removeItem(at: Recorder.staging)
        let config = ARWorldTrackingConfiguration()
        if useLiDAR && Recorder.lidarAvailable {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        Torch.shared.applySoon()
        Diagnostics.log("Camera start: LiDAR \(config.frameSemantics.contains(.sceneDepth))")
    }

    /// Starts a new reference in the running session.
    func begin(scene: String, setup: String, name: String) {
        guard reference == nil else { return }
        let id = UUID()
        do {
            try FileManager.default.createDirectory(at: ReferenceStore.folder(for: id), withIntermediateDirectories: true)
        } catch {
            self.error = error.localizedDescription
            return
        }
        reference = Reference(id: id, scene: scene, setup: setup, name: name, created: Date(), keyframes: [])
        lastSaved = nil
        keyframeCount = 0
        capturing = true
        error = nil
        Diagnostics.log("Record start: \(scene)\(setup) \(name), auto \(autoCapture)")
    }

    /// Saves as soon as there is at least one view and the map is ready.
    func saveWhenReady() {
        // A second tap while it is still waiting for the map saves now, map or not.
        if pendingSave { saveAnyway = true }
        if !pendingSave { pendingSince = Date() }
        pendingSave = true
        autoCapture = false
        saveIfReady()
    }

    private var pendingSince = Date()
    private var saveAnyway = false
    /// How long it waits for ARKit's map before saving without it, so the shutter never hangs on
    /// plain surfaces or too close up, where the map never gets good enough.
    static let mapWait: TimeInterval = 12

    /// Waiting too long for the map: save the views as a photo-only reference.
    private func saveIfStuck() {
        guard pendingSave, !saving, keyframeCount > 0, saveAnyway || Date().timeIntervalSince(pendingSince) > Self.mapWait else { return }
        pendingSave = false
        saveAnyway = false
        Diagnostics.log("Record: no good room map after \(Int(Date().timeIntervalSince(pendingSince))) s (mapping \(mappingStatus.rawValue)), saving without it")
        Task {
            if let saved = await finish(withoutMap: true) { onSaved?(saved) }
        }
    }

    private func saveIfReady() {
        guard pendingSave, !saving, canSaveMap, keyframeCount > 0 else { return }
        pendingSave = false
        saveAnyway = false
        Task {
            if let saved = await finish() { onSaved?(saved) }
        }
    }

    /// ARKit's map is only reliable once it has seen enough; Apple's guidance is to save then.
    var canSaveMap: Bool {
        mappingStatus == .mapped || mappingStatus == .extending
    }

    /// Saves the room map and the keyframe list. Returns the finished reference.
    func finish(withoutMap: Bool = false) async -> Reference? {
        guard var reference else { return nil }
        saving = true
        defer { saving = false }
        // Let queued photo writes finish first.
        await withCheckedContinuation { continuation in writeQueue.async { continuation.resume() } }
        do {
            do {
                let map: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
                    session.getCurrentWorldMap { map, error in
                        if let map {
                            continuation.resume(returning: map)
                        } else {
                            continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                        }
                    }
                }
                try ReferenceStore.saveWorldMap(map, for: reference.id)
            } catch where withoutMap {
                // Saved as a photo reference: the ghost works, finding the room by map does not.
                reference.photoOnly = true
                Diagnostics.log("Record: room map unavailable (\(error.localizedDescription)), saved as a photo reference")
            }
            reference.keyframes = self.reference?.keyframes ?? []
            if !placer.models.isEmpty {
                try placer.copyFiles(to: ReferenceStore.folder(for: reference.id))
                reference.models = placer.models
            }
            reference.measurements = measurer.measurements
            reference.torch = Torch.shared.savedLevel
            reference.notes = measurer.notes
            try ReferenceStore.save(reference)
            // The session keeps running, so the next reference starts with the room already mapped.
            self.reference = nil
            capturing = false
            keyframeCount = 0
            Diagnostics.log("Record saved: \(reference.keyframes.count) keyframes")
            return reference
        } catch {
            self.error = "Could not save the room map: \(error.localizedDescription). Move the phone slowly and tap the shutter again."
            Diagnostics.log("Record save failed: \(error)")
            return nil
        }
    }

    /// Keeps the next camera frame as a keyframe, wherever the camera is.
    func captureNow() {
        captureNext = true
    }

    /// Stops the camera and throws away a reference that was started but not saved.
    func stop() {
        measurer.active = false
        session.pause()
        if let reference { ReferenceStore.delete(reference) }
        reference = nil
        capturing = false
        pendingSave = false
        showDots = false
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // The session delivers frames on the main queue (no delegateQueue is set).
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { self.handle(frame) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = ARErrors.message(for: error)
        Diagnostics.log("Record session failed: \(error)")
        Task { @MainActor in self.error = message }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Diagnostics.log("Record interrupted")
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Diagnostics.log("Record interruption ended")
    }

    /// Without this, ARKit starts a new coordinate system after an interruption (a call, the app
    /// going to the background) and the keyframes before and after would not line up.
    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }

    /// Mapping status in steps, filled in between by how many points of the room ARKit has found.
    private func updateScanProgress(_ frame: ARFrame) {
        let count = frame.rawFeaturePoints?.points.count ?? 0
        if abs(count - pointCount) > 20 { pointCount = count }
        let points = Double(count)
        let progress: Double
        switch frame.worldMappingStatus {
        case .mapped: progress = 1
        case .extending: progress = 0.8 + min(0.15, points / 4000)
        case .limited: progress = 0.2 + min(0.5, points / 1000)
        default: progress = min(0.2, points / 1000)
        }
        // Only forwards while waiting to save, so the ring does not jump back.
        let next = pendingSave ? max(scanProgress, progress) : progress
        if abs(next - scanProgress) > 0.01 { scanProgress = next }
    }

    private func handle(_ frame: ARFrame) {
        let isNormal: Bool
        if case .normal = frame.camera.trackingState { isNormal = true } else { isNormal = false }
        if trackingNormal != isNormal { trackingNormal = isNormal }
        if mappingStatus != frame.worldMappingStatus { mappingStatus = frame.worldMappingStatus }
        updateScanProgress(frame)
        saveIfReady()
        saveIfStuck()
        updateDots(frame)
        guard isNormal, var reference, reference.keyframes.count < maxKeyframes, pendingWrites < 3 else { return }

        let transform = frame.camera.transform
        let position = transform.columns.3.xyz
        let forward = -transform.columns.2.xyz
        if captureNext {
            captureNext = false
        } else {
            guard autoCapture else { return }
            if let last = lastSaved {
                let moved = simd_distance(position, last.position)
                let turned = acos(min(1, max(-1, simd_dot(forward, last.forward))))
                if moved < minMove && turned < minTurn { return }
            }
        }
        lastSaved = (position, forward)
        // Copy what the keyframe needs now; never keep the frame itself.
        let snapshot = FrameSnapshot(frame)

        let index = reference.keyframes.count
        let keyframe = snapshot.keyframe(
            imageFile: String(format: "frame_%04d.jpg", index),
            depthFile: String(format: "depth_%04d.bin", index),
            transform: transform)
        reference.keyframes.append(keyframe)
        self.reference = reference
        keyframeCount = reference.keyframes.count

        let folder = ReferenceStore.folder(for: reference.id)
        let context = ciContext
        pendingWrites += 1
        writeQueue.async {
            snapshot.write(keyframe, to: folder, context: context)
            Task { @MainActor in self.pendingWrites -= 1 }
        }
    }
}

/// The points a scan has covered so far. Only touched on the recorder's dots queue.
final class ScanCloud: @unchecked Sendable {
    static let maxPoints = 100_000
    /// One dot per cube this size, so the dots stay spaced out and the set shows between them.
    static let spacing: Float = 0.03
    static let color = SIMD3<Float>(1, 0.84, 0.1)
    private(set) var cloud = GhostCore.Cloud()
    private var filled = [SIMD3<Int32>: Int32]()

    func reset() {
        cloud = GhostCore.Cloud()
        filled = [:]
    }

    func add(depth: [Float], camera: PinholeCamera) {
        let w = camera.width
        let h = camera.height
        guard depth.count == w * h else { return }
        var points: [SIMD3<Float>] = []
        for v in stride(from: 0, to: h, by: 4) {
            for u in stride(from: 0, to: w, by: 4) {
                let d = depth[v * w + u]
                guard d > 0.1, d < GhostCore.maxRange else { continue }
                points.append(camera.unproject(u: Float(u), v: Float(v), depth: d))
            }
        }
        add(points: points)
    }

    func add(points: [SIMD3<Float>]) {
        for point in points where cloud.positions.count < ScanCloud.maxPoints {
            let q = (point / ScanCloud.spacing).rounded(.down)
            let c = SIMD3<Int32>(Int32(q.x), Int32(q.y), Int32(q.z))
            guard filled[c] == nil else { continue }
            filled[c] = Int32(cloud.positions.count)
            cloud.positions.append(point)
            cloud.colors.append(ScanCloud.color)
        }
    }
}

extension Recorder {
    /// Adds what the camera sees now to the scan's dots and draws them all, a few times a
    /// second on a background queue.
    fileprivate func updateDots(_ frame: ARFrame) {
        guard showDots, !dotsBusy, viewport != .zero, Date().timeIntervalSince(lastDots) > 0.2 else { return }
        if case .normal = frame.camera.trackingState {} else { return }
        lastDots = Date()
        dotsBusy = true
        let full = CVPixelBufferGetWidth(frame.capturedImage)
        let fullHeight = CVPixelBufferGetHeight(frame.capturedImage)
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        var depth: (values: [Float], width: Int, height: Int)?
        if let depthMap = frame.sceneDepth?.depthMap {
            depth = (DepthMap.floats(DepthMap.copy(depthMap)), CVPixelBufferGetWidth(depthMap), CVPixelBufferGetHeight(depthMap))
        }
        let tracked = frame.rawFeaturePoints?.points ?? []
        let placement = Restorer.Placement(
            display: frame.displayTransform(for: Screen.orientation, viewportSize: viewport), viewport: viewport)
        let context = ciContext
        let scan = scanCloud
        dotsQueue.async {
            if let depth {
                scan.add(depth: depth.values, camera: PinholeCamera(
                    cameraToWorld: transform, intrinsics: intrinsics, imageWidth: full, width: depth.width, height: depth.height))
            }
            scan.add(points: tracked)
            // A third of the camera's size, one pixel per dot: small dots with the set between them.
            let screen = PinholeCamera(
                cameraToWorld: transform, intrinsics: intrinsics, imageWidth: full, width: full / 3, height: fullHeight / 3)
            var cloud = scan.cloud
            cloud.colors = Array(repeating: ScanCloud.color, count: cloud.positions.count)
            let drawn = GhostCore.renderDots(surface: cloud, states: nil, camera: screen, strength: 0.9, size: 0)
            let image = Ghost3D.image(drawn, width: screen.width, height: screen.height)
                .flatMap { Restorer.render($0, placement: placement, context: context) }
            Task { @MainActor in
                self.dotsBusy = false
                if self.showDots { self.scanDots = image }
            }
        }
    }
}

/// The parts of an ARFrame a keyframe needs, copied out so the frame can be released.
struct FrameSnapshot: @unchecked Sendable {
    let image: CIImage
    let intrinsics: simd_float3x3
    let imageWidth: Int
    let imageHeight: Int
    let depth: Data?
    let depthWidth: Int
    let depthHeight: Int
    /// The first saved depth map's format and contents go in the feedback log once per launch.
    static var loggedDepth = false

    init(_ frame: ARFrame) {
        let pixels = frame.capturedImage
        // Copy the camera image so ARKit can reuse its buffer.
        image = CIImage(cvPixelBuffer: pixels).copyRendered()
        intrinsics = frame.camera.intrinsics
        imageWidth = CVPixelBufferGetWidth(pixels)
        imageHeight = CVPixelBufferGetHeight(pixels)
        if let sceneDepth = frame.sceneDepth {
            let depthMap = sceneDepth.depthMap
            // Unsure LiDAR readings (edges, dark or shiny surfaces) are dropped: they cause false
            // highlights and stray 3D ghost points.
            let kept = DepthMap.copy(depthMap, keepingOnly: sceneDepth.confidenceMap)
            if !FrameSnapshot.loggedDepth {
                FrameSnapshot.loggedDepth = true
                let raw = DepthMap.floats(DepthMap.copy(depthMap))
                let confidence = sceneDepth.confidenceMap.map(DepthMap.bytes)
                let format = sceneDepth.confidenceMap.map(DepthMap.describe) ?? "none"
                Diagnostics.log("Depth \(DepthMap.describe(depthMap)): raw \(DepthMap.stats(raw, confidence: confidence)); confidence \(format), trusted \(DepthMap.confidence(sceneDepth.confidenceMap) != nil); kept \(DepthMap.stats(DepthMap.floats(kept), confidence: nil))")
            }
            depth = kept
            depthWidth = CVPixelBufferGetWidth(depthMap)
            depthHeight = CVPixelBufferGetHeight(depthMap)
        } else {
            depth = nil
            depthWidth = 0
            depthHeight = 0
        }
    }
}

extension FrameSnapshot {
    /// Describes this frame as a keyframe; `depthFile` is dropped when there is no LiDAR depth.
    func keyframe(imageFile: String, depthFile: String, transform: simd_float4x4) -> Keyframe {
        Keyframe(
            imageFile: imageFile,
            depthFile: depth == nil ? nil : depthFile,
            transform: flatten(transform),
            intrinsics: flatten(intrinsics),
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            depthWidth: depthWidth,
            depthHeight: depthHeight)
    }

    /// Saves the photo (and depth) under the keyframe's file names. Slow: call off the main thread.
    /// Photos are stored at most 1280 pixels wide, enough for the ghost, to save space; the
    /// keyframe keeps the camera's full size, which its intrinsics refer to.
    func write(_ keyframe: Keyframe, to folder: URL, context: CIContext) {
        let scale = min(1, 1280 / max(image.extent.width, 1))
        let stored = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        if let jpeg = context.jpegRepresentation(
            of: stored, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.85])
        {
            try? jpeg.write(to: folder.appendingPathComponent(keyframe.imageFile))
        }
        if let depthFile = keyframe.depthFile, let depth {
            try? depth.write(to: folder.appendingPathComponent(depthFile))
        }
    }
}

private let snapshotContext = CIContext()

extension CIImage {
    /// Renders the image into a new bitmap-backed CIImage, detaching it from the source buffer.
    func copyRendered() -> CIImage {
        guard let cg = snapshotContext.createCGImage(self, from: extent) else { return self }
        return CIImage(cgImage: cg)
    }
}
