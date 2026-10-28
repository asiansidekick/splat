import ARKit
import CoreImage
import Foundation
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

    let session = ARSession()
    let reference: Reference
    var viewport: CGSize = .zero

    private var current: Keyframe?
    private var ghostSource: CIImage?
    private var renderedFor: (id: String, viewport: CGSize)?
    private var lastUpdate = Date.distantPast
    private var diffBusy = false
    private let ciContext = CIContext()
    private let diffQueue = DispatchQueue(label: "depth-diff")
    private let writeQueue = DispatchQueue(label: "snapshot-writer")
    private var depthCache: [String: [Float]] = [:]

    var usesDepth: Bool { reference.hasDepth && Recorder.lidarAvailable }

    init(reference: Reference) {
        self.reference = reference
    }

    func start() {
        do {
            let map = try ReferenceStore.loadWorldMap(for: reference.id)
            let config = ARWorldTrackingConfiguration()
            config.initialWorldMap = map
            if usesDepth {
                config.frameSemantics.insert(.sceneDepth)
            }
            session.delegate = self
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            status = .relocalizing
        } catch {
            status = .failed("Could not open this reference: \(error.localizedDescription)")
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
        MainActor.assumeIsolated { self.handle(frame) }
    }

    private func handle(_ frame: ARFrame) {
        // ARKit reports normal tracking once it has recognised the saved room.
        guard case .normal = frame.camera.trackingState else {
            if status == .ready { status = .relocalizing }
            return
        }
        if status != .ready { status = .ready }
        let now = Date()
        guard now.timeIntervalSince(lastUpdate) > 0.1, viewport != .zero else { return }
        lastUpdate = now

        let camera = frame.camera.transform
        let keyframe = lockedKeyframe ?? Guidance.closest(to: camera, in: reference.keyframes)
        guard let keyframe else { return }
        current = keyframe
        updateGuidance(camera: camera, target: keyframe)
        updateGhost(keyframe, frame: frame)
        if usesDepth && showDifferences {
            updateDifferences(frame: frame, around: camera)
        } else if differences != nil {
            differences = nil
        }
    }

    private func updateGuidance(camera: simd_float4x4, target: Keyframe) {
        let move = Guidance.offset(from: camera, to: target)
        matched = move.isMatched
        guidance = move.description
    }

    // MARK: Ghost photo

    private func updateGhost(_ keyframe: Keyframe, frame: ARFrame) {
        if let done = renderedFor, done.id == keyframe.id, done.viewport == viewport { return }
        let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(keyframe.imageFile)
        guard let image = CIImage(contentsOf: url) else { return }
        ghost = render(image, frame: frame)
        renderedFor = (keyframe.id, viewport)
    }

    /// Lays an image in the camera's sensor orientation over the screen exactly like the live
    /// camera feed is laid out.
    private func render(_ image: CIImage, frame: ARFrame) -> UIImage? {
        let size = image.extent.size
        let toUnit = CGAffineTransform(scaleX: 1 / size.width, y: 1 / size.height)
        // Core Image puts the origin bottom left; ARKit's display transform expects top left.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        let display = frame.displayTransform(for: .portrait, viewportSize: viewport)
        let toView = CGAffineTransform(scaleX: viewport.width, y: viewport.height)
        let placed = image
            .transformed(by: toUnit.concatenating(flip).concatenating(display).concatenating(flip).concatenating(toView))
            .cropped(to: CGRect(origin: .zero, size: viewport))
        guard let cg = ciContext.createCGImage(placed, from: CGRect(origin: .zero, size: viewport)) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: LiDAR differences

    private func updateDifferences(frame: ARFrame, around camera: simd_float4x4) {
        guard !diffBusy, let depthMap = frame.sceneDepth?.depthMap else { return }
        let nearby = Guidance.closest(to: camera, in: reference.keyframes.filter { $0.depthFile != nil }, count: 3)
        let references = nearby.compactMap { keyframe -> (Keyframe, [Float])? in
            guard let depth = depth(for: keyframe) else { return nil }
            return (keyframe, depth)
        }
        guard !references.isEmpty else { return }
        let live = DepthView(
            depth: DepthMap.floats(DepthMap.copy(depthMap)),
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap),
            cameraToWorld: camera,
            intrinsics: frame.camera.intrinsics,
            imageWidth: CVPixelBufferGetWidth(frame.capturedImage))
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
