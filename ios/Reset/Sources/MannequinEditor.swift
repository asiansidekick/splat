import SceneKit
import SwiftUI
import UIKit

/// Pose a mannequin by hand (Phil, 2026-11-10): drag a hand or foot and the arm or leg follows; drag the head to
/// lean the body; drag anywhere else to walk round it. Presets along the bottom.
struct MannequinPoseEditor: View {
    let spec: MannequinSpec
    let onDone: (MannequinSpec) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pose: MannequinPose

    init(spec: MannequinSpec, onDone: @escaping (MannequinSpec) -> Void) {
        self.spec = spec
        self.onDone = onDone
        _pose = State(initialValue: spec.pose)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon) }
                Spacer()
                Text("Pose").font(Theme.headline)
                Spacer()
                Button {
                    var changed = spec
                    changed.pose = pose
                    onDone(changed)
                    dismiss()
                } label: { Text("Done").fontWeight(.bold) }
            }
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ZStack(alignment: .top) {
                PoseStage(person: spec.body, height: spec.height, pose: $pose)
                Text("Drag a mint dot: hands and feet move the arm or leg, the head leans the body. Drag elsewhere to turn round.")
                    .font(Theme.caption)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MannequinPose.all, id: \.name) { item in
                        Button(item.name) { pose = item.pose }
                            .font(Theme.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(pose == item.pose ? Theme.accent : Color.white)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 10)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// The 3D view with the draggable dots.
private struct PoseStage: UIViewRepresentable {
    let person: Mannequin.Body
    let height: Float
    @Binding var pose: MannequinPose

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        let scene = SCNScene()
        view.scene = scene
        let floor = SCNNode(geometry: SCNCylinder(radius: 0.8, height: 0.005))
        floor.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.2, alpha: 1)
        floor.simdPosition = SIMD3(0, -0.003, 0)
        scene.rootNode.addChildNode(floor)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 40
        scene.rootNode.addChildNode(camera)
        context.coordinator.view = view
        context.coordinator.camera = camera
        context.coordinator.placeCamera()
        context.coordinator.rebuild(pose)
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.shown != pose { context.coordinator.rebuild(pose) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PoseStage
        weak var view: SCNView?
        var camera: SCNNode?
        var figure: SCNNode?
        var handles: [String: SCNNode] = [:]
        var shown: MannequinPose?
        private var yaw: Float = 0.5
        private var dragging: String?
        private var depth: Float = 0
        private var lastPoint: CGPoint = .zero

        init(_ parent: PoseStage) { self.parent = parent }

        func placeCamera() {
            let distance = parent.height * 1.9 + 0.6
            let centre = SIMD3<Float>(0, parent.height * 0.52, 0)
            camera?.simdPosition = centre + SIMD3(sin(yaw) * distance, parent.height * 0.12, cos(yaw) * distance)
            camera?.simdLook(at: centre)
        }

        func rebuild(_ pose: MannequinPose) {
            guard let scene = view?.scene else { return }
            figure?.removeFromParentNode()
            let made = Mannequin.make(parent.person, pose: pose, height: parent.height)
            scene.rootNode.addChildNode(made)
            figure = made
            shown = pose
            for (_, handle) in handles { handle.removeFromParentNode() }
            handles = [:]
            for name in ["end.hand.L", "end.hand.R", "end.foot.L", "end.foot.R", "end.head"] {
                guard let marker = made.childNode(withName: name, recursively: true) else { continue }
                let dot = SCNNode(geometry: SCNSphere(radius: CGFloat(0.045 * parent.height / 1.7)))
                dot.geometry?.firstMaterial?.diffuse.contents = Theme.accentUI
                dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.simdPosition = marker.simdWorldPosition
                dot.renderingOrder = 10
                dot.geometry?.firstMaterial?.readsFromDepthBuffer = false
                scene.rootNode.addChildNode(dot)
                handles[name] = dot
            }
        }

        private func node(_ name: String) -> SCNNode? { figure?.childNode(withName: name, recursively: true) }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                dragging = nil
                var best: CGFloat = 44
                for (name, handle) in handles {
                    let p = view.projectPoint(handle.position)
                    let gap = hypot(CGFloat(p.x) - point.x, CGFloat(p.y) - point.y)
                    if gap < best { best = gap; dragging = name; depth = p.z }
                }
                lastPoint = point
            case .changed:
                if let dragging {
                    let world = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), depth))
                    move(dragging, to: SIMD3(world.x, world.y, world.z))
                } else {
                    yaw -= Float(point.x - lastPoint.x) * 0.01
                    lastPoint = point
                    placeCamera()
                }
            default:
                dragging = nil
            }
        }

        /// Solves the limb (or the lean) for the dragged dot and shows the new pose.
        private func move(_ handle: String, to target: SIMD3<Float>) {
            var pose = shown ?? parent.pose
            if handle == "end.head" {
                guard let pelvis = node("pelvis") else { return }
                let up = simd_normalize(target - pelvis.simdWorldPosition)
                pose.spineForward = max(-30, min(60, asin(max(-1, min(1, up.z))) * 180 / .pi))
                pose.spineSide = max(-30, min(30, atan2(-up.x, up.y) * 180 / .pi))
            } else {
                let isArm = handle.hasPrefix("end.hand")
                let side = handle.hasSuffix("L") ? "L" : "R"
                let sign: Float = side == "L" ? 1 : -1
                guard let top = node(isArm ? "shoulder.\(side)" : "hip.\(side)"),
                      let middle = node(isArm ? "elbow.\(side)" : "knee.\(side)"),
                      let end = node(handle) else { return }
                let s = top.simdWorldPosition, m = middle.simdWorldPosition, e = end.simdWorldPosition
                let a = simd_length(m - s), b = simd_length(e - m)
                var toTarget = target - s
                let reach = min(simd_length(toTarget), (a + b) * 0.995)
                guard reach > 0.01 else { return }
                toTarget = simd_normalize(toTarget)
                // Bend the same way as now, so the elbow or knee keeps pointing where it did.
                var pole = (m - s) - simd_dot(m - s, toTarget) * toTarget
                if simd_length(pole) < 0.01 { pole = isArm ? SIMD3(0, -0.3, -1) : SIMD3(0, 0, 1) }
                pole = simd_normalize(pole - simd_dot(pole, toTarget) * toTarget)
                let cosAngle = max(-1, min(1, (a * a + reach * reach - b * b) / (2 * a * reach)))
                let joint = s + a * (cosAngle * toTarget + sqrt(max(0, 1 - cosAngle * cosAngle)) * pole)
                let hand = s + reach * toTarget
                // Into the frame the limb hangs from: the spine for arms, the (unturned) pelvis for legs.
                let frame = isArm ? (node("spine.in")?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
                                  : simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
                let upper = frame.inverse.act(joint - s), lower = frame.inverse.act(hand - joint)
                let solved = PoseFromSkeleton.aim(upper: upper, lower: lower, bendsForward: isArm)
                let deg: (Float) -> Float = { $0 * 180 / .pi }
                if isArm {
                    let arm = MannequinPose.Arm(out: deg(solved.z) * sign, forward: -deg(solved.x), inward: -deg(solved.y) * sign, elbow: max(0, -deg(solved.bend)))
                    if side == "L" { pose.left = arm } else { pose.right = arm }
                } else {
                    let leg = MannequinPose.Leg(out: deg(solved.z) * sign, forward: -deg(solved.x), inward: -deg(solved.y) * sign, knee: max(0, deg(solved.bend)))
                    if side == "L" { pose.leftLeg = leg } else { pose.rightLeg = leg }
                }
            }
            rebuild(pose)
            parent.pose = pose
        }
    }
}
