import ARKit
import CoreImage
import RealityKit
import SceneKit
import UIKit
import Vision
import os
import simd

// Scanning just a head, to put on any character (Phil, 2026-11-22: "Let's streamline the pipeline to scan a head
// either in selfie mode with the front facing camera or manually scanning an actor's head and have that as an option
// to place on any character").
//
// Selfie: the phone is held still at arm's length and the head turns in front of it. ARKit's face tracking says where
// the head is in every picture, so each picture can be cut down to just the head (person outline from Vision, inside
// the space a head can take). With the room blacked out, the head turning in front of a still camera looks to the model
// builder like a camera going round a head.
// Walking round: someone walks round the actor with the back camera, keeping the head in the middle. Where the lines of
// sight meet is the middle of the head; the picture that sees the face most square on says which way it faces.
// Either way the model builder makes the head from the cut-down pictures, its camera places are fitted to the known
// ones (real size, upright, facing +Z), and the head is cut at the neck like a posable person's head (ScanRig).

/// One scanned head: Documents/Heads/<name>/. The finished head is ScanRig.headFile with its "scanned-head-…" pictures,
/// the same files a character with a scanned head keeps beside it, so they are simply copied there.
struct HeadFolder: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    private var titleFile: URL { url.appendingPathComponent("title.txt") }
    var title: String {
        let given = (try? String(contentsOf: titleFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return given.isEmpty ? name : given
    }
    func rename(to text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == name { try? FileManager.default.removeItem(at: titleFile) }
        else { try? clean.write(to: titleFile, atomically: true, encoding: .utf8) }
    }
    var shotsFolder: URL { url.appendingPathComponent("Shots", isDirectory: true) }
    var maskedFolder: URL { url.appendingPathComponent("Masked", isDirectory: true) }
    var checkpoint: URL { url.appendingPathComponent("Checkpoint", isDirectory: true) }
    var captureFile: URL { url.appendingPathComponent("capture.json") }
    /// The whole head in head space, before the neck cut and turn (HeadMath), for the check screen.
    var wholeFile: URL { url.appendingPathComponent("whole.bin") }
    var headFile: URL { url.appendingPathComponent(ScanRig.headFile) }
    var thumbnail: URL { url.appendingPathComponent("thumbnail.jpg") }
    var settingsFile: URL { url.appendingPathComponent("cut.json") }
    var hasHead: Bool { FileManager.default.fileExists(atPath: headFile.path) }
    var created: Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }

    /// The files a character needs for this head: the head itself and its pictures.
    var headFiles: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0 == ScanRig.headFile || $0.hasPrefix("scanned-head-") }.map { url.appendingPathComponent($0) }
    }

    func loadHead() -> BodyMesh? { (try? Data(contentsOf: headFile)).flatMap { ScanRig.head(from: $0) } }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Heads", isDirectory: true)
    }

    static func new() throws -> HeadFolder {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = HeadFolder(url: root.appendingPathComponent("Head \(f.string(from: Date()))", isDirectory: true))
        try FileManager.default.createDirectory(at: folder.shotsFolder, withIntermediateDirectories: true)
        return folder
    }

    /// Finished heads, newest first.
    static func all() -> [HeadFolder] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter(\.hasDirectoryPath).map { HeadFolder(url: $0) }.filter(\.hasHead).sorted { $0.created > $1.created }
    }

    /// Scans abandoned before a head was made. One that may still be building (the scanner was closed while it
    /// built) is left for two hours.
    static func tidy() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        for url in urls where url.hasDirectoryPath {
            let folder = HeadFolder(url: url)
            guard !folder.hasHead else { continue }
            let building = FileManager.default.fileExists(atPath: folder.captureFile.path) && Date().timeIntervalSince(folder.created) < 7200
            if !building { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// One picture of a head scan and what was known when it was taken.
struct HeadShot: Codable {
    var file: String
    /// Where the camera was, column major: in head space for a selfie, in the room when walking round.
    var camera: [Float]
    var fx: Float, fy: Float, cx: Float, cy: Float
    var width: Int, height: Int
    /// Vision's person outline, kept as "<file>.mask" (width, height, then one byte a pixel).
    var mask: String?
    /// A face Vision found: its middle in the picture's own pixels (as the camera wrote it, on its side), and how far
    /// it is turned (radians, 0 square on).
    var faceCentre: [Float]?
    var faceYaw: Float?
    var faceSize: Float?
    /// False for a selfie picture of the back of the head, taken with the face out of sight: its camera is only where
    /// the phone last saw the face (good enough to cut the head out, not to place the picture). Nil means placed.
    var posed: Bool?
    var isPosed: Bool { posed ?? true }
}

struct HeadCaptureRecord: Codable {
    var selfie: Bool
    var shots: [HeadShot]
    /// Selfie: the chin's height in head space, from ARKit's face shape.
    var chin: Float?
    /// Selfie: both eyes (left, then right) and the tip of the nose in head space, from ARKit's face shape. Both eyes'
    /// colour is taken from one picture so they look the same way (Phil, 2026-11-22).
    var eyes: [[Float]]?
    var nose: [Float]?
}

/// What the check screen changed: the neck cut's height and the head's turn (radians about up).
struct HeadCutSettings: Codable {
    var cut: Float
    var turn: Float
    /// The chin's height in head space (heads made before 2026-11-22 afternoon have none).
    var chin: Float?
}

/// What a character needs to know of a scanned head beyond its shape: how far its chin is above its neck cut
/// (metres), so the head is lined up and sized by its face (Phil's 1408 test: lined up by the neck it sat low and
/// too big). Kept beside the head's files as "scanned-head-info.json" so it travels with them.
struct HeadInfo: Codable {
    var chin: Float
    static let file = "scanned-head-info.json"
    static func load(_ folder: URL) -> HeadInfo? {
        (try? Data(contentsOf: folder.appendingPathComponent(file))).flatMap { try? JSONDecoder().decode(HeadInfo.self, from: $0) }
    }
}

// MARK: Taking the pictures

@MainActor
final class HeadCapture: NSObject, ObservableObject, ARSessionDelegate {
    static let slots = 24
    static var selfieSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    let session = ARSession()
    @Published private(set) var shots = 0
    @Published private(set) var lit = Set<Int>()
    @Published private(set) var hint = ""
    @Published var recording = false
    /// The ring is full: the shutter's next step is to build.
    @Published private(set) var complete = false
    /// Selfie, once the face ring is full: the phone stands still while the person turns slowly all the way round, so
    /// the back of the head is seen too (Phil, 2026-11-22). Pictures keep coming while the face is out of sight, and the
    /// scan is complete when the face comes back square on.
    @Published private(set) var backOfHead = false
    private(set) var selfie = true
    static let frontShots = 70, backShots = 36
    var maxShots: Int { selfie ? Self.frontShots + Self.backShots : 90 }
    private var lastFacePlace: simd_float4x4?
    private var lastBackTime: TimeInterval = 0
    private var awayFrames = 0
    private var backKept = 0

    private var folder: HeadFolder?
    private var record = HeadCaptureRecord(selfie: true, shots: [])
    private var keptDirections: [SIMD3<Float>] = []
    private var keptPlaces: [SIMD3<Float>] = []
    private var keptForwards: [SIMD3<Float>] = []
    private var lastLook: (direction: SIMD3<Float>, position: SIMD3<Float>, time: TimeInterval)?
    private var chins: [Float] = []
    private var eyesSeen: [[SIMD3<Float>]] = []
    private var noses: [SIMD3<Float>] = []
    private var frameCount = 0
    private var writing = 0
    private let queue = DispatchQueue(label: "head-pictures", qos: .userInitiated)
    private let context = CIContext()

    func begin(_ folder: HeadFolder, selfie: Bool) {
        self.folder = folder
        self.selfie = selfie
        record = HeadCaptureRecord(selfie: selfie, shots: [])
        keptDirections = []
        keptPlaces = []
        keptForwards = []
        lastLook = nil
        chins = []
        eyesSeen = []
        noses = []
        backOfHead = false
        lastFacePlace = nil
        lastBackTime = 0
        awayFrames = 0
        backKept = 0
        shots = 0
        lit = []
        complete = false
        recording = false
        hint = ""
        session.delegate = self
        if selfie {
            let configuration = ARFaceTrackingConfiguration()
            configuration.maximumNumberOfTrackedFaces = 1
            configuration.isLightEstimationEnabled = false
            // The sharpest pictures the front camera gives at 30 a second or more.
            if let best = ARFaceTrackingConfiguration.supportedVideoFormats.filter({ $0.framesPerSecond >= 30 })
                .max(by: { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }) {
                configuration.videoFormat = best
            }
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            Diagnostics.log(String(format: "Head scan: selfie camera %.0f x %.0f", configuration.videoFormat.imageResolution.width, configuration.videoFormat.imageResolution.height))
        } else {
            session.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
            Diagnostics.log("Head scan: back camera, walking round")
        }
    }

    /// Stops the camera and writes down what each picture saw. Returns once every picture is on disk.
    func end() async -> Int {
        recording = false
        session.pause()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        // The last pictures' notes (outline, face) come back on the main actor.
        var waited = 0
        while writing > 0, waited < 150 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 1
        }
        let sorted = chins.sorted()
        if !sorted.isEmpty { record.chin = sorted[sorted.count / 2] }
        func middle(_ points: [SIMD3<Float>]) -> [Float] {
            (0..<3).map { k in let v = points.map { $0[k] }.sorted(); return v[v.count / 2] }
        }
        if !eyesSeen.isEmpty {
            record.eyes = [middle(eyesSeen.map { $0[0] }), middle(eyesSeen.map { $0[1] })]
        }
        if !noses.isEmpty { record.nose = middle(noses) }
        if let folder, let data = try? JSONEncoder().encode(record) { try? data.write(to: folder.captureFile) }
        return record.shots.count
    }

    func stop() {
        recording = false
        session.pause()
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { self.handle(frame) }
    }

    private func handle(_ frame: ARFrame) {
        frameCount += 1
        let camera = frame.camera.transform
        let place: simd_float4x4
        let direction: SIMD3<Float>
        if selfie {
            guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
                lastLook = nil
                // Only once the face was last seen turning away (not while the phone is being stood up).
                guard backOfHead, recording, let folder, let last = lastFacePlace, simd_normalize(last.columns.3.xyz).z < 0.8 else {
                    setHint("Face the camera")
                    return
                }
                // The back of the head: a picture every 0.4 s while the face is out of sight.
                setHint("")
                awayFrames += 1
                if frame.timestamp - lastBackTime >= 0.4, writing < 3, backKept < Self.backShots {
                    lastBackTime = frame.timestamp
                    backKept += 1
                    keep(frame, place: last, direction: simd_normalize(last.columns.3.xyz), folder: folder, posed: false)
                }
                return
            }
            place = face.transform.inverse * camera
            direction = simd_normalize(place.columns.3.xyz)
            lastFacePlace = place
            // Back round to face the phone after turning away for a while: done.
            if backOfHead, recording, !complete, awayFrames > 45, backKept >= 6, direction.z > 0.9 {
                complete = true
                Haptics.success()
                Diagnostics.log("Head scan: turned all the way round, \(backKept) pictures of the back of the head")
            }
            if frameCount % 6 == 0, let low = face.geometry.vertices.map(\.y).min() { chins.append(low) }
            if frameCount % 6 == 3 {
                eyesSeen.append([face.leftEyeTransform.columns.3.xyz, face.rightEyeTransform.columns.3.xyz])
                if let tip = face.geometry.vertices.filter({ abs($0.x) < 0.02 }).max(by: { $0.z < $1.z }) { noses.append(tip) }
            }
        } else {
            guard case .normal = frame.camera.trackingState else {
                setHint("Move slowly")
                lastLook = nil
                return
            }
            place = camera
            direction = -camera.columns.2.xyz
        }
        // How fast the view is turning: pictures taken while turning fast are blurred.
        let position = place.columns.3.xyz
        var turning: Float = 0, moving: Float = 0
        if let before = lastLook {
            let dt = Float(frame.timestamp - before.time)
            if dt > 0.001, dt < 0.5 {
                turning = acos(min(1, max(-1, simd_dot(direction, before.direction)))) / dt
                moving = simd_distance(position, before.position) / dt
            }
        }
        lastLook = (direction, position, frame.timestamp)
        let exposure = Float(min(max(frame.camera.exposureDuration, 1.0 / 120), 1.0 / 15))
        let turnLimit = min(0.5, 0.012 / exposure)
        let fast = selfie ? turning > turnLimit * 1.6 : (turning > turnLimit * 2 || moving > 0.6)
        guard recording, let folder else {
            setHint("")
            return
        }
        setHint(fast ? "Slower" : "")
        guard !fast, writing < 3, record.shots.count - backKept < (selfie ? Self.frontShots : maxShots) else { return }
        // A new picture once the view has changed enough: 5° round a selfie, 7° or 6 cm walking round.
        let key = selfie ? direction : place.columns.3.xyz
        if selfie {
            guard HeadMath.nearestAngle(direction, keptDirections) >= 5 * .pi / 180 else { return }
        } else {
            let turned = HeadMath.nearestAngle(direction, keptForwards)
            let moved = keptPlaces.map { simd_distance($0, key) }.min() ?? .greatestFiniteMagnitude
            guard turned >= 7 * .pi / 180 || moved >= 0.06 else { return }
        }
        keep(frame, place: place, direction: direction, folder: folder, posed: true)
    }

    private func setHint(_ text: String) {
        if hint != text { hint = text }
    }

    /// A placed picture: its view kept, and the ring lit.
    private func remember(place: simd_float4x4, direction: SIMD3<Float>) {
        keptDirections.append(direction)
        keptPlaces.append(place.columns.3.xyz)
        keptForwards.append(direction)
        // The ring: a selfie by which way the head has turned, walking round by where round the head the phone is.
        var slot: Int?
        if selfie {
            slot = HeadMath.selfieSlot(place.columns.3.xyz, slots: Self.slots)
        } else if let middle = middleSoFar() {
            // Every picture so far, placed round the head now its middle is better known.
            var all = Set<Int>()
            for p in keptPlaces { if let s = HeadMath.roundSlot(camera: p, centre: middle, slots: Self.slots) { all.insert(s) } }
            if all.count > lit.count { Haptics.tap() }
            lit = all
        }
        if let slot, !lit.contains(slot) {
            lit.insert(slot)
            Haptics.tap()
        }
        guard lit.count >= Self.slots, !complete, !backOfHead, shots >= (selfie ? 15 : 30) else { return }
        Haptics.success()
        if selfie {
            // The face is done; now the back of the head.
            backOfHead = true
            awayFrames = 0
            Diagnostics.log("Head scan: face ring full (\(shots) pictures), now the back of the head")
        } else {
            complete = true
        }
    }

    private func keep(_ frame: ARFrame, place: simd_float4x4, direction: SIMD3<Float>, folder: HeadFolder, posed: Bool) {
        let number = record.shots.count + 1
        let name = String(format: "HEAD_%03d.jpg", number)
        let size = frame.camera.imageResolution
        let k = frame.camera.intrinsics
        record.shots.append(HeadShot(file: name, camera: flatten(place), fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                                     width: Int(size.width), height: Int(size.height), posed: posed ? nil : false))
        shots = record.shots.count
        if posed {
            remember(place: place, direction: direction)
        } else if backKept % 4 == 0 {
            Haptics.tap()
        }
        let image = CIImage(cvPixelBuffer: frame.capturedImage).copyRendered()
        let url = folder.shotsFolder.appendingPathComponent(name)
        let context = context
        let index = number - 1
        writing += 1
        queue.async { [weak self] in
            if let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                     options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]) {
                try? jpeg.write(to: url)
            }
            let found = HeadVision.read(image, context: context, maskTo: url.appendingPathExtension("mask"))
            Task { @MainActor in
                guard let self else { return }
                self.writing -= 1
                guard index < self.record.shots.count else { return }
                if found.mask { self.record.shots[index].mask = name + ".mask" }
                self.record.shots[index].faceCentre = found.faceCentre.map { [$0.x, $0.y] }
                self.record.shots[index].faceYaw = found.faceYaw
                self.record.shots[index].faceSize = found.faceSize
            }
        }
    }

    /// Walking round: the middle of the head from the lines of sight so far.
    private func middleSoFar() -> SIMD3<Float>? {
        guard keptPlaces.count >= 4, let middle = HeadMath.raysMeet(keptPlaces, keptForwards) else {
            // Until then, half a metre in front of the first picture.
            guard let first = keptPlaces.first, let look = keptForwards.first else { return nil }
            return first + look * 0.5
        }
        // A middle far from the phone means the lines barely crossed yet.
        guard let first = keptPlaces.first, simd_distance(middle, first) < 2 else { return keptPlaces[0] + keptForwards[0] * 0.5 }
        return middle
    }
}

/// Vision's look at a picture: the person's outline, and a face.
enum HeadVision {
    struct Found {
        var mask = false
        var faceCentre: SIMD2<Float>?
        var faceYaw: Float?
        var faceSize: Float?
    }

    /// The picture is as the camera wrote it (on its side): Vision is told so (.right), and what it gives back is turned
    /// back into the picture's own pixels.
    static func read(_ image: CIImage, context: CIContext, maskTo url: URL) -> Found {
        var out = Found()
        guard let cg = context.createCGImage(image, from: image.extent) else { return out }
        let width = Float(cg.width), height = Float(cg.height)
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .right, options: [:])
        do { try handler.perform([segmentation, faces]) } catch { return out }
        if let buffer = segmentation.results?.first?.pixelBuffer {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
            if let base = CVPixelBufferGetBaseAddress(buffer), w > 0, h > 0 {
                var data = Data()
                var dims = [UInt32(w), UInt32(h)]
                data.append(Data(bytes: &dims, count: 8))
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { data.append(bytes + y * row, count: w) }
                out.mask = (try? data.write(to: url)) != nil
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        if let face = (faces.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            // Upright, x across and y up from the bottom; the picture itself is on its side (.right).
            let b = face.boundingBox
            out.faceCentre = SIMD2(Float(1 - b.midY) * width, Float(1 - b.midX) * height)
            out.faceYaw = face.yaw.map { Float(truncating: $0) }
            out.faceSize = Float(b.width * b.height)
        }
        return out
    }

    /// A saved person outline: width, height and its bytes.
    static func loadMask(_ url: URL) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let data = try? Data(contentsOf: url), data.count > 8 else { return nil }
        let w = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
        let h = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
        guard w > 0, h > 0, data.count >= 8 + w * h else { return nil }
        return (w, h, [UInt8](data[8..<(8 + w * h)]))
    }
}

// MARK: Building the head

enum HeadBuilder {
    enum Failure: Error {
        case tooFew(Int), lost, noModel, noFit, nothingLeft, unsupported
        var words: String {
            switch self {
            case .tooFew(let n): return "Only \(n) pictures were kept, too few for a head. Turn more slowly, all the way each side."
            case .lost: return "The head couldn't be found in the pictures. Keep the head in the middle of the picture."
            case .noModel: return "The builder made no model from these pictures. Try again in even light, turning more slowly."
            case .noFit: return "The head's size and turn couldn't be worked out. Try again, turning more slowly."
            case .nothingLeft: return "Nothing was left once the head was cut at the neck. Try again with the whole head in the picture."
            case .unsupported: return DeviceSupport.apology("building 3D heads")
            }
        }
    }

    /// Where each picture's camera was in head space, and the record. Walking round, head space comes from where the
    /// lines of sight meet and which picture sees the face square on.
    static func headSpace(_ record: HeadCaptureRecord) -> [simd_float4x4]? {
        let cameras = record.shots.map { matrix4($0.camera) }
        guard !record.selfie else { return cameras }
        let places = cameras.map { $0.columns.3.xyz }, looks = cameras.map { -$0.columns.2.xyz }
        guard let middle = HeadMath.raysMeet(places, looks) else { return nil }
        let reach = places.map { simd_distance($0, middle) }.sorted()
        let typical: Float = reach.isEmpty ? 0 : reach[reach.count / 2]
        guard typical > 0.12, typical < 2.5 else {
            Diagnostics.log(String(format: "Head scan: the lines of sight meet %.2f m from the phone, not a head", typical))
            return nil
        }
        // The face: the picture whose face is most square on (a bigger face breaking ties); else the first picture.
        let square = record.shots.indices.filter { record.shots[$0].faceYaw != nil || record.shots[$0].faceSize != nil }
            .min { a, b in
                let ya = abs(record.shots[a].faceYaw ?? 0.6), yb = abs(record.shots[b].faceYaw ?? 0.6)
                if abs(ya - yb) > 0.05 { return ya < yb }
                return (record.shots[a].faceSize ?? 0) > (record.shots[b].faceSize ?? 0)
            } ?? 0
        let head = HeadMath.frame(centre: middle, towards: places[square])
        Diagnostics.log(String(format: "Head scan: head middle %.2f m from the phone, face from picture %d (yaw %.0f°)",
                               typical, square + 1, (record.shots[square].faceYaw ?? 0) * 180 / .pi))
        let back = head.inverse
        return cameras.map { back * $0 }
    }

    /// Phil, 2026-11-22: both eyes must look the same way. They are coloured again from the one picture that saw the
    /// face most square on (see HeadEyes). `builder` gives where the model builder put a picture's camera in head space
    /// (place, turn): it agrees with the head's shape better than the phone's own record, so it is used when its way
    /// round matches the phone's.
    static func matchEyes(_ head: BodyMesh, pictures: inout [String: UIImage], folder: HeadFolder, record: HeadCaptureRecord,
                          cameras: [simd_float4x4], flip: Int, builder: (String) -> (SIMD3<Float>, simd_quatf)?) {
        guard head.uvs != nil, cameras.count == record.shots.count else { return }
        var best = -1
        var bestFacing: Float = -1
        for (i, c) in cameras.enumerated() where record.shots[i].isPosed {
            let p = c.columns.3.xyz
            guard simd_length(p) > 0.05 else { continue }
            let facing = simd_normalize(p).z
            if facing > bestFacing { bestFacing = facing; best = i }
        }
        guard best >= 0, bestFacing > 0.85 else {
            Diagnostics.log("Head scan: no picture square on to the face, eyes left as built")
            return
        }
        let shot = record.shots[best]
        guard let photo = UIImage(contentsOfFile: folder.shotsFolder.appendingPathComponent(shot.file).path)?.cgImage else { return }

        // Where the eyes are on this head.
        let chin = HeadMath.chin(head.positions) ?? record.chin ?? -0.11
        let tip = HeadEyes.noseTip(head.positions, chin: chin)
        var eyes: [SIMD3<Float>] = []
        var from = "guessed from the nose"
        if let seen = record.eyes, seen.count == 2, seen.allSatisfy({ $0.count == 3 }) {
            eyes = seen.map { SIMD3($0[0], $0[1], $0[2]) }
            from = "from the face tracking"
            // Moved by however far the built head's nose is from the tracked one (the builder's fit can be a few cm out).
            if let tip, let n = record.nose, n.count == 3 {
                let shift = tip - SIMD3(n[0], n[1], n[2])
                if simd_length(shift) < 0.03 {
                    eyes = eyes.map { $0 + shift }
                    from += String(format: ", moved %.1f cm to the built nose", simd_length(shift) * 100)
                }
            }
        } else if let guessed = HeadEyes.guess(head.positions, chin: chin) {
            eyes = guessed
        }
        guard eyes.count == 2 else {
            Diagnostics.log("Head scan: eyes not found, left as built")
            return
        }

        // The camera as the builder placed it, when it turns the same way as the phone's (within 25 degrees).
        var camera = cameras[best]
        var useFlip = flip
        var which = "phone's place"
        if let (place, q) = builder(shot.file) {
            let r = simd_float3x3(q)
            let known = simd_float3x3(simd_normalize(camera.columns.0.xyz), simd_normalize(camera.columns.1.xyz), simd_normalize(camera.columns.2.xyz))
            func apart(_ a: simd_float3x3) -> Float {
                let trace = simd_dot(a.columns.0, known.columns.0) + simd_dot(a.columns.1, known.columns.1) + simd_dot(a.columns.2, known.columns.2)
                return acos(min(1, max(-1, (trace - 1) / 2)))
            }
            // Some builders look down +Z with Y down; ARKit looks down -Z with Y up.
            let plain = r, upturned = simd_float3x3(r.columns.0, -r.columns.1, -r.columns.2)
            let a = apart(plain), b = apart(upturned)
            let pick = a <= b ? plain : upturned
            if min(a, b) < 25 * .pi / 180 {
                camera = simd_float4x4(SIMD4(pick.columns.0, 0), SIMD4(pick.columns.1, 0), SIMD4(pick.columns.2, 0), SIMD4(place, 1))
                useFlip = 0
                which = String(format: "builder's place, %.0f degrees and %.1f cm from the phone's", min(a, b) * 180 / .pi,
                               simd_distance(place, cameras[best].columns.3.xyz) * 100)
            } else {
                which = String(format: "phone's place (builder's turned %.0f degrees away)", min(a, b) * 180 / .pi)
            }
        }
        let changed = HeadEyes.match(head, pictures: &pictures, eyes: eyes, photo: photo, camera: camera, shot: shot, flip: useFlip)
        Diagnostics.log(String(format: "Head scan: eyes (%@) coloured from picture %d, %.0f degrees off square on, %@; %d picture pixels changed",
                               from, best, acos(min(1, bestFacing)) * 180 / .pi, which, changed))
    }

    /// Selfie pictures from ARKit's front camera: which way round its picture is against ARKit's own sums is checked
    /// against where Vision saw the face (0 as is, 1 across, 2 up and down, 3 both).
    static func flip(_ record: HeadCaptureRecord, _ cameras: [simd_float4x4]) -> Int {
        var error = [Float](repeating: 0, count: 4)
        var counted = 0
        for (i, shot) in record.shots.enumerated() {
            guard shot.isPosed, let face = shot.faceCentre, face.count == 2,
                  let nose = HeadMath.project(SIMD3(0, 0.0, 0.06), camera: cameras[i], fx: shot.fx, fy: shot.fy, cx: shot.cx, cy: shot.cy) else { continue }
            let f = SIMD2(face[0], face[1]), w = Float(shot.width), h = Float(shot.height)
            let options = [nose, SIMD2(w - nose.x, nose.y), SIMD2(nose.x, h - nose.y), SIMD2(w - nose.x, h - nose.y)]
            for k in 0..<4 { error[k] += simd_distance(options[k], f) }
            counted += 1
        }
        guard counted > 0 else { return 0 }
        let best = error.indices.min { error[$0] < error[$1] } ?? 0
        Diagnostics.log(String(format: "Head scan: picture way round %d from %d faces (off by %.0f px, as is %.0f px)", best, counted, error[best] / Float(counted), error[0] / Float(counted)))
        return best
    }

    /// Writes each picture with everything but the head blacked out, into the Masked folder. Returns how many.
    static func cutOut(_ folder: HeadFolder, _ record: HeadCaptureRecord, cameras: [simd_float4x4], flip: Int) -> Int {
        let manager = FileManager.default
        try? manager.removeItem(at: folder.maskedFolder)
        try? manager.createDirectory(at: folder.maskedFolder, withIntermediateDirectories: true)
        let floor = (record.chin ?? -0.11) - 0.07
        let shell = HeadMath.headShell(floor: floor)
        var made = 0
        for (i, shot) in record.shots.enumerated() {
            autoreleasepool {
                guard let source = UIImage(contentsOfFile: folder.shotsFolder.appendingPathComponent(shot.file).path)?.cgImage else { return }
                let w = source.width, h = source.height
                let sx = Float(w) / Float(max(1, shot.width)), sy = Float(h) / Float(max(1, shot.height))
                var outline: [SIMD2<Float>] = []
                for p in shell {
                    guard var q = HeadMath.project(p, camera: cameras[i], fx: shot.fx, fy: shot.fy, cx: shot.cx, cy: shot.cy) else { continue }
                    if flip & 1 != 0 { q.x = Float(shot.width) - q.x }
                    if flip & 2 != 0 { q.y = Float(shot.height) - q.y }
                    outline.append(SIMD2(q.x * sx, q.y * sy))
                }
                let hull = HeadMath.hull(outline)
                guard hull.count >= 3 else { return }
                let rows = HeadMath.rows(of: hull, width: w, height: h)
                let person = shot.mask.flatMap { HeadVision.loadMask(folder.shotsFolder.appendingPathComponent($0)) }
                // The picture drawn into memory, then every pixel outside the head made black.
                let bytesPerRow = w * 4
                var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
                let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
                    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                    ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
                    return true
                }
                guard drawn else { return }
                var kept = 0
                for y in 0..<h {
                    let (from, to) = rows[y]
                    for x in 0..<w {
                        var keep = x >= from && x <= to
                        if keep, let person {
                            // The outline is upright when Vision turned it (taller than wide); the picture is on its side.
                            let mx: Int, my: Int
                            if person.width < person.height {
                                mx = min(person.width - 1, (h - 1 - y) * person.width / h)
                                my = min(person.height - 1, x * person.height / w)
                            } else {
                                mx = min(person.width - 1, x * person.width / w)
                                my = min(person.height - 1, y * person.height / h)
                            }
                            keep = person.bytes[my * person.width + mx] > 60
                        }
                        if keep { kept += 1 } else {
                            let p = y * bytesPerRow + x * 4
                            pixels[p] = 0; pixels[p + 1] = 0; pixels[p + 2] = 0
                        }
                    }
                }
                guard kept > w * h / 200 else { return }
                let data = Data(pixels)
                guard let provider = CGDataProvider(data: data as CFData),
                      let cut = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                      let jpeg = UIImage(cgImage: cut).jpegData(compressionQuality: 0.92) else { return }
                if (try? jpeg.write(to: folder.maskedFolder.appendingPathComponent(shot.file))) != nil { made += 1 }
            }
        }
        return made
    }

    /// The whole build: cut the pictures down, build, fit, cut at the neck, save. `progress` gets 0 to 1.
    static func build(_ folder: HeadFolder, progress: @escaping @Sendable (Double) -> Void) async throws {
        let started = Date()
        guard PhotogrammetrySession.isSupported else { throw Failure.unsupported }
        guard let data = try? Data(contentsOf: folder.captureFile), let record = try? JSONDecoder().decode(HeadCaptureRecord.self, from: data) else { throw Failure.tooFew(0) }
        guard record.shots.count >= 12 else { throw Failure.tooFew(record.shots.count) }
        guard let cameras = headSpace(record) else { throw Failure.lost }
        let flip = record.selfie ? Self.flip(record, cameras) : 0
        let made = await Task.detached(priority: .userInitiated) { HeadBuilder.cutOut(folder, record, cameras: cameras, flip: flip) }.value
        Diagnostics.log("Head scan: \(made) of \(record.shots.count) pictures cut down to the head (\(record.selfie ? "selfie" : "walking round"), \(record.shots.filter { $0.mask != nil }.count) with a person outline, \(record.shots.filter { !$0.isPosed }.count) of the back of the head)")
        guard made >= 12 else { throw Failure.tooFew(made) }
        progress(0.02)

        Diagnostics.log(String(format: "Head scan: memory before building, %.0f MB free", Double(os_proc_available_memory()) / 1_000_000))
        var config = PhotogrammetrySession.Configuration()
        try? FileManager.default.removeItem(at: folder.checkpoint)
        try? FileManager.default.createDirectory(at: folder.checkpoint, withIntermediateDirectories: true)
        config.checkpointDirectory = folder.checkpoint
        let session = try PhotogrammetrySession(input: folder.maskedFolder, configuration: config)
        let raw = folder.url.appendingPathComponent("raw.usdz")
        try? FileManager.default.removeItem(at: raw)
        var builderPlaces: [String: SIMD3<Float>] = [:]
        var builderTurns: [String: simd_quatf] = [:]
        try await withTaskCancellationHandler {
            try session.process(requests: [.modelFile(url: raw), .poses])
            outputs: for try await output in session.outputs {
                switch output {
                case .requestProgress(_, let fraction): progress(0.02 + 0.93 * fraction)
                case .requestComplete(_, let result):
                    if case .poses(let poses) = result {
                        for (sample, pose) in poses.posesBySample {
                            if let name = poses.urlsBySample[sample]?.lastPathComponent {
                                builderPlaces[name] = pose.translation
                                builderTurns[name] = pose.rotation
                            }
                        }
                    }
                case .requestError(_, let error): throw error
                case .processingComplete: break outputs
                case .processingCancelled: throw CancellationError()
                default: break
                }
            }
        } onCancel: {
            session.cancel()
        }
        try? FileManager.default.removeItem(at: folder.checkpoint)
        guard FileManager.default.fileExists(atPath: raw.path) else { throw Failure.noModel }

        // The builder's camera places against the known ones in head space.
        var from: [SIMD3<Float>] = [], to: [SIMD3<Float>] = []
        for (i, shot) in record.shots.enumerated() {
            guard shot.isPosed, let p = builderPlaces[shot.file] else { continue }
            from.append(p)
            to.append(cameras[i].columns.3.xyz)
        }
        guard let fit = ScanAlign.fit(from: from, to: to), fit.error < 0.08 else {
            Diagnostics.log("Head scan: \(from.count) builder places matched, no fit")
            throw Failure.noFit
        }
        Diagnostics.log(String(format: "Head scan: %d of %d pictures placed by the builder, scale %.3f, error %.1f cm", from.count, record.shots.count, fit.scale, fit.error * 100))
        let backs = record.shots.filter { !$0.isPosed }
        if !backs.isEmpty {
            Diagnostics.log("Head scan: \(backs.filter { builderPlaces[$0.file] != nil }.count) of \(backs.count) back-of-head pictures placed by the builder")
        }

        guard let (mesh, pictures) = ScanCharacterMaker.read(raw) else { throw Failure.noModel }
        try? FileManager.default.removeItem(at: raw)
        let turn = fit.quaternion, shift = SIMD3(fit.translation[0], fit.translation[1], fit.translation[2])
        var head = mesh
        head.positions = head.positions.map { fit.scale * turn.act($0) + shift }
        head.normals = head.normals.map { turn.act($0) }
        // Bits away from the head (a shoulder, the backdrop) go.
        head = ScanRigPieces.near(head, radius: 0.32)
        head = ScanRig.mainPiece(head).0
        guard head.triangleCount > 200 else { throw Failure.nothingLeft }

        // The pictures by name, then both eyes coloured again from the one picture that saw the face most square on.
        var named: [String: UIImage] = [:]
        for (i, part) in mesh.parts.enumerated() {
            if let texture = part.texture, i < pictures.count, let picture = pictures[i], named[texture] == nil { named[texture] = picture }
        }
        matchEyes(head, pictures: &named, folder: folder, record: record, cameras: cameras, flip: flip,
                  builder: { name in
                      guard let place = builderPlaces[name], let turn0 = builderTurns[name] else { return nil }
                      return (fit.scale * turn.act(place) + shift, turn * turn0)
                  })

        // The pictures, under the names a character keeps them by.
        for (index, part) in head.parts.enumerated() {
            guard let texture = part.texture else { continue }
            let saved = "scanned-head-" + texture
            if let picture = named[texture], let jpeg = HeadPiece.jpeg(picture) {
                try jpeg.write(to: folder.url.appendingPathComponent(saved), options: .atomic)
                head.parts[index].texture = saved
            } else {
                head.parts[index].texture = nil
            }
        }
        try ScanRig.headData(head).write(to: folder.wholeFile, options: .atomic)
        let chin = HeadMath.chin(head.positions) ?? record.chin ?? -0.11
        Diagnostics.log(String(format: "Head scan: chin %.1f cm below the middle of the head (%@)", -chin * 100, HeadMath.chin(head.positions) == nil ? "guessed" : "from the face's profile"))
        try HeadPiece.save(folder, whole: head, settings: HeadCutSettings(cut: chin - 0.025, turn: 0, chin: chin))
        try? FileManager.default.removeItem(at: folder.maskedFolder)
        progress(1)
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for p in head.positions { low = simd_min(low, p); high = simd_max(high, p) }
        Diagnostics.log(String(format: "Head scan: head made, %d triangles, %.0f x %.0f x %.0f cm, middle at %.0f, %.0f, %.0f cm, %.0f s", head.triangleCount,
                               (high.x - low.x) * 100, (high.y - low.y) * 100, (high.z - low.z) * 100,
                               (low.x + high.x) * 50, (low.y + high.y) * 50, (low.z + high.z) * 50, Date().timeIntervalSince(started)))
    }
}

/// Cutting a whole head at its neck, and saving it.
enum HeadPiece {
    static func loadWhole(_ folder: HeadFolder) -> BodyMesh? {
        (try? Data(contentsOf: folder.wholeFile)).flatMap { ScanRig.head(from: $0) }
    }

    static func settings(_ folder: HeadFolder) -> HeadCutSettings? {
        (try? Data(contentsOf: folder.settingsFile)).flatMap { try? JSONDecoder().decode(HeadCutSettings.self, from: $0) }
    }

    /// The whole head turned by `turn` about up.
    static func turned(_ whole: BodyMesh, _ turn: Float) -> BodyMesh {
        guard turn != 0 else { return whole }
        let q = simd_quatf(angle: turn, axis: SIMD3(0, 1, 0))
        var out = whole
        out.positions = out.positions.map { q.act($0) }
        out.normals = out.normals.map { q.act($0) }
        return out
    }

    /// The head piece: turned, cut at the neck, its cut at 0,0,0 (ScanRig.headPiece's way).
    static func piece(_ whole: BodyMesh, settings: HeadCutSettings) -> BodyMesh {
        let head = turned(whole, settings.turn)
        var cut = HeadMath.neckCut(head.positions, chin: settings.chin ?? settings.cut + 0.035)
        cut.y = settings.cut
        // Phil's 1408 test: the neck's bottom was ragged. Triangles crossing the cut are cut along it, so it ends in a
        // clean edge.
        var out = clip(head, above: settings.cut)
        out = ScanRig.mainPiece(out).0
        out.positions = out.positions.map { $0 - cut }
        return out
    }

    /// The part of a mesh above height `y`, triangles crossing it cut exactly along it (new corners in between, with
    /// their normals and picture places in between too).
    static func clip(_ mesh: BodyMesh, above y: Float) -> BodyMesh {
        var out = BodyMesh(positions: [], normals: [], uvs: mesh.uvs == nil ? nil : [], triangles: [], parts: [])
        var kept = [Int32](repeating: -1, count: mesh.positions.count)
        func original(_ i: Int) -> UInt32 {
            if kept[i] < 0 {
                kept[i] = Int32(out.positions.count)
                out.positions.append(mesh.positions[i])
                out.normals.append(i < mesh.normals.count ? mesh.normals[i] : SIMD3(0, 1, 0))
                if let uvs = mesh.uvs { out.uvs!.append(i < uvs.count ? uvs[i] : .zero) }
            }
            return UInt32(kept[i])
        }
        func between(_ a: Int, _ b: Int) -> UInt32 {
            let pa = mesh.positions[a], pb = mesh.positions[b]
            let t = (y - pa.y) / (pb.y - pa.y)
            out.positions.append(pa + (pb - pa) * t)
            let na = a < mesh.normals.count ? mesh.normals[a] : SIMD3(0, 1, 0), nb = b < mesh.normals.count ? mesh.normals[b] : SIMD3(0, 1, 0)
            let n = na + (nb - na) * t
            out.normals.append(simd_length(n) > 1e-6 ? simd_normalize(n) : SIMD3(0, 1, 0))
            if let uvs = mesh.uvs {
                let ua = a < uvs.count ? uvs[a] : .zero, ub = b < uvs.count ? uvs[b] : .zero
                out.uvs!.append(ua + (ub - ua) * t)
            }
            return UInt32(out.positions.count - 1)
        }
        for part in mesh.parts {
            let first = out.triangles.count / 3
            for t in part.firstTriangle..<min(mesh.triangleCount, part.firstTriangle + part.triangleCount) {
                let c = (0..<3).map { Int(mesh.triangles[t * 3 + $0]) }
                let above = c.map { mesh.positions[$0].y > y }
                let count = above.filter { $0 }.count
                if count == 0 { continue }
                if count == 3 {
                    out.triangles += c.map(original)
                    continue
                }
                // Round the triangle in order, keeping what is above and adding where each side crosses.
                var ring: [UInt32] = []
                for k in 0..<3 {
                    let a = c[k], b = c[(k + 1) % 3]
                    if above[k] { ring.append(original(a)) }
                    if above[k] != above[(k + 1) % 3] { ring.append(between(a, b)) }
                }
                for k in 1..<(ring.count - 1) where ring.count >= 3 { out.triangles += [ring[0], ring[k], ring[k + 1]] }
            }
            let made = out.triangles.count / 3 - first
            if made > 0 { out.parts.append(BodyMesh.Part(firstTriangle: first, triangleCount: made, texture: part.texture, color: part.color)) }
        }
        return out
    }

    /// Writes the head piece and its small picture.
    @discardableResult
    static func save(_ folder: HeadFolder, whole: BodyMesh, settings: HeadCutSettings) throws -> BodyMesh {
        let head = piece(whole, settings: settings)
        guard head.triangleCount > 100 else { throw HeadBuilder.Failure.nothingLeft }
        try ScanRig.headData(head).write(to: folder.headFile, options: .atomic)
        try? JSONEncoder().encode(settings).write(to: folder.settingsFile)
        if let chin = settings.chin {
            try? JSONEncoder().encode(HeadInfo(chin: chin - settings.cut)).write(to: folder.url.appendingPathComponent(HeadInfo.file), options: .atomic)
        }
        let url = folder.url
        Task { @MainActor in
            if let picture = HeadPiece.thumbnail(head, pictures: url), let jpeg = picture.jpegData(compressionQuality: 0.85) {
                try? jpeg.write(to: url.appendingPathComponent("thumbnail.jpg"), options: .atomic)
                NotificationCenter.default.post(name: HeadPiece.thumbnailMade, object: url)
            }
        }
        return head
    }

    static let thumbnailMade = Notification.Name("HeadThumbnailMade")

    /// A head as a node, unlit with its photographs.
    static func node(_ head: BodyMesh, pictures: URL) -> SCNNode {
        FBXImport.headNode(head, textures: pictures)
    }

    /// The head from the front, a little to one side, on white.
    @MainActor static func thumbnail(_ head: BodyMesh, pictures: URL) -> UIImage? {
        let scene = SCNScene()
        scene.background.contents = UIColor.white
        let node = node(head, pictures: pictures)
        node.simdEulerAngles = SIMD3(0, 0.35, 0)
        scene.rootNode.addChildNode(node)
        let (low, high) = node.boundingBox
        let middle = (SIMD3<Float>(low) + SIMD3<Float>(high)) / 2
        let size = max(Float(high.y - low.y), Float(high.x - low.x))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.simdPosition = middle + SIMD3(0, 0, size * 2.1 + 0.05)
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: 400, height: 400), antialiasingMode: .multisampling4X)
    }

    static func jpeg(_ image: UIImage) -> Data? {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > 0 else { return nil }
        let factor = min(1, 4096 / longest)
        let size = CGSize(width: (image.size.width * image.scale * factor).rounded(), height: (image.size.height * image.scale * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.9)
    }

    /// "<character> with <head>'s head": a copy of an FBX character with this head kept beside it, for FBXImport to
    /// put on its head bone (as ScanCharacterMaker.putHead does with a head from a body scan). The character's own
    /// file is not changed.
    static func put(_ folder: HeadFolder, on character: URL, fit: HeadFit? = nil) throws -> URL {
        let manager = FileManager.default
        let place = character.deletingLastPathComponent()
        let base = (character.deletingPathExtension().lastPathComponent + " with \(folder.title)'s head").replacingOccurrences(of: "/", with: "-")
        var target = place.appendingPathComponent("\(base).fbx")
        var number = 2
        while manager.fileExists(atPath: target.path) {
            target = place.appendingPathComponent("\(base) \(number).fbx")
            number += 1
        }
        let textures = FBXImport.texturesFolder(for: target)
        try manager.copyItem(at: character, to: target)
        if manager.fileExists(atPath: FBXImport.texturesFolder(for: character).path) {
            try manager.copyItem(at: FBXImport.texturesFolder(for: character), to: textures)
        }
        try manager.createDirectory(at: textures, withIntermediateDirectories: true)
        // A head put on before goes: only one head rides on the head bone.
        for old in (try? manager.contentsOfDirectory(atPath: textures.path)) ?? [] where old == ScanRig.headFile || old.hasPrefix("scanned-head-") {
            try? manager.removeItem(at: textures.appendingPathComponent(old))
        }
        for file in folder.headFiles {
            try manager.copyItem(at: file, to: textures.appendingPathComponent(file.lastPathComponent))
        }
        try fit?.save(to: textures)
        Diagnostics.log("Head scan: \(folder.title) put on \(character.lastPathComponent) as \(target.lastPathComponent)")
        return target
    }
}

enum ScanRigPieces {
    /// The triangles within `radius` of the middle of head space.
    static func near(_ mesh: BodyMesh, radius: Float) -> BodyMesh {
        ScanRig.part(of: mesh) { corners in corners.allSatisfy { simd_length($0) < radius } }
    }
}

/// How a scanned head sits on a character (Phil, 2026-11-22: "it's too small, needs adjustment"): its size and how
/// far it is raised and brought forward (metres), and its turn about up (radians), all about its neck cut. Kept as
/// "scanned-head-fit.json" beside the head's own files on the character, so it travels with them.
struct HeadFit: Codable, Equatable {
    var scale: Float = 1
    var lift: Float = 0
    var forward: Float = 0
    var turn: Float = 0

    static let file = "scanned-head-fit.json"
    static let nodeName = "scannedHeadFit"

    static func load(_ folder: URL) -> HeadFit? {
        (try? Data(contentsOf: folder.appendingPathComponent(file))).flatMap { try? JSONDecoder().decode(HeadFit.self, from: $0) }
    }

    func save(to folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent(Self.file), options: .atomic)
    }

    var transform: simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: turn, axis: SIMD3(0, 1, 0)))
        m.columns.0 *= scale
        m.columns.1 *= scale
        m.columns.2 *= scale
        m.columns.3 = SIMD4(0, lift, forward, 1)
        return m
    }

    /// The height of a head piece above its neck cut.
    static func height(of head: BodyMesh) -> Float { head.positions.map(\.y).max() ?? 0.22 }

    /// The fit that gives the head the character's own chin-to-crown height with its chin where the character's was.
    /// `crown`: the character's chin to the top of its head; `chinAt`: its chin's height above where the head's neck
    /// cut goes (metres). Without the head's chin (`info`), it is sized by its whole height above the cut.
    static func auto(_ head: BodyMesh, info: HeadInfo?, crown: Float, chinAt: Float) -> HeadFit {
        let tall = height(of: head)
        guard tall > 0.05, crown > 0.05 else { return HeadFit() }
        guard let chin = info?.chin, chin >= 0, chin < tall - 0.05 else {
            return HeadFit(scale: min(2.5, max(0.4, (crown + chinAt) / tall)))
        }
        let scale = min(2.5, max(0.4, crown / (tall - chin)))
        return HeadFit(scale: scale, lift: chinAt - chin * scale)
    }

    /// The head as a node inside a node that carries the fit (found by `nodeName` to adjust it live).
    static func wrap(_ head: BodyMesh, pictures: URL, fit: HeadFit) -> SCNNode {
        let holder = SCNNode()
        holder.name = nodeName
        holder.simdTransform = fit.transform
        holder.addChildNode(FBXImport.headNode(head, textures: pictures))
        return holder
    }
}
