import ARKit
import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import Vision

// Phil, 2026-11-22: "copy a pose it sees in live view or an imported image and apply to a character". The phone reads
// the person's body in 3D from one picture (Vision, on the phone, no internet), and the selected character, mannequin,
// scanned person or imported Mixamo figure takes that pose where it stands. The camera keeps running as it is, so the
// models stay put in the room.

enum PoseReader {
    private static let joints: [(BodyJoints.Joint, VNHumanBodyPose3DObservation.JointName)] = [
        (.hips, .root), (.neck, .centerShoulder), (.head, .centerHead),
        (.leftShoulder, .leftShoulder), (.leftElbow, .leftElbow), (.leftWrist, .leftWrist),
        (.rightShoulder, .rightShoulder), (.rightElbow, .rightElbow), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.leftKnee, .leftKnee), (.leftAnkle, .leftAnkle),
        (.rightHip, .rightHip), (.rightKnee, .rightKnee), (.rightAnkle, .rightAnkle),
    ]

    /// The pose of the largest person in a photo. Slow (a fraction of a second): call it off the main thread.
    static func read(_ image: CGImage, orientation: CGImagePropertyOrientation) -> MannequinPose? {
        read(VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]), what: "photo")
    }

    /// The same from a camera picture.
    static func read(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> MannequinPose? {
        read(VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:]), what: nil)
    }

    private static func read(_ handler: VNImageRequestHandler, what: String?) -> MannequinPose? {
        let request = VNDetectHumanBodyPose3DRequest()
        do {
            try handler.perform([request])
        } catch {
            if let what { Diagnostics.log("Pose from \(what): couldn't read (\(error.localizedDescription))") }
            return nil
        }
        // The person filling most of the picture, head to ankles.
        func span(_ o: VNHumanBodyPose3DObservation) -> Double {
            guard let top = try? o.pointInImage(.topHead), let l = try? o.pointInImage(.leftAnkle), let r = try? o.pointInImage(.rightAnkle) else { return 0 }
            return hypot(top.x - (l.x + r.x) / 2, top.y - (l.y + r.y) / 2)
        }
        guard let person = (request.results ?? []).max(by: { span($0) < span($1) }) else {
            if let what { Diagnostics.log("Pose from \(what): no person found") }
            return nil
        }
        var body = BodyJoints()
        var seen: [(point: SIMD3<Float>, picture: SIMD2<Float>)] = []
        for (joint, name) in joints {
            guard let place = try? person.cameraRelativePosition(name) else { continue }
            let p = SIMD3<Float>(place.columns.3.x, place.columns.3.y, place.columns.3.z)
            body[joint] = p
            if let q = try? person.pointInImage(name) { seen.append((point: p, picture: SIMD2<Float>(Float(q.x), Float(q.y)))) }
        }
        guard seen.count >= 8, let up = pictureUp(seen) else {
            if let what { Diagnostics.log("Pose from \(what): too few joints (\(seen.count))") }
            return nil
        }
        body.up = up
        body.upFromPicture = true
        // Vision's picture points start at the bottom; if they did not, the head would come out below the feet.
        if let head = body[.head], let l = body[.leftAnkle], let r = body[.rightAnkle] {
            let tall = simd_length(head - (l + r) / 2)
            if simd_dot(head - (l + r) / 2, up) < -0.5 * tall { body.up = -up }
        }
        // The camera's space could be the other handedness: then knees would fold forward. Seen in a mirror again.
        let handedness = PoseFromBody.handedness(body)
        if handedness < -0.25 { body = body.mirrored }
        let pose = PoseFromBody.pose(body)
        if let what {
            Diagnostics.log("Pose from \(what): \(pose?.summary ?? "not enough of the body seen"), \(seen.count) joints, \((request.results ?? []).count) people, knees \(String(format: "%.2f", handedness))")
        }
        return pose
    }

    /// Which way is up in the camera's 3D space: the axis that goes up the picture as the joints do.
    static func pictureUp(_ seen: [(point: SIMD3<Float>, picture: SIMD2<Float>)]) -> SIMD3<Float>? {
        guard seen.count >= 3 else { return nil }
        let n = Float(seen.count)
        let meanP = seen.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.point } / n
        let meanV = seen.reduce(Float(0)) { $0 + $1.picture.y } / n
        var best: (axis: Int, corr: Float) = (0, 0)
        for axis in 0..<3 {
            var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
            for s in seen {
                let a = s.point[axis] - meanP[axis], b = s.picture.y - meanV
                sxy += a * b; sxx += a * a; syy += b * b
            }
            let corr = sxx > 0 && syy > 0 ? sxy / sqrt(sxx * syy) : 0
            if abs(corr) > abs(best.corr) { best = (axis, corr) }
        }
        guard abs(best.corr) > 0.3 else { return nil }
        var up = SIMD3<Float>(repeating: 0)
        up[best.axis] = best.corr > 0 ? 1 : -1
        return up
    }

    /// A photo picked from the library, upright as it shows.
    static func read(photo data: Data) -> MannequinPose? {
        guard let image = UIImage(data: data), let cg = image.cgImage else {
            Diagnostics.log("Pose from photo: couldn't open the picture")
            return nil
        }
        return read(cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }
}

/// Copying a pose from the live camera onto one character: the phone looks for a person a few times a second, and
/// Copy pose gives the character the pose it saw last. Phil, 2026-11-22: "automatic when still", "with the phone's
/// selfie camera also": Auto copies once the person has held a pose for a moment (so one person can pose alone), and
/// the selfie camera can be used instead of the back one (the room camera waits meanwhile).
@MainActor
final class PoseTaker: ObservableObject {
    let target: UUID
    let name: String
    @Published var seen = false
    @Published var copied = 0
    /// Copies by itself when the person holds still.
    @Published var auto: Bool {
        didSet { UserDefaults.standard.set(auto, forKey: "poseTake.auto"); watch = StillWatch(); hold = 0 }
    }
    /// How far the current hold has got toward an automatic copy, 0 to 1.
    @Published var hold: Double = 0
    /// The selfie camera is on (the room camera waits).
    @Published private(set) var selfie = false
    let selfieCamera = SelfieCamera()
    private weak var placer: ModelPlacer?
    private var latest: (pose: MannequinPose, at: Date)?
    private var task: Task<Void, Never>?
    private var watch = StillWatch()
    private var pausedRoom: ARConfiguration?
    private let started = Date()

    static var selfieSupported: Bool { SelfieCamera.available }

    init(placer: ModelPlacer, target: UUID, name: String) {
        self.placer = placer
        self.target = target
        self.name = name
        auto = UserDefaults.standard.object(forKey: "poseTake.auto") as? Bool ?? true
        Diagnostics.log("Pose from camera: looking, for \(name), auto \(auto)")
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let taker = self, taker.placer != nil else { return }
                await taker.look()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func look() async {
        let pose: MannequinPose?
        if selfie {
            guard let buffer = selfieCamera.latest() else { return }
            let box = FrameBox(buffer: buffer)
            // The selfie camera's pictures come upright and not mirrored (see SelfieCamera).
            pose = await Task.detached(priority: .userInitiated) { PoseReader.read(box.buffer, orientation: .up) }.value
        } else {
            guard let buffer = placer?.session.currentFrame?.capturedImage else { return }
            let box = FrameBox(buffer: buffer)
            let orientation = StoryboardScreen.sensorOrientation()
            pose = await Task.detached(priority: .userInitiated) { PoseReader.read(box.buffer, orientation: orientation) }.value
        }
        guard !Task.isCancelled else { return }
        if let pose { latest = (pose, Date()) }
        // Seen within the last second: a missed picture or two doesn't blink the button.
        seen = latest.map { Date().timeIntervalSince($0.at) < 1 } ?? false
        guard auto else { hold = 0; return }
        let step = watch.see(pose, at: Date().timeIntervalSince(started))
        hold = step.progress
        if step.fire { copy(automatically: true) }
    }

    func copy(automatically: Bool = false) {
        guard let latest, Date().timeIntervalSince(latest.at) < 1.5, let placer else { return }
        placer.applyCopiedPose(latest.pose, to: target)
        copied += 1
        hold = 0
        Diagnostics.log("Pose from \(selfie ? "selfie" : "camera"): copied onto \(name)\(automatically ? " (held still)" : ""), \(latest.pose.summary)")
        Haptics.success()
    }

    /// Between the back (room) camera and the selfie camera.
    func switchCamera() {
        guard let placer else { return }
        latest = nil
        seen = false
        watch = StillWatch()
        hold = 0
        if selfie {
            selfieCamera.stop()
            selfie = false
            if let pausedRoom { placer.session.run(pausedRoom) }
            pausedRoom = nil
            Diagnostics.log("Pose from camera: back camera")
        } else {
            pausedRoom = placer.session.configuration
            placer.session.pause()
            selfie = true
            selfieCamera.start()
            Diagnostics.log("Pose from camera: selfie camera, room camera paused")
        }
    }

    func finish() {
        task?.cancel()
        task = nil
        if selfie { switchCamera() }
        Diagnostics.log("Pose from camera: done, \(copied) copied")
        placer?.poseTaker = nil
    }
}

/// The phone's front camera, for copying the pose of the person holding it (or of someone in front of a phone on a
/// stand). Keeps only the newest picture, upright for how the phone is held and not mirrored, so a raised left arm is
/// read as the left. Started and stopped off the main thread (opening a camera waits for the room camera to let go).
final class SelfieCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static var available: Bool { AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "reset.pose.selfie", qos: .userInitiated)
    private let lock = NSLock()
    private var newest: CVPixelBuffer?
    private var configured = false

    func start() {
        let angle = MainActor.assumeIsolated { LensCamera.angle }
        queue.async { [self] in
            if !configured {
                configured = true
                session.beginConfiguration()
                session.sessionPreset = .hd1280x720
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
            }
            for output in session.outputs {
                if let connection = output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                    if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                }
            }
            session.startRunning()
            Diagnostics.log("Pose from selfie: camera \(session.isRunning ? "running" : "did not start")")
        }
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
            lock.lock(); newest = nil; lock.unlock()
        }
    }

    /// The newest picture, if one came in.
    func latest() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return newest
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); newest = buffer; lock.unlock()
    }
}

/// What the selfie camera sees, mirrored as a selfie is, filling the screen behind the bar.
struct SelfiePreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class Holder: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> Holder {
        let view = Holder()
        view.backgroundColor = .black
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: Holder, context: Context) {
        if let connection = view.preview.connection, connection.isVideoRotationAngleSupported(LensCamera.angle) {
            connection.videoRotationAngle = LensCamera.angle
        }
    }
}

/// The bar over the room camera, or with the selfie camera on, the selfie picture over the whole screen with the bar on it.
struct PoseTakeLayer: View {
    @ObservedObject var taker: PoseTaker

    var body: some View {
        PoseTakeBar(taker: taker)
            .fullScreenCover(isPresented: Binding(get: { taker.selfie }, set: { if !$0, taker.selfie { taker.switchCamera() } })) {
                ZStack(alignment: .top) {
                    SelfiePreview(session: taker.selfieCamera.session).ignoresSafeArea()
                    PoseTakeBar(taker: taker)
                }
                .background(Color.black)
            }
    }
}

/// Over the camera while copying a pose onto a character.
struct PoseTakeBar: View {
    @ObservedObject var taker: PoseTaker

    private var words: String {
        if !taker.seen { return taker.selfie ? "Step back until you're in view, head to feet." : "Point at the person, head to feet in view." }
        if taker.auto {
            if taker.hold > 0 { return "Hold still…" }
            return taker.copied > 0 ? "Copied. Change pose to copy again, or Done." : "Got the person. Hold a pose to copy it."
        }
        return taker.copied > 0 ? "Copied. Copy pose again, or Done." : "Got the person. Tap Copy pose."
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(words)
                .font(Theme.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
            HStack(spacing: 10) {
                Button(taker.copied > 0 ? "Done" : "Cancel") { TapGate.run("Pose take finish") { taker.finish() } }
                    .buttonStyle(.bordered)
                    .caughtTap("Pose take finish") { taker.finish() }
                Button { TapGate.run("Pose take") { taker.copy() } } label: {
                    Label("Copy pose", systemImage: "figure.stand")
                        // The hold toward an automatic copy fills the button's outline.
                        .overlay {
                            if taker.auto, taker.hold > 0 {
                                Capsule().trim(from: 0, to: taker.hold).stroke(Color.white, lineWidth: 3).padding(-8)
                                    .animation(.linear(duration: 0.25), value: taker.hold)
                            }
                        }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.onAccent)
                .disabled(!taker.seen)
                .caughtTap("Pose take", enabled: taker.seen) { taker.copy() }
            }
            .font(Theme.headline)
            HStack(spacing: 10) {
                Button(taker.auto ? "Auto copy: on" : "Auto copy: off") { TapGate.run("Pose take auto") { taker.auto.toggle() } }
                    .buttonStyle(.bordered)
                    .tint(taker.auto ? Theme.accent : .white)
                    .caughtTap("Pose take auto") { taker.auto.toggle() }
                if PoseTaker.selfieSupported {
                    Button(taker.selfie ? "Back camera" : "Selfie camera") { TapGate.run("Pose take camera") { taker.switchCamera() } }
                        .buttonStyle(.bordered)
                        .caughtTap("Pose take camera") { taker.switchCamera() }
                }
            }
            .font(Theme.footnote.weight(.semibold))
        }
        .padding(.top, 8)
    }
}

/// The Copy pose button's choice: from the live camera, or from a photo in the library. Lay it on the model tools.
struct CopyPoseChooser: ViewModifier {
    @ObservedObject var placer: ModelPlacer
    @Binding var isPresented: Bool
    /// The live camera is there (not over a saved frame).
    var live: Bool
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var reading = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Copy a pose", isPresented: $isPresented, titleVisibility: .visible) {
                if live {
                    Button("From the camera") { placer.startPoseTaker() }
                }
                Button("From a photo") { pickingPhoto = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This character takes the pose of a person, seen now or in a photo.")
            }
            .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item, let id = placer.selectedModel else { return }
                photo = nil
                reading = true
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    let pose = await Task.detached(priority: .userInitiated) { data.flatMap { PoseReader.read(photo: $0) } }.value
                    reading = false
                    if let pose {
                        placer.applyCopiedPose(pose, to: id)
                        Haptics.success()
                    } else {
                        placer.modelError = "Couldn't find a whole person in that photo. Pick one with the person head to feet in view."
                    }
                }
            }
            .overlay(alignment: .top) {
                if reading {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white)
                        Text("Reading the pose").font(Theme.footnote.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 3)
                    .padding(.top, 50)
                    .allowsHitTesting(false)
                }
            }
    }
}
