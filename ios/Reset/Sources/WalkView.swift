import SceneKit
import SwiftUI
import simd

/// Walk through a reference like street view (Phil, 2026-11-13): stand at one of the places it was shot, drag to look
/// round (the frames shot from that spot are hung round you), tap a ring on the floor to move to the next place.
/// Not AR: works anywhere, any time.
@MainActor
final class WalkScene: ObservableObject {
    struct Stop {
        let position: SIMD3<Float>
        /// Which way to face on arrival: the first frame shot there.
        let yaw: Float
        let members: [Int]
    }

    /// Frames shot within this distance of each other count as one standing place.
    static let samePlace: Float = 0.8
    static let reach: Float = 9
    static let frameLimit = 40

    let scene = SCNScene()
    /// Turns round (yaw) and sits at the standing place; the camera under it tilts (pitch).
    let yawNode = SCNNode()
    let cameraNode = SCNNode()
    private let pictures = SCNNode()
    private let rings = SCNNode()
    private var nodes: [SCNNode] = []
    @Published private(set) var stops: [Stop] = []
    @Published private(set) var current = 0
    @Published private(set) var ready = false
    @Published private(set) var failed = false
    @Published private(set) var pictureCount = 0
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var fieldOfView: CGFloat = 65
    private var released = false

    init() {
        let camera = SCNCamera()
        camera.zNear = 0.05
        camera.zFar = 80
        camera.fieldOfView = fieldOfView
        cameraNode.camera = camera
        yawNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(yawNode)
        scene.rootNode.addChildNode(pictures)
        scene.rootNode.addChildNode(rings)
        scene.background.contents = UIColor.black
    }

    func build(_ reference: Reference) async {
        let pieces = await Task.detached(priority: .userInitiated) {
            Backdrop.pieces(reference: reference, mapPoints: [], limit: WalkScene.frameLimit)
        }.value
        guard !released else { return }
        guard !pieces.isEmpty else {
            failed = true
            return
        }
        nodes = Backdrop.nodes(from: pieces)
        for node in nodes {
            node.isHidden = true
            pictures.addChildNode(node)
        }
        var found: [(position: SIMD3<Float>, yaw: Float, members: [Int])] = []
        for (index, piece) in pieces.enumerated() {
            let position = piece.camera.columns.3.xyz
            if let at = found.firstIndex(where: { simd_distance($0.position, position) < Self.samePlace }) {
                found[at].members.append(index)
            } else {
                let ahead = -piece.camera.columns.2.xyz
                found.append((position, atan2(-ahead.x, -ahead.z), [index]))
            }
        }
        stops = found.map { Stop(position: $0.position, yaw: $0.yaw, members: $0.members) }
        pictureCount = pieces.count
        ready = true
        go(to: 0, animated: false)
    }

    /// Stands at a place: its frames fade in and the others out, and the rings to the places near it appear.
    func go(to index: Int, animated: Bool = true) {
        guard stops.indices.contains(index) else { return }
        let stop = stops[index]
        let members = Set(stop.members)
        current = index
        for (i, node) in nodes.enumerated() where members.contains(i) { node.isHidden = false }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.6 : 0
        yawNode.position = SCNVector3(stop.position.x, stop.position.y, stop.position.z)
        for (i, node) in nodes.enumerated() { node.opacity = members.contains(i) ? 1 : 0 }
        SCNTransaction.completionBlock = { [weak self] in
            guard let self else { return }
            for (i, node) in self.nodes.enumerated() where !members.contains(i) { node.isHidden = true }
        }
        SCNTransaction.commit()
        if !animated { yaw = stop.yaw; pitch = 0; applyLook() }
        showRings()
    }

    private func showRings() {
        rings.childNodes.forEach { $0.removeFromParentNode() }
        let here = stops[current].position
        let near = stops.indices
            .filter { $0 != current }
            .map { (index: $0, distance: simd_distance(stops[$0].position, here)) }
            .filter { $0.distance < Self.reach }
            .sorted { $0.distance < $1.distance }
            .prefix(6)
        for item in near {
            var along = stops[item.index].position - here
            along.y = 0
            guard simd_length(along) > 0.05 else { continue }
            let spot = here + simd_normalize(along) * min(simd_length(along), 2.2) - SIMD3(0, 1.35, 0)
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.3, pipeRadius: 0.035))
            let disc = SCNNode(geometry: SCNCylinder(radius: 0.3, height: 0.004))
            for node in [ring, disc] {
                let material = SCNMaterial()
                material.diffuse.contents = UIColor(red: 0.45, green: 0.95, blue: 0.75, alpha: node === ring ? 0.95 : 0.3)
                material.lightingModel = .constant
                material.readsFromDepthBuffer = false
                material.writesToDepthBuffer = false
                node.geometry?.materials = [material]
                node.renderingOrder = 200
            }
            let holder = SCNNode()
            holder.name = "stop-\(item.index)"
            holder.addChildNode(ring)
            holder.addChildNode(disc)
            holder.position = SCNVector3(spot.x, spot.y, spot.z)
            rings.addChildNode(holder)
        }
    }

    /// The place a tap landed on, if it was on a ring.
    func place(at hits: [SCNHitTestResult]) -> Int? {
        for hit in hits {
            var node: SCNNode? = hit.node
            while let current = node {
                if let name = current.name, name.hasPrefix("stop-"), let index = Int(name.dropFirst(5)) { return index }
                node = current.parent
            }
        }
        return nil
    }

    func look(dx: CGFloat, dy: CGFloat, height: CGFloat) {
        let perPoint = Float(fieldOfView * .pi / 180) / Float(max(height, 1))
        yaw += Float(dx) * perPoint
        pitch = min(max(pitch + Float(dy) * perPoint, -1.4), 1.4)
        applyLook()
    }

    func zoom(by scale: CGFloat) {
        fieldOfView = min(max(fieldOfView / scale, 30), 100)
        cameraNode.camera?.fieldOfView = fieldOfView
    }

    private func applyLook() {
        yawNode.eulerAngles = SCNVector3(0, yaw, 0)
        cameraNode.eulerAngles = SCNVector3(pitch, 0, 0)
    }

    /// Lets go of the pictures (they are the memory); called when the viewer closes.
    func release() {
        released = true
        for node in nodes {
            node.geometry = nil
            node.removeFromParentNode()
        }
        nodes = []
        rings.childNodes.forEach { $0.removeFromParentNode() }
    }
}

struct WalkSceneView: UIViewRepresentable {
    let walk: WalkScene

    func makeCoordinator() -> Coordinator { Coordinator(walk: walk) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = walk.scene
        view.pointOfView = walk.cameraNode
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let walk: WalkScene
        init(walk: WalkScene) { self.walk = walk }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let move = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            walk.look(dx: move.x, dy: move.y, height: view.bounds.height)
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            walk.zoom(by: gesture.scale)
            gesture.scale = 1
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .boundingBoxOnly: true,
            ])
            if let index = walk.place(at: hits) {
                Haptics.tap()
                walk.go(to: index)
            }
        }
    }
}

struct WalkView: View {
    let reference: Reference
    @Environment(\.dismiss) private var dismiss
    @StateObject private var walk = WalkScene()
    @State private var hint = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            WalkSceneView(walk: walk).ignoresSafeArea()
            if walk.failed {
                Text("This reference has no frames to walk through.")
                    .font(Theme.footnote).foregroundStyle(.white.opacity(0.8))
            } else if !walk.ready {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Button("Done") { dismiss() }
                        .font(Theme.body.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer()
                    if walk.ready {
                        Text("Place \(walk.current + 1) of \(walk.stops.count)")
                            .font(Theme.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2)
                Spacer()
                if walk.ready, hint {
                    Text("Drag to look. Pinch to zoom. Tap a ring to move.")
                        .font(Theme.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2)
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await walk.build(reference)
            try? await Task.sleep(for: .seconds(6))
            withAnimation { hint = false }
        }
        .onDisappear { walk.release() }
    }
}
