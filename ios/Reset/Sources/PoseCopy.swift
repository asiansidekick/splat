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
        func model(_ name: String) -> SIMD3<Float>? {
            skeleton.modelTransform(for: ARSkeleton.JointName(rawValue: name)).map { $0.columns.3.xyz }
        }
        func world(_ name: String) -> SIMD3<Float>? {
            model(name).map { (anchor.transform * SIMD4($0, 1)).xyz }
        }
        guard let pose = PoseFromSkeleton.pose(model) else {
            placer.modelError = "Couldn't read the whole body. Step back so all of the actor is in view."
            return
        }
        // Floor under the feet, height from the floor to the top of the head.
        let toes = [world("left_toes_joint"), world("right_toes_joint")].compactMap { $0 }
        let floor = (toes.map(\.y).min() ?? anchor.transform.columns.3.y - 0.95) - 0.03
        let headTop = (world("head_joint")?.y ?? floor + 1.6) + 0.1
        let height = min(2.1, max(1.2, headTop - floor))
        let hips = anchor.transform.columns.3.xyz
        var forward = anchor.transform.columns.2.xyz
        forward.y = 0
        forward = simd_length(forward) > 0.01 ? simd_normalize(forward) : SIMD3(0, 0, 1)
        var transform = matrix_identity_float4x4
        transform.columns.0 = SIMD4(forward.z, 0, -forward.x, 0)
        transform.columns.2 = SIMD4(forward, 0)
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

/// Turns the tracked skeleton (positions in the body's own space: Y up, facing +Z, its left +X) into joint angles.
enum PoseFromSkeleton {
    private static func deg(_ r: Float) -> Float { r * 180 / .pi }
    private static func rz(_ a: Float) -> simd_float3x3 { simd_float3x3(simd_quatf(angle: a, axis: SIMD3(0, 0, 1))) }
    private static func rx(_ a: Float) -> simd_float3x3 { simd_float3x3(simd_quatf(angle: a, axis: SIMD3(1, 0, 0))) }
    private static func ry(_ a: Float) -> simd_float3x3 { simd_float3x3(simd_quatf(angle: a, axis: SIMD3(0, 1, 0))) }

    /// Angles (z, x, y) that hang a limb along `upper`, twisted so its lower part bends only about x, and that bend.
    /// Elbows bend the lower part forward, knees backward (`bendsForward`). Checked against the forward maths in Python.
    static func aim(upper: SIMD3<Float>, lower: SIMD3<Float>, bendsForward: Bool) -> (z: Float, x: Float, y: Float, bend: Float) {
        let d = simd_normalize(upper)
        let x = asin(max(-1, min(1, -d.z)))
        let z = atan2(d.x, -d.y)
        let g = (rz(z) * rx(x)).transpose * simd_normalize(lower)
        // A nearly straight limb has no clear twist: leave it untwisted.
        let y: Float = hypot(g.x, g.z) < 0.05 ? 0 : (bendsForward ? atan2(g.x, g.z) : atan2(-g.x, -g.z))
        let t = ry(y).transpose * g
        return (z, x, y, atan2(-t.z, -t.y))
    }

    static func pose(_ at: (String) -> SIMD3<Float>?) -> MannequinPose? {
        guard let root = at("hips_joint"), let neck = at("neck_1_joint") else { return nil }
        var p = MannequinPose()
        // Spine: lean forward (x) and to the side (z), from hips to neck.
        let up = simd_normalize(neck - root)
        let spineX = asin(max(-1, min(1, up.z)))
        let spineZ = atan2(-up.x, up.y)
        p.spineForward = deg(spineX)
        p.spineSide = deg(spineZ)
        let spine = rz(spineZ) * rx(spineX)
        if let head = at("head_joint") {
            let h = spine.transpose * simd_normalize(head - neck)
            p.headDown = deg(asin(max(-1, min(1, h.z))))
        }
        for (side, prefix) in [(Float(1), "left"), (Float(-1), "right")] {
            guard let shoulder = at("\(prefix)_arm_joint"), let elbow = at("\(prefix)_forearm_joint"), let wrist = at("\(prefix)_hand_joint"),
                  let hip = at("\(prefix)_upLeg_joint"), let knee = at("\(prefix)_leg_joint"), let ankle = at("\(prefix)_foot_joint")
            else { return nil }
            let a = aim(upper: spine.transpose * (elbow - shoulder), lower: spine.transpose * (wrist - elbow), bendsForward: true)
            let arm = MannequinPose.Arm(out: deg(a.z) * side, forward: -deg(a.x), inward: -deg(a.y) * side, elbow: -deg(a.bend))
            let l = aim(upper: knee - hip, lower: ankle - knee, bendsForward: false)
            let leg = MannequinPose.Leg(out: deg(l.z) * side, forward: -deg(l.x), inward: -deg(l.y) * side, knee: deg(l.bend))
            if side > 0 { p.left = arm; p.leftLeg = leg } else { p.right = arm; p.rightLeg = leg }
        }
        return p
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
