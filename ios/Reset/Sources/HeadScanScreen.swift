import ARKit
import RealityKit
import SceneKit
import SwiftUI

/// What a scanned head can be put on (Phil, 2026-11-22: "have that as an option to place on any character"): a
/// mannequin, or any posable character in the gallery (a scanned person or an imported Mixamo FBX).
enum HeadTarget {
    case mannequin(MannequinBody)
    case character(URL)

    /// Every character in the gallery a head can go on: the mannequins first, then the FBX characters.
    static func all() -> [(name: String, target: HeadTarget)] {
        MannequinBody.allCases.map { ("\($0.rawValue) mannequin", HeadTarget.mannequin($0)) }
            + ModelLibrary.all().filter { $0.pathExtension.lowercased() == "fbx" }.map { ($0.deletingPathExtension().lastPathComponent, HeadTarget.character($0)) }
    }
}

/// Head scanning, one step after another like the object scanner: camera, building, check, done.
@MainActor
final class HeadScanModel: ObservableObject {
    enum Phase: Equatable {
        case starting, ready, capturing, finishing
        case building(Double)
        case check(HeadFolder)
        case fitting(HeadFolder)
        case done(HeadFolder)
        case failed(String)
    }

    @Published var phase: Phase = .starting
    /// Remembered: the front camera (selfie) or the back camera (someone walks round the actor).
    @Published var selfie: Bool {
        didSet {
            UserDefaults.standard.set(selfie, forKey: "headScanSelfie")
            if selfie != oldValue, phase == .ready || phase == .starting { start(after: 0.3) }
        }
    }
    @Published private(set) var last: HeadFolder? = HeadFolder.all().first
    let capture = HeadCapture()
    private var folder: HeadFolder?
    private var startTask: Task<Void, Never>?

    init() {
        selfie = (UserDefaults.standard.object(forKey: "headScanSelfie") as? Bool ?? true) && HeadCapture.selfieSupported
    }

    /// `after`: the camera another scanner held is let go of first.
    func start(after delay: Double = 0.9) {
        guard PhotogrammetrySession.isSupported else {
            phase = .failed(DeviceSupport.apology("scanning heads"))
            return
        }
        capture.stop()
        if let folder, !folder.hasHead { try? FileManager.default.removeItem(at: folder.url) }
        folder = nil
        HeadFolder.tidy()
        phase = .starting
        startTask?.cancel()
        startTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            do {
                let made = try HeadFolder.new()
                self.folder = made
                self.capture.begin(made, selfie: self.selfie)
                self.phase = .ready
            } catch {
                self.phase = .failed("Couldn't make the head's folder: \(error.localizedDescription)")
            }
        }
    }

    func shutter() {
        switch phase {
        case .ready:
            capture.recording = true
            phase = .capturing
            Diagnostics.log("Head scan: recording (\(selfie ? "selfie" : "walking round"))")
        case .capturing:
            // A selfie stopped before the ring filled still goes on to the back of the head; the next tap builds.
            if selfie, capture.startBackOfHead() { return }
            finish()
        default: break
        }
    }

    func finish() {
        guard phase == .capturing, let folder else { return }
        phase = .finishing
        Task { [weak self] in
            guard let self else { return }
            let count = await self.capture.end()
            Diagnostics.log("Head scan: stopped with \(count) pictures, \(self.capture.lit.count) of \(HeadCapture.slots) of the ring")
            guard count >= 12 else {
                try? FileManager.default.removeItem(at: folder.url)
                self.folder = nil
                self.phase = .failed(HeadBuilder.Failure.tooFew(count).words)
                return
            }
            self.build(folder)
        }
    }

    private func build(_ folder: HeadFolder) {
        phase = .building(0)
        Task { [weak self] in
            do {
                try await HeadBuilder.build(folder) { fraction in
                    Task { @MainActor [weak self] in
                        if case .building = self?.phase { self?.phase = .building(fraction) }
                    }
                }
                self?.last = folder
                self?.phase = .check(folder)
            } catch {
                Diagnostics.log("Head scan: build failed: \(error)")
                self?.phase = .failed((error as? HeadBuilder.Failure)?.words ?? "Couldn't build the head: \(error.localizedDescription)")
            }
        }
    }

    /// Saved: straight on to putting it on a body.
    func saved(_ folder: HeadFolder) {
        last = folder
        self.folder = nil
        phase = .fitting(folder)
    }

    func fit(_ folder: HeadFolder) { phase = .fitting(folder) }

    /// Scan again: this head goes.
    func again(dropping folder: HeadFolder?) {
        if let folder { try? FileManager.default.removeItem(at: folder.url) }
        last = HeadFolder.all().first
        start(after: 0.3)
    }

    func show(_ folder: HeadFolder) {
        capture.stop()
        phase = .done(folder)
    }

    /// Leaving: the camera is let go of. A build that is running carries on; an unbuilt scan leaves nothing behind.
    func close() {
        startTask?.cancel()
        capture.stop()
        if let folder, !folder.hasHead, phase == .ready || phase == .capturing || phase == .starting {
            try? FileManager.default.removeItem(at: folder.url)
        }
    }
}

struct HeadScanScreen: View {
    let close: () -> Void
    /// A character file to stand in the room (an FBX made with the head).
    let place: (URL) -> Void
    /// A mannequin wearing the head, to stand in the room.
    let mannequin: (HeadFolder, MannequinBody, HeadFit) -> Void
    /// Back to the object scanner: Object (false) or Person (true).
    let switchMode: (Bool) -> Void
    @StateObject private var model = HeadScanModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .building(let fraction):
                BuildingView(fraction: fraction, words: "Building the head on the phone")
            case .check(let folder):
                HeadCheckView(folder: folder, saved: { model.saved(folder) }, again: { model.again(dropping: folder) })
            case .fitting(let folder):
                HeadFitScreen(head: folder, done: { putOn(folder, $0, $1) }, cancel: { model.show(folder) })
            case .done(let folder):
                HeadDoneView(folder: folder, putOn: { model.fit(folder) }, again: { model.again(dropping: nil) }, close: close)
            case .failed(let text):
                MessageView(text: text, close: close) { model.start(after: 0.3) }
            default:
                CameraView(session: model.capture.session).ignoresSafeArea()
                HeadCaptureControls(model: model, capture: model.capture, close: close, switchMode: { person in
                    model.close()
                    switchMode(person)
                })
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.close() }
    }

    private func putOn(_ folder: HeadFolder, _ target: HeadTarget, _ fit: HeadFit) {
        model.close()
        switch target {
        case .mannequin(let body):
            mannequin(folder, body, fit)
        case .character(let url):
            do { place(try HeadPiece.put(folder, on: url, fit: fit)) } catch {
                Diagnostics.log("Head scan: could not put \(folder.title) on \(url.lastPathComponent): \(error)")
            }
        }
    }
}

/// The camera's controls: the ring filling as the head is seen from all round, the modes and the shutter.
private struct HeadCaptureControls: View {
    @ObservedObject var model: HeadScanModel
    @ObservedObject var capture: HeadCapture
    let close: () -> Void
    let switchMode: (Bool) -> Void

    var body: some View {
        ZStack {
            HeadRing(lit: capture.lit, slots: HeadCapture.slots, active: model.phase == .capturing)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Button("Done", action: close).font(.body.weight(.semibold)).fixedSize()
                    if model.phase == .capturing {
                        Text("\(capture.shots) / \(capture.maxShots)").font(.caption.monospacedDigit().weight(.semibold))
                    }
                    Spacer()
                    Text(capture.hint).font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                }
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
                if model.phase == .ready || model.phase == .starting {
                    cameraPicker
                    modePicker
                }
                Text(stepText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 3)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                bottomBar
            }
        }
        // A full ring builds straight away, like Face ID finishing on its own.
        .onChange(of: capture.complete) { _, full in
            if full, model.phase == .capturing { model.finish() }
        }
    }

    private var stepText: String {
        switch model.phase {
        case .starting: return "Starting camera…"
        case .ready where model.selfie: return "Phone at arm's length. Tap, then turn your head slowly to fill the circle"
        case .capturing where model.selfie && capture.backOfHead:
            return "Now the back: stand the phone up, then turn slowly all the way round until you face it again. Tap to finish"
        case .capturing where model.selfie: return "Slowly left, right, up and down"
        case .ready: return "Tap, then walk slowly round the actor, head in the middle"
        case .capturing: return "All the way round, phone a little above the head. Tap to stop"
        case .finishing: return "Saving pictures…"
        default: return ""
        }
    }

    /// Like the Camera app's modes: words above the shutter, the chosen one in yellow.
    private var modePicker: some View {
        HStack(spacing: 22) {
            Button("Object") { switchMode(false) }.foregroundStyle(.white)
            Button("Person") { switchMode(true) }.foregroundStyle(.white)
            Text("Head").foregroundStyle(.yellow)
        }
        .font(.footnote.weight(.semibold))
        .fixedSize()
        .shadow(radius: 3)
        .padding(.bottom, 10)
    }

    /// Which camera: the front one for your own head, the back one for someone else's.
    private var cameraPicker: some View {
        HStack(spacing: 22) {
            if HeadCapture.selfieSupported {
                Button("Selfie") { model.selfie = true }
                    .foregroundStyle(model.selfie ? Color.yellow : Color.white)
            }
            Button("Someone else") { model.selfie = false }
                .foregroundStyle(model.selfie ? Color.white : Color.yellow)
        }
        .font(.caption.weight(.semibold))
        .fixedSize()
        .shadow(radius: 3)
        .padding(.bottom, 8)
    }

    private var bottomBar: some View {
        HStack {
            Button { if let last = model.last { model.show(last) } } label: { HeadThumb(folder: model.last) }
                .frame(width: 80)
                .disabled(model.last == nil || model.phase == .capturing)
            Spacer()
            Button(action: model.shutter) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    if model.phase == .capturing {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                    } else {
                        Circle().fill(.white).frame(width: 60, height: 60)
                    }
                }
            }
            .disabled(!(model.phase == .ready || model.phase == .capturing))
            Spacer()
            Group {
                if model.phase == .capturing {
                    Button("Cancel") { model.again(dropping: nil) }
                } else {
                    Color.clear
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 80, height: 44)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }
}

/// A ring of short lines round the middle of the picture, lit one by one as the head is seen from each way (as Face ID
/// does when it learns a face).
private struct HeadRing: View {
    let lit: Set<Int>
    let slots: Int
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) * 0.36
            ZStack {
                ForEach(0..<slots, id: \.self) { i in
                    Capsule()
                        .fill(lit.contains(i) ? Theme.accent : Color.white.opacity(active ? 0.55 : 0.3))
                        .frame(width: 4, height: lit.contains(i) ? 22 : 14)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(y: -radius)
                        .rotationEffect(.radians(Double.pi / 2 - Double(i) / Double(slots) * 2 * Double.pi))
                }
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .animation(.easeOut(duration: 0.2), value: lit)
        }
    }
}

/// The last head's small picture.
struct HeadThumb: View {
    let folder: HeadFolder?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "face.smiling").font(.title3).foregroundStyle(.white)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: folder == nil ? 0 : 1.5))
        .task(id: folder?.url.path ?? "") { image = folder.flatMap { UIImage(contentsOfFile: $0.thumbnail.path) } }
        .onReceive(NotificationCenter.default.publisher(for: HeadPiece.thumbnailMade)) { note in
            if let url = note.object as? URL, url == folder?.url { image = UIImage(contentsOfFile: url.appendingPathComponent("thumbnail.jpg").path) }
        }
    }
}

// MARK: Checking the head

/// The head as built, with the line where it is cut from its neck. Drag up or down to move the line, sideways to turn
/// the head until it faces the screen. Save keeps it.
struct HeadCheckView: View {
    let folder: HeadFolder
    let saved: () -> Void
    let again: () -> Void
    @State private var whole: BodyMesh?
    @State private var cut: Float = -0.145
    @State private var turn: Float = 0
    @State private var chin: Float?
    @State private var start: (cut: Float, turn: Float)?
    @State private var vertical: Bool?
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let whole {
                HeadStage(whole: whole, pictures: folder.url, cut: cut, turn: turn)
                    .ignoresSafeArea()
                    .gesture(drag)
            } else {
                ProgressView().tint(.white)
            }
            VStack(spacing: 0) {
                Text("Up or down moves the neck line. Sideways turns the face to you.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 3)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange).padding(.top, 6).padding(.horizontal, 24)
                }
                Spacer()
                HStack {
                    Button("Scan again", action: again)
                        .font(.body.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color.white.opacity(0.15), in: Capsule())
                    Spacer()
                    Button(action: save) {
                        Text(saving ? "Saving…" : "Save head")
                            .font(.body.weight(.semibold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(Theme.accent, in: Capsule())
                    }
                    .disabled(saving || whole == nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .task {
            let target = folder
            let loaded = await Task.detached(priority: .userInitiated) { () -> (BodyMesh?, HeadCutSettings?) in
                (HeadPiece.loadWhole(target), HeadPiece.settings(target))
            }.value
            if let settings = loaded.1 { cut = settings.cut; turn = settings.turn; chin = settings.chin }
            whole = loaded.0
            if whole == nil { problem = "The head couldn't be opened." }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if start == nil {
                    start = (cut, turn)
                    vertical = abs(value.translation.height) > abs(value.translation.width)
                }
                guard let start else { return }
                if vertical == true {
                    cut = min(-0.04, max(-0.27, start.cut - Float(value.translation.height) * 0.0006))
                } else {
                    turn = start.turn + Float(value.translation.width) * 0.008
                }
            }
            .onEnded { _ in
                start = nil
                vertical = nil
            }
    }

    private func save() {
        guard let whole else { return }
        saving = true
        let target = folder, settings = HeadCutSettings(cut: cut, turn: turn, chin: chin)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Error? in
                do { try HeadPiece.save(target, whole: whole, settings: settings); return nil } catch { return error }
            }.value
            saving = false
            if let result {
                problem = (result as? HeadBuilder.Failure)?.words ?? result.localizedDescription
            } else {
                Diagnostics.log(String(format: "Head scan: saved, neck line %.1f cm below the middle, turned %.0f°", -cut * 100, turn * 180 / .pi))
                Haptics.success()
                saved()
            }
        }
    }
}

/// The head in 3D from the front and a little above, with a mint ring and disc where the neck is cut.
private struct HeadStage: UIViewRepresentable {
    let whole: BodyMesh
    let pictures: URL
    let cut: Float
    let turn: Float

    final class Coordinator {
        let turner = SCNNode()
        let line = SCNNode()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.12, alpha: 1)
        view.scene = scene
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = UIColor(white: 0.12, alpha: 1)
        // Phil's 1406 test: drawn only on demand, the head never showed. It draws all the time here.
        view.rendersContinuously = true
        view.isPlaying = true
        context.coordinator.turner.addChildNode(HeadPiece.node(whole, pictures: pictures))
        scene.rootNode.addChildNode(context.coordinator.turner)
        // The neck line: a thin ring and a faint disc.
        var span: Float = 0.13
        for p in whole.positions { span = max(span, abs(p.x) + 0.02) }
        span = min(span, 0.4)
        let ring = SCNTorus(ringRadius: CGFloat(span), pipeRadius: CGFloat(span * 0.02))
        let disc = SCNCylinder(radius: CGFloat(span), height: 0.0005)
        for geometry in [ring, disc] as [SCNGeometry] {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = Theme.accentUI.withAlphaComponent(geometry === disc ? 0.28 : 0.95)
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.renderingOrder = 5
            context.coordinator.line.addChildNode(node)
        }
        scene.rootNode.addChildNode(context.coordinator.line)
        // Framed on the head as built, wherever it came out and whatever its size.
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for p in whole.positions { low = simd_min(low, p); high = simd_max(high, p) }
        if low.x > high.x { low = SIMD3(-0.12, -0.15, -0.12); high = SIMD3(0.12, 0.15, 0.12) }
        let middle = (low + high) / 2, size = max(0.1, max(high.y - low.y, high.x - low.x))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 34
        camera.camera?.zNear = 0.01
        camera.simdPosition = middle + SIMD3(0, size * 0.55, size * 2.6)
        camera.simdLook(at: middle)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        update(context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ c: Coordinator) {
        c.turner.simdOrientation = simd_quatf(angle: turn, axis: SIMD3(0, 1, 0))
        c.line.simdPosition = SIMD3(0, cut, 0)
    }
}

// MARK: Done

/// The head is in the Gallery: put it on a body, or scan another.
struct HeadDoneView: View {
    let folder: HeadFolder
    let putOn: () -> Void
    let again: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            HeadThumb(folder: folder).scaleEffect(1.8).padding(.bottom, 24)
            Text("Head ready").font(.title2.weight(.semibold))
            Text("Kept in the Gallery.").font(.footnote).foregroundStyle(.secondary)
            Button(action: putOn) {
                Text("Put it on a body").font(.body.weight(.semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(.top, 6)
            Spacer()
            HStack(spacing: 12) {
                Button("New scan", action: again).buttonStyle(.bordered)
                Button("Done", action: close).buttonStyle(.bordered)
            }
            .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}
