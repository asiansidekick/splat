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
    @State private var proportion: MannequinProportion
    @State private var showsBuild = false
    /// Phil, 2026-11-19 (Magic Poser): undo, redo, flip.
    @State private var undo: [MannequinPose] = []
    @State private var redo: [MannequinPose] = []
    @ObservedObject private var library = PoseLibrary.shared
    @State private var saving = false
    @State private var poseName = ""

    init(spec: MannequinSpec, onDone: @escaping (MannequinSpec) -> Void) {
        self.spec = spec
        self.onDone = onDone
        _pose = State(initialValue: spec.pose)
        _proportion = State(initialValue: spec.proportion ?? MannequinProportion())
    }

    /// One slider for the length or width of a part, from 80% to 120% of the standard body.
    private func buildSlider(_ name: String, _ value: Binding<Float>) -> some View {
        HStack {
            Text(name).font(Theme.footnote).frame(width: 78, alignment: .leading)
            Slider(value: value, in: 0.8...1.2).tint(Theme.accent)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").font(Theme.footnote.monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
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
                    changed.proportion = proportion.isStandard ? nil : proportion
                    onDone(changed)
                    dismiss()
                } label: { Text("Done").fontWeight(.bold) }
            }
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ZStack(alignment: .top) {
                PoseStage(person: spec.body, height: spec.height, proportion: proportion, pose: $pose, onBegin: { undo.append(pose); redo = [] })
                Text("Mint dots reach. Yellow: hips turn and tilt, wrists and ankles bend. Drag elsewhere to turn round.")
                    .font(Theme.caption)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 8) {
                Button("Undo") { if let last = undo.popLast() { redo.append(pose); pose = last } }.disabled(undo.isEmpty)
                Button("Redo") { if let next = redo.popLast() { undo.append(pose); pose = next } }.disabled(redo.isEmpty)
                Button("Mirror") { undo.append(pose); redo = []; pose = pose.mirrored }
                Button("Reset") { undo.append(pose); redo = []; pose = spec.pose == pose ? .standing : spec.pose }
                Button("Save") { saving = true }
                Button("Build") { showsBuild.toggle() }
            }
            .font(Theme.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(Theme.accent)
            .padding(.top, 6)
            if showsBuild {
                VStack(spacing: 2) {
                    buildSlider("Arms", $proportion.arms)
                    buildSlider("Legs", $proportion.legs)
                    buildSlider("Torso", $proportion.torso)
                    buildSlider("Head", $proportion.head)
                    buildSlider("Shoulders", $proportion.shoulders)
                    Button("Standard build") { proportion = MannequinProportion() }
                        .font(Theme.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(library.items) { item in
                        Button(item.name) { undo.append(pose); redo = []; pose = item.pose }
                            .font(Theme.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Theme.accent.opacity(0.25), in: Capsule())
                            .foregroundStyle(pose == item.pose ? Theme.accent : Color.white)
                            .contextMenu { Button("Delete", role: .destructive) { library.delete(item) } }
                    }
                    ForEach(MannequinPose.all, id: \.name) { item in
                        Button(item.name) { undo.append(pose); redo = []; pose = item.pose }
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
        .alert("Save pose", isPresented: $saving) {
            TextField("Name", text: $poseName)
            Button("Save") { library.save(pose, name: poseName); poseName = "" }
            Button("Cancel", role: .cancel) { poseName = "" }
        } message: {
            Text("Keep this pose to use again on any character. Hold a saved pose to delete it.")
        }
    }
}

/// The 3D view with the draggable dots.
private struct PoseStage: UIViewRepresentable {
    let person: Mannequin.Body
    let height: Float
    var proportion = MannequinProportion()
    @Binding var pose: MannequinPose
    var onBegin: () -> Void = {}

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
        context.coordinator.addTurnHandle(to: scene)
        context.coordinator.placeCamera()
        context.coordinator.rebuild(pose)
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.shown != pose || context.coordinator.shownProportion != proportion { context.coordinator.rebuild(pose) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PoseStage
        weak var view: SCNView?
        var camera: SCNNode?
        var figure: SCNNode?
        var handles: [String: SCNNode] = [:]
        var shown: MannequinPose?
        var shownProportion: MannequinProportion?
        private var yaw: Float = 0.5
        /// Phil, 2026-11-20: a rotate handle under the figure: curved white arrows on the floor facing the viewer.
        /// Drag them left or right to turn the figure round (the view orbits it).
        private var turnKnob: SCNNode?
        private var dragging: String?
        private var depth: Float = 0
        private var lastPoint: CGPoint = .zero

        init(_ parent: PoseStage) { self.parent = parent }

        func placeCamera() {
            let distance = parent.height * 1.9 + 0.6
            let centre = SIMD3<Float>(0, parent.height * 0.52, 0)
            camera?.simdPosition = centre + SIMD3(sin(yaw) * distance, parent.height * 0.12, cos(yaw) * distance)
            camera?.simdLook(at: centre)
            // The arrows face the viewer, wherever the view has orbited to.
            turnKnob?.eulerAngles.y = yaw
            turnKnob?.simdPosition = SIMD3(0, 0.004, 0)
        }

        func addTurnHandle(to scene: SCNScene) {
            let icon = TurnIcon.node(radius: parent.height * 0.3)
            scene.rootNode.addChildNode(icon)
            turnKnob = icon
        }

        func rebuild(_ pose: MannequinPose) {
            guard let scene = view?.scene else { return }
            figure?.removeFromParentNode()
            let made = Mannequin.make(parent.person, pose: pose, height: parent.height, proportion: parent.proportion)
            shownProportion = parent.proportion
            scene.rootNode.addChildNode(made)
            figure = made
            shown = pose
            for (_, handle) in handles { handle.removeFromParentNode() }
            handles = [:]
            // Phil, 2026-11-10: elbows and knees get their own (smaller) dots.
            for name in ["end.hand.L", "end.hand.R", "end.foot.L", "end.foot.R", "end.head", "elbow.L", "elbow.R", "knee.L", "knee.R",
                         "tip.hand.L", "tip.hand.R", "tip.foot.L", "tip.foot.R", "tip.crown", "tip.ear", "tip.shoulder.L", "tip.shoulder.R", "pelvis"] {
                guard let marker = made.childNode(withName: name, recursively: true) else { continue }
                let joint = !name.hasPrefix("end.")
                let dot = SCNNode(geometry: SCNSphere(radius: CGFloat((joint ? 0.032 : 0.045) * parent.height / 1.7)))
                dot.geometry?.firstMaterial?.diffuse.contents = Coordinator.articulates(name) ? UIColor.systemYellow : Theme.accentUI
                dot.geometry?.firstMaterial?.lightingModel = .constant
                dot.simdPosition = marker.simdWorldPosition
                dot.renderingOrder = 10
                dot.geometry?.firstMaterial?.readsFromDepthBuffer = false
                scene.rootNode.addChildNode(dot)
                handles[name] = dot
            }
        }

        /// Hips, wrists and ankles bend by how far they are dragged; the rest reach.
        static func articulates(_ name: String) -> Bool { name == "pelvis" || name.hasPrefix("tip.") }

        private var startPose = MannequinPose()
        private var startPoint: CGPoint = .zero

        private func articulate(_ handle: String, to point: CGPoint) {
            let side = handle.hasSuffix("L") ? 0 : 1
            let joint: PoseDrag.Joint = handle == "pelvis" ? .hips : handle == "tip.crown" ? .headLook : handle == "tip.ear" ? .headTilt : handle.hasPrefix("tip.shoulder") ? .shoulder(side)
                : handle.hasPrefix("tip.hand") ? .wrist(side) : .ankle(side)
            let pose = PoseDrag.solve(joint, target: .zero, top: .zero, middle: .zero, end: .zero, hips: .zero, from: startPose,
                                      screen: SIMD2(Float(point.x - startPoint.x), Float(point.y - startPoint.y)))
            rebuild(pose.limited)
            parent.pose = pose.limited
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
                if turnKnob != nil {
                    let reach = parent.height * 0.3
                    let p = view.projectPoint(SCNVector3(sin(yaw) * reach, 0.004, cos(yaw) * reach))
                    if hypot(CGFloat(p.x) - point.x, CGFloat(p.y) - point.y) < (dragging == nil ? 50 : best) { dragging = "turn" }
                }
                lastPoint = point
                startPoint = point
                startPose = shown ?? parent.pose
                if dragging != nil, dragging != "turn" { parent.onBegin() }
            case .changed:
                if dragging == "turn" {
                    yaw -= Float(point.x - lastPoint.x) * 0.012
                    lastPoint = point
                    placeCamera()
                } else if let dragging, Coordinator.articulates(dragging) {
                    articulate(dragging, to: point)
                } else if let dragging {
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
            if handle.hasPrefix("elbow.") || handle.hasPrefix("knee.") {
                // Swing the upper arm or thigh so the elbow or knee goes to the finger; the forearm or shin keeps its bend.
                let isArm = handle.hasPrefix("elbow.")
                let side = handle.hasSuffix("L") ? "L" : "R"
                guard let top = node(isArm ? "shoulder.\(side)" : "hip.\(side)"), let middle = node(handle),
                      let end = node(isArm ? "end.hand.\(side)" : "end.foot.\(side)") else { return }
                let s = top.simdWorldPosition, m = middle.simdWorldPosition, e = end.simdWorldPosition
                let a = simd_length(m - s)
                guard a > 0.01, simd_length(target - s) > 0.01 else { return }
                let swing = simd_quatf(from: simd_normalize(m - s), to: simd_normalize(target - s))
                let joint = s + a * simd_normalize(target - s)
                let hand = joint + swing.act(e - m)
                solveLimb(isArm: isArm, side: side, shoulder: s, joint: joint, end: hand, into: &pose)
            } else if handle == "end.head" {
                guard let pelvis = node("pelvis") else { return }
                let up = simd_normalize(target - pelvis.simdWorldPosition)
                pose.spineForward = max(-30, min(60, asin(max(-1, min(1, up.z))) * 180 / .pi))
                pose.spineSide = max(-30, min(30, atan2(-up.x, up.y) * 180 / .pi))
            } else {
                let isArm = handle.hasPrefix("end.hand")
                let side = handle.hasSuffix("L") ? "L" : "R"
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
                solveLimb(isArm: isArm, side: side, shoulder: s, joint: joint, end: hand, into: &pose)
            }
            pose = pose.limited
            rebuild(pose)
            parent.pose = pose
        }

        /// Turns a shoulder (or hip), elbow (or knee) and hand (or foot) position into the limb's angles.
        private func solveLimb(isArm: Bool, side: String, shoulder s: SIMD3<Float>, joint: SIMD3<Float>, end hand: SIMD3<Float>,
                               into pose: inout MannequinPose) {
                let sign: Float = side == "L" ? 1 : -1
                // Into the frame the limb hangs from: the spine for arms, the (unturned) pelvis for legs.
                let frame = isArm ? (node("spine.in")?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
                                  : (node("pelvis")?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
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
    }
}


/// Curved arrows lying on the floor, pointing both ways round: the picture for "drag left or right to turn it".
/// The arc is centred on the +Z side of the node and sits at its origin; (Phil, 2026-11-20).
enum TurnIcon {
    static func node(radius r: Float, width: Float? = nil) -> SCNNode {
        let w = width ?? r * 0.13
        let half: Float = 0.8
        let head = (w * 2.2) / r
        func point(_ angle: Float, _ radius: Float) -> CGPoint { CGPoint(x: CGFloat(sin(angle) * radius), y: CGFloat(cos(angle) * radius)) }
        let path = UIBezierPath()
        let steps = 20
        path.move(to: point(-half, r + w / 2))
        for i in 0...steps { path.addLine(to: point(-half + 2 * half * Float(i) / Float(steps), r + w / 2)) }
        path.addLine(to: point(half, r + w * 1.2))
        path.addLine(to: point(half + head, r))
        path.addLine(to: point(half, r - w * 1.2))
        for i in 0...steps { path.addLine(to: point(half - 2 * half * Float(i) / Float(steps), r - w / 2)) }
        path.addLine(to: point(-half, r - w * 1.2))
        path.addLine(to: point(-half - head, r))
        path.addLine(to: point(-half, r + w * 1.2))
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: CGFloat(w * 0.2))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.92)
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        shape.materials = [material]
        let arrows = SCNNode(geometry: shape)
        // The shape is drawn in X and Y; laid flat, its Y becomes the floor's +Z.
        arrows.eulerAngles.x = .pi / 2
        arrows.renderingOrder = 2500
        let holder = SCNNode()
        holder.name = "turnicon"
        holder.addChildNode(arrows)
        return holder
    }
}
