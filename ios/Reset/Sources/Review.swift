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
    @State private var index = 0
    @Environment(\.dismiss) private var dismiss

    init(reference: Reference, onSave: @escaping (Reference) -> Void) {
        _reference = State(initialValue: reference)
        self.onSave = onSave
    }

    private var frames: [Keyframe] { reference.keyframes + reference.snapshots.map(\.frame) }
    private var folder: URL { ReferenceStore.folder(for: reference.id) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if frames.indices.contains(index) {
                    FramePage(frame: frames[index], folder: folder, measurer: measurer)
                        .id(frames[index].id)
                } else {
                    Spacer()
                    Text("This reference has no frames.").foregroundStyle(.white)
                    Spacer()
                }
                strip
            }
            MeasureEntry(measurer: measurer)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onAppear {
            measurer.load(measurements: reference.measurements, notes: reference.notes, removed: reference.removedMarks)
        }
        .onReceive(measurer.$revision.dropFirst()) { _ in
            reference.measurements = measurer.measurements
            reference.notes = measurer.notes
            reference.removedMarks = measurer.removed
            onSave(reference)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button("Done") { dismiss() }
                .font(.body.weight(.semibold))
            Spacer()
            Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .disabled(index == 0)
            VStack(spacing: 0) {
                Text("Frame \(index + 1) of \(frames.count)").font(.subheadline.weight(.semibold)).monospacedDigit()
                if index >= reference.keyframes.count { Text("Snapshot").font(.caption2).foregroundStyle(.secondary) }
            }
            Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .disabled(index >= frames.count - 1)
            Spacer()
            Button { measurer.scaleText(by: 0.8) } label: { Text("A").font(.footnote.weight(.bold)).frame(width: 30, height: 36) }
            Button { measurer.scaleText(by: 1.25) } label: { Text("A").font(.title3.weight(.bold)).frame(width: 30, height: 36) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
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
            Text("\(number)").font(.caption2.weight(.bold)).monospacedDigit()
                .padding(.horizontal, 4).background(Color.black.opacity(0.6)).foregroundStyle(.white)
            if frame.depthFile == nil {
                Image(systemName: "ruler").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    .overlay(Rectangle().fill(Color.white.opacity(0.7)).frame(height: 1).rotationEffect(.degrees(-35)))
                    .padding(3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? Color.yellow : Color.clear, lineWidth: 3))
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

    private struct Loaded: @unchecked Sendable {
        let image: UIImage
        let cg: CGImage
        let depth: [Float]?
    }

    private struct Touch {
        var start: CGPoint
        var current: CGPoint
        var began = Date()
    }

    @State private var loaded: Loaded?
    @State private var failed = false
    @State private var touch: Touch?
    @State private var message: String?

    var body: some View {
        GeometryReader { geometry in
            let size = Self.fit(aspect: CGFloat(frame.uprightAspect), in: geometry.size)
            ZStack {
                content(size)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay(alignment: .top) {
            if let text = hint {
                Banner(text: text, fadesAfter: 5).padding(.top, 6).allowsHitTesting(false)
            }
        }
        .task(id: frame.id) { await load() }
    }

    private var hint: String? {
        if let message { return message }
        guard let loaded else { return nil }
        if loaded.depth == nil { return "No LiDAR depth in this frame: notes go in mid-air, and lines need a frame that has depth (marked in the strip)." }
        return "Drag to measure. Hold to add a note. Tap a mark to edit."
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
            marks(size).allowsHitTesting(false)
            pointer(size).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if touch == nil {
                        touch = Touch(start: value.startLocation, current: value.location)
                    } else {
                        touch?.current = value.location
                    }
                }
                .onEnded { value in
                    let began = touch?.began ?? Date()
                    touch = nil
                    finish(value, held: Date().timeIntervalSince(began), size: size)
                }
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

    /// While a finger is down: the points that will be marked sit above it, joined by a line.
    @ViewBuilder
    private func pointer(_ size: CGSize) -> some View {
        if let touch, hypot(touch.current.x - touch.start.x, touch.current.y - touch.start.y) >= 10 {
            let a = Self.aim(touch.start), b = Self.aim(touch.current)
            ZStack {
                Path { p in
                    p.move(to: a)
                    p.addLine(to: b)
                }
                .stroke(Color(Measurer.lineColour), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ring(a)
                ring(b)
                Path { p in
                    p.move(to: b)
                    p.addLine(to: touch.current)
                }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private func ring(_ p: CGPoint) -> some View {
        Circle().stroke(Color.white, lineWidth: 2)
            .background(Circle().fill(Color.black.opacity(0.25)))
            .frame(width: 22, height: 22)
            .position(p)
    }

    private static func aim(_ finger: CGPoint) -> CGPoint {
        CGPoint(x: finger.x, y: max(finger.y - Measurer.aimOffset, 8))
    }

    // MARK: Touch

    private func finish(_ value: DragGesture.Value, held: TimeInterval, size: CGSize) {
        let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
        guard measurer.entry == nil else { return }
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
        guard let values = loaded?.depth, frame.depthWidth > 0, frame.depthHeight > 0 else { return nil }
        let x = n.x * Float(frame.depthWidth), y = n.y * Float(frame.depthHeight)
        let metres = DepthMap.planeDepth(values, width: frame.depthWidth, height: frame.depthHeight, x: x, y: y)
            ?? DepthMap.sample(values, width: frame.depthWidth, height: frame.depthHeight, x: Int(x), y: Int(y))
        return metres.map { $0 * Measurer.depthScale }
    }

    private func addLine(from p: CGPoint, to q: CGPoint, size: CGSize) {
        guard let loaded, loaded.depth != nil else {
            say("This frame has no LiDAR depth, so lines can't be drawn on it. Try another frame.")
            Haptics.warning()
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
                .font(.system(size: 15 * scale, weight: .bold, design: .rounded))
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
