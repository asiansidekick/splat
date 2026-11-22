import SceneKit
import SwiftUI
import simd

/// Putting a scanned head on a body (Phil, 2026-11-22: "it's too small, needs adjustment, the head to body menu is
/// ugly, need to see the body"). The bodies are pictures along the bottom edge; the chosen one stands in the middle
/// wearing the head, sized at first to its own head. Pinch sizes the head, dragging up or down raises or lowers it,
/// dragging sideways turns the body to look at it from the side. Place puts it in the room as shown.
struct HeadFitScreen: View {
    let head: HeadFolder
    /// A character to begin with (from a character's own menu); else the first body.
    var start: URL? = nil
    let done: (HeadTarget, HeadFit) -> Void
    let cancel: () -> Void

    @StateObject private var stage = HeadFitStage()
    @State private var targets: [(name: String, target: HeadTarget)] = []
    @State private var chosen = -1
    /// Each body's fit, as adjusted, kept while switching between bodies.
    @State private var fits: [Int: HeadFit] = [:]
    @State private var fit = HeadFit()
    @State private var pinchFrom: Float?
    @State private var dragFrom: (lift: Float, turn: Float)?
    @State private var dragUpDown: Bool?
    @State private var close = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HeadFitView(stage: stage)
                .ignoresSafeArea()
                .gesture(drag)
                .simultaneousGesture(pinch)
            if stage.loading { ProgressView().tint(.white) }
            if let problem = stage.problem {
                Text(problem).font(.footnote.weight(.semibold)).foregroundStyle(.orange).multilineTextAlignment(.center)
                    .padding(14).background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).padding(30)
            }
            VStack(spacing: 0) {
                HStack {
                    Button("Back", action: cancel).font(.body.weight(.semibold)).foregroundStyle(.white)
                    Spacer()
                    Button(close ? "Whole body" : "Close up") {
                        close.toggle()
                        stage.frame(close: close)
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.white.opacity(0.15), in: Capsule())
                }
                .shadow(radius: 3)
                .padding(.horizontal, 18).padding(.top, 10)
                Spacer()
                HStack(alignment: .bottom) {
                    Text("Pinch to size the head. Drag up or down to raise it, sideways to look round.")
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .shadow(color: .black, radius: 3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button { if chosen >= 0 { done(targets[chosen].target, fit) } } label: {
                        Text("Place").font(.body.weight(.semibold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 22).padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                    }
                    .disabled(chosen < 0 || stage.loading || stage.problem != nil)
                }
                .padding(.horizontal, 18).padding(.bottom, 10)
                bodies
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear {
            targets = HeadTarget.all()
            var first = 0
            if let start, let index = targets.firstIndex(where: { if case .character(let url) = $0.target { return url.standardizedFileURL == start.standardizedFileURL }; return false }) {
                first = index
            }
            choose(first)
        }
        .onDisappear { stage.tidy() }
    }

    /// The bodies along the bottom edge, as pictures with their names.
    private var bodies: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(targets.indices, id: \.self) { i in
                        Button { choose(i) } label: {
                            VStack(spacing: 3) {
                                BodyPicture(target: targets[i].target)
                                    .frame(width: 68, height: 68)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(i == chosen ? Theme.accent : Color.clear, lineWidth: 3))
                                Text(targets[i].name).font(.caption2.weight(.semibold)).foregroundStyle(i == chosen ? Theme.accent : .white)
                                    .lineLimit(2).multilineTextAlignment(.center).frame(width: 76)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .background(Color.black.opacity(0.55).ignoresSafeArea(edges: .bottom))
            .onChange(of: chosen) { _, i in withAnimation { scroller.scrollTo(i, anchor: .center) } }
        }
    }

    private func choose(_ index: Int) {
        guard index >= 0, index < targets.count, index != chosen else { return }
        if chosen >= 0 { fits[chosen] = fit }
        chosen = index
        let shown = stage.show(targets[index].target, head: head, fit: fits[index])
        fit = shown
        stage.frame(close: close)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchFrom == nil { pinchFrom = fit.scale }
                fit.scale = min(3, max(0.3, (pinchFrom ?? 1) * Float(value.magnification)))
                stage.apply(fit)
            }
            .onEnded { _ in pinchFrom = nil }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragFrom == nil {
                    dragFrom = (fit.lift, stage.turn)
                    dragUpDown = abs(value.translation.height) > abs(value.translation.width)
                }
                guard let from = dragFrom else { return }
                if dragUpDown == true {
                    // Close up a finger's length moves the head a few centimetres; the whole body, more.
                    let perPoint: Float = close ? 0.0004 : 0.0015
                    fit.lift = min(0.25, max(-0.25, from.lift - Float(value.translation.height) * perPoint))
                    stage.apply(fit)
                } else {
                    stage.setTurn(from.turn + Float(value.translation.width) * 0.01)
                }
            }
            .onEnded { _ in
                dragFrom = nil
                dragUpDown = nil
            }
    }
}

/// A body's small picture: a mannequin drawn here, a character as the gallery draws it.
private struct BodyPicture: View {
    let target: HeadTarget
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "figure.stand").font(.title2).foregroundStyle(.gray) }
        }
        .task(id: key) {
            switch target {
            case .mannequin(let body): image = HeadFitStage.mannequinPicture(body)
            case .character(let url): image = await FBXThumbnail.render(url)
            }
        }
    }

    private var key: String {
        switch target {
        case .mannequin(let body): return body.rawValue
        case .character(let url): return url.path
        }
    }
}

/// The 3D scene of the Put on a body screen.
@MainActor
final class HeadFitStage: ObservableObject {
    let scene = SCNScene()
    let camera = SCNNode()
    private let turner = SCNNode()
    private var shown: SCNNode?
    private var fitNode: SCNNode?
    private var height: Float = 1.7
    private var temporary: [URL] = []
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    private(set) var turn: Float = 0

    init() {
        scene.background.contents = UIColor(white: 0.13, alpha: 1)
        scene.rootNode.addChildNode(turner)
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.camera?.zNear = 0.02
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 700
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.simdEulerAngles = SIMD3(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(key)
    }

    /// Shows a body wearing the head, with `fit` or else sized to the body's own head. Returns the fit shown.
    func show(_ target: HeadTarget, head: HeadFolder, fit given: HeadFit?) -> HeadFit {
        shown?.removeFromParentNode()
        shown = nil
        fitNode = nil
        problem = nil
        guard let mesh = head.loadHead() else {
            problem = "The head couldn't be opened."
            return given ?? HeadFit()
        }
        var fit = given ?? HeadFit()
        let node: SCNNode
        switch target {
        case .mannequin(let body):
            if given == nil { fit = HeadFit.auto(mesh, room: Mannequin.headRoom(body, height: nil, proportion: nil)) }
            node = Mannequin.make(body, pose: MannequinPose.standing, head: HeadFit.wrap(mesh, pictures: head.url, fit: fit))
            height = Mannequin.defaultHeight(body)
        case .character(let url):
            // A copy of the character with the head beside it, read as it will be placed.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HeadFit-\(UUID().uuidString)", isDirectory: true)
            temporary.append(folder)
            let copy = folder.appendingPathComponent(url.lastPathComponent)
            let textures = FBXImport.texturesFolder(for: copy)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: copy)
                if FileManager.default.fileExists(atPath: FBXImport.texturesFolder(for: url).path) {
                    try FileManager.default.copyItem(at: FBXImport.texturesFolder(for: url), to: textures)
                }
                try FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)
                for old in (try? FileManager.default.contentsOfDirectory(atPath: textures.path)) ?? [] where old == ScanRig.headFile || old.hasPrefix("scanned-head-") {
                    try? FileManager.default.removeItem(at: textures.appendingPathComponent(old))
                }
                for file in head.headFiles { try FileManager.default.copyItem(at: file, to: textures.appendingPathComponent(file.lastPathComponent)) }
                try given?.save(to: textures)
            } catch {
                problem = "This character couldn't be read."
                return fit
            }
            guard let loaded = FBXImport.load(copy, name: url.deletingPathExtension().lastPathComponent) else {
                problem = "This character couldn't be read."
                return fit
            }
            guard let used = loaded.headFit else {
                problem = "No head was found on this character's skeleton, so a head can't go on it."
                return fit
            }
            fit = used
            node = loaded.node
            height = max(0.3, loaded.high.y - loaded.low.y)
        }
        turner.addChildNode(node)
        shown = node
        fitNode = node.childNode(withName: HeadFit.nodeName, recursively: true)
        apply(fit)
        return fit
    }

    func apply(_ fit: HeadFit) {
        fitNode?.simdTransform = fit.transform
    }

    func setTurn(_ angle: Float) {
        turn = angle
        turner.simdOrientation = simd_quatf(angle: angle, axis: SIMD3(0, 1, 0))
    }

    /// Close up on the head, or the whole body.
    func frame(close: Bool) {
        var target = SIMD3<Float>(0, height * 0.5, 0)
        var distance = height * 2.2 + 0.3
        if close {
            let at = fitNode?.simdWorldPosition ?? SIMD3(0, height * 0.9, 0)
            target = SIMD3(0, at.y + 0.08, 0)
            distance = 1.0
        }
        camera.simdPosition = target + SIMD3(0, close ? 0.05 : height * 0.1, distance)
        camera.simdLook(at: target)
    }

    /// The copies made for showing characters go when the screen closes.
    func tidy() {
        for folder in temporary { try? FileManager.default.removeItem(at: folder) }
        temporary = []
    }

    private static var pictures: [MannequinBody: UIImage] = [:]

    static func mannequinPicture(_ body: MannequinBody) -> UIImage? {
        if let hit = pictures[body] { return hit }
        let scene = SCNScene()
        scene.background.contents = UIColor.white
        scene.rootNode.addChildNode(Mannequin.make(body, pose: MannequinPose.standing))
        let h = Mannequin.defaultHeight(body)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.simdPosition = SIMD3(0, h / 2, h * 2.1)
        camera.simdLook(at: SIMD3(0, h / 2, 0))
        scene.rootNode.addChildNode(camera)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .ambient
        light.light?.intensity = 900
        scene.rootNode.addChildNode(light)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.simdEulerAngles = SIMD3(-0.5, 0.4, 0)
        scene.rootNode.addChildNode(key)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 240, height: 240), antialiasingMode: .multisampling4X)
        pictures[body] = image
        return image
    }
}

private struct HeadFitView: UIViewRepresentable {
    @ObservedObject var stage: HeadFitStage

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = stage.scene
        view.pointOfView = stage.camera
        view.backgroundColor = UIColor(white: 0.13, alpha: 1)
        view.antialiasingMode = .multisampling4X
        // Phil's 1406 test: a view drawn only on demand showed nothing. It draws all the time here.
        view.rendersContinuously = true
        view.isPlaying = true
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}
