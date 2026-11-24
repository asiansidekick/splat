import ARKit
import CoreImage
import ImageIO
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
    /// Phil, 2026-11-22: "use front facing camera to scan a person so they can see themselves". The selfie camera has
    /// no body tracking, so Vision's 3D body pose of each picture says where the camera was from the body instead
    /// (and how tall the body is, which gives the size). Kept as camera place and the body's up, in Vision's body space.
    private(set) var selfieTurn = false
    static var selfieTurnSupported: Bool { ARFaceTrackingConfiguration.isSupported }
    private var visionPlaces: [String: (place: SIMD3<Float>, up: SIMD3<Float>)] = [:]
    private var lastKeptAt: TimeInterval = 0
    private var heights: [Float] = []

    func begin(_ folder: ScanFolder, turning: Bool = false, selfie: Bool = false) {
        selfieTurn = turning && selfie && Self.selfieTurnSupported
        self.turning = turning && (selfieTurn || Self.turningSupported)
        visionPlaces = [:]
        lastKeptAt = 0
        heights = []
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
        if selfieTurn {
            let configuration = ARFaceTrackingConfiguration()
            configuration.isLightEstimationEnabled = false
            if let best = ARFaceTrackingConfiguration.supportedVideoFormats.filter({ $0.framesPerSecond >= 30 })
                .max(by: { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }) {
                configuration.videoFormat = best
            }
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            ScanLog.add(String(format: "Turn on the spot: selfie camera %.0f x %.0f", configuration.videoFormat.imageResolution.width, configuration.videoFormat.imageResolution.height))
        } else if self.turning {
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
        var waited = 0
        while writing > 0, waited < 150 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        if selfieTurn { cameras = Self.upright(visionPlaces) }
        if selfieTurn, !heights.isEmpty {
            let sorted = heights.sorted()
            ScanLog.add(String(format: "Selfie turn: %d of %d pictures placed by Vision's body pose, body %.2f m tall", cameras.count, shots, sorted[sorted.count / 2]))
        }
        if let folder, !cameras.isEmpty, let data = try? JSONEncoder().encode(cameras) {
            try? data.write(to: folder.camerasFile)
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { self.handle(frame) }
    }

    private func handle(_ frame: ARFrame) {
        if selfieTurn {
            handleSelfieTurn(frame)
            return
        }
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

    /// Selfie camera, person turning: a picture every 0.45 s; Vision places each one from the body it sees.
    private func handleSelfieTurn(_ frame: ARFrame) {
        guard recording, shots < Self.maxShots, writing < 3, let folder, frame.timestamp - lastKeptAt >= 0.45 else { return }
        lastKeptAt = frame.timestamp
        shots += 1
        let name = String(format: "IMG_%04d.jpg", shots)
        let image = CIImage(cvPixelBuffer: frame.capturedImage).copyRendered()
        let url = folder.images.appendingPathComponent(name)
        let context = context
        writing += 1
        queue.async {
            let pose = OwnCapture.bodyPose(image, context: context)
            if let jpeg = OwnCapture.personOnly(image, context: context) { try? jpeg.write(to: url) }
            Task { @MainActor in
                self.writing -= 1
                guard let pose else {
                    self.seesBody = false
                    return
                }
                self.seesBody = true
                self.visionPlaces[name] = (pose.place, pose.up)
                self.heights.append(pose.height)
                // How far round: the camera's way round the body, about the body's up.
                let up = simd_normalize(pose.up)
                var flat = pose.place - up * simd_dot(pose.place, up)
                guard simd_length(flat) > 0.1 else { return }
                flat = simd_normalize(flat)
                let side = simd_normalize(simd_cross(up, abs(up.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)))
                let yaw = atan2(simd_dot(flat, simd_cross(up, side)), simd_dot(flat, side))
                if let last = self.lastYaw {
                    var step = yaw - last
                    if step > .pi { step -= 2 * .pi }
                    if step < -.pi { step += 2 * .pi }
                    if abs(step) < 1.2 { self.turned += step }
                }
                self.lastYaw = yaw
                if self.recording, !self.turnedRound, abs(self.turned) > 2 * .pi + 0.25, self.shots >= 30 {
                    self.turnedRound = true
                    ScanLog.add("Selfie turn: all the way round, \(self.shots) pictures")
                }
            }
        }
    }

    /// Vision's 3D body pose of a picture written on its side: where the camera was from the body's root (hips), the
    /// body's up (root to the middle of the head) in the same space, and the body's height.
    nonisolated static func bodyPose(_ image: CIImage, context: CIContext) -> (place: SIMD3<Float>, up: SIMD3<Float>, height: Float)? {
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        let request = VNDetectHumanBodyPose3DRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .right, options: [:])
        guard (try? handler.perform([request])) != nil, let body = request.results?.first,
              let head = try? body.recognizedPoint(.centerHead) else { return nil }
        let up = head.position.columns.3.xyz
        guard simd_length(up) > 0.1 else { return nil }
        return (body.cameraOriginMatrix.columns.3.xyz, up, body.bodyHeight)
    }

    /// Vision's camera places turned so the body's up (the average over all pictures) is +Y, for the model's fit.
    static func upright(_ places: [String: (place: SIMD3<Float>, up: SIMD3<Float>)]) -> [String: [Float]] {
        guard !places.isEmpty else { return [:] }
        let sum = places.values.reduce(SIMD3<Float>(0, 0, 0)) { $0 + simd_normalize($1.up) }
        guard simd_length(sum) > 1e-3 else { return [:] }
        let y = simd_normalize(sum)
        let x = simd_normalize(simd_cross(y, abs(y.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)))
        let z = simd_cross(x, y)
        var out: [String: [Float]] = [:]
        for (name, value) in places {
            let p = value.place
            out[name] = [simd_dot(p, x), simd_dot(p, y), simd_dot(p, z)]
        }
        return out
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
        var keep = [Bool](repeating: false, count: w * h)
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
                if base[my * row + mx] > 40 { kept += 1; keep[y * w + x] = true }
            }
        }
        // No person in the picture: it is left out.
        guard kept > w * h / 100 else { return nil }
        MaskFill.fill(&pixels, width: w, height: h, keep: keep)
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

    /// How the pictures were taken, chosen above the shutter.
    enum Kind: String {
        case object   // walking round an object
        case person   // walking round a person
        case turn     // phone still, person turning (back camera, body tracking)
        case selfie   // phone still, person turning in front of the selfie camera (places from Vision)
    }
    private var kindFile: URL { url.appendingPathComponent("scan-kind.txt") }
    /// nil for scans made before the kind was written down (before 2026-11-24).
    var kind: Kind? {
        (try? String(contentsOf: kindFile, encoding: .utf8)).flatMap { Kind(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    func setKind(_ kind: Kind) {
        try? kind.rawValue.write(to: kindFile, atomically: true, encoding: .utf8)
    }
}

/// Whether a Person scan really has a person in it (Phil, 2026-11-24: an object scanned with Person still chosen
/// was offered a skeleton). Vision looks for a person in up to 8 pictures spread through the scan.
enum ScanPersonCheck {
    static func picturesShowPerson(_ folder: ScanFolder) -> Bool {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder.images, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return false }
        let count = min(8, files.count)
        var seen = 0
        for i in 0..<count where showsPerson(files[i * files.count / count]) { seen += 1 }
        Diagnostics.log("Scan: person check, a person in \(seen) of \(count) pictures")
        // Walking round, high and low, some pictures show only part of the person: a third is enough.
        return seen * 3 >= count
    }

    /// A person taking up a good part of the picture. The camera writes pictures on their side (.right); a phone
    /// held sideways writes them upright, so that is tried too.
    static func showsPerson(_ url: URL) -> Bool {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return false }
        for orientation in [CGImagePropertyOrientation.right, .up] {
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
            try? handler.perform([request])
            let found = (request.results ?? []).contains { $0.confidence > 0.5 && max($0.boundingBox.width, $0.boundingBox.height) > 0.25 }
            if found { return true }
        }
        return false
    }
}

enum ScanBake {
    /// Whether the cameras hardly change height (a phone standing still while the person turns): such a fit can't
    /// tell up from down.
    static func flatRing(_ cameras: [String: [Float]]) -> Bool {
        let heights = cameras.values.compactMap { $0.count == 3 ? $0[1] : nil }
        guard heights.count >= 4 else { return false }
        var total: Float = 0
        for h in heights { total += h }
        let mean = total / Float(heights.count)
        var squares: Float = 0
        for h in heights { squares += (h - mean) * (h - mean) }
        let spread = (squares / Float(heights.count)).squareRoot()
        return spread < 0.1
    }

    /// For a model of a standing person: false when it is wider round its bottom fifth than round its top fifth
    /// (ankles below shoulders and arms the right way up), nil when it can't be told.
    @MainActor static func standsUpright(_ url: URL) -> Bool? {
        guard let (mesh, _) = ScanCharacterMaker.read(url), mesh.positions.count > 100 else { return nil }
        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        for p in mesh.positions { low = min(low, p.y); high = max(high, p.y) }
        let tall = high - low
        guard tall > 0.3 else { return nil }
        func width(_ from: Float, _ to: Float) -> Float {
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for p in mesh.positions where p.y >= low + from * tall && p.y <= low + to * tall {
                lo = simd_min(lo, SIMD2(p.x, p.z)); hi = simd_max(hi, SIMD2(p.x, p.z))
            }
            guard lo.x <= hi.x else { return 0 }
            let size: SIMD2<Float> = hi - lo
            return max(size.x, size.y)
        }
        let top = width(0.7, 0.85), bottom = width(0.15, 0.3)
        ScanLog.add(String(format: "Standing check: %.2f m wide near the top, %.2f m near the bottom", top, bottom))
        guard top > 0, bottom > 0, abs(top - bottom) > 0.05 else { return nil }
        return top > bottom
    }

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


/// Phil's 1411 tests: black smears down the arms, sides and neck of scanned people and heads. The builder colours each
/// part from a picture that saw it, and a part just outside a picture's person outline came out black. Outside the
/// outline, a band of about 32 pixels is now filled with the person's own nearest colours, and only beyond it black.
/// Gaps between the legs, or between an arm and the body, stay black (Phil, 1414: filled in, they joined the limbs
/// into the body and the people came out like starfish): anywhere with the person within `gap` pixels on both sides,
/// across or along the picture.
enum MaskFill {
    static func fill(_ pixels: inout [UInt8], width w: Int, height h: Int, keep: [Bool], band: Int = 32, gap: Int = 200) {
        var between = [Bool](repeating: false, count: w * h)
        // Across: the nearest person to the left and to the right of each pixel.
        var lastLeft = [Int](repeating: -1_000_000, count: w)
        for y in 0..<h {
            var last = -1_000_000
            for x in 0..<w {
                if keep[y * w + x] { last = x } else { lastLeft[x] = last }
            }
            last = 1_000_000
            for x in stride(from: w - 1, through: 0, by: -1) {
                if keep[y * w + x] { last = x; continue }
                if x - lastLeft[x] < gap && last - x < gap { between[y * w + x] = true }
            }
        }
        // Along: the nearest person above and below.
        var above = [Int](repeating: -1_000_000, count: w * h)
        var lastUp = [Int](repeating: -1_000_000, count: w)
        for y in 0..<h {
            for x in 0..<w {
                if keep[y * w + x] { lastUp[x] = y } else { above[y * w + x] = lastUp[x] }
            }
        }
        var lastDown = [Int](repeating: 1_000_000, count: w)
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in 0..<w {
                let i = y * w + x
                if keep[i] { lastDown[x] = y; continue }
                if y - above[i] < gap && lastDown[x] - y < gap { between[i] = true }
            }
        }
        let step = 4
        let cw = (w + step - 1) / step, ch = (h + step - 1) / step
        var colour = [SIMD3<Float>](repeating: .zero, count: cw * ch)
        var has = [Bool](repeating: false, count: cw * ch)
        var counts = [Int](repeating: 0, count: cw * ch)
        for y in 0..<h {
            for x in 0..<w where keep[y * w + x] {
                let c = (y / step) * cw + x / step, p = (y * w + x) * 4
                colour[c] += SIMD3(Float(pixels[p]), Float(pixels[p + 1]), Float(pixels[p + 2]))
                counts[c] += 1
            }
        }
        for c in 0..<(cw * ch) where counts[c] > 0 {
            colour[c] /= Float(counts[c])
            has[c] = true
        }
        // Grown outward a cell at a time, each new cell the average of its filled neighbours.
        for _ in 0..<max(1, band / step) {
            var grown: [(Int, SIMD3<Float>)] = []
            for cy in 0..<ch {
                for cx in 0..<cw where !has[cy * cw + cx] {
                    var sum = SIMD3<Float>(0, 0, 0)
                    var n: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = cx + dx, ny = cy + dy
                            guard nx >= 0, ny >= 0, nx < cw, ny < ch, has[ny * cw + nx] else { continue }
                            sum += colour[ny * cw + nx]
                            n += 1
                        }
                    }
                    if n > 0 { grown.append((cy * cw + cx, sum / n)) }
                }
            }
            if grown.isEmpty { break }
            for (c, value) in grown { colour[c] = value; has[c] = true }
        }
        for y in 0..<h {
            for x in 0..<w where !keep[y * w + x] {
                let c = (y / step) * cw + x / step, p = (y * w + x) * 4
                let value = has[c] && !between[y * w + x] ? colour[c] : SIMD3<Float>(0, 0, 0)
                pixels[p] = UInt8(min(255, max(0, value.x))); pixels[p + 1] = UInt8(min(255, max(0, value.y))); pixels[p + 2] = UInt8(min(255, max(0, value.z)))
            }
        }
    }
}
