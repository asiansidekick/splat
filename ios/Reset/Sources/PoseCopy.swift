import ARKit
import SceneKit
import SwiftUI

/// Copy the actor's pose (Phil, 2026-11-10): the phone tracks the person's body, and one tap stands a mannequin
/// in their exact stance on their spot, for lining the actor up again on the next take. The session switches to
/// body tracking for the moment it takes, then goes back to what it was running.
@MainActor
final class PoseCopier: ObservableObject {
    static var supported: Bool { ARBodyTrackingConfiguration.isSupported }

    /// Which mannequin the next copy makes; switchable on the bar between actors.
    @Published var body: Mannequin.Body
    @Published var seen = false
    @Published var copied = 0
    private weak var placer: ModelPlacer?
    private let previous: ARConfiguration?
    private var timer: Timer?

    init(placer: ModelPlacer, body: Mannequin.Body) {
        self.placer = placer
        self.body = body
        previous = placer.session.configuration
        let configuration = ARBodyTrackingConfiguration()
        configuration.automaticSkeletonScaleEstimationEnabled = true
        configuration.planeDetection = [.horizontal]
        // No reset: the room stays where it is, so the copy lands on the actor's spot.
        placer.session.run(configuration)
        Diagnostics.log("Pose copy: body tracking on")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.seen = self?.bodyAnchor != nil }
        }
    }

    private var bodyAnchor: ARBodyAnchor? {
        placer?.session.currentFrame?.anchors.compactMap { $0 as? ARBodyAnchor }.first { $0.isTracked }
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        if let previous { placer?.session.run(previous) }
        Diagnostics.log("Pose copy: back to the usual camera")
        placer?.poseCopier = nil
    }

    func copy() {
        guard let anchor = bodyAnchor, let placer else { return }
        let skeleton = anchor.skeleton
        func world(_ name: String) -> SIMD3<Float>? {
            skeleton.modelTransform(for: ARSkeleton.JointName(rawValue: name)).map { (anchor.transform * SIMD4($0.columns.3.xyz, 1)).xyz }
        }
        // The room's up is known here, so the lean is the real lean.
        let joints = BodyJoints.fromARKit(world)
        guard let pose = PoseFromBody.pose(joints), let axes = PoseFromBody.frame(joints, up: SIMD3(0, 1, 0)) else {
            placer.modelError = "Couldn't read the whole body. Step back so all of the actor is in view."
            return
        }
        // Floor under the feet, height from the floor to the top of the head.
        let toes = [world("left_toes_joint"), world("right_toes_joint")].compactMap { $0 }
        let floor = (toes.map(\.y).min() ?? anchor.transform.columns.3.y - 0.95) - 0.03
        let headTop = (world("head_joint")?.y ?? floor + 1.6) + 0.1
        let height = min(2.1, max(1.2, headTop - floor))
        let hips = anchor.transform.columns.3.xyz
        // Facing the way the actor's hips and shoulders face (its left +X, front +Z).
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4(axes.columns.0, 0)
        transform.columns.2 = SIMD4(axes.columns.2, 0)
        transform.columns.3 = SIMD4(hips.x, floor, hips.z, 1)
        let name = "\(body.rawValue), copied pose"
        Diagnostics.log(String(format: "Pose copy: height %.2f m, floor %.2f, %@", height, floor, pose.summary))
        let figure = Mannequin.make(body, pose: pose, height: height)
        // Keep the feet where the actor's feet were: the figure stands on its lowest point, under its hips.
        guard let url = Examples.file(for: figure, name: name) else { return }
        // Phil, 2026-11-10: several actors in one frame. The phone tracks one body at a time, so the copier stays on
        // after each copy: point at the next actor and copy again, then Done.
        let before = placer.selectedModel
        placer.add(from: [url], at: transform, right: transform.columns.0.xyz)
        if let id = placer.selectedModel, id != before { placer.setMannequin(MannequinSpec(body: body, height: height, pose: pose), for: id) }
        placer.selectedModel = nil
        copied += 1
        Haptics.success()
    }
}

extension BodyJoints {
    /// From ARKit's tracked skeleton (joint names as ARKit gives them), in the room's space where up is +Y.
    static func fromARKit(_ at: (String) -> SIMD3<Float>?) -> BodyJoints {
        var body = BodyJoints()
        let names: [(Joint, String)] = [
            (.hips, "hips_joint"), (.neck, "neck_1_joint"), (.head, "head_joint"),
            (.leftShoulder, "left_arm_joint"), (.leftElbow, "left_forearm_joint"), (.leftWrist, "left_hand_joint"),
            (.rightShoulder, "right_arm_joint"), (.rightElbow, "right_forearm_joint"), (.rightWrist, "right_hand_joint"),
            (.leftHip, "left_upLeg_joint"), (.leftKnee, "left_leg_joint"), (.leftAnkle, "left_foot_joint"),
            (.rightHip, "right_upLeg_joint"), (.rightKnee, "right_leg_joint"), (.rightAnkle, "right_foot_joint"),
        ]
        for (joint, name) in names { body[joint] = at(name) }
        return body
    }
}

extension MannequinPose {
    var summary: String {
        String(format: "spine %.0f/%.0f, L arm out %.0f fwd %.0f elbow %.0f, R arm out %.0f fwd %.0f elbow %.0f, L knee %.0f, R knee %.0f",
               spineForward, spineSide, left.out, left.forward, left.elbow, right.out, right.forward, right.elbow, leftLeg.knee, rightLeg.knee)
    }
}

/// Over the camera while copying a pose.
struct PoseCopyBar: View {
    @ObservedObject var copier: PoseCopier

    var body: some View {
        VStack(spacing: 8) {
            Text(copier.seen ? (copier.copied > 0 ? "\(copier.copied) copied. Got the next one: Copy pose, or Done." : "Got the actor. Tap Copy pose.") :
                 copier.copied > 0 ? "\(copier.copied) copied. Point at the next actor, or Done." : "Point at the actor, head to feet in view.")
                .font(Theme.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
            // Body tracking reads joints only, not whether it is a woman or a man: pick for each actor here.
            // Plain buttons, not a segmented control, so they answer on its side too.
            HStack(spacing: 0) {
                ForEach(Mannequin.Body.allCases, id: \.self) { kind in
                    Button { TapGate.run("Pose body " + kind.rawValue) { copier.body = kind } } label: {
                        Text(kind.rawValue)
                            .font(Theme.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(copier.body == kind ? Theme.accent : Color.white.opacity(0.15), in: Capsule())
                            .foregroundStyle(copier.body == kind ? Theme.onAccent : Color.white)
                    }
                    .caughtTap("Pose body " + kind.rawValue) { copier.body = kind }
                }
            }
            .frame(maxWidth: 200)
            HStack(spacing: 12) {
                Button(copier.copied > 0 ? "Done" : "Cancel") { TapGate.run("Pose finish") { copier.finish() } }
                    .buttonStyle(.bordered)
                    .caughtTap("Pose finish") { copier.finish() }
                Button { TapGate.run("Pose copy") { copier.copy() } } label: { Label("Copy pose", systemImage: "figure.stand") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.onAccent)
                    .disabled(!copier.seen)
                    .caughtTap("Pose copy", enabled: copier.seen) { copier.copy() }
            }
            .font(Theme.headline)
        }
        .padding(.top, 8)
    }
}
