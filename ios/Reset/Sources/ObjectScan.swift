import Foundation
import RealityKit
import SwiftUI

/// One scan on disk: Documents/Scans/<name>/ holds Images/, Checkpoint/ and, once built, model.usdz.
struct ScanFolder: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    private var titleFile: URL { url.appendingPathComponent("title.txt") }
    /// What the scan is called on screen: the name the person gave it, else its folder's name (Phil, 2026-11-18:
    /// rename scans). The folder and files keep their names, so nothing that refers to them breaks.
    var title: String {
        let given = (try? String(contentsOf: titleFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return given.isEmpty ? name : given
    }
    func rename(to text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == name {
            try? FileManager.default.removeItem(at: titleFile)
        } else {
            try? clean.write(to: titleFile, atomically: true, encoding: .utf8)
        }
    }
    /// The name a scan model file goes by when placed: its title.
    static func title(ofModelAt file: URL) -> String? {
        guard file.path.contains("/Scans/") else { return nil }
        let given = (try? String(contentsOf: file.deletingLastPathComponent().appendingPathComponent("title.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return given.isEmpty ? nil : given
    }
    var images: URL { url.appendingPathComponent("Images", isDirectory: true) }
    var checkpoint: URL { url.appendingPathComponent("Checkpoint", isDirectory: true) }
    var model: URL { url.appendingPathComponent("\(name).usdz") }
    var hasModel: Bool { FileManager.default.fileExists(atPath: model.path) }
    /// The first build: everything the pictures saw, before cropping.
    var full: URL { url.appendingPathComponent("\(name) full.usdz") }
    var hasFull: Bool { FileManager.default.fileExists(atPath: full.path) }
    private var boundsFile: URL { url.appendingPathComponent("session-bounds.json") }

    func saveSessionBounds(_ box: CropBox) {
        try? JSONEncoder().encode(box).write(to: boundsFile)
    }

    var sessionBounds: CropBox? {
        (try? Data(contentsOf: boundsFile)).flatMap { try? JSONDecoder().decode(CropBox.self, from: $0) }
    }
    var created: Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
    var imageCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: images.path).filter { $0.lowercased().hasSuffix(".heic") || $0.lowercased().hasSuffix(".jpg") }.count) ?? 0
    }

    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Scans", isDirectory: true)  // Files > Reset > Scans
    }

    static func new() throws -> ScanFolder {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = ScanFolder(url: root.appendingPathComponent("Scan \(f.string(from: Date()))", isDirectory: true))
        try FileManager.default.createDirectory(at: folder.images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.checkpoint, withIntermediateDirectories: true)
        return folder
    }

    static func all() -> [ScanFolder] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.hasDirectoryPath }.map { ScanFolder(url: $0) }.sorted { $0.created > $1.created }
    }
}

/// Scan lines go into Reset's feedback log.
enum ScanLog {
    static func add(_ line: String) { Diagnostics.log("Scan: " + line) }
}

/// Drives Apple's Object Capture: ObjectCaptureSession takes the pictures (with its own guidance
/// dial and point cloud), then PhotogrammetrySession builds a real-size USDZ on the phone.
/// This follows the flow of Apple's "Guided Capture" sample rather than our own scanning maths.
@MainActor
final class ScanModel: ObservableObject {
    enum Phase: Equatable {
        case unsupported(String)
        case starting
        case ready          // camera on, nothing chosen yet
        case detecting      // box around the object, adjustable
        case capturing      // pictures being taken automatically
        case passDone       // a full turn is done: another pass, flip, or finish
        case finishing      // session writing its last pictures
        case building(Double) // photogrammetry progress 0...1
        case cropping(ScanFolder) // whole area built; choose what to keep
        case done(ScanFolder)
        case failed(String)
    }

    @Published var phase: Phase = .starting
    @Published var hint: String = ""
    @Published var shots = 0
    @Published var maxShots = 0
    @Published var passes = 1
    @Published var library: [ScanFolder] = ScanFolder.all()

    @Published private(set) var session: ObjectCaptureSession?
    /// Reset's own camera is taking the pictures (Apple's capture took none on this phone).
    @Published private(set) var ownCamera = false
    let own = OwnCapture()
    /// Remembered once Apple's capture has stalled on this phone, so later scans start with Reset's camera.
    private static var prefersOwn: Bool {
        get { UserDefaults.standard.bool(forKey: "scanOwnCamera") }
        set { UserDefaults.standard.set(newValue, forKey: "scanOwnCamera") }
    }
    private var folder: ScanFolder?
    private var tasks: [Task<Void, Never>] = []
    private var poll: Timer?
    private var buildTask: Task<Void, Never>?

    /// iOS 17 needs Apple's box round the object; from iOS 18 capture starts without one.
    static var usesBox: Bool {
        if #available(iOS 18.0, *) { return false }
        return true
    }

    static var supported: Bool { ObjectCaptureSession.isSupported }

    func start(retry: Bool = false) {
        if !retry { retried = false }
        startedAt = Date()
        lastPolled = ""
        guard ObjectCaptureSession.isSupported else {
            phase = .unsupported("This device can't run Apple's Object Capture (it needs LiDAR and iOS 17).")
            ScanLog.add("Object Capture not supported on this device")
            return
        }
        stopSession()
        // Scans started and abandoned before any picture leave empty folders; tidy them away.
        for old in ScanFolder.all() where old.imageCount == 0 && !old.hasModel && !old.hasFull {
            try? FileManager.default.removeItem(at: old.url)
        }
        library = ScanFolder.all()
        do {
            let folder = try ScanFolder.new()
            self.folder = folder
            if Self.prefersOwn {
                startOwn(folder, recording: false)
                return
            }
            var config = ObjectCaptureSession.Configuration()
            config.checkpointDirectory = folder.checkpoint
            config.isOverCaptureEnabled = false
            let session = ObjectCaptureSession()
            session.start(imagesDirectory: folder.images, configuration: config)
            self.session = session
            lastState = ""
            shots = 0
            passes = 1
            phase = .starting
            hint = ""
            ScanLog.add("Session start: \(folder.name)")
            watch(session)
        } catch {
            phase = .failed("Couldn't make the scan folder: \(error.localizedDescription)")
            ScanLog.add("Folder error: \(error)")
        }
    }

    /// Reset's own camera takes over: for a new scan, or in the middle of one where Apple's capture took nothing.
    private func startOwn(_ folder: ScanFolder, recording: Bool) {
        ownCamera = true
        shots = 0
        maxShots = OwnCapture.maxShots
        passes = 1
        hint = ""
        own.begin(folder)
        own.recording = recording
        phase = recording ? .capturing : .ready
        ScanLog.add("Own camera start: \(folder.name), recording \(recording)")
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func switchToOwn() {
        guard let session, let folder else { return }
        ScanLog.add("Apple's capture is taking no pictures: switching to Reset's own camera")
        Self.prefersOwn = true
        session.cancel()
        stopSession()
        phase = .starting
        hint = ""
        Task { [weak self] in
            // Apple's session lets go of the camera first.
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.startOwn(folder, recording: true)
        }
    }

    private func watch(_ session: ObjectCaptureSession) {
        tasks.append(Task { [weak self] in
            for await state in session.stateUpdates {
                self?.stateChanged(state)
            }
        })
        tasks.append(Task { [weak self] in
            for await feedback in session.feedbackUpdates {
                self?.hint = Self.text(for: feedback)
                ScanLog.add("Feedback: \(feedback.map { "\($0)" }.sorted().joined(separator: ", "))")
            }
        })
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var lastPolled = ""
    private var startedAt = Date()
    private var retried = false

    private func tick() {
        if ownCamera {
            shots = own.shots
            let text = !own.tracking ? "Move slowly" : own.tooFast ? "Slow down" : ""
            if hint != text { hint = text }
            if phase == .capturing, shots >= OwnCapture.maxShots { finish() }
            return
        }
        guard let session else { return }
        // The state is read here as well as listened for: on Phil's phone (build 1306) no state ever arrived and the
        // camera stayed black.
        let polled = "\(session.state)"
        if polled != lastPolled {
            lastPolled = polled
            ScanLog.add("Polled state: \(polled)")
            stateChanged(session.state)
        }
        if phase == .starting, Date().timeIntervalSince(startedAt) > 6 {
            if retried {
                ScanLog.add("Camera never started (state \(polled)), giving up")
                session.cancel()
                stopSession()
                phase = .failed("The scanning camera didn't start. Close other camera apps, then tap Start again.")
            } else {
                ScanLog.add("Camera not started after 6 s (state \(polled)), trying once more")
                retried = true
                session.cancel()
                stopSession()
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self?.start(retry: true)
                }
            }
            return
        }
        let taken = session.numberOfShotsTaken
        if taken != shots { lastShotAt = Date() }
        shots = taken
        maxShots = session.maximumNumberOfInputImages
        // Apple takes pictures by itself as the phone moves, but on Phil's phone (build 1307) it took none in 44 s.
        // When a second goes by with no picture, one is asked for here, so a scan always fills.
        if phase == .capturing, Date().timeIntervalSince(lastShotAt) > 1.0 {
            if session.canRequestImageCapture {
                if ownShots == 0 {
                    var auto = "unknown"
                    if #available(iOS 18.0, *) { auto = "\(session.isAutoCaptureEnabled)" }
                    ScanLog.add("No automatic pictures: taking one a second (auto capture \(auto))")
                }
                ownShots += 1
                lastShotAt = Date()
                session.requestImageCapture()
            } else if !loggedCannot, Date().timeIntervalSince(lastShotAt) > 5 {
                loggedCannot = true
                ScanLog.add("Pictures can't be asked for either (tracking \(session.cameraTracking), feedback \(hint))")
                switchToOwn()
                return
            }
        }
        if phase == .capturing && Self.usesBox && session.userCompletedScanPass {
            phase = .passDone
            ScanLog.add("Pass \(passes) done, \(shots) pictures")
        }
    }

    private var lastState = ""
    private var lastShotAt = Date()
    private var ownShots = 0
    private var loggedCannot = false

    private func stateChanged(_ state: ObjectCaptureSession.CaptureState) {
        // Heard and polled: act once on each.
        let name = "\(state)"
        guard name != lastState else { return }
        lastState = name
        ScanLog.add("State: \(state)")
        switch state {
        case .initializing: phase = .starting
        case .ready: phase = .ready
        case .detecting: phase = .detecting
        case .capturing:
            if phase != .passDone {
                if phase != .capturing {
                    lastShotAt = Date()
                    ownShots = 0
                    loggedCannot = false
                }
                phase = .capturing
            }
        case .finishing: phase = .finishing
        case .completed: build()
        case .failed(let error):
            ScanLog.add("Session failed: \(error)")
            stopSession()
            phase = .failed("Scanning stopped: \(error.localizedDescription)")
        @unknown default: break
        }
    }

    // MARK: Shutter actions

    /// One button does the next step, like a camera shutter.
    func shutter() {
        if ownCamera {
            switch phase {
            case .ready:
                own.recording = true
                phase = .capturing
                ScanLog.add("Own camera: record start")
            case .capturing:
                finish()
            default: break
            }
            return
        }
        guard let session else { return }
        switch phase {
        case .ready:
            // Area mode (iOS 18+): no box, just record and walk round, like Scaniverse.
            if #available(iOS 18.0, *) {
                session.startCapturing()
                ScanLog.add("Record start (area mode, no box)")
            } else if !session.startDetecting() {
                hint = "Point at the object, then tap again."
            }
        case .detecting:
            session.startCapturing()
        case .capturing, .passDone:
            finish()
        default: break
        }
    }

    func resetBox() { session?.resetDetection() }

    func anotherPass(flipped: Bool) {
        guard let session else { return }
        if flipped { session.beginNewScanPassAfterFlip() } else { session.beginNewScanPass() }
        passes += 1
        phase = flipped ? .detecting : .capturing
        ScanLog.add("Pass \(passes) begins\(flipped ? " after flip" : "")")
    }

    func finish() {
        if ownCamera {
            guard let folder, phase == .capturing else { return }
            phase = .finishing
            let count = own.shots
            ScanLog.add("Own camera: finish with \(count) pictures")
            Task { [weak self] in
                guard let self else { return }
                await self.own.end()
                self.stopSession()
                if count < 10 {
                    try? FileManager.default.removeItem(at: folder.url)
                    self.folder = nil
                    self.phase = .failed("Only \(count) pictures were taken, too few for a model. Walk slowly all the way round the object before stopping.")
                } else {
                    self.build(folder)
                }
            }
            return
        }
        guard let session else { return }
        ScanLog.add("Finish with \(session.numberOfShotsTaken) pictures, \(ownShots) asked for here")
        if session.numberOfShotsTaken < 10 {
            // Too few to build anything: say so instead of a failed build.
            let count = session.numberOfShotsTaken
            session.cancel()
            stopSession()
            if let folder { try? FileManager.default.removeItem(at: folder.url) }
            folder = nil
            phase = .failed("Only \(count) pictures were taken, too few for a model. Walk slowly all the way round the object before stopping.")
            return
        }
        session.finish()
        phase = .finishing
    }

    func cancel() {
        if ownCamera {
            own.recording = false
            own.session.pause()
        }
        session?.cancel()
        stopSession()
        if let folder { try? FileManager.default.removeItem(at: folder.url) }
        folder = nil
        // Only one capture session may exist; give the old one a moment to shut down.
        phase = .starting
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.start()
        }
    }

    /// Leaving the scanner: the camera is given back, and a scan with no pictures leaves nothing behind. A build
    /// that is running carries on.
    func close() {
        if ownCamera {
            own.recording = false
            own.session.pause()
            stopSession()
            if let folder, !folder.hasModel, !folder.hasFull, phase == .ready || phase == .capturing || phase == .starting {
                try? FileManager.default.removeItem(at: folder.url)
            }
            ScanLog.add("Closed (own camera)")
            return
        }
        guard session != nil else { return }
        session?.cancel()
        stopSession()
        if let folder, folder.imageCount == 0, !folder.hasModel, !folder.hasFull { try? FileManager.default.removeItem(at: folder.url) }
        ScanLog.add("Closed")
    }

    private func stopSession() {
        tasks.forEach { $0.cancel() }
        tasks = []
        poll?.invalidate()
        poll = nil
        session = nil
        ownCamera = false
    }

    // MARK: Building the model

    /// The capture session must be gone before photogrammetry runs (both need the GPU and memory).
    private func build() {
        guard let folder else { return }
        stopSession()
        build(folder)
    }

    /// Builds a model from a scan's pictures. Without a crop, the whole area is built into
    /// `full` and the crop screen opens; with one, Apple rebuilds just what is inside the box
    /// (reusing the first build's checkpoint) into the final model.
    func build(_ folder: ScanFolder, crop: CropBox? = nil) {
        if session != nil {
            // Started from the library: drop the live capture and its empty folder first.
            session?.cancel()
            stopSession()
            if let live = self.folder, live != folder, live.imageCount == 0 { try? FileManager.default.removeItem(at: live.url) }
        }
        self.folder = folder
        phase = .building(0)
        hint = ""
        let out = crop == nil ? folder.full : folder.model
        try? FileManager.default.removeItem(at: out)
        if let crop {
            ScanLog.add("Crop build start: \(folder.name), box \(crop.min) to \(crop.max)")
        } else {
            ScanLog.add("Build start: \(folder.name), \(folder.imageCount) pictures")
        }
        buildTask = Task { [weak self] in
            // Let the capture session release the camera and memory before photogrammetry starts.
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                guard PhotogrammetrySession.isSupported else {
                    throw NSError(domain: "Scan", code: 1, userInfo: [NSLocalizedDescriptionKey: "This device can't build models."])
                }
                var config = PhotogrammetrySession.Configuration()
                config.checkpointDirectory = folder.checkpoint
                let session = try PhotogrammetrySession(input: folder.images, configuration: config)
                if let crop {
                    let geometry = PhotogrammetrySession.Request.Geometry(bounds: BoundingBox(min: crop.min, max: crop.max))
                    try session.process(requests: [.modelFile(url: out, detail: .reduced, geometry: geometry)])
                } else {
                    // Bounds come back in the session's own space, which the crop box must be in.
                    // Pictures from Reset's own camera carry no size or which way is up: the builder's idea of where
                    // each was taken is asked for too, to line the model up with the room afterwards.
                    let ownCameras = folder.cameras
                    try session.process(requests: ownCameras == nil ? [.modelFile(url: out), .bounds] : [.modelFile(url: out), .bounds, .poses])
                }
                for try await output in session.outputs {
                    switch output {
                    case .requestProgress(_, let fraction):
                        self?.phase = .building(fraction)
                    case .requestComplete(_, let result):
                        if case .bounds(let b) = result {
                            ScanLog.add("Session bounds: \(b.min) to \(b.max)")
                            folder.saveSessionBounds(CropBox(min: b.min, max: b.max))
                        } else if case .poses(let poses) = result {
                            Self.saveFit(poses, folder: folder)
                        } else {
                            ScanLog.add("Model saved: \(out.lastPathComponent)")
                        }
                    case .requestError(_, let error):
                        throw error
                    case .processingComplete:
                        self?.built(folder, cropped: crop != nil)
                        return
                    case .processingCancelled:
                        self?.phase = .failed("Building was cancelled.")
                        return
                    default:
                        break
                    }
                }
                self?.built(folder, cropped: crop != nil)
            } catch {
                ScanLog.add("Build failed: \(error)")
                self?.phase = .failed("Couldn't build the model: \(error.localizedDescription). The pictures are kept; try Build again from the library.")
                self?.library = ScanFolder.all()
            }
        }
    }

    private func built(_ folder: ScanFolder, cropped: Bool) {
        library = ScanFolder.all()
        if !cropped, folder.hasFull, folder.cameras != nil {
            // Reset's own pictures: no crop step yet (the builder's space is not upright), the model is made real
            // size and upright and that is it.
            let fit = folder.fit
            let ok = ScanBake.bake(folder.full, to: folder.model, fit: fit)
            ScanLog.add("Own camera model: fit \(fit.map { String(format: "scale %.3f, error %.3f m", $0.scale, $0.error) } ?? "none"), written \(ok)")
            library = ScanFolder.all()
            phase = ok ? .done(folder) : .failed("The model couldn't be saved.")
            return
        }
        if cropped {
            phase = folder.hasModel ? .done(folder) : .failed("The cropped model wasn't written. Try Crop again from the library.")
        } else if folder.hasFull {
            phase = .cropping(folder)
        } else {
            phase = .failed("The model file wasn't written. The pictures are kept; try Build again from the library.")
        }
    }

    /// Where the builder thinks each picture was taken, against where ARKit knows it was: the model's real size and
    /// which way is up come from fitting one to the other.
    private static func saveFit(_ poses: PhotogrammetrySession.Poses, folder: ScanFolder) {
        guard let cameras = folder.cameras else { return }
        var from: [SIMD3<Float>] = []
        var to: [SIMD3<Float>] = []
        for (sample, pose) in poses.posesBySample {
            guard let name = poses.urlsBySample[sample]?.lastPathComponent, let place = cameras[name], place.count == 3 else { continue }
            from.append(pose.translation)
            to.append(SIMD3(place[0], place[1], place[2]))
        }
        guard let fit = ScanAlign.fit(from: from, to: to) else {
            ScanLog.add("Poses: \(poses.posesBySample.count) from the builder, \(from.count) matched, no fit")
            return
        }
        ScanLog.add(String(format: "Poses: %d matched of %d pictures, scale %.3f, error %.3f m", from.count, cameras.count, fit.scale, fit.error))
        // A fit that leaves the cameras more than a hand's width out is not to be trusted.
        guard fit.error < 0.15, let data = try? JSONEncoder().encode(fit) else { return }
        try? data.write(to: folder.fitFile)
    }

    /// Crop screen: keep the whole area as it is.
    func keepAll(_ folder: ScanFolder) {
        try? FileManager.default.removeItem(at: folder.model)
        do {
            try FileManager.default.copyItem(at: folder.full, to: folder.model)
            ScanLog.add("Kept the whole area: \(folder.name)")
            library = ScanFolder.all()
            phase = .done(folder)
        } catch {
            phase = .failed("Couldn't save the model: \(error.localizedDescription)")
        }
    }

    func openCrop(_ folder: ScanFolder) {
        guard folder.hasFull else { return }
        if session != nil {
            session?.cancel()
            stopSession()
            if let live = self.folder, live != folder, live.imageCount == 0 { try? FileManager.default.removeItem(at: live.url) }
        }
        self.folder = folder
        phase = .cropping(folder)
    }

    func delete(_ folder: ScanFolder) {
        try? FileManager.default.removeItem(at: folder.url)
        library = ScanFolder.all()
    }

    /// Short feedback in the style of the Camera app: one line, most urgent first.
    static func text(for feedback: Set<ObjectCaptureSession.Feedback>) -> String {
        if feedback.contains(.environmentTooDark) { return "Too dark" }
        if feedback.contains(.movingTooFast) { return "Slow down" }
        if feedback.contains(.objectTooClose) { return "Move back" }
        if feedback.contains(.objectTooFar) { return "Move closer" }
        if feedback.contains(.outOfFieldOfView) { return "Aim at the object" }
        if feedback.contains(.environmentLowLight) { return "More light helps" }
        return ""
    }
}
