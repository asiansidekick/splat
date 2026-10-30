import ARKit
import SceneKit
import SwiftUI
import simd

/// Dimensioning and notes in the room (Phil, 2026-10-30): drag a line across something, or aim the
/// middle of the screen and tap + at each end, and the line stays in the room with a size on it.
/// The phone's own reading is only a guess ("~"); a large pop-out asks for the real length, which
/// is what the line then shows. Notes are comic-book bubbles that can sit on a surface or in mid-air,
/// at the crosshair or where a finger is held down, and be moved later. All saved with the reference.
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
    /// What the large pop-out is asking for: a line's real length, or a note's text (nil = a new one).
    enum Entry: Hashable {
        case length(UUID)
        case note(UUID?)
    }
    @Published private(set) var entry: Entry?
    /// Where a new note goes when it was started by holding a finger down; nil = at the crosshair.
    private var noteSpot: SIMD3<Float>?
    /// The note being carried: it follows the crosshair until dropped.
    @Published private(set) var moving: UUID?
    /// How far ahead a note hangs in mid-air when the crosshair is on nothing.
    private var airDistance: Float = 1
    /// What the last drag was made of, written to the log when the line is kept so a wrong length
    /// can be traced to the depth, the mapping or the pose.
    private var dragDetail = ""
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
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.6
        hold.delegate = self
        view.addGestureRecognizer(hold)
    }

    /// Holding a finger down puts a note right there: on the surface under the finger, or in mid-air.
    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, active, moving == nil, entry == nil, let view = gesture.view as? ARSCNView else { return }
        let location = gesture.location(in: view)
        var spot: SIMD3<Float>?
        if let frame = session.currentFrame, case .normal = frame.camera.trackingState, let depth = Measurer.depth(of: frame) {
            spot = Measurer.point(in: frame, depth: depth, at: location, view: view)
        }
        if spot == nil {
            let near = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1))
            let direction = simd_normalize(SIMD3(far.x - near.x, far.y - near.y, far.z - near.z))
            spot = SIMD3(near.x, near.y, near.z) + direction * airDistance
        }
        noteSpot = spot
        Haptics.tap()
        entry = .note(nil)
    }

    func askLength(_ id: UUID) { entry = .length(id) }

    func askNote(editing id: UUID? = nil) {
        if id == nil { noteSpot = nil }
        entry = .note(id)
    }

    func dismissEntry() {
        entry = nil
        noteSpot = nil
    }

    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer else { return true }
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
        dragDetail = Measurer.detail(frame: frame, depth: depth, view: view, from: drawStart, to: location, a: a, b: b)
        updatePreview()
    }

    private func finishDrag(screenLength: CGFloat) {
        defer {
            drag = nil
            updatePreview()
        }
        guard let drag, screenLength > 24, simd_distance(drag.a, drag.b) > 0.005 else { return }
        let line = RoomMeasurement(a: array(drag.a), b: array(drag.b), created: Date())
        measurements.append(line)
        entry = .length(line.id)
        Haptics.success()
        Diagnostics.log("Measured \(Measurer.text(measurements[measurements.count - 1].length)) (drawn on the screen, one frame)")
        Diagnostics.log("Drag detail: \(dragDetail)")
        changed()
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard active, moving == nil, let view = gesture.view as? ARSCNView else { return }
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
        if let drag { return "~" + Measurer.text(simd_distance(drag.a, drag.b)) }
        if moving != nil { return "Aim where it goes, tap ✓" }
        if selected != nil { return "Edit, move or delete the red one" }
        guard let cursor else { return trackingNote ?? "Aim at a surface" }
        if let start { return "~" + Measurer.text(simd_distance(start, cursor)) }
        return measurements.isEmpty && notes.isEmpty ? "Drag a line across it, or hold to add a note" : "Drag a line, or hold to add a note"
    }

    /// Starts a line at the crosshair, or finishes the one started.
    func addPoint() {
        if moving != nil {
            dropNote()
            return
        }
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
        let line = RoomMeasurement(a: array(start), b: array(cursor), created: Date())
        measurements.append(line)
        entry = .length(line.id)
        Haptics.success()
        let camera = session.currentFrame?.camera.transform.columns.3
        let away = camera.map { simd_distance(cursor, SIMD3($0.x, $0.y, $0.z)) }
        Diagnostics.log("Measured \(Measurer.text(measurements[measurements.count - 1].length)) (\(fromLiDAR ? "LiDAR" : "estimated surfaces")), end \(away.map { String(format: "%.2f m", $0) } ?? "?") from the camera")
        changed()
    }

    /// What a note currently says, for editing it.
    func noteText(_ id: UUID) -> String? { notes.first { $0.id == id }?.text }

    /// Saves the note from the pop-out: a new one at the held spot, the crosshair or in mid-air,
    /// or new words for one already there.
    func saveNote(_ text: String, editing id: UUID?) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        defer { dismissEntry() }
        guard !text.isEmpty else { return }
        if let id, let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].text = text
            notes[index].edited = Date()
        } else if let spot = noteSpot ?? cursor ?? airPoint() {
            notes.append(RoomNote(text: text, position: array(spot), created: Date()))
        } else {
            Haptics.warning()
            return
        }
        Haptics.success()
        changed()
    }

    /// Picks the selected note up so it follows the crosshair, or puts it down where it is.
    func toggleMove() {
        if moving != nil {
            dropNote()
        } else if let id = selected, notes.contains(where: { $0.id == id }) {
            moving = id
            Haptics.tap()
        }
    }

    private func dropNote() {
        guard let id = moving else { return }
        moving = nil
        if let index = notes.firstIndex(where: { $0.id == id }) { notes[index].edited = Date() }
        Haptics.success()
        changed()
    }

    /// A point straight ahead of the phone, for a note that hangs in the air.
    private func airPoint() -> SIMD3<Float>? {
        guard let t = session.currentFrame?.camera.transform else { return nil }
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        return SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z) + forward * airDistance
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
        moving = nil
        entry = nil
        noteSpot = nil
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
        if let cursor, let camera = session.currentFrame?.camera.transform.columns.3 {
            airDistance = min(max(simd_distance(cursor, SIMD3(camera.x, camera.y, camera.z)), 0.4), 4)
        }
        if let id = moving, let index = notes.firstIndex(where: { $0.id == id }), let spot = cursor ?? airPoint() {
            notes[index].position = array(spot)
            rebuild()
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

    /// A line of numbers for the log: where each end fell in the picture, the depth there, the
    /// phone's tilt, the height difference, and what the length would be if the depth were the
    /// distance along the ray instead of straight ahead.
    static func detail(frame: ARFrame, depth: Depth, view: UIView, from p: CGPoint, to q: CGPoint, a: SIMD3<Float>, b: SIMD3<Float>) -> String {
        let size = view.bounds.size
        let toImage = frame.displayTransform(for: Screen.orientation, viewportSize: size).inverted()
        func norm(_ l: CGPoint) -> CGPoint { CGPoint(x: l.x / size.width, y: l.y / size.height).applying(toImage) }
        let na = norm(p), nb = norm(q)
        func metres(_ n: CGPoint) -> Float {
            DepthMap.sample(depth.values, width: depth.width, height: depth.height,
                            x: Int(n.x * CGFloat(depth.width)), y: Int(n.y * CGFloat(depth.height))) ?? 0
        }
        let ma = metres(na), mb = metres(nb)
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        func ray(_ n: CGPoint) -> SIMD3<Float> {
            SIMD3((Float(n.x) * Float(res.width) - k[2][0]) / k[0][0], -(Float(n.y) * Float(res.height) - k[2][1]) / k[1][1], -1)
        }
        // If the depth were distance along each ray, the points would be along the unit rays.
        func world(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let w = frame.camera.transform * SIMD4(v.x, v.y, v.z, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        let rangeLength = simd_distance(world(simd_normalize(ray(na)) * ma), world(simd_normalize(ray(nb)) * mb))
        let t = frame.camera.transform
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let pitch = asin(max(-1, min(1, forward.y))) * 180 / .pi
        return String(format: "view %@→%@ image (%.3f,%.3f)→(%.3f,%.3f) depth %.3f/%.3f m, pitch %.0f°, rise %.1f cm, along-ray length %.1f cm, f %.0f/%.0f c %.0f,%.0f res %.0fx%.0f depth %ldx%ld %@",
                      "\(Int(p.x)),\(Int(p.y))", "\(Int(q.x)),\(Int(q.y))", na.x, na.y, nb.x, nb.y, ma, mb, pitch,
                      abs(a.y - b.y) * 100, rangeLength * 100, k[0][0], k[1][1], k[2][0], k[2][1], res.width, res.height,
                      depth.width, depth.height, "\(Screen.orientation.rawValue) view \(Int(size.width))x\(Int(size.height))")
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
                scale: measurement.measured > 0 ? measurement.length / measurement.measured : 1,
                approx: measurement.typed == nil)
            line.name = "mark:\(measurement.id.uuidString)"
            root.addChildNode(line)
        }
        for note in notes {
            let pin = SCNNode()
            pin.name = "mark:\(note.id.uuidString)"
            let picked = note.id == selected
            let height = labelHeight(at: note.spot)
            pin.addChildNode(Measurer.dot(at: note.spot, radius: max(height * 0.12, 0.003), colour: picked ? Measurer.pickedColour : Measurer.noteColour))
            pin.addChildNode(ModelDimensions.bubble(note.text, picked: picked, height: height * 1.2, at: note.spot + SIMD3(0, height * 0.2, 0)))
            root.addChildNode(pin)
        }
        ModelDimensions.onTop(root)
    }

    /// A measured line with its length; with axes, its level part and upright part beside it.
    private func node(for a: SIMD3<Float>, _ b: SIMD3<Float>, axes: Bool, colour: UIColor = Measurer.lineColour, scale: Float = 1, approx: Bool = false) -> SCNNode {
        let guess = approx ? "~" : ""
        let node = SCNNode()
        let middle = (a + b) / 2
        let height = labelHeight(at: middle)
        let radius = max(height * 0.05, 0.0012)
        node.addChildNode(Measurer.line(from: a, to: b, radius: radius, colour: colour))
        node.addChildNode(Measurer.dot(at: a, radius: radius * 3, colour: .white))
        node.addChildNode(Measurer.dot(at: b, radius: radius * 3, colour: .white))
        node.addChildNode(ModelDimensions.tag(guess + Measurer.text(simd_distance(a, b) * scale), colour: colour, height: height, at: middle + SIMD3(0, height * 0.9, 0)))
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
        node.addChildNode(ModelDimensions.tag("↔ " + guess + Measurer.text(level * scale), colour: ModelDimensions.depth, height: height * 0.8,
                                              at: (low + corner) / 2 - SIMD3(0, height * 0.8, 0)))
        node.addChildNode(ModelDimensions.tag("↕ " + guess + Measurer.text(rise * scale), colour: ModelDimensions.height, height: height * 0.8,
                                              at: (corner + high) / 2 + simd_normalize(corner - low) * height * 1.6))
        return node
    }

    /// The line being drawn: from where it started to the crosshair, with its length.
    private func updatePreview() {
        preview.childNodes.forEach { $0.removeFromParentNode() }
        guard active else { return }
        if let drag {
            preview.addChildNode(Measurer.dot(at: drag.a, radius: 0.004, colour: .white))
            preview.addChildNode(node(for: drag.a, drag.b, axes: false, approx: true))
            ModelDimensions.onTop(preview)
            return
        }
        guard let start else { return }
        preview.addChildNode(Measurer.dot(at: start, radius: 0.004, colour: .white))
        if let cursor, simd_distance(start, cursor) > 0.002 {
            preview.addChildNode(node(for: start, cursor, axes: false, approx: true))
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
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .allowsHitTesting(false)
        }
    }
}

/// The measuring buttons, above the bottom controls while measuring.
struct MeasureBar: View {
    @ObservedObject var measurer: Measurer
    @State private var confirmingClear = false

    var body: some View {
        if measurer.active {
            HStack(spacing: 18) {
                if measurer.selected != nil && measurer.moving == nil {
                    if let line = measurer.selectedMeasurement {
                        small("pencil", "Size", tint: .yellow) { measurer.askLength(line.id) }
                    } else if let id = measurer.selected {
                        small("pencil", "Edit", tint: .yellow) { measurer.askNote(editing: id) }
                        small("arrow.up.and.down.and.arrow.left.and.right", "Move", tint: .yellow) { measurer.toggleMove() }
                    }
                } else if measurer.moving == nil {
                    small("arrow.uturn.backward", "Undo") { measurer.undo() }
                        .disabled(measurer.start == nil && measurer.isEmpty)
                    small(measurer.showAxes ? "move.3d" : "line.diagonal", measurer.showAxes ? "Axes on" : "Axes off") {
                        measurer.showAxes.toggle()
                    }
                }
                Button { measurer.addPoint() } label: {
                    Image(systemName: measurer.start == nil && measurer.moving == nil ? "plus" : "checkmark")
                        .font(.title.bold())
                        .frame(width: 62, height: 62)
                        .background(Color.yellow, in: Circle())
                        .foregroundStyle(.black)
                }
                .accessibilityLabel(measurer.moving != nil ? "Put the note down here" : measurer.start == nil ? "Start a line here" : "End the line here")
                if measurer.moving == nil {
                    small("text.bubble", "Note") { measurer.askNote() }
                    if measurer.selected != nil {
                        small("trash.fill", "Delete", tint: .red) { measurer.deleteSelected() }
                    } else {
                        small("trash", "Delete") { confirmingClear = true }
                            .disabled(measurer.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.45), in: Capsule())
            .confirmationDialog("Delete every dimension and note?", isPresented: $confirmingClear, titleVisibility: .visible) {
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

/// The large pop-outs over the camera: one for typing a line's real length, one for writing a
/// note in a comic-book speech bubble. They zoom in from the middle of the screen.
struct MeasureEntry: View {
    @ObservedObject var measurer: Measurer
    @State private var text = ""
    @AppStorage("lengthUnit") private var unit = "cm"
    @FocusState private var focused: Bool

    private static let units: [(name: String, metres: Float)] = [("cm", 0.01), ("mm", 0.001), ("m", 1), ("in", 0.0254), ("ft", 0.3048)]

    private func comic(_ size: CGFloat) -> Font { .custom("MarkerFelt-Wide", size: size) }

    var body: some View {
        ZStack {
            if let entry = measurer.entry {
                Color.black.opacity(0.6).ignoresSafeArea()
                Group {
                    switch entry {
                    case .length(let id): lengthCard(id)
                    case .note(let id): noteCard(id)
                    }
                }
                .transition(.scale(scale: 0.2).combined(with: .opacity))
                .id(entry)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.7), value: measurer.entry)
        .onChange(of: measurer.entry, initial: true) { _, entry in prepare(entry) }
    }

    private func prepare(_ entry: Measurer.Entry?) {
        switch entry {
        case .length(let id)?:
            if let typed = measurer.measurements.first(where: { $0.id == id })?.typed {
                text = String(format: "%.4g", Double(typed / factor))
            } else {
                text = ""
            }
        case .note(let id)?:
            text = id.flatMap { measurer.noteText($0) } ?? ""
        case nil:
            text = ""
        }
        if entry != nil { DispatchQueue.main.async { focused = true } }
    }

    private var factor: Float { Self.units.first { $0.name == unit }?.metres ?? 0.01 }

    private func lengthCard(_ id: UUID) -> some View {
        let guess = measurer.measurements.first { $0.id == id }?.measured
        return VStack(spacing: 14) {
            Text("HOW BIG IS IT?").font(comic(32)).foregroundStyle(.black)
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .focused($focused)
                .font(.system(size: 68, weight: .black, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
                .padding(.vertical, 8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.black, lineWidth: 4))
            HStack(spacing: 8) {
                ForEach(Self.units, id: \.name) { item in
                    Button { unit = item.name } label: {
                        Text(item.name).font(comic(24))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(unit == item.name ? Color.black : Color.white, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(unit == item.name ? Color.yellow : Color.black)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black, lineWidth: 3))
                    }
                }
            }
            if let guess {
                Button {
                    text = String(format: "%.4g", Double(guess / factor))
                } label: {
                    Text("The phone guesses ~\(Measurer.text(guess)). Tap to use it.")
                        .font(.footnote.bold())
                        .foregroundStyle(.black.opacity(0.7))
                }
            }
            HStack(spacing: 14) {
                comicButton("SKIP", fill: .white) { measurer.dismissEntry() }
                comicButton("SET IT!", fill: .black, text: .yellow) {
                    var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let last = typed.last, last.isNumber || last == "." { typed += unit }
                    guard let metres = LengthText.parse(typed) else {
                        Haptics.warning()
                        return
                    }
                    measurer.setLength(metres, for: id)
                    measurer.dismissEntry()
                }
            }
        }
        .padding(20)
        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.black, lineWidth: 6))
        .shadow(color: .black, radius: 0, x: 7, y: 7)
        .padding(.horizontal, 18)
    }

    private func noteCard(_ id: UUID?) -> some View {
        VStack(spacing: 22) {
            ZStack {
                SpeechBubble().fill(Color.white)
                SpeechBubble().stroke(Color.black, style: StrokeStyle(lineWidth: 6, lineJoin: .round))
                TextField("WRITE SOMETHING!", text: $text, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focused)
                    .textInputAutocapitalization(.characters)
                    .font(comic(30))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 30)
                    .padding(.top, 26)
                    .padding(.bottom, 62)
                    .onChange(of: text) { _, value in
                        if value.count > 120 { text = String(value.prefix(120)) }
                    }
            }
            .frame(minHeight: 230)
            .shadow(color: .black, radius: 0, x: 7, y: 7)
            .overlay(alignment: .topLeading) {
                Text(id == nil ? "NOTE!" : "EDIT!")
                    .font(comic(26))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(Starburst().fill(Color.yellow))
                    .background(Starburst().stroke(Color.black, lineWidth: 4))
                    .rotationEffect(.degrees(-8))
                    .offset(x: -8, y: -26)
            }
            HStack(spacing: 14) {
                comicButton("CANCEL", fill: .white) { measurer.dismissEntry() }
                comicButton(id == nil ? "PLACE IT!" : "SAVE IT!", fill: .yellow) { measurer.saveNote(text, editing: id) }
            }
        }
        .padding(.horizontal, 22)
    }

    private func comicButton(_ title: String, fill: Color, text color: Color = .black, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(comic(26))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(fill, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(color)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black, lineWidth: 4))
                .shadow(color: .black, radius: 0, x: 4, y: 4)
        }
    }
}

/// A rounded speech bubble with a tail at the bottom left.
struct SpeechBubble: Shape {
    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 38
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
        let c: CGFloat = 34
        var p = Path()
        p.move(to: CGPoint(x: body.minX + c, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - c, y: body.minY))
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + c), control: CGPoint(x: body.maxX, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - c))
        p.addQuadCurve(to: CGPoint(x: body.maxX - c, y: body.maxY), control: CGPoint(x: body.maxX, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX + 110, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX + 46, y: rect.maxY))
        p.addLine(to: CGPoint(x: body.minX + 62, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX + c, y: body.maxY))
        p.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY - c), control: CGPoint(x: body.minX, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + c))
        p.addQuadCurve(to: CGPoint(x: body.minX + c, y: body.minY), control: CGPoint(x: body.minX, y: body.minY))
        p.closeSubpath()
        return p
    }
}

/// A comic-book starburst for the "NOTE!" flash.
struct Starburst: Shape {
    func path(in rect: CGRect) -> Path {
        let points = 12
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        for i in 0..<(points * 2) {
            let angle = Double(i) * .pi / Double(points)
            let radius = i % 2 == 0 ? 1.0 : 0.72
            let point = CGPoint(x: centre.x + CGFloat(cos(angle) * radius) * rect.width / 2,
                                y: centre.y + CGFloat(sin(angle) * radius) * rect.height / 2)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
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
