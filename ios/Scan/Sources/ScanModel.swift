import Foundation
import RealityKit
import SwiftUI

/// One scan on disk: Documents/Scans/<name>/ holds Images/, Checkpoint/ and, once built, model.usdz.
struct ScanFolder: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var images: URL { url.appendingPathComponent("Images", isDirectory: true) }
    var checkpoint: URL { url.appendingPathComponent("Checkpoint", isDirectory: true) }
    var model: URL { url.appendingPathComponent("\(name).usdz") }
    var hasModel: Bool { FileManager.default.fileExists(atPath: model.path) }
    var created: Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
    var imageCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: images.path).filter { $0.lowercased().hasSuffix(".heic") }.count) ?? 0
    }

    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Scans", isDirectory: true)
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

/// A plain text log in Documents, shared from the library so problems can be read off the phone.
enum ScanLog {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scan log.txt")
    private static let queue = DispatchQueue(label: "scan.log")

    static func add(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp)  \(line)\n"
        print(text, terminator: "")
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }
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

    func start() {
        guard ObjectCaptureSession.isSupported else {
            phase = .unsupported("This device can't run Apple's Object Capture (it needs LiDAR and iOS 17).")
            ScanLog.add("Object Capture not supported on this device")
            return
        }
        stopSession()
        // Scans started and abandoned before any picture leave empty folders; tidy them away.
        for old in ScanFolder.all() where old.imageCount == 0 && !old.hasModel {
            try? FileManager.default.removeItem(at: old.url)
        }
        library = ScanFolder.all()
        do {
            let folder = try ScanFolder.new()
            self.folder = folder
            var config = ObjectCaptureSession.Configuration()
            config.checkpointDirectory = folder.checkpoint
            config.isOverCaptureEnabled = false
            let session = ObjectCaptureSession()
            session.start(imagesDirectory: folder.images, configuration: config)
            self.session = session
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

    private func watch(_ session: ObjectCaptureSession) {
        tasks.append(Task { [weak self] in
            for await state in session.stateUpdates {
                self?.stateChanged(state)
            }
        })
        tasks.append(Task { [weak self] in
            for await feedback in session.feedbackUpdates {
                self?.hint = Self.text(for: feedback)
            }
        })
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let session else { return }
        shots = session.numberOfShotsTaken
        maxShots = session.maximumNumberOfInputImages
        if phase == .capturing && Self.usesBox && session.userCompletedScanPass {
            phase = .passDone
            ScanLog.add("Pass \(passes) done, \(shots) pictures")
        }
    }

    private func stateChanged(_ state: ObjectCaptureSession.CaptureState) {
        ScanLog.add("State: \(state)")
        switch state {
        case .initializing: phase = .starting
        case .ready: phase = .ready
        case .detecting: phase = .detecting
        case .capturing: if phase != .passDone { phase = .capturing }
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
        guard let session else { return }
        ScanLog.add("Finish with \(session.numberOfShotsTaken) pictures")
        session.finish()
        phase = .finishing
    }

    func cancel() {
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

    private func stopSession() {
        tasks.forEach { $0.cancel() }
        tasks = []
        poll?.invalidate()
        poll = nil
        session = nil
    }

    // MARK: Building the model

    /// The capture session must be gone before photogrammetry runs (both need the GPU and memory).
    private func build() {
        guard let folder else { return }
        stopSession()
        build(folder)
    }

    func build(_ folder: ScanFolder) {
        if session != nil {
            // Started from the library: drop the live capture and its empty folder first.
            session?.cancel()
            stopSession()
            if let live = self.folder, live != folder, live.imageCount == 0 { try? FileManager.default.removeItem(at: live.url) }
        }
        self.folder = folder
        phase = .building(0)
        hint = ""
        ScanLog.add("Build start: \(folder.name), \(folder.imageCount) pictures")
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
                try session.process(requests: [.modelFile(url: folder.model)])
                for try await output in session.outputs {
                    switch output {
                    case .requestProgress(_, let fraction):
                        self?.phase = .building(fraction)
                    case .requestComplete(_, _):
                        ScanLog.add("Model saved: \(folder.model.lastPathComponent)")
                    case .requestError(_, let error):
                        throw error
                    case .processingComplete:
                        self?.built(folder)
                        return
                    case .processingCancelled:
                        self?.phase = .failed("Building was cancelled.")
                        return
                    default:
                        break
                    }
                }
                self?.built(folder)
            } catch {
                ScanLog.add("Build failed: \(error)")
                self?.phase = .failed("Couldn't build the model: \(error.localizedDescription). The pictures are kept; try Build again from the library.")
                self?.library = ScanFolder.all()
            }
        }
    }

    private func built(_ folder: ScanFolder) {
        library = ScanFolder.all()
        if folder.hasModel {
            phase = .done(folder)
        } else {
            phase = .failed("The model file wasn't written. The pictures are kept; try Build again from the library.")
        }
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
