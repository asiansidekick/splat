import ARKit
import ImageIO
import SceneKit
import SwiftUI
import simd

/// Phil, 2026-10-31: look at every frame of a reference away from the set, and dimension and note
/// them there. Marks are kept in the room's coordinates, so they save with the reference, sync,
/// and show in the live view and in the other frames.
@MainActor
struct FrameReview: View {
    let onSave: (Reference) -> Void
    @State private var reference: Reference
    @StateObject private var measurer = Measurer(session: ARSession(), parent: SCNNode())
    @StateObject private var placer: ModelPlacer
    @StateObject private var stage: ReviewStage
    /// 3D model mode: touches move the models instead of drawing marks.
    @State private var editingModels = false
    @State private var importingModel = false
    @State private var makingCutout = false
    @State private var choosingExample = false
    @State private var exploring = false
    /// Off (the default): pinch to zoom, one finger moves the photo. On: one finger draws dimensions and notes.
    @State private var measuring = false
    @State private var index = 0
    /// Counts presses of Save photo; the page showing saves its frame when it changes.
    @State private var exportCount = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSize

    /// Phil, 2026-11-10: the thumbnails go in landscape and while placing models or measuring, so the photo gets the room.
    private var sideways: Bool { verticalSize == .compact }
    private var showsStrip: Bool { !sideways && !editingModels && !measuring }

    init(reference: Reference, startMeasuring: Bool = false, onSave: @escaping (Reference) -> Void) {
        _reference = State(initialValue: reference)
        _measuring = State(initialValue: startMeasuring)
        self.onSave = onSave
        let root = SCNNode()
        _placer = StateObject(wrappedValue: ModelPlacer(session: ARSession(), root: root, folder: ReferenceStore.folder(for: reference.id)))
        _stage = StateObject(wrappedValue: ReviewStage(modelRoot: root))
    }

    private var frames: [Keyframe] { reference.keyframes + reference.snapshots.map(\.frame) }
    private var folder: URL { ReferenceStore.folder(for: reference.id) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if frames.indices.contains(index) {
                    FramePage(frame: frames[index], folder: folder, measurer: measurer,
                              stage: stage, placer: placer, editingModels: editingModels, panMode: !measuring && !editingModels,
                              onPickMark: { measuring = true },
                              planeDepth: reference.planeDepths[frames[index].imageFile],
                              onPlaneDepth: { depth in
                                  guard frames.indices.contains(index) else { return }
                                  reference.planeDepths[frames[index].imageFile] = depth
                                  onSave(reference)
                              },
                              onSwipe: { move($0) }, exportRequest: exportCount)
                        .id(frames[index].id)
                } else {
                    Spacer()
                    Text("This reference has no frames.").foregroundStyle(.white)
                    Spacer()
                }
                if showsStrip { strip }
            }
            MeasureEntry(measurer: measurer)
            VStack {
                Spacer()
                ModelOverlay(placer: placer, showsFloor: false)
                    .padding(.bottom, showsStrip ? 84 : 8)
                    .padding(.horizontal, 12)
            }
        }
        .fileImporter(isPresented: $importingModel, allowedContentTypes: ModelImport.pickerTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, frames.indices.contains(index) else { return }
            let spot = placement(for: frames[index])
            placer.add(from: urls, at: spot.transform, right: spot.right)
        }
        .sheet(isPresented: $choosingExample) {
            if frames.indices.contains(index) {
                ExamplesSheet(placer: placer, base: Cutout.frontFacing(camera: frames[index].position, position: placement(for: frames[index]).transform.columns.3.xyz)).themed()
            }
        }
        .sheet(isPresented: $makingCutout) {
            if frames.indices.contains(index) {
                CutoutMaker(placer: placer, base: Cutout.frontFacing(camera: frames[index].position, position: placement(for: frames[index]).transform.columns.3.xyz)).themed()
            }
        }
        .fullScreenCover(isPresented: $exploring) { ExploreView(reference: reference).themed() }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onAppear {
            measurer.load(measurements: reference.measurements, notes: reference.notes, removed: reference.removedMarks)
            placer.load(reference.models)
        }
        .onReceive(placer.$models.dropFirst()) { models in
            guard models != reference.models else { return }
            reference.models = models
            onSave(reference)
        }
        .onReceive(measurer.$revision.dropFirst()) { _ in
            reference.measurements = measurer.measurements
            reference.notes = measurer.notes
            reference.removedMarks = measurer.removed
            onSave(reference)
        }
    }

    /// Two rows so nothing is squeezed: Done and the frame pager on top, the tools underneath.
    private var topBar: some View {
        // In landscape the pager and the tools share one row, leaving the height to the photo.
        let layout = sideways ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 2))
        return layout {
            ZStack {
                HStack(spacing: 4) {
                    Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 40) }
                        .disabled(index == 0)
                    VStack(spacing: 0) {
                        Text("Frame \(index + 1) of \(frames.count)")
                            .font(Theme.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).fixedSize()
                        if index >= reference.keyframes.count {
                            Text("Snapshot").font(Theme.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                    }
                    .frame(minWidth: 96)
                    Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 40, height: 40) }
                        .disabled(index >= frames.count - 1)
                }
                HStack {
                    Button { dismiss() } label: {
                        Text("Done").font(Theme.body.weight(.semibold)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 14).frame(height: 40)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 16) {
                if ExploreView.offered {
                    Button { exploring = true } label: { Image(systemName: "view.3d").frame(width: 40, height: 36) }
                        .accessibilityLabel("Fly through in 3D")
                }
                Button {
                    editingModels.toggle()
                    if editingModels { measurer.deselect(); measuring = false } else { placer.selectedModel = nil }
                } label: {
                    Image(systemName: editingModels ? "cube.fill" : "cube").frame(width: 40, height: 36)
                }
                .tint(editingModels ? Theme.accent : nil)
                .accessibilityLabel(editingModels ? "Back to dimensions and notes" : "Place 3D models")
                if editingModels {
                    Menu {
                        Button { importingModel = true } label: { Label("3D model (USDZ, OBJ or STL)", systemImage: "cube") }
                        Button { makingCutout = true } label: { Label("Cut-out from photos", systemImage: "figure.stand") }
                        Button { choosingExample = true } label: { Label("Examples: people, set pieces", systemImage: "figure.stand.dress") }
                        Toggle(isOn: $stage.hidesBehindSet) { Label("Models go behind real things", systemImage: "square.2.layers.3d") }
                    } label: { Image(systemName: "plus").frame(width: 40, height: 36) }
                        .accessibilityLabel("Add a 3D model or cut-out")
                }
                Button { measuring.toggle(); if measuring { editingModels = false } } label: {
                    Image(systemName: measuring ? "ruler.fill" : "ruler").frame(width: 40, height: 36)
                }
                .tint(measuring ? Theme.accent : nil)
                .accessibilityLabel(measuring ? "Back to zooming" : "Measure and add notes")
                Button { measurer.scaleText(by: 0.8) } label: { Text("A").font(Theme.footnote.weight(.bold)).frame(width: 40, height: 36) }
                    .accessibilityLabel("Smaller text")
                Button { measurer.scaleText(by: 1.25) } label: { Text("A").font(Theme.title3.weight(.bold)).frame(width: 40, height: 36) }
                    .accessibilityLabel("Bigger text")
                // Phil, 2026-11-10: save this frame, with its models and marks, to Photos.
                Button { exportCount += 1 } label: { Image(systemName: "square.and.arrow.down").frame(width: 40, height: 36) }
                    .disabled(!frames.indices.contains(index))
                    .accessibilityLabel("Save this frame to Photos")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
    }

    /// Where a new model goes in a frame: on the floor-ish surface low in the picture, from the saved
    /// depth, or a metre and a bit straight ahead when the frame has none.
    private func placement(for frame: Keyframe) -> (transform: simd_float4x4, right: SIMD3<Float>) {
        let camera = frame.cameraToWorld
        var right = camera.columns.0.xyz
        right.y = 0
        right = simd_length(right) > 0.01 ? simd_normalize(right) : SIMD3(1, 0, 0)
        var spot: SIMD3<Float>?
        if let file = frame.depthFile, frame.depthWidth > 0, frame.depthHeight > 0,
           let data = try? Data(contentsOf: folder.appendingPathComponent(file)) {
            let values = DepthMap.floats(data)
            let n = frame.turn.sensor(fromUpright: SIMD2(0.5, 0.7))
            let x = n.x * Float(frame.depthWidth), y = n.y * Float(frame.depthHeight)
            if let metres = DepthMap.planeDepth(values, width: frame.depthWidth, height: frame.depthHeight, x: x, y: y, radius: 10)
                ?? DepthMap.sample(values, width: frame.depthWidth, height: frame.depthHeight, x: Int(x), y: Int(y)) {
                spot = frame.point(atSensor: n, metres: metres)
            }
        }
        let place = spot ?? frame.point(atSensor: SIMD2(0.5, 0.5), metres: 1.3) ?? frame.position + frame.forward
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(place.x, place.y, place.z, 1)
        return (transform, right)
    }

    private func move(_ step: Int) {
        measurer.deselect()
        index = min(max(index + step, 0), frames.count - 1)
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { item in
                        FrameThumb(frame: item.element, folder: folder, number: item.offset + 1, current: item.offset == index)
                            .id(item.offset)
                            .onTapGesture {
                                measurer.deselect()
                                index = item.offset
                            }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 64)
            .padding(.vertical, 6)
            .onChange(of: index) { _, value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
        }
    }
}

/// A small photo in the strip along the bottom.
@MainActor
struct FrameThumb: View {
    let frame: Keyframe
    let folder: URL
    let number: Int
    let current: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
            Text("\(number)").font(Theme.caption.weight(.bold)).monospacedDigit()
                .padding(.horizontal, 4).background(Color.black.opacity(0.6)).foregroundStyle(.white)
            if frame.depthFile == nil {
                Image(systemName: "ruler").font(Theme.caption).foregroundStyle(.white.opacity(0.7))
                    .overlay(Rectangle().fill(Color.white.opacity(0.7)).frame(height: 1).rotationEffect(.degrees(-35)))
                    .padding(3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? Theme.accent : Color.clear, lineWidth: 3))
        .task(id: frame.id) {
            let url = folder.appendingPathComponent(frame.imageFile)
            let orientation = frame.uprightOrientation
            let cg = await Task.detached { FrameImage.thumbnail(url) }.value?.cg
            if let cg { image = UIImage(cgImage: cg, scale: 1, orientation: orientation) }
        }
    }
}

/// Image and depth reading for saved frames.
enum FrameImage {
    struct Box: @unchecked Sendable { let cg: CGImage }

    static func thumbnail(_ url: URL) -> Box? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Box.init)
    }

    static func full(_ url: URL) -> Box? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil).map(Box.init)
    }

    /// The sharp corner nearest `n` (0 to 1, sensor layout) in the photo, or `n` itself if none is clear.
    static func snapped(_ n: SIMD2<Float>, in cg: CGImage) -> SIMD2<Float> {
        let w = cg.width, h = cg.height
        let radius = 56 * Float(w) / 1920
        let half = Int(radius) + 10
        let cx = Int(n.x * Float(w)), cy = Int(n.y * Float(h))
        let x0 = max(0, cx - half), y0 = max(0, cy - half)
        let x1 = min(w, cx + half), y1 = min(h, cy + half)
        let pw = x1 - x0, ph = y1 - y0
        guard pw > 24, ph > 24, let crop = cg.cropping(to: CGRect(x: x0, y: y0, width: pw, height: ph)) else { return n }
        var bytes = [UInt8](repeating: 0, count: pw * ph)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: pw, height: ph))
            return true
        }
        let luma = bytes.map { Float($0) }
        guard drawn, let corner = CornerSnap.corner(luma: luma, width: pw, height: ph, near: SIMD2(Float(cx - x0), Float(cy - y0)), within: radius) else { return n }
        return SIMD2((Float(x0) + corner.x + 0.5) / Float(w), (Float(y0) + corner.y + 0.5) / Float(h))
    }
}

/// One frame, big, with the marks that fall in it. Drag to measure, hold to leave a note, tap a mark to edit it.
@MainActor
struct FramePage: View {
    let frame: Keyframe
    let folder: URL
    @ObservedObject var measurer: Measurer
    let stage: ReviewStage
    let placer: ModelPlacer
    let editingModels: Bool
    var panMode = false
    /// Called when a tap in zoom mode lands on a mark: the screen switches to measuring so it can be edited.
    var onPickMark: () -> Void = {}
    /// For a photo with no depth: how far out the scene is, once a length typed along something known set it.
    var planeDepth: Float?
    var onPlaneDepth: (Float) -> Void = { _ in }
    /// A quick sideways swipe on the whole photo (not zoomed in): -1 for the previous frame, 1 for the next.
    var onSwipe: (Int) -> Void = { _ in }
    /// Changes when Save photo is pressed.
    var exportRequest = 0

    private struct Loaded: @unchecked Sendable {
        let image: UIImage
        let cg: CGImage
        let depth: [Float]?
    }

    private struct Touch {
        var start: CGPoint
        var current: CGPoint
        var began = Date()
        /// When the finger first moved, so a hold on a line's end before moving can be told from drawing.
        var movedAt: Date?
    }

    @State private var loaded: Loaded?
    @State private var failed = false
    @State private var touch: Touch?
    @State private var message: String?
    @State private var viewSize: CGSize = .zero
    @State private var exporting = false
    /// Pinch zoom (1 to 8x) and where the photo is moved to.
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var pinching = false
    /// A line just drawn on a photo with no depth, drawn 1 m out until its real length is typed.
    @State private var scalePending: (id: UUID, a: SIMD2<Float>, b: SIMD2<Float>)?

    /// Phil, 2026-11-10: zooming in fills the whole screen, not only the photo's box, so the photo can be
    /// moved until its edge meets the screen's edge.
    private func clamped(_ pan: CGSize, zoom: CGFloat, size: CGSize, box: CGSize) -> CGSize {
        let x = max(0, (size.width * zoom - box.width) / 2), y = max(0, (size.height * zoom - box.height) / 2)
        return CGSize(width: min(max(pan.width, -x), x), height: min(max(pan.height, -y), y))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = Self.fit(aspect: CGFloat(frame.uprightAspect), in: geometry.size)
            ZStack {
                content(size)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoom)
                    .offset(pan)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onAppear { viewSize = size }
            .onChange(of: size) { _, value in viewSize = value }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        pinching = true
                        touch = nil
                        zoom = min(max(baseZoom * value, 1), 8)
                        pan = clamped(pan, zoom: zoom, size: size, box: geometry.size)
                    }
                    .onEnded { _ in
                        baseZoom = zoom
                        basePan = pan
                        Task { try? await Task.sleep(for: .milliseconds(250)); pinching = false }
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !pinching else { return }
                        pan = clamped(CGSize(width: basePan.width + value.translation.width, height: basePan.height + value.translation.height), zoom: zoom, size: size, box: geometry.size)
                    }
                    .onEnded { value in
                        basePan = pan
                        let across = value.translation.width, down = value.translation.height
                        if zoom <= 1.02, abs(across) > 70, abs(across) > abs(down) * 1.6 {
                            onSwipe(across < 0 ? 1 : -1)
                            return
                        }
                        // A tap, not a drag: if it lands on a mark, switch to measuring and open the mark.
                        if hypot(value.translation.width, value.translation.height) < 6 {
                            let centre = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            let local = CGPoint(
                                x: (value.location.x - centre.x - pan.width) / zoom + size.width / 2,
                                y: (value.location.y - centre.y - pan.height) / zoom + size.height / 2)
                            tap(local, size: size)
                            if measurer.selected != nil { onPickMark() }
                        }
                    },
                including: panMode ? .all : .none
            )
            .overlay(alignment: .topTrailing) {
                if zoom > 1.02 {
                    Button {
                        withAnimation(.snappy) { zoom = 1; baseZoom = 1; pan = .zero; basePan = .zero }
                    } label: {
                        Text("\(zoom, specifier: "%.1f")×  Reset")
                            .font(Theme.footnote.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                    }
                    .padding(8)
                }
            }
        }
        .overlay(alignment: .top) {
            if let text = hint {
                Banner(text: text, fadesAfter: 5).padding(.top, 6).allowsHitTesting(false)
            }
        }
        .task(id: frame.id) { await load() }
        .onChange(of: exportRequest) { _, _ in Task { await export() } }
        .onReceive(measurer.$scaleResult) { result in
            guard let result, let pending = scalePending, result.id == pending.id else { return }
            scalePending = nil
            onPlaneDepth(result.depth)
            if let wa = frame.point(atSensor: pending.a, metres: result.depth), let wb = frame.point(atSensor: pending.b, metres: result.depth) {
                measurer.moveEnd(pending.id, end: 0, to: wa)
                measurer.moveEnd(pending.id, end: 1, to: wb)
                measurer.setLength(result.metres, for: pending.id)
            }
            say("Scale set. Measure things at the same distance as that line: nearer or farther ones will read wrong.")
        }
        .onChange(of: measurer.entry) { _, entry in
            // The window was closed without a length: the provisional line goes.
            if entry == nil, let pending = scalePending {
                scalePending = nil
                measurer.deleteMark(pending.id)
            }
        }
    }

    private var hint: String? {
        if let message { return message }
        guard let loaded else { return nil }
        if loaded.depth == nil, planeDepth == nil { return "No depth in this photo: drag a line along something you know the size of and type its real length. Everything else on that flat view is then measured from it. Notes work as normal." }
        return panMode ? "Swipe for the next frame. Pinch to zoom, drag to move. Tap the ruler to measure or add notes." : "Drag to measure. Hold to add a note. Hold a line's end, then drag it to move it. Tap a mark to edit."
    }

    private static func fit(aspect: CGFloat, in box: CGSize) -> CGSize {
        guard box.width > 0, box.height > 0, aspect > 0 else { return .zero }
        return box.width / box.height > aspect ? CGSize(width: box.height * aspect, height: box.height) : CGSize(width: box.width, height: box.width / aspect)
    }

    private func load() async {
        loaded = nil
        failed = false
        let imageURL = folder.appendingPathComponent(frame.imageFile)
        let depthURL = frame.depthFile.map { folder.appendingPathComponent($0) }
        let orientation = frame.uprightOrientation
        let result: Loaded? = await Task.detached {
            guard let box = FrameImage.full(imageURL) else { return nil }
            var depth: [Float]?
            if let depthURL, let data = try? Data(contentsOf: depthURL) {
                let values = DepthMap.floats(data)
                depth = values.isEmpty ? nil : values
            }
            return Loaded(image: UIImage(cgImage: box.cg, scale: 1, orientation: orientation), cg: box.cg, depth: depth)
        }.value
        if let result { loaded = result } else { failed = true }
    }

    // MARK: Drawing

    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let image = loaded?.image {
                Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
            } else if failed {
                Text("This photo is missing.").foregroundStyle(.white.opacity(0.7)).frame(width: size.width, height: size.height)
            } else {
                ProgressView().tint(.white).frame(width: size.width, height: size.height)
            }
            ReviewModelsView(stage: stage, placer: placer, frame: frame, folder: folder)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(editingModels)
            marks(size).allowsHitTesting(false)
            pointer(size).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pinching { return }
                    if touch == nil {
                        touch = Touch(start: value.startLocation, current: value.location)
                    } else {
                        touch?.current = value.location
                        if touch?.movedAt == nil, hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) >= 10 {
                            touch?.movedAt = Date()
                        }
                    }
                }
                .onEnded { value in
                    let last = touch
                    touch = nil
                    if pinching { return }
                    finish(value, held: Date().timeIntervalSince(last?.began ?? Date()), carrying: carriedEnd(last, size: size), size: size)
                },
            including: editingModels || panMode ? .none : .all
        )
    }

    private func place(_ world: SIMD3<Float>, _ size: CGSize) -> CGPoint? {
        guard let sensor = frame.project(world) else { return nil }
        let u = frame.turn.upright(fromSensor: sensor)
        return CGPoint(x: CGFloat(u.x) * size.width, y: CGFloat(u.y) * size.height)
    }

    private func marks(_ size: CGSize) -> some View {
        let scale = CGFloat(measurer.textScale)
        return ZStack(alignment: .topLeading) {
            ForEach(measurer.measurements) { line in
                if let a = place(line.start, size), let b = place(line.end, size) {
                    ReviewLine(a: a, b: b, label: (line.typed == nil ? "~" : "") + Measurer.text(line.length),
                               picked: measurer.selected == line.id, scale: scale)
                }
            }
            ForEach(measurer.notes) { note in
                if let tip = place(note.spot, size) {
                    ReviewNote(text: note.text, tip: tip, picked: measurer.selected == note.id, scale: scale)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// While a finger is down: the points that will be marked, joined by a line, with a loupe beside the finger.
    @ViewBuilder
    private func pointer(_ size: CGSize) -> some View {
        if let touch, hypot(touch.current.x - touch.start.x, touch.current.y - touch.start.y) >= 10, carriedEnd(touch, size: size) != nil {
            ZStack {
                ring(touch.current)
                loupe(at: touch.current, size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        } else if let touch, hypot(touch.current.x - touch.start.x, touch.current.y - touch.start.y) >= 10 {
            let a = Self.aim(touch.start), b = Self.aim(touch.current)
            ZStack {
                Path { p in
                    p.move(to: a)
                    p.addLine(to: b)
                }
                .stroke(Color(Measurer.lineColour), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ring(a)
                ring(b)
                loupe(at: touch.current, size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    /// A magnified window beside the finger, with a dot where it really is.
    private func loupe(at finger: CGPoint, size: CGSize) -> some View {
        let d = Measurer.loupeSize
        let half = d / 2 + 6
        let above = finger.y > d + 40
        let centre = CGPoint(
            x: min(max(finger.x - 70, half), max(size.width - half, half)),
            y: min(max(above ? finger.y - 90 : finger.y + 100, half), max(size.height - half, half)))
        return ZStack {
            if let image = loupeImage(at: finger, size: size) {
                Image(uiImage: image).resizable().scaledToFill().frame(width: d, height: d)
            } else {
                Color.black.opacity(0.4)
            }
            Circle().fill(Color.red).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 3))
        .position(centre)
    }

    private func loupeImage(at location: CGPoint, size: CGSize) -> UIImage? {
        guard let loaded, size.width > 0, let n = sensorPoint(location, size: size) else { return nil }
        let cg = loaded.cg
        let uprightWidth = frame.turn.swapsSides ? cg.height : cg.width
        let side = Int(Measurer.loupeSize / Measurer.loupeZoom * CGFloat(uprightWidth) / size.width)
        guard side > 8 else { return nil }
        let cx = Int(n.x * Float(cg.width)), cy = Int(n.y * Float(cg.height))
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard rect.width > 4, rect.height > 4, let crop = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop, scale: 1, orientation: frame.uprightOrientation)
    }

    private func ring(_ p: CGPoint) -> some View {
        Circle().stroke(Color.white, lineWidth: 2)
            .background(Circle().fill(Color.black.opacity(0.25)))
            .frame(width: 22, height: 22)
            .position(p)
    }

    private static func aim(_ finger: CGPoint) -> CGPoint {
        CGPoint(x: finger.x, y: max(finger.y - Measurer.aimOffset, 0))
    }

    // MARK: Touch

    private func finish(_ value: DragGesture.Value, held: TimeInterval, carrying: (id: UUID, end: Int)?, size: CGSize) {
        let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
        guard measurer.entry == nil else { return }
        if let carrying {
            moveEnd(carrying, to: value.location, size: size)
            return
        }
        if moved < 10 {
            if held >= 0.5 {
                addNote(at: value.startLocation, size: size)
            } else {
                tap(value.startLocation, size: size)
            }
        } else {
            addLine(from: Self.aim(value.startLocation), to: Self.aim(value.location), size: size)
        }
    }

    /// The end of a line a touch picked up: it went down on that end and stayed there half a second
    /// before the finger moved.
    private func carriedEnd(_ touch: Touch?, size: CGSize) -> (id: UUID, end: Int)? {
        guard let touch, let movedAt = touch.movedAt, movedAt.timeIntervalSince(touch.began) >= 0.5 else { return nil }
        return lineEnd(near: touch.start, size: size)
    }

    private func lineEnd(near p: CGPoint, size: CGSize) -> (id: UUID, end: Int)? {
        var best: (id: UUID, end: Int, distance: CGFloat)?
        for line in measurer.measurements {
            for (end, point) in [line.start, line.end].enumerated() {
                guard let shown = place(point, size) else { continue }
                let d = hypot(shown.x - p.x, shown.y - p.y)
                if d < 40, d < (best?.distance ?? .infinity) { best = (line.id, end, d) }
            }
        }
        return best.map { ($0.id, $0.end) }
    }

    private func moveEnd(_ picked: (id: UUID, end: Int), to location: CGPoint, size: CGSize) {
        guard let loaded, loaded.depth != nil, var n = sensorPoint(location, size: size) else {
            say("This frame has no LiDAR depth, so the end can't be moved here.")
            Haptics.warning()
            return
        }
        n = FrameImage.snapped(n, in: loaded.cg)
        guard let metres = depth(at: n), let world = frame.point(atSensor: n, metres: metres) else {
            say("No depth reading there. Try a spot on a surface.")
            Haptics.warning()
            return
        }
        measurer.moveEnd(picked.id, end: picked.end, to: world)
    }

    private func tap(_ location: CGPoint, size: CGSize) {
        var best: (id: UUID, distance: CGFloat)?
        func consider(_ id: UUID, _ distance: CGFloat, within limit: CGFloat) {
            if distance < limit, distance < (best?.distance ?? .infinity) { best = (id, distance) }
        }
        for line in measurer.measurements {
            guard let a = place(line.start, size), let b = place(line.end, size) else { continue }
            consider(line.id, Self.distance(from: location, toSegment: a, b), within: 30)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 14)
            consider(line.id, hypot(location.x - mid.x, location.y - mid.y), within: 40)
        }
        for note in measurer.notes {
            guard let tip = place(note.spot, size) else { continue }
            // The bubble sits up and to the right of its tip.
            let centre = CGPoint(x: tip.x + 37, y: tip.y - 38 * CGFloat(measurer.textScale))
            consider(note.id, min(hypot(location.x - tip.x, location.y - tip.y), hypot(location.x - centre.x, location.y - centre.y) - 20), within: 50)
        }
        if let best { measurer.open(best.id) } else { measurer.deselect() }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Where in the photo (0 to 1, sensor layout) a place on the shown picture is.
    private func sensorPoint(_ location: CGPoint, size: CGSize) -> SIMD2<Float>? {
        guard size.width > 0, size.height > 0 else { return nil }
        let u = SIMD2(Float(location.x / size.width), Float(location.y / size.height))
        guard (0...1).contains(u.x), (0...1).contains(u.y) else { return nil }
        return frame.turn.sensor(fromUpright: u)
    }

    /// Metres out to the surface at a place in the photo, from the saved depth.
    private func depth(at n: SIMD2<Float>) -> Float? {
        guard let values = loaded?.depth, frame.depthWidth > 0, frame.depthHeight > 0 else { return planeDepth }
        let x = n.x * Float(frame.depthWidth), y = n.y * Float(frame.depthHeight)
        let metres = DepthMap.planeDepth(values, width: frame.depthWidth, height: frame.depthHeight, x: x, y: y, radius: 10)
            ?? DepthMap.planeDepth(values, width: frame.depthWidth, height: frame.depthHeight, x: x, y: y)
            ?? DepthMap.sample(values, width: frame.depthWidth, height: frame.depthHeight, x: Int(x), y: Int(y))
        return metres
    }

    private func addLine(from p: CGPoint, to q: CGPoint, size: CGSize) {
        guard let loaded else { return }
        if loaded.depth == nil, planeDepth == nil {
            // No depth anywhere: the first line is drawn 1 m out and its real length, typed next, sets the scale.
            guard let a = sensorPoint(p, size: size), let b = sensorPoint(q, size: size),
                  let wa = frame.point(atSensor: a, metres: 1), let wb = frame.point(atSensor: b, metres: 1),
                  let id = measurer.addLine(from: wa, to: wb) else {
                say("That line is too short.")
                return
            }
            scalePending = (id, a, b)
            measurer.askPlaneScale(id)
            return
        }
        guard var a = sensorPoint(p, size: size), var b = sensorPoint(q, size: size) else { return }
        a = FrameImage.snapped(a, in: loaded.cg)
        b = FrameImage.snapped(b, in: loaded.cg)
        guard let da = depth(at: a), let db = depth(at: b),
              let wa = frame.point(atSensor: a, metres: da), let wb = frame.point(atSensor: b, metres: db) else {
            say("No depth reading at one end. Try a spot on a surface.")
            Haptics.warning()
            return
        }
        if measurer.addLine(from: wa, to: wb) == nil { say("That line is too short.") }
    }

    private func addNote(at location: CGPoint, size: CGSize) {
        guard let n = sensorPoint(location, size: size) else { return }
        // On the surface if there is depth, else in mid-air a little way out.
        guard let spot = frame.point(atSensor: n, metres: depth(at: n) ?? 1.5) else { return }
        measurer.askNote(at: spot)
    }

    /// The photo at up to 2400 pixels on its long side, the models drawn in as they sit, and the
    /// dimensions and notes on top, saved to Photos.
    private func export() async {
        guard !exporting else { return }
        guard let loaded else { say("The photo is still loading."); return }
        exporting = true
        defer { exporting = false }
        placer.selectedModel = nil
        measurer.deselect()
        let full = loaded.image.size
        let k = min(1, 2400 / max(full.width, full.height, 1))
        let out = CGSize(width: (full.width * k).rounded(), height: (full.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let photo = UIGraphicsImageRenderer(size: out, format: format).image { _ in
            loaded.image.draw(in: CGRect(origin: .zero, size: out))
        }
        let withModels = placer.models.isEmpty ? photo : (stage.render(over: photo, size: out) ?? photo)
        var marks: UIImage?
        if viewSize.width > 0, !(measurer.measurements.isEmpty && measurer.notes.isEmpty) {
            let renderer = ImageRenderer(content: self.marks(viewSize))
            renderer.scale = out.width / viewSize.width
            marks = renderer.uiImage
        }
        let final = UIGraphicsImageRenderer(size: out, format: format).image { _ in
            withModels.draw(in: CGRect(origin: .zero, size: out))
            marks?.draw(in: CGRect(origin: .zero, size: out))
        }
        Diagnostics.log("Review: save frame \(frame.imageFile) \(Int(out.width))x\(Int(out.height)), models \(placer.models.count), marks \(marks != nil)")
        let saved = await PhotoLibrary.save([final])
        say(saved ? "Saved to Photos." : "Could not save to Photos.")
    }

    private func say(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if message == text { message = nil }
        }
    }
}

/// A dimension drawn over a frame: the line, round ends and its size.
@MainActor
private struct ReviewLine: View {
    let a: CGPoint
    let b: CGPoint
    let label: String
    let picked: Bool
    let scale: CGFloat

    var body: some View {
        let colour = picked ? Color(Measurer.pickedColour) : Color(Measurer.lineColour)
        ZStack {
            Path { p in
                p.move(to: a)
                p.addLine(to: b)
            }
            .stroke(colour, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            Circle().fill(colour).frame(width: 9, height: 9).position(a)
            Circle().fill(colour).frame(width: 9, height: 9).position(b)
            Text(label)
                .font(Theme.font(size: 15 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(colour)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.black.opacity(0.55), in: Capsule())
                .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 14 * scale)
        }
    }
}

/// A note drawn over a frame: a comic bubble whose tail points at the place it was left.
@MainActor
private struct ReviewNote: View {
    let text: String
    let tip: CGPoint
    let picked: Bool
    let scale: CGFloat

    private let width: CGFloat = 150
    private let height: CGFloat = 78

    var body: some View {
        ZStack {
            SpeechBubble().fill(Color.black).offset(x: 2, y: 2)
            SpeechBubble().fill(picked ? Color(red: 1, green: 0.8, blue: 0.8) : Color.white)
            SpeechBubble().stroke(Color.black, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            Text(text.uppercased())
                .font(.custom("MarkerFelt-Wide", size: 15))
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 12)
                .padding(.bottom, 26)
        }
        .frame(width: width, height: height)
        // The tail's tip is 38 points in from the left at the bottom; keep that on the place.
        .scaleEffect(scale, anchor: UnitPoint(x: 38 / width, y: 1))
        .position(x: tip.x - 38 + width / 2, y: tip.y - height / 2)
    }
}
