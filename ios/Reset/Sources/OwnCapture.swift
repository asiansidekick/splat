import ARKit
import CoreImage
import SceneKit
import simd

/// Takes a scan's pictures with Reset's own camera (Phil, 2026-11-17: on his iPhone 14 Pro Apple's Object Capture
/// started, tracked, and took no pictures at all). A picture is kept every few centimetres or degrees as the phone
/// goes round, at a steady moment, with where the camera was, so the finished model can be made real size and upright.
@MainActor
final class OwnCapture: NSObject, ARSessionDelegate {
    static let maxShots = 120

    let session = ARSession()
    /// Pictures are kept only while this is on.
    var recording = false
    private(set) var shots = 0
    private(set) var tooFast = false
    private(set) var tracking = true
    private var folder: ScanFolder?
    /// Where each picture was taken, by file name: x, y, z in the room.
    private var cameras: [String: [Float]] = [:]
    private var lastShot: (position: SIMD3<Float>, forward: SIMD3<Float>)?
    private var lastPose: (position: SIMD3<Float>, forward: SIMD3<Float>, time: TimeInterval)?
    private var writing = 0
    private let queue = DispatchQueue(label: "scan-pictures")
    private let context = CIContext()

    func begin(_ folder: ScanFolder) {
        self.folder = folder
        shots = 0
        cameras = [:]
        lastShot = nil
        lastPose = nil
        recording = false
        tooFast = false
        session.delegate = self
        session.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    /// Stops the camera and writes down where the pictures were taken. Returns once every picture is on disk.
    func end() async {
        recording = false
        session.pause()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        if let folder, !cameras.isEmpty, let data = try? JSONEncoder().encode(cameras) {
            try? data.write(to: folder.camerasFile)
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { self.handle(frame) }
    }

    private func handle(_ frame: ARFrame) {
        let normal: Bool
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        tracking = normal
        let transform = frame.camera.transform
        let position = transform.columns.3.xyz
        let forward = -transform.columns.2.xyz
        var turning: Float = 0
        var moving: Float = 0
        if let before = lastPose {
            let dt = Float(frame.timestamp - before.time)
            if dt > 0.001, dt < 0.5 {
                turning = acos(min(1, max(-1, simd_dot(forward, before.forward)))) / dt
                moving = simd_distance(position, before.position) / dt
            }
        }
        lastPose = (position, forward, frame.timestamp)
        let exposure = Float(min(max(frame.camera.exposureDuration, 1.0 / 120), 1.0 / 15))
        let turnLimit = min(0.5, 0.012 / exposure)
        tooFast = turning > turnLimit * 2.2 || moving > 0.8
        guard recording, normal, shots < Self.maxShots, writing < 3, let folder else { return }
        if let last = lastShot {
            let moved = simd_distance(position, last.position)
            let turned = acos(min(1, max(-1, simd_dot(forward, last.forward))))
            // A picture every 8 cm or 8 degrees: neighbours overlap well, which the model builder needs.
            if moved < 0.08 && turned < 0.14 { return }
            let steady = turning < turnLimit && moving < 0.35
            if !steady && moved < 0.16 && turned < 0.28 { return }
        }
        lastShot = (position, forward)
        shots += 1
        let name = String(format: "IMG_%04d.jpg", shots)
        cameras[name] = [position.x, position.y, position.z]
        let image = CIImage(cvPixelBuffer: frame.capturedImage).copyRendered()
        let url = folder.images.appendingPathComponent(name)
        let context = context
        writing += 1
        queue.async {
            if let jpeg = context.jpegRepresentation(
                of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
            {
                try? jpeg.write(to: url)
            }
            Task { @MainActor in self.writing -= 1 }
        }
    }
}

extension ScanFolder {
    /// Where Reset's own camera was for each picture (none for scans made with Apple's capture).
    var camerasFile: URL { url.appendingPathComponent("cameras.json") }
    var fitFile: URL { url.appendingPathComponent("fit.json") }
    var cameras: [String: [Float]]? {
        (try? Data(contentsOf: camerasFile)).flatMap { try? JSONDecoder().decode([String: [Float]].self, from: $0) }
    }
    var fit: ScanAlign.Fit? {
        (try? Data(contentsOf: fitFile)).flatMap { try? JSONDecoder().decode(ScanAlign.Fit.self, from: $0) }
    }
}

enum ScanBake {
    /// Writes the model real size, upright and standing on its own middle, from the fit between the model
    /// builder's camera places and the room's. Without a fit the model is copied as it is.
    @MainActor static func bake(_ source: URL, to out: URL, fit: ScanAlign.Fit?) -> Bool {
        try? FileManager.default.removeItem(at: out)
        guard let fit, let scene = try? SCNScene(url: source, options: nil) else {
            return (try? FileManager.default.copyItem(at: source, to: out)) != nil
        }
        let turned = SCNNode()
        for child in scene.rootNode.childNodes { turned.addChildNode(child) }
        turned.simdOrientation = fit.quaternion
        turned.simdScale = SIMD3(repeating: fit.scale)
        let holder = SCNNode()
        holder.addChildNode(turned)
        let (low, high) = holder.boundingBox
        holder.position = SCNVector3(-(low.x + high.x) / 2, -low.y, -(low.z + high.z) / 2)
        scene.rootNode.addChildNode(holder)
        if scene.write(to: out, options: nil, delegate: nil, progressHandler: nil) { return true }
        return (try? FileManager.default.copyItem(at: source, to: out)) != nil
    }
}
