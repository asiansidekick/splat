import ARKit
import CoreImage
import SceneKit
import Vision
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

    /// Phil, 2026-11-22: "Could a USDZ be generated of a person standing and spinning themselves with the back facing
    /// camera?" The phone stands still and the person turns slowly on the spot. ARKit's body tracking says which way
    /// the body faces, so each picture is placed as if the phone had walked round a still person (camera places in
    /// the body's own space, turned only about up), and every picture has the room blacked out round the person (it
    /// stays still while the person turns, which would confuse the builder).
    private(set) var turning = false
    static var turningSupported: Bool { ARBodyTrackingConfiguration.isSupported }
    /// How far the person has turned so far (radians, either way), and whether that is all the way round.
    private(set) var turned: Float = 0
    private(set) var turnedRound = false
    private(set) var seesBody = false
    private var lastYaw: Float?

    func begin(_ folder: ScanFolder, turning: Bool = false) {
        self.turning = turning && Self.turningSupported
        turned = 0
        turnedRound = false
        seesBody = false
        lastYaw = nil
        self.folder = folder
        shots = 0
        cameras = [:]
        lastShot = nil
        lastPose = nil
        recording = false
        tooFast = false
        session.delegate = self
        if self.turning {
            let configuration = ARBodyTrackingConfiguration()
            configuration.automaticSkeletonScaleEstimationEnabled = true
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            ScanLog.add("Turn on the spot: body tracking")
        } else {
            session.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        }
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
        if turning {
            handleTurning(frame)
            return
        }
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

    /// Turn on the spot: the camera stands still, so its place is read in the body's own space.
    private func handleTurning(_ frame: ARFrame) {
        guard let body = frame.anchors.compactMap({ $0 as? ARBodyAnchor }).first, body.isTracked else {
            seesBody = false
            lastPose = nil
            return
        }
        seesBody = true
        // The body's own space, turned only about up: the hips, facing where the body faces.
        var facing = body.transform.columns.2.xyz
        facing.y = 0
        guard simd_length(facing) > 0.2 else { return }
        facing = simd_normalize(facing)
        let yaw = atan2(facing.x, facing.z)
        if let last = lastYaw {
            var step = yaw - last
            if step > .pi { step -= 2 * .pi }
            if step < -.pi { step += 2 * .pi }
            // A sudden flip is tracking mixing up front and back: that moment is passed over.
            guard abs(step) < 0.5 else { return }
            turned += step
        }
        lastYaw = yaw
        let hips = body.transform.columns.3.xyz
        let up = SIMD3<Float>(0, 1, 0), side = simd_normalize(simd_cross(up, facing))
        let space = simd_float4x4(SIMD4(side, 0), SIMD4(up, 0), SIMD4(facing, 0), SIMD4(hips, 1))
        let transform = space.inverse * frame.camera.transform
        let position = transform.columns.3.xyz
        let forward = -transform.columns.2.xyz
        var turningSpeed: Float = 0
        if let before = lastPose {
            let dt = Float(frame.timestamp - before.time)
            if dt > 0.001, dt < 0.5 { turningSpeed = acos(min(1, max(-1, simd_dot(forward, before.forward)))) / dt }
        }
        lastPose = (position, forward, frame.timestamp)
        let exposure = Float(min(max(frame.camera.exposureDuration, 1.0 / 120), 1.0 / 15))
        let turnLimit = min(0.5, 0.012 / exposure)
        tooFast = turningSpeed > turnLimit * 2.2
        if recording, !turnedRound, abs(turned) > 2 * .pi + 0.25, shots >= 30 {
            turnedRound = true
            ScanLog.add(String(format: "Turn on the spot: all the way round, %d pictures, body scale %.2f", shots, body.estimatedScaleFactor))
        }
        guard recording, !tooFast, shots < Self.maxShots, writing < 3, let folder else { return }
        if let last = lastShot {
            // A picture every 6 degrees the person turns (or 8 cm, should they step about).
            let moved = simd_distance(position, last.position)
            let swung = acos(min(1, max(-1, simd_dot(simd_normalize(position), simd_normalize(last.position)))))
            if moved < 0.08 && swung < 0.105 { return }
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
            if let jpeg = OwnCapture.personOnly(image, context: context) { try? jpeg.write(to: url) }
            Task { @MainActor in self.writing -= 1 }
        }
    }

    /// The picture with everything but the person (Vision's outline, kept generous for hair) made black. The picture
    /// is as the camera wrote it, on its side: Vision is told so (.right) and its outline is turned back.
    nonisolated static func personOnly(_ image: CIImage, context: CIContext) -> Data? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let w = cg.width, h = cg.height
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .right, options: [:])
        guard (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let mw = CVPixelBufferGetWidth(buffer), mh = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self), mw > 0, mh > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var kept = 0
        for y in 0..<h {
            for x in 0..<w {
                // The outline is upright when Vision turned it (taller than wide); the picture is on its side.
                let mx: Int, my: Int
                if mw < mh {
                    mx = min(mw - 1, (h - 1 - y) * mw / h)
                    my = min(mh - 1, x * mh / w)
                } else {
                    mx = min(mw - 1, x * mw / w)
                    my = min(mh - 1, y * mh / h)
                }
                if base[my * row + mx] > 40 { kept += 1; continue }
                let p = (y * w + x) * 4
                pixels[p] = 0; pixels[p + 1] = 0; pixels[p + 2] = 0
            }
        }
        // No person in the picture: it is left out.
        guard kept > w * h / 100 else { return nil }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let made = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return context.jpegRepresentation(of: CIImage(cgImage: made), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92])
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
