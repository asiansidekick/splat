import ARKit
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
/// Copy pose gives the character the pose it saw last.
@MainActor
final class PoseTaker: ObservableObject {
    let target: UUID
    let name: String
    @Published var seen = false
    @Published var copied = 0
    private weak var placer: ModelPlacer?
    private var latest: (pose: MannequinPose, at: Date)?
    private var task: Task<Void, Never>?

    init(placer: ModelPlacer, target: UUID, name: String) {
        self.placer = placer
        self.target = target
        self.name = name
        Diagnostics.log("Pose from camera: looking, for \(name)")
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let taker = self, taker.placer != nil else { return }
                await taker.look()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func look() async {
        guard let buffer = placer?.session.currentFrame?.capturedImage else { return }
        let box = FrameBox(buffer: buffer)
        let orientation = StoryboardScreen.sensorOrientation()
        let pose = await Task.detached(priority: .userInitiated) { PoseReader.read(box.buffer, orientation: orientation) }.value
        guard !Task.isCancelled else { return }
        if let pose { latest = (pose, Date()) }
        // Seen within the last second: a missed picture or two doesn't blink the button.
        seen = latest.map { Date().timeIntervalSince($0.at) < 1 } ?? false
    }

    func copy() {
        guard let latest, Date().timeIntervalSince(latest.at) < 1.5, let placer else { return }
        placer.applyCopiedPose(latest.pose, to: target)
        copied += 1
        Diagnostics.log("Pose from camera: copied onto \(name), \(latest.pose.summary)")
        Haptics.success()
    }

    func finish() {
        task?.cancel()
        task = nil
        Diagnostics.log("Pose from camera: done, \(copied) copied")
        placer?.poseTaker = nil
    }
}

/// Over the camera while copying a pose onto a character.
struct PoseTakeBar: View {
    @ObservedObject var taker: PoseTaker

    var body: some View {
        VStack(spacing: 8) {
            Text(taker.seen ? "Got the person. Tap Copy pose." : "Point at the person, head to feet in view.")
                .font(Theme.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
            HStack(spacing: 12) {
                Button(taker.copied > 0 ? "Done" : "Cancel") { TapGate.run("Pose take finish") { taker.finish() } }
                    .buttonStyle(.bordered)
                    .caughtTap("Pose take finish") { taker.finish() }
                Button { TapGate.run("Pose take") { taker.copy() } } label: { Label("Copy pose", systemImage: "figure.stand") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(!taker.seen)
                    .caughtTap("Pose take", enabled: taker.seen) { taker.copy() }
            }
            .font(Theme.headline)
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
