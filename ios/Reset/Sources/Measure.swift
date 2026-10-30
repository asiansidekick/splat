import ARKit
import SceneKit
import SwiftUI
import simd

/// Measuring with a crosshair (Phil, 2026-10-30): aim the middle of the screen at a point, tap +
/// to start a line, aim at the other end and tap + again. Lines and notes stay in the room, saved
/// with the reference, each with its length; with Axes on, also its level and upright parts, so
/// several sizes show at once. Uses LiDAR depth where there is some, ARKit's surfaces otherwise.
@MainActor
final class Measurer: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    @Published var active = false {
        didSet { if active != oldValue { activeChanged() } }
    }
    @Published private(set) var measurements: [RoomMeasurement] = []
    @Published private(set) var notes: [RoomNote] = []
    @Published private(set) var removed: [UUID] = []
    /// Where the crosshair meets the room, nil when it is on nothing.
    @Published private(set) var cursor: SIMD3<Float>?
    /// Whether the crosshair's distance comes from LiDAR or only from ARKit's estimated surfaces,
    /// which can be well out; shown under the reading.
    @Published private(set) var fromLiDAR = false
    /// A line being drawn with a finger, both ends read from one camera frame.
    struct DragLine: Equatable {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
    }
    @Published private(set) var drag: DragLine?
    private var drawStart: CGPoint = .zero
    private var loggedSource: Bool?
    /// Why there is no distance when tracking isn't ready, shown in place of the reading.
    @Published private(set) var trackingNote: String?
    private var loggedNote: String?
    /// The first end of the line being drawn.
    @Published private(set) var start: SIMD3<Float>?
    /// Bumped when the person adds or deletes something, so the reference is saved.
    @Published private(set) var revision = 0
    /// The line or note tapped, ready to delete on its own.
    @Published private(set) var selected: UUID? {
        didSet { if selected != oldValue { rebuild() } }
    }
    @Published var showAxes = UserDefaults.standard.object(forKey: "measureAxes") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showAxes, forKey: "measureAxes")
            rebuild()
        }
    }

    let session: ARSession
    private let root = SCNNode()
    private let preview = SCNNode()
    private var timer: Timer?

    static let lineColour = UIColor(red: 1, green: 0.84, blue: 0.1, alpha: 1)
    static let noteColour = UIColor(red: 1, green: 0.55, blue: 0.15, alpha: 1)
    static let pickedColour = UIColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)

    init(session: ARSession, parent: SCNNode) {
        self.session = session
        super.init()
        root.name = "measurements"
        parent.addChildNode(root)
        parent.addChildNode(preview)
    }

    /// While measuring, a tap on a line, its length or a note picks it; a tap elsewhere lets go.
    func attachGestures(to view: ARSCNView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDraw(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return true }
        return MainActor.assumeIsolated { self.active }
    }

    /// Drag a line across the screen: both ends are read from the same camera frame, so the length
    /// is the LiDAR's own, whatever the phone's tracking is doing. Hold the phone still.
    @objc private func handleDraw(_ gesture: UIPanGestureRecognizer) {
        guard active, let view = gesture.view as? ARSCNView else { return }
        let location = gesture.location(in: view)
        switch gesture.state {
        case .began:
            // The pan starts a few points into the drag: the line starts where the finger went down.
            let moved = gesture.translation(in: view)
            drawStart = CGPoint(x: location.x - moved.x, y: location.y - moved.y)
            start = nil
            selected = nil
            updateDrag(to: location, in: view)
        case .changed:
            updateDrag(to: location, in: view)
        case .ended:
            updateDrag(to: location, in: view)
            finishDrag(screenLength: hypot(location.x - drawStart.x, location.y - drawStart.y))
        default:
            drag = nil
            updatePreview()
        }
    }

    private func updateDrag(to location: CGPoint, in view: ARSCNView) {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState, let depth = Measurer.depth(of: frame),
            let a = Measurer.point(in: frame, depth: depth, at: drawStart, view: view),
            let b = Measurer.point(in: frame, depth: depth, at: location, view: view)
        else {
            drag = nil
            updatePreview()
            return
        }
        drag = DragLine(a: a, b: b)
        updatePreview()
    }

    private func finishDrag(screenLength: CGFloat) {
        defer {
            drag = nil
            updatePreview()
        }
        guard let drag, screenLength > 24, simd_distance(drag.a, drag.b) > 0.005 else { return }
        measurements.append(RoomMeasurement(a: array(drag.a), b: array(drag.b), created: Date()))
        Haptics.success()
        Diagnostics.log("Measured \(Measurer.text(measurements[measurements.count - 1].length)) (drawn on the screen, one frame)")
        changed()
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard active, let view = gesture.view as? ARSCNView else { return }
        let hits = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        let picked = hits.lazy.compactMap { Measurer.markID(of: $0.node) }.first
        if picked != nil { Haptics.tap() }
        selected = picked
    }

    /// The id of the line or note a drawn node belongs to.
    private static func markID(of node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let candidate = current {
            if let name = candidate.name, name.hasPrefix("mark:") { return UUID(uuidString: String(name.dropFirst(5))) }
            current = candidate.parent
        }
        return nil
    }

    /// The picked line, if a line (not a note) is picked.
    var selectedMeasurement: RoomMeasurement? {
        measurements.first { $0.id == selected }
    }

    /// Types in a line's real length (nil goes back to what the phone measured).
    func setLength(_ metres: Float?, for id: UUID) {
        guard let index = measurements.firstIndex(where: { $0.id == id }) else { return }
        measurements[index].typed = metres
        measurements[index].edited = Date()
        Diagnostics.log("Measurement edited: measured \(Measurer.text(measurements[index].measured)), shown \(Measurer.text(measurements[index].length))")
        changed()
    }

    /// Deletes the picked line or note.
    func deleteSelected() {
        guard let id = selected else { return }
        measurements.removeAll { $0.id == id }
        notes.removeAll { $0.id == id }
        removed.append(id)
        selected = nil
        changed()
    }

    /// Shows what a reference has saved.
    func load(measurements: [RoomMeasurement], notes: [RoomNote], removed: [UUID]) {
        self.measurements = measurements
        self.notes = notes
        self.removed = removed
        if let selected, !measurements.contains(where: { $0.id == selected }) && !notes.contains(where: { $0.id == selected }) {
            self.selected = nil
        }
        rebuild()
    }

    /// What the readout under the crosshair says.
    var readout: String {
        if let drag { return Measurer.text(simd_distance(drag.a, drag.b)) }
        if selected != nil { return "Edit or delete the red one" }
        guard let cursor else { return trackingNote ?? "Aim at a surface" }
        if let start { return Measurer.text(simd_distance(start, cursor)) }
        return measurements.isEmpty && notes.isEmpty ? "Drag a line across it, or aim and tap +" : "Drag a line, or aim and tap +"
    }

    /// Starts a line at the crosshair, or finishes the one started.
    func addPoint() {
        guard let cursor else {
            Haptics.warning()
            return
        }
        guard let start else {
            start = cursor
            Haptics.tap()
            updatePreview()
            return
        }
        self.start = nil
        guard simd_distance(start, cursor) > 0.005 else {
            updatePreview()
            return
        }
        measurements.append(RoomMeasurement(a: array(start), b: array(cursor), created: Date()))
        Haptics.success()
        let camera = session.currentFrame?.camera.transform.columns.3
        let away = camera.map { simd_distance(cursor, SIMD3($0.x, $0.y, $0.z)) }
        Diagnostics.log("Measured \(Measurer.text(measurements[measurements.count - 1].length)) (\(fromLiDAR ? "LiDAR" : "estimated surfaces")), end \(away.map { String(format: "%.2f m", $0) } ?? "?") from the camera")
        changed()
    }

    func addNote(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cursor, !text.isEmpty else { return }
        notes.append(RoomNote(text: String(text.prefix(120)), position: array(cursor), created: Date()))
        Haptics.success()
        changed()
    }

    /// Takes back the line being started, or else the newest measurement or note.
    func undo() {
        if start != nil {
            start = nil
            updatePreview()
            return
        }
        let lastLine = measurements.last?.created ?? .distantPast
        let lastNote = notes.last?.created ?? .distantPast
        if let line = measurements.last, lastLine >= lastNote {
            measurements.removeLast()
            removed.append(line.id)
        } else if let note = notes.last {
            notes.removeLast()
            removed.append(note.id)
        } else {
            return
        }
        changed()
    }

    func clear() {
        start = nil
        selected = nil
        removed += measurements.map(\.id) + notes.map(\.id)
        measurements = []
        notes = []
        changed()
    }

    var isEmpty: Bool { measurements.isEmpty && notes.isEmpty }

    private func changed() {
        revision += 1
        rebuild()
        updatePreview()
    }

    private func activeChanged() {
        timer?.invalidate()
        timer = nil
        start = nil
        cursor = nil
        selected = nil
        loggedSource = nil
        trackingNote = nil
        loggedNote = nil
        drag = nil
        updatePreview()
        guard active else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let frame = session.currentFrame else {
            cursor = nil
            updatePreview()
            return
        }
        guard case .normal = frame.camera.trackingState else {
            cursor = nil
            let note = Measurer.reason(frame.camera.trackingState)
            trackingNote = note
            if note != loggedNote {
                loggedNote = note
                Diagnostics.log("Measure: no distance, \(note)")
            }
            updatePreview()
            return
        }
        trackingNote = nil
        loggedNote = nil
        if let point = Measurer.depthPoint(frame) {
            cursor = point
            fromLiDAR = true
        } else {
            cursor = Measurer.surfacePoint(frame, session: session)
            fromLiDAR = false
        }
        if loggedSource != fromLiDAR {
            loggedSource = fromLiDAR
            Diagnostics.log("Measure: distance from \(fromLiDAR ? "LiDAR depth" : "estimated surfaces (no LiDAR depth)")")
        }
        updatePreview()
    }

    /// What to tell the person when ARKit can't place the phone yet.
    static func reason(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return ""
        case .notAvailable: return "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return "Moving too fast: slow down"
            case .insufficientFeatures: return "Too dark or plain to track: add light or aim at detail"
            case .initializing: return "Finding position: move slowly"
            case .relocalizing: return "Finding the room again: move slowly"
            @unknown default: return "Tracking limited"
            }
        }
    }

    // MARK: Finding the point under the crosshair

    /// The LiDAR depth in the middle of the picture (the median of the middle 3 by 3 readings),
    /// along the ray through the middle of the screen.
    static func depthPoint(_ frame: ARFrame) -> SIMD3<Float>? {
        guard let depth = depth(of: frame) else { return nil }
        return point(in: frame, depth: depth, normalized: CGPoint(x: 0.5, y: 0.5))
    }

    /// A frame's LiDAR depth as metres, whatever format ARKit sends (32 or 16 bit, depth or disparity).
    struct Depth {
        let values: [Float]
        let width: Int
        let height: Int
    }

    static func depth(of frame: ARFrame) -> Depth? {
        guard let map = (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap else { return nil }
        return Depth(values: DepthMap.floats(DepthMap.copy(map)), width: CVPixelBufferGetWidth(map), height: CVPixelBufferGetHeight(map))
    }

    /// The point in the room under a point of the view, from this frame's depth.
    static func point(in frame: ARFrame, depth: Depth, at location: CGPoint, view: UIView) -> SIMD3<Float>? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        // From the view's points to the camera picture's own 0 to 1 coordinates.
        let toImage = frame.displayTransform(for: Screen.orientation, viewportSize: size).inverted()
        let n = CGPoint(x: location.x / size.width, y: location.y / size.height).applying(toImage)
        return point(in: frame, depth: depth, normalized: n)
    }

    /// `normalized`: where in the camera picture, 0 to 1 across and down in the sensor's layout.
    static func point(in frame: ARFrame, depth: Depth, normalized n: CGPoint) -> SIMD3<Float>? {
        guard (0...1).contains(n.x), (0...1).contains(n.y),
            let metres = DepthMap.sample(depth.values, width: depth.width, height: depth.height,
                                         x: Int(n.x * CGFloat(depth.width)), y: Int(n.y * CGFloat(depth.height)))
        else { return nil }
        let k = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        // ARKit's camera looks down -z with y up; the picture counts y down.
        let x = (Float(n.x) * Float(size.width) - k[2][0]) / k[0][0]
        let y = -(Float(n.y) * Float(size.height) - k[2][1]) / k[1][1]
        let world = frame.camera.transform * SIMD4(x * metres, y * metres, -metres, 1)
        return SIMD3(world.x, world.y, world.z)
    }

    /// Where the middle of the screen meets a surface ARKit has found or estimates.
    static func surfacePoint(_ frame: ARFrame, session: ARSession) -> SIMD3<Float>? {
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .any)
        guard let hit = session.raycast(query).first else { return nil }
        let p = hit.worldTransform.columns.3
        return SIMD3(p.x, p.y, p.z)
    }

    // MARK: Drawing

    /// Millimetres are noise from a phone: tenths of a centimetre up to a metre, then centimetres.
    static func text(_ metres: Float) -> String { LengthText.format(metres) }

    private func array(_ p: SIMD3<Float>) -> [Float] { [p.x, p.y, p.z] }

    /// How tall labels are: readable from where the phone is now.
    private func labelHeight(at p: SIMD3<Float>) -> Float {
        guard let camera = session.currentFrame?.camera.transform.columns.3 else { return 0.03 }
        let distance = simd_distance(p, SIMD3(camera.x, camera.y, camera.z))
        return min(max(distance * 0.035, 0.012), 0.12)
    }

    private func rebuild() {
        root.childNodes.forEach { $0.removeFromParentNode() }
        for measurement in measurements {
            let picked = measurement.id == selected
            let line = node(
                for: measurement.start, measurement.end, axes: showAxes && !picked,
                colour: picked ? Measurer.pickedColour : Measurer.lineColour,
                scale: measurement.measured > 0 ? measurement.length / measurement.measured : 1)
            line.name = "mark:\(measurement.id.uuidString)"
            root.addChildNode(line)
        }
        for note in notes {
            let pin = SCNNode()
            pin.name = "mark:\(note.id.uuidString)"
            let colour = note.id == selected ? Measurer.pickedColour : Measurer.noteColour
            let height = labelHeight(at: note.spot)
            pin.addChildNode(Measurer.dot(at: note.spot, radius: max(height * 0.18, 0.004), colour: colour))
            pin.addChildNode(Measurer.line(from: note.spot, to: note.spot + SIMD3(0, height * 1.2, 0), radius: max(height * 0.04, 0.001), colour: colour))
            pin.addChildNode(ModelDimensions.tag(note.text, colour: colour, height: height, at: note.spot + SIMD3(0, height * 1.8, 0)))
            root.addChildNode(pin)
        }
        ModelDimensions.onTop(root)
    }

    /// A measured line with its length; with axes, its level part and upright part beside it.
    private func node(for a: SIMD3<Float>, _ b: SIMD3<Float>, axes: Bool, colour: UIColor = Measurer.lineColour, scale: Float = 1) -> SCNNode {
        let node = SCNNode()
        let middle = (a + b) / 2
        let height = labelHeight(at: middle)
        let radius = max(height * 0.05, 0.0012)
        node.addChildNode(Measurer.line(from: a, to: b, radius: radius, colour: colour))
        node.addChildNode(Measurer.dot(at: a, radius: radius * 3, colour: .white))
        node.addChildNode(Measurer.dot(at: b, radius: radius * 3, colour: .white))
        node.addChildNode(ModelDimensions.tag(Measurer.text(simd_distance(a, b) * scale), colour: colour, height: height, at: middle + SIMD3(0, height * 0.9, 0)))
        guard axes else { return node }
        let low = a.y <= b.y ? a : b
        let high = a.y <= b.y ? b : a
        let corner = SIMD3(high.x, low.y, high.z)
        let level = simd_distance(low, corner)
        let rise = high.y - low.y
        // Only when the line really slopes; a level or upright line is its own axis.
        guard level > 0.01, rise > 0.01 else { return node }
        node.addChildNode(Measurer.line(from: low, to: corner, radius: radius * 0.6, colour: ModelDimensions.depth.withAlphaComponent(0.85)))
        node.addChildNode(Measurer.line(from: corner, to: high, radius: radius * 0.6, colour: ModelDimensions.height.withAlphaComponent(0.85)))
        node.addChildNode(ModelDimensions.tag("↔ " + Measurer.text(level * scale), colour: ModelDimensions.depth, height: height * 0.8,
                                              at: (low + corner) / 2 - SIMD3(0, height * 0.8, 0)))
        node.addChildNode(ModelDimensions.tag("↕ " + Measurer.text(rise * scale), colour: ModelDimensions.height, height: height * 0.8,
                                              at: (corner + high) / 2 + simd_normalize(corner - low) * height * 1.6))
        return node
    }

    /// The line being drawn: from where it started to the crosshair, with its length.
    private func updatePreview() {
        preview.childNodes.forEach { $0.removeFromParentNode() }
        guard active else { return }
        if let drag {
            preview.addChildNode(Measurer.dot(at: drag.a, radius: 0.004, colour: .white))
            preview.addChildNode(node(for: drag.a, drag.b, axes: false))
            ModelDimensions.onTop(preview)
            return
        }
        guard let start else { return }
        preview.addChildNode(Measurer.dot(at: start, radius: 0.004, colour: .white))
        if let cursor, simd_distance(start, cursor) > 0.002 {
            preview.addChildNode(node(for: start, cursor, axes: false))
        }
        ModelDimensions.onTop(preview)
    }

    static func line(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float, colour: UIColor) -> SCNNode {
        let length = simd_distance(a, b)
        let node = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius), height: CGFloat(max(length, 0.0005))))
        node.geometry?.materials = [ModelDimensions.flat(colour)]
        node.simdPosition = (a + b) / 2
        if length > 0 {
            // Cylinders stand along y; straight down needs a half turn, which from(_:to:) can't pick.
            let direction = (b - a) / length
            node.simdOrientation = simd_dot(direction, SIMD3(0, 1, 0)) < -0.9999
                ? simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
                : simd_quatf(from: SIMD3(0, 1, 0), to: direction)
        }
        return node
    }

    static func dot(at p: SIMD3<Float>, radius: Float, colour: UIColor) -> SCNNode {
        let node = SCNNode(geometry: SCNSphere(radius: CGFloat(radius)))
        node.geometry?.materials = [ModelDimensions.flat(colour)]
        node.simdPosition = p
        return node
    }
}

/// Over the camera while measuring: the crosshair and what it reads.
struct MeasureReticle: View {
    @ObservedObject var measurer: Measurer

    var body: some View {
        if measurer.active {
            let found = measurer.cursor != nil
            // The crosshair's middle sits on the middle of the screen, the reading just under it.
            ZStack {
                Circle().stroke(found ? Color.yellow : Color.white.opacity(0.6), lineWidth: 2).frame(width: 34, height: 34)
                Circle().fill(found ? Color.yellow : Color.white.opacity(0.6)).frame(width: 6, height: 6)
                Text(measurer.readout)
                    .font(.subheadline.bold().monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(y: 40)
                if found && !measurer.fromLiDAR {
                    Text("Estimated: may be out")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .fixedSize()
                        .offset(y: 66)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .allowsHitTesting(false)
        }
    }
}

/// The measuring buttons, above the bottom controls while measuring.
struct MeasureBar: View {
    @ObservedObject var measurer: Measurer
    @State private var writing = false
    @State private var draft = ""
    @State private var confirmingClear = false
    @State private var editing = false
    @State private var draftLength = ""

    var body: some View {
        if measurer.active {
            HStack(spacing: 18) {
                small("arrow.uturn.backward", "Undo") { measurer.undo() }
                    .disabled(measurer.start == nil && measurer.isEmpty)
                small(measurer.showAxes ? "move.3d" : "line.diagonal", measurer.showAxes ? "Axes on" : "Axes off") {
                    measurer.showAxes.toggle()
                }
                Button { measurer.addPoint() } label: {
                    Image(systemName: measurer.start == nil ? "plus" : "checkmark")
                        .font(.title.bold())
                        .frame(width: 62, height: 62)
                        .background(Color.yellow, in: Circle())
                        .foregroundStyle(.black)
                }
                .accessibilityLabel(measurer.start == nil ? "Start a measurement here" : "End the measurement here")
                small("text.bubble", "Note") {
                    draft = ""
                    writing = true
                }
                .disabled(measurer.cursor == nil)
                if measurer.selected != nil {
                    if let line = measurer.selectedMeasurement {
                        small("pencil", "Edit", tint: .yellow) {
                            draftLength = String(format: "%.1f", line.length * 100)
                            editing = true
                        }
                    }
                    small("trash.fill", "Delete", tint: .red) { measurer.deleteSelected() }
                } else {
                    small("trash", "Delete") { confirmingClear = true }
                        .disabled(measurer.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45), in: Capsule())
            .alert("Note at the crosshair", isPresented: $writing) {
                TextField("For example: cup handle faces camera", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Add") { measurer.addNote(draft) }
            }
            .alert("Real length", isPresented: $editing) {
                TextField("For example: 29.7 cm, 0.3 m, 12 in", text: $draftLength)
                    .keyboardType(.numbersAndPunctuation)
                Button("Cancel", role: .cancel) {}
                if let line = measurer.selectedMeasurement, line.typed != nil {
                    Button("Use measured") { measurer.setLength(nil, for: line.id) }
                }
                Button("Set") {
                    if let line = measurer.selectedMeasurement, let metres = LengthText.parse(draftLength) {
                        measurer.setLength(metres, for: line.id)
                    }
                }
            } message: {
                Text("Type the true length of what you measured. A number on its own is centimetres; add mm, m, in or ft for other units.")
            }
            .confirmationDialog("Delete every measurement and note?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { measurer.clear() }
            }
        }
    }

    private func small(_ symbol: String, _ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .frame(minWidth: 40)
            .foregroundStyle(tint)
        }
        .accessibilityLabel(title)
    }
}

/// The top-bar ruler that turns measuring on and off.
struct MeasureToggle: View {
    @ObservedObject var measurer: Measurer

    var body: some View {
        Button {
            Haptics.tap()
            measurer.active.toggle()
        } label: {
            Image(systemName: "ruler").font(.title3)
                .foregroundStyle(measurer.active ? Color.yellow : Color.white)
        }
        .accessibilityLabel(measurer.active ? "Stop measuring" : "Measure")
    }
}
