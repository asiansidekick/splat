import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// The back (or front) camera, for full resolution stills. Keeps the preview and the saved photos
/// upright in any orientation.
final class Camera: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var error: String?
    @Published var paused = false
    @Published private(set) var isFront = false

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.session")
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var pending: [Int64: (UIImage?) -> Void] = [:]

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            self?.paused = true
        }
        center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.paused = false
        }
    }

    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                await MainActor.run { self.error = "Camera access is off. Turn it on in Settings, Match, Camera." }
                return
            }
            queue.async {
                if !self.configured { self.configure(front: false) }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func flip() {
        let front = !isFront
        queue.async { self.configure(front: front) }
    }

    /// Called by the preview once its layer exists, so the preview can be kept level.
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if let device = input?.device { makeCoordinator(for: device) }
    }

    func capture(_ completion: @escaping (UIImage?) -> Void) {
        let angle = coordinator?.videoRotationAngleForHorizonLevelCapture
        queue.async {
            if let angle, let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            self.pending[settings.uniqueID] = completion
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configure(front: Bool) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !configured {
            session.sessionPreset = .photo
            if session.isMultitaskingCameraAccessSupported {
                session.isMultitaskingCameraAccessEnabled = true  // keeps working in Split View on iPad
            }
        }
        guard let device = Self.device(front: front), let newInput = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async { self.error = "No camera available." }
            return
        }
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            return
        }
        session.addInput(newInput)
        input = newInput
        if !configured, session.canAddOutput(output) {
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .balanced
            configured = true
        }
        DispatchQueue.main.async {
            self.isFront = front
            self.makeCoordinator(for: device)
        }
    }

    /// The back camera that switches lenses by itself where there is one (close-ups on Pro phones),
    /// otherwise the plain wide camera.
    private static func device(front: Bool) -> AVCaptureDevice? {
        if front { return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) }
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        return types.lazy.compactMap { type in found.first { $0.deviceType == type } }.first
    }

    private func makeCoordinator(for device: AVCaptureDevice) {
        guard let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        self.coordinator = coordinator
        layer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak layer] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { layer?.connection?.videoRotationAngle = angle }
        }
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        let id = photo.resolvedSettings.uniqueID
        queue.async {
            let completion = self.pending.removeValue(forKey: id)
            DispatchQueue.main.async { completion?(image) }
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// The live camera, fitted (not cropped) so the reference ghost lines up with what gets saved.
struct CameraPreview: UIViewRepresentable {
    let camera: Camera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspect
        camera.attach(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

/// Outlines of a photo, to show over the live camera instead of the whole photo.
enum Ghost {
    static func edges(of image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let scale = min(1, 1200 / max(input.extent.width, input.extent.height))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let edges = CIFilter.edges()
        edges.inputImage = small
        edges.intensity = 6
        let mono = CIFilter.colorControls()
        mono.inputImage = edges.outputImage
        mono.saturation = 0
        mono.contrast = 1.4
        guard let output = mono.outputImage,
            let cg = CIContext().createCGImage(output, from: small.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Match camera

/// Take photos with the reference shown see-through over the live camera, so the new photo
/// can be framed the same and anything different stands out.
struct MatchCameraView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = Camera()
    let boardID: UUID
    @State private var ghostID: UUID?
    @State private var angle: String
    @State private var ghost: UIImage?
    @State private var ghostEdges: UIImage?
    @State private var opacity = 0.4
    @State private var outlines = false
    @State private var ghostScale: CGFloat = 1
    @State private var ghostOffset: CGSize = .zero
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGSize?
    @State private var lastShot: Shot?
    @State private var comparing: ComparePair?
    @State private var flash = false

    init(boardID: UUID, ghost: Shot?) {
        self.boardID = boardID
        _ghostID = State(initialValue: ghost?.id)
        _angle = State(initialValue: ghost?.angle ?? "")
    }

    private var board: Board? { store.board(boardID) }

    var body: some View {
        GeometryReader { geometry in
            // Controls sit beside the picture, never on it: a bar above and below in portrait,
            // columns either side in landscape, like the built-in Camera app.
            let landscape = geometry.size.width > geometry.size.height
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if landscape { leftColumn } else { topBar }
                viewfinder
                if landscape { rightColumn } else { bottomBar }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .statusBarHidden()
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .task(id: ghostID) { await loadGhost() }
        .fullScreenCover(item: $comparing) { pair in
            CompareView(boardID: boardID, before: pair.before, after: pair.after).environmentObject(store)
        }
    }

    private var viewfinder: some View {
        ZStack(alignment: .top) {
            ZStack {
                CameraPreview(camera: camera)
                ghostLayer
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(ghostGesture)
            .onTapGesture(count: 2) {
                withAnimation {
                    ghostScale = 1
                    ghostOffset = .zero
                }
            }
            if flash { Color.white.opacity(0.6).allowsHitTesting(false) }
            VStack(spacing: 6) {
                if camera.paused {
                    banner("Camera paused. On iPad it stops while another app uses it.")
                }
                if let error = camera.error { banner(error) }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var ghostLayer: some View {
        if let image = outlines ? ghostEdges : ghost {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .colorMultiply(outlines ? .cyan : .white)
                .blendMode(outlines ? .screen : .normal)
                .opacity(outlines ? max(opacity, 0.6) : opacity)
                .scaleEffect(x: camera.isFront ? -ghostScale : ghostScale, y: ghostScale)
                .offset(ghostOffset)
                .allowsHitTesting(false)
        }
    }

    /// Pinch and drag the ghost to line up a photo framed differently, such as a QTake screenshot.
    private var ghostGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = ghostScale }
                ghostScale = min(max((pinchStart ?? 1) * value.magnification, 0.3), 5)
            }
            .onEnded { _ in pinchStart = nil }
            .simultaneously(with: DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if dragStart == nil { dragStart = ghostOffset }
                    let start = dragStart ?? .zero
                    ghostOffset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in dragStart = nil })
    }

    private var title: String {
        guard let board else { return "" }
        return "Sc \(board.scene) · \(board.subject.isEmpty ? board.department.name : board.subject)"
    }

    private var doneButton: some View {
        Button("Done") { dismiss() }
            .font(.body.weight(.semibold))
            .foregroundStyle(.yellow)
    }

    private var flipButton: some View {
        Button {
            camera.flip()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3)
        }
        .accessibilityLabel("Switch camera")
    }

    private var outlinesButton: some View {
        Button {
            outlines.toggle()
        } label: {
            Image(systemName: outlines ? "square.dashed" : "photo").frame(width: 30, height: 30)
        }
        .accessibilityLabel(outlines ? "Show whole photo" : "Show outlines only")
    }

    private var shutter: some View {
        Button(action: shoot) {
            ZStack {
                Circle().fill(.white).frame(width: 58, height: 58)
                Circle().stroke(.white, lineWidth: 3).frame(width: 68, height: 68)
            }
        }
        .accessibilityLabel("Take photo")
    }

    // Portrait

    private var topBar: some View {
        HStack {
            doneButton
            Spacer()
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            flipButton
        }
        .padding(.horizontal)
        .frame(height: 40)
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if ghost != nil {
                HStack(spacing: 10) {
                    Image(systemName: "circle.lefthalf.filled")
                    Slider(value: $opacity, in: 0...1)
                    outlinesButton
                }
                .padding(.horizontal)
            }
            HStack(alignment: .center) {
                lastShotButton
                Spacer(minLength: 4)
                ghostMenu
                Spacer(minLength: 4)
                shutter
                Spacer(minLength: 4)
                angleMenu
                Spacer(minLength: 4)
                takeMenu
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    // Landscape

    private var leftColumn: some View {
        VStack(spacing: 12) {
            doneButton
            Spacer(minLength: 4)
            if ghost != nil {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: $opacity, in: 0...1)
                    .frame(width: 130)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 36, height: 130)
                outlinesButton
            }
            Spacer(minLength: 4)
            flipButton
        }
        .padding(.vertical, 12)
        .frame(width: 76)
    }

    private var rightColumn: some View {
        VStack(spacing: 8) {
            takeMenu
            angleMenu
            Spacer(minLength: 4)
            shutter
            Spacer(minLength: 4)
            ghostMenu
            lastShotButton
        }
        .padding(.vertical, 12)
        .frame(width: 96)
    }

    private var ghostMenu: some View {
        Menu {
            Button("No overlay") { ghostID = nil }
            if let board {
                Section("References") {
                    ForEach(board.references.reversed()) { shot in
                        Button(shot.label) { select(shot) }
                    }
                }
                Section("Other photos") {
                    ForEach(board.shots.filter { !$0.isReference }.sorted { $0.taken > $1.taken }) { shot in
                        Button(shot.label) { select(shot) }
                    }
                }
            }
        } label: {
            control(ghostID == nil ? "No overlay" : "Overlay", systemImage: "square.on.square")
        }
    }

    private var angleMenu: some View {
        Menu {
            Picker("Angle", selection: $angle) {
                Text("No angle").tag("")
                ForEach(Slate.angles, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            control(angle.isEmpty ? "Angle" : angle, systemImage: "camera.rotate")
        }
    }

    private var takeMenu: some View {
        let scene = board?.scene ?? ""
        let take = store.take(for: scene)
        return Menu {
            Button("Next take (\(take + 1))") { store.setTake(take + 1, for: scene) }
            if take > 0 {
                Button("Back to \(Slate.takeName(take - 1))") { store.setTake(take - 1, for: scene) }
                Button("Prep") { store.setTake(0, for: scene) }
            }
        } label: {
            control(Slate.shortTake(take), systemImage: "film")
        }
    }

    @ViewBuilder
    private var lastShotButton: some View {
        if let lastShot, let thumbnail = store.thumbnail(lastShot, in: boardID) {
            Button {
                let before = ghostID.flatMap { id in board?.shots.first { $0.id == id } } ?? board?.reference(for: lastShot)
                comparing = ComparePair(before: before?.id, after: lastShot.id)
            } label: {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
            }
            .accessibilityLabel("Compare last photo")
        } else {
            Color.clear.frame(width: 48, height: 48)
        }
    }

    /// A small icon with a caption, so the bars stay slim.
    private func control(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage).font(.title3)
            Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 60, height: 44)
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(10)
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }

    private func select(_ shot: Shot) {
        ghostID = shot.id
        angle = shot.angle
    }

    private func shoot() {
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { flash = false } }
        let angle = self.angle
        camera.capture { image in
            guard let image else { return }
            Task {
                if let shot = await store.addShot(image, to: boardID, angle: angle, source: .camera) {
                    lastShot = shot
                }
            }
        }
    }

    private func loadGhost() async {
        ghostScale = 1
        ghostOffset = .zero
        guard let ghostID, let shot = board?.shots.first(where: { $0.id == ghostID }) else {
            ghost = nil
            ghostEdges = nil
            return
        }
        let boardID = self.boardID
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, UIImage?) in
            let image = BoardStore.image(shot, in: boardID, maxPixels: 1600)
            return (image, image.flatMap(Ghost.edges(of:)))
        }.value
        ghost = loaded.0
        ghostEdges = loaded.1
    }
}
