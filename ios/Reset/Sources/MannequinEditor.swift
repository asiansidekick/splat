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
    /// The group of ready-made poses shown along the bottom; nil shows the groups (Phil, 2026-11-22).
    @State private var chipGroup: String?

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
                    if let name = chipGroup, let group = MannequinPose.groups.first(where: { $0.name == name }) {
                        Button { chipGroup = nil } label: { Label("Groups", systemImage: "chevron.left") }
                            .font(Theme.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Theme.accent.opacity(0.25), in: Capsule())
                            .foregroundStyle(Color.white)
                        ForEach(group.poses, id: \.name) { item in
                            Button(item.name) { undo.append(pose); redo = []; pose = item.pose }
                                .font(Theme.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                                .background(Color.white.opacity(0.12), in: Capsule())
                                .foregroundStyle(pose == item.pose ? Theme.accent : Color.white)
                        }
                    } else {
                        ForEach(MannequinPose.groups, id: \.name) { group in
                            Button { chipGroup = group.name } label: { Label(group.name, systemImage: group.symbol) }
                                .font(Theme.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                                .background(Color.white.opacity(0.12), in: Capsule())
                                .foregroundStyle(group.poses.contains { $0.pose == pose } ? Theme.accent : Color.white)
                        }
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
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.shown != pose || context.coordinator.shownProportion != proportion {
            context.coordinator.rebuild(pose)
            context.coordinator.refreshWheels()
        }
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
            showSelected()
        }

        /// Hips, wrists and ankles bend by how far they are dragged; the rest reach.
        static func articulates(_ name: String) -> Bool { name == "pelvis" || name.hasPrefix("tip.") }

        private var startPose = MannequinPose()
        private var startPoint: CGPoint = .zero
        /// Phil, 2026-11-21: the dot last touched stays selected, with a wheel round its joint for each way it turns;
        /// and the yellow dots turn their joint the way the finger goes, like the mint ones.
        private let wheels = PoseWheelSet()
        private var selected: String?

        private static func joint(_ handle: String) -> PoseDrag.Joint {
            let side = handle.hasSuffix("L") ? 0 : 1
            switch handle {
            case "pelvis": return .hips
            case "tip.crown": return .headLook
            case "tip.ear": return .headTilt
            case "end.head": return .head
            default:
                if handle.hasPrefix("tip.shoulder") { return .shoulder(side) }
                if handle.hasPrefix("tip.hand") { return .wrist(side) }
                if handle.hasPrefix("tip.foot") { return .ankle(side) }
                if handle.hasPrefix("elbow.") { return .elbow(side) }
                if handle.hasPrefix("knee.") { return .knee(side) }
                if handle.hasPrefix("end.hand") { return .hand(side) }
                return .foot(side)
            }
        }

        private var project: (SIMD3<Float>) -> SIMD2<Float>? {
            { [weak view] p in
                guard let view else { return nil }
                let shown = view.projectPoint(SCNVector3(p.x, p.y, p.z))
                return shown.z > 0 && shown.z < 1 ? SIMD2(Float(shown.x), Float(shown.y)) : nil
            }
        }

        /// The wheels round the selected dot's joint, for the pose shown now.
        func refreshWheels() {
            guard let selected, dragging == nil, let root = view?.scene?.rootNode else { return }
            let pose = shown ?? parent.pose
            let h = parent.height
            func at(_ name: String) -> SIMD3<Float>? { node(name)?.simdWorldPosition }
            /// A point fixed to a part of the figure, found again by name (the figure is made afresh for each pose).
            func riding(_ name: String, _ world: SIMD3<Float>) -> () -> SIMD3<Float> {
                guard let n = node(name) else { return { world } }
                let local = n.simdConvertPosition(world, from: nil)
                return { [weak self] in self?.node(name)?.simdConvertPosition(local, to: nil) ?? world }
            }
            let joint = Self.joint(selected)
            let side = selected.hasSuffix("L") ? "L" : "R"
            let isArm: Bool = { if case .knee = joint { return false }; if case .foot = joint { return false }; if case .ankle = joint { return false }; return true }()
            let ratio: Float = {
                guard let a = at(isArm ? "shoulder.\(side)" : "hip.\(side)"), let b = at(isArm ? "elbow.\(side)" : "knee.\(side)"),
                      let e = at(isArm ? "end.hand.\(side)" : "end.foot.\(side)"), simd_distance(a, b) > 1e-5 else { return 1 }
                return simd_distance(b, e) / simd_distance(a, b)
            }()
            let up = SIMD3<Float>(0, 1, 0), ahead = SIMD3<Float>(0, 0, 1)
            let anchor: (PoseAxis) -> PoseWheelSet.Anchor? = { axis in
                func letter(_ s: Int) -> String { s == 0 ? "L" : "R" }
                switch axis {
                case .headTurn, .headNod:
                    guard let c = at("neck") else { return nil }
                    return .init(pivot: riding("tip.crown", c), probe: riding("tip.crown", c + ahead * (h * 0.1)))
                case .headTilt:
                    guard let c = at("neck") else { return nil }
                    return .init(pivot: riding("tip.crown", c), probe: riding("tip.crown", c + up * (h * 0.12)))
                case .shrug(let s), .roll(let s):
                    guard let l = at("shoulder.L"), let r = at("shoulder.R") else { return nil }
                    let middle = (l + r) / 2
                    return .init(pivot: { middle }, probe: riding("shoulder.\(letter(s))", s == 0 ? l : r))
                case .wristBend(let s), .wristSide(let s):
                    guard let w = at("wrist.\(letter(s))"), let tip = at("tip.hand.\(letter(s))") else { return nil }
                    return .init(pivot: riding("tip.hand.\(letter(s))", w), probe: riding("tip.hand.\(letter(s))", tip))
                case .anklePoint(let s), .ankleTurn(let s):
                    guard let a = at("ankle.\(letter(s))") else { return nil }
                    return .init(pivot: riding("tip.foot.\(letter(s))", a), probe: riding("tip.foot.\(letter(s))", a + ahead * (h * 0.08)))
                case .hipTurn, .hipTilt:
                    guard let c = at("pelvis"), let hip = at("hip.L") else { return nil }
                    return .init(pivot: riding("pelvis", c), probe: riding("hip.L", hip))
                case .leanForward, .leanSide:
                    guard let c = at("pelvis"), let n = at("neck") else { return nil }
                    return .init(pivot: riding("pelvis", c), probe: riding("neck", n))
                case .swivel(let arm, let s):
                    let l = letter(s)
                    guard let t = at(arm ? "shoulder.\(l)" : "hip.\(l)"), let m = at(arm ? "elbow.\(l)" : "knee.\(l)"),
                          let e = at(arm ? "end.hand.\(l)" : "end.foot.\(l)"), simd_distance(t, e) > 1e-4 else { return nil }
                    let line = simd_normalize(e - t)
                    let foot = t + line * simd_dot(m - t, line)
                    return .init(pivot: { foot }, probe: riding(arm ? "elbow.\(l)" : "knee.\(l)", m))
                case .bend(let arm, let s):
                    let l = letter(s)
                    guard let m = at(arm ? "elbow.\(l)" : "knee.\(l)"), let e = at(arm ? "end.hand.\(l)" : "end.foot.\(l)") else { return nil }
                    return .init(pivot: riding(arm ? "elbow.\(l)" : "knee.\(l)", m), probe: riding(arm ? "end.hand.\(l)" : "end.foot.\(l)", e))
                }
            }
            wheels.build(joint, pose: pose, ratio: ratio, smallest: h * 0.05, colours: [Theme.accentUI, .systemYellow],
                         show: { [weak self] in self?.rebuild($0) }, anchor: anchor, parent: root)
            rebuild(pose)
            showSelected()
        }

        /// The selected dot white, the others their own colour.
        private func showSelected() {
            for (name, dot) in handles {
                dot.geometry?.firstMaterial?.diffuse.contents = name == selected ? UIColor.white
                    : Coordinator.articulates(name) ? UIColor.systemYellow : Theme.accentUI
            }
        }

        private func select(_ name: String?) {
            selected = name
            if name == nil { wheels.clear() } else { refreshWheels() }
            showSelected()
        }

        /// The dot nearest the finger, within about a thumb's width.
        private func nearestHandle(_ point: CGPoint, within: CGFloat) -> (name: String, gap: CGFloat, depth: Float)? {
            guard let view else { return nil }
            var best: (name: String, gap: CGFloat, depth: Float)?
            for (name, handle) in handles {
                let p = view.projectPoint(handle.position)
                let gap = hypot(CGFloat(p.x) - point.x, CGFloat(p.y) - point.y)
                if gap < (best?.gap ?? within) { best = (name, gap, p.z) }
            }
            return best
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            select(nearestHandle(gesture.location(in: view), within: 44)?.name)
        }

        /// A yellow dot: its joint turns so the point it moves goes the way the finger has gone.
        private func articulate(to point: CGPoint) {
            let finger = SIMD2(Float(point.x), Float(point.y))
            guard let moved = wheels.dragHandle(to: finger, project: project) else { return }
            rebuild(moved.pose)
            parent.pose = moved.pose
            if moved.far {
                let was = dragging
                dragging = nil
                refreshWheels()
                dragging = was
                wheels.beginHandle(moved.pose, finger: finger)
            }
        }

        private func node(_ name: String) -> SCNNode? { figure?.childNode(withName: name, recursively: true) }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                dragging = nil
                startPoint = point
                startPose = shown ?? parent.pose
                lastPoint = point
                // A wheel of the selected dot first: the joint turns as the wheel does.
                if wheels.pick(SIMD2(Float(point.x), Float(point.y)), pose: startPose, project: project) {
                    dragging = "wheel"
                    parent.onBegin()
                    return
                }
                let near = nearestHandle(point, within: 44)
                let best: CGFloat = near?.gap ?? 44
                if let near { dragging = near.name; depth = near.depth }
                if turnKnob != nil {
                    let reach = parent.height * 0.3
                    let p = view.projectPoint(SCNVector3(sin(yaw) * reach, 0.004, cos(yaw) * reach))
                    if hypot(CGFloat(p.x) - point.x, CGFloat(p.y) - point.y) < (dragging == nil ? 50 : best) { dragging = "turn" }
                }
                if let name = dragging, name != "turn" {
                    parent.onBegin()
                    if Coordinator.articulates(name) {
                        if selected != name || wheels.joint != Self.joint(name) {
                            let was = dragging
                            dragging = nil
                            selected = name
                            refreshWheels()
                            dragging = was
                        }
                        wheels.beginHandle(startPose, finger: SIMD2(Float(point.x), Float(point.y)))
                    } else {
                        // The limb reaches: its wheels come back where it ends up.
                        selected = name
                        wheels.clear()
                        showSelected()
                    }
                }
            case .changed:
                if dragging == "wheel" {
                    if let pose = wheels.turnWheel(to: SIMD2(Float(point.x), Float(point.y)), project: project), pose != shown {
                        rebuild(pose)
                        parent.pose = pose
                    }
                } else if dragging == "turn" {
                    yaw -= Float(point.x - lastPoint.x) * 0.012
                    lastPoint = point
                    placeCamera()
                } else if let dragging, Coordinator.articulates(dragging) {
                    articulate(to: point)
                } else if let dragging {
                    let world = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), depth))
                    move(dragging, to: SIMD3(world.x, world.y, world.z))
                } else {
                    yaw -= Float(point.x - lastPoint.x) * 0.01
                    lastPoint = point
                    placeCamera()
                }
            default:
                let posed = dragging != nil && dragging != "turn"
                dragging = nil
                wheels.letGo()
                if posed, selected != nil { refreshWheels() }
            }
        }

        /// Solves the limb (or the lean) for the dragged dot and shows the new pose. The same posing as a character in
        /// live view (PoseDrag): real joint ranges, the elbow or knee kept pointing where it was, arms kept out of the body.
        private func move(_ handle: String, to target: SIMD3<Float>) {
            let pose = shown ?? parent.pose
            let side = handle.hasSuffix("L") ? "L" : "R"
            let index = side == "L" ? 0 : 1
            let joint: PoseDrag.Joint
            let isArm = handle.hasPrefix("elbow.") || handle.hasPrefix("end.hand") || handle == "end.head"
            if handle.hasPrefix("elbow.") { joint = .elbow(index) } else if handle.hasPrefix("knee.") { joint = .knee(index) }
            else if handle == "end.head" { joint = .head } else if handle.hasPrefix("end.hand") { joint = .hand(index) } else { joint = .foot(index) }
            guard let top = node(isArm ? "shoulder.\(side)" : "hip.\(side)"), let middle = node(isArm ? "elbow.\(side)" : "knee.\(side)"),
                  let end = node(isArm ? "end.hand.\(side)" : "end.foot.\(side)"), let pelvis = node("pelvis") else { return }
            // The arms hang from the spine as it leans from the pelvis; the legs from the pelvis.
            let hips = pelvis.simdWorldOrientation
            let frames = PoseDrag.Frames(
                arm: { p, _ in hips * simd_quatf(angle: p.spineSide * .pi / 180, axis: SIMD3(0, 0, 1)) * simd_quatf(angle: p.spineForward * .pi / 180, axis: SIMD3(1, 0, 0)) },
                leg: { _ in hips })
            let shape = Mannequin.torso(parent.person, height: parent.height, proportion: parent.proportion)
            let slabs = shape.slabs.compactMap { item in node(item.node).map { item.slab.moved(by: $0.simdWorldTransform) } }
            let body = BodyVolume(slabs: slabs, upperArm: shape.upperArm, forearm: shape.forearm)
            let solved = PoseDrag.solve(joint, target: target, top: top.simdWorldPosition, middle: middle.simdWorldPosition, end: end.simdWorldPosition,
                                        hips: pelvis.simdWorldPosition, from: pose, frames: frames, body: body)
            rebuild(solved)
            parent.pose = solved
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
