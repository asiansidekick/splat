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
    /// How big dimension and note text is drawn; pinch while measuring to change it.
    @Published private(set) var textScale = UserDefaults.standard.object(forKey: "measureTextScale") as? Float ?? 1
    /// What the last drag was made of, written to the log when the line is kept so a wrong length
    /// can be traced to the depth, the mapping or the pose.
    private var dragDetail = ""
    private var dragView: ARSCNView?
    private var dragLocation: CGPoint?
    private var dragFinger: CGPoint = .zero
    private var dragSamples: [DragLine] = []
    private var dragSampleTime: TimeInterval = 0
    private var dragTooClose = false
    /// Where the finger is, the point it is aiming at above it, and where the corner snap put
    /// that point, all in screen points, so the aim can be drawn where it can be seen.
    struct Pointer: Equatable {
        var finger: CGPoint
        var aim: CGPoint
        var landed: CGPoint
        var start: CGPoint
    }
    @Published private(set) var pointer: Pointer?
    /// The aim point sits this far above the finger, so the finger never hides it.
    static let aimOffset: CGFloat = 70
    /// The crosshair is nearer than the LiDAR can read.
    @Published private(set) var tooClose = false
    private var drawStart: CGPoint = .zero
    private var loggedSource: Bool?
    /// Why there is no distance when tracking isn't ready, shown in place of the reading.
    @Published private(set) var trackingNote: String?
    private var loggedNote: String?
    /// The first end of the line being drawn.
    @Published private(set) var start: SIMD3<Float>?
    /// Bumped when the person adds or deletes something, so the reference is saved.
    @Published private(set) var revision = 0
    /// How much the phone's depth readings are stretched to agree with a real length typed in
    /// against a tape measure (Phil, 2026-10-31). 1 = as read.
    @Published private(set) var calibration = Measurer.depthScale
    static var depthScale: Float = UserDefaults.standard.object(forKey: "measureDepthScale") as? Float ?? 1
    /// The line or note tapped, ready to delete on its own.
    @Published private(set) var selected: UUID? {
        didSet { if selected != oldValue { rebuild() } }
    }
    @Published var showAxes = UserDefaults.standard.object(forKey: "measureAxes2") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(showAxes, forKey: "measureAxes2")
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
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.6
        hold.delegate = self
        view.addGestureRecognizer(hold)
    }

    /// Pinch to make the dimension and note text bigger or smaller.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard active else { return }
        textScale = min(max(textScale * Float(gesture.scale), 0.4), 5)
        gesture.scale = 1
        rebuild()
        updatePreview()
        if gesture.state == .ended { UserDefaults.standard.set(textScale, forKey: "measureTextScale") }
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
        guard gestureRecognizer is UIPanGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer || gestureRecognizer is UIPinchGestureRecognizer else { return true }
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
            drawStart = Measurer.aim(for: CGPoint(x: location.x - moved.x, y: location.y - moved.y), in: view)
            start = nil
            selected = nil
            updateDrag(to: location, in: view)
        case .changed:
            updateDrag(to: location, in: view)
        case .ended:
            updateDrag(to: location, in: view)
            finishDrag(screenLength: hypot(Measurer.aim(for: location, in: view).x - drawStart.x, Measurer.aim(for: location, in: view).y - drawStart.y))
        default:
            endDrag()
        }
    }

    private func endDrag() {
        pointer = nil
        drag = nil
        dragLocation = nil
        dragView = nil
        dragSamples = []
        dragTooClose = false
        updatePreview()
    }

    private func updateDrag(to location: CGPoint, in view: ARSCNView) {
        // Moving the finger starts the averaging again; holding it still builds it up.
        let aim = Measurer.aim(for: location, in: view)
        if let last = dragLocation, hypot(last.x - aim.x, last.y - aim.y) > 1.5 { dragSamples = [] }
        dragFinger = location
        dragLocation = aim
        dragView = view
        sampleDrag()
    }

    /// Reads both ends from the newest camera frame and averages the last few, so a hand held
    /// still gives a steadier line than any one frame.
    private func sampleDrag() {
        guard let view = dragView, let location = dragLocation, let frame = session.currentFrame, frame.timestamp != dragSampleTime else { return }
        dragSampleTime = frame.timestamp
        guard case .normal = frame.camera.trackingState, let depth = Measurer.depth(of: frame),
            let a = Measurer.locate(in: frame, depth: depth, at: drawStart, view: view, snap: true),
            let b = Measurer.locate(in: frame, depth: depth, at: location, view: view, snap: true)
        else {
            dragSamples = []
            drag = nil
            pointer = nil
            updatePreview()
            return
        }
        pointer = Pointer(
            finger: dragFinger, aim: location,
            landed: Measurer.screenPoint(of: b.normalized, frame: frame, view: view),
            start: Measurer.screenPoint(of: a.normalized, frame: frame, view: view))
        dragSamples.append(DragLine(a: a.point, b: b.point))
        if dragSamples.count > 8 { dragSamples.removeFirst() }
        let line = DragLine(a: Measurer.median(dragSamples.map(\.a)), b: Measurer.median(dragSamples.map(\.b)))
        drag = line
        let camera = frame.camera.transform.columns.3
        let eye = SIMD3(camera.x, camera.y, camera.z)
        dragTooClose = min(simd_distance(line.a, eye), simd_distance(line.b, eye)) < Measurer.minimumRange
        dragDetail = Measurer.detail(frame: frame, session: session, depth: depth, view: view, from: drawStart, to: location, a: line.a, b: line.b)
            + String(format: ", snapped %@/%@, averaged over %ld frames", a.snapped ? "yes" : "no", b.snapped ? "yes" : "no", dragSamples.count)
        updatePreview()
    }

    private func finishDrag(screenLength: CGFloat) {
        defer { endDrag() }
        guard let drag, screenLength > 24, simd_distance(drag.a, drag.b) > 0.005 else { return }
        let line = RoomMeasurement(a: array(drag.a), b: array(drag.b), created: Date())
        measurements.append(line)
        Haptics.success()
        Diagnostics.log("Measured \(Measurer.text(measurements[measurements.count - 1].length)) (drawn on the screen)")
        Diagnostics.log("Drag detail: \(dragDetail)")
        changed()
    }

    /// The nearest the LiDAR reads reliably.
    static let minimumRange: Float = 0.25

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard active, moving == nil, let view = gesture.view as? ARSCNView else { return }
        let hits = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        let picked = hits.lazy.compactMap { Measurer.markID(of: $0.node) }.first
        if picked != nil { Haptics.tap() }
        selected = picked
        // Tapping a dimension or note is how you edit it.
        if let picked { entry = measurements.contains { $0.id == picked } ? .length(picked) : .note(picked) }
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
        deleteMark(id)
    }

    func deleteMark(_ id: UUID) {
        measurements.removeAll { $0.id == id }
        notes.removeAll { $0.id == id }
        removed.append(id)
        if selected == id { selected = nil }
        entry = nil
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
        if let drag { return "~" + Measurer.text(simd_distance(drag.a, drag.b)) + (dragTooClose ? " · too close" : "") }
        if moving != nil { return "Aim where it goes, tap ✓" }
        if selected != nil { return "Edit, move or delete the red one" }
        guard let cursor else { return trackingNote ?? "Aim at a surface" }
        if tooClose { return "Too close: step back a little" }
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
        Haptics.success()
        let camera = session.currentFrame?.camera.transform.columns.3
        let away = camera.map { simd_distance(cursor, SIMD3($0.x, $0.y, $0.z)) }
        Diagnostics.log("Measured \(Measurer.text(measurements[measurements.count - 1].length)) (\(fromLiDAR ? "LiDAR" : "estimated surfaces")), end \(away.map { String(format: "%.2f m", $0) } ?? "?") from the camera")
        changed()
    }

    // MARK: Reviewing saved frames away from the set

    /// Adds a line between two places worked out from a saved frame's depth.
    @discardableResult
    func addLine(from a: SIMD3<Float>, to b: SIMD3<Float>) -> UUID? {
        guard simd_distance(a, b) > 0.005 else { return nil }
        let line = RoomMeasurement(a: array(a), b: array(b), created: Date())
        measurements.append(line)
        Haptics.success()
        Diagnostics.log("Measured in a saved frame: \(Measurer.text(line.measured))")
        changed()
        return line.id
    }

    /// Opens the note window for a note that will go at `spot` in the room.
    func askNote(at spot: SIMD3<Float>) {
        noteSpot = spot
        Haptics.tap()
        entry = .note(nil)
    }

    /// Picks a line or note and opens its window, as tapping it in the room does.
    func open(_ id: UUID) {
        guard measurements.contains(where: { $0.id == id }) || notes.contains(where: { $0.id == id }) else { return }
        Haptics.tap()
        selected = id
        entry = measurements.contains { $0.id == id } ? .length(id) : .note(id)
    }

    func deselect() { selected = nil }

    /// Takes the real length typed for a line (say, against a tape measure laid in the scene) as
    /// the truth: later readings are stretched by the same ratio. Returns false if it can't be used.
    @discardableResult
    func calibrate(_ id: UUID, to metres: Float) -> Bool {
        guard let line = measurements.first(where: { $0.id == id }), line.measured > 0.03, metres > 0.03 else { return false }
        let scale = min(max(Measurer.depthScale * metres / line.measured, 0.3), 3)
        Measurer.depthScale = scale
        calibration = scale
        UserDefaults.standard.set(scale, forKey: "measureDepthScale")
        Diagnostics.log(String(format: "Calibrated: read %.1f cm, real %.1f cm, depth scale now %.3f", line.measured * 100, metres * 100, scale))
        setLength(metres, for: id)
        return true
    }

    func resetCalibration() {
        Measurer.depthScale = 1
        calibration = 1
        UserDefaults.standard.removeObject(forKey: "measureDepthScale")
        Haptics.tap()
    }

    /// Makes the text on lines and notes bigger or smaller (and remembers it).
    func scaleText(by factor: Float) {
        textScale = min(max(textScale * factor, 0.4), 5)
        UserDefaults.standard.set(textScale, forKey: "measureTextScale")
        rebuild()
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
        if dragLocation != nil { sampleDrag() }
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
            let away = simd_distance(cursor, SIMD3(camera.x, camera.y, camera.z))
            airDistance = min(max(away, 0.4), 4)
            let close = fromLiDAR && away < Measurer.minimumRange
            if tooClose != close { tooClose = close }
        } else if tooClose {
            tooClose = false
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
        locate(in: frame, depth: depth, at: location, view: view, snap: false)?.point
    }

    /// Like `point`, and with `snap` first moves the place onto the sharp corner nearest to it in
    /// the camera picture, if there is a clear one. Says whether it moved.
    static func locate(in frame: ARFrame, depth: Depth, at location: CGPoint, view: UIView, snap: Bool) -> (point: SIMD3<Float>, snapped: Bool, normalized: CGPoint)? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        // From the view's points to the camera picture's own 0 to 1 coordinates.
        let toImage = frame.displayTransform(for: Screen.orientation, viewportSize: size).inverted()
        var n = CGPoint(x: location.x / size.width, y: location.y / size.height).applying(toImage)
        var moved = false
        if snap, let corner = snapped(frame, to: n) {
            n = corner
            moved = true
        }
        guard let point = point(in: frame, depth: depth, normalized: n) else { return nil }
        return (point, moved, n)
    }

    /// The aim point for a finger: straight above it, kept on the screen.
    static func aim(for finger: CGPoint, in view: UIView) -> CGPoint {
        CGPoint(x: finger.x, y: max(finger.y - aimOffset, 8))
    }

    /// Where a place in the camera picture (0 to 1) shows on the screen, in points.
    static func screenPoint(of normalized: CGPoint, frame: ARFrame, view: UIView) -> CGPoint {
        let size = view.bounds.size
        let shown = normalized.applying(frame.displayTransform(for: Screen.orientation, viewportSize: size))
        return CGPoint(x: shown.x * size.width, y: shown.y * size.height)
    }

    /// The sharp corner nearest `n` (0 to 1 across the camera picture), found in the picture's
    /// brightness around it; nil when there is none that is clear.
    static func snapped(_ frame: ARFrame, to n: CGPoint, radius: Float = 56) -> CGPoint? {
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let half = Int(radius) + 10
        let cx = Int(n.x * CGFloat(width)), cy = Int(n.y * CGFloat(height))
        let x0 = max(0, cx - half), y0 = max(0, cy - half)
        let x1 = min(width, cx + half), y1 = min(height, cy + half)
        let w = x1 - x0, h = y1 - y0
        guard w > 24, h > 24 else { return nil }
        var patch = [Float](repeating: 0, count: w * h)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = bytes + (y0 + y) * rowBytes + x0
            for x in 0..<w { patch[y * w + x] = Float(row[x]) }
        }
        guard let corner = CornerSnap.corner(luma: patch, width: w, height: h, near: SIMD2(Float(cx - x0), Float(cy - y0)), within: radius) else { return nil }
        return CGPoint(x: (CGFloat(x0) + CGFloat(corner.x) + 0.5) / CGFloat(width), y: (CGFloat(y0) + CGFloat(corner.y) + 0.5) / CGFloat(height))
    }

    private static func median(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        func middle(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return SIMD3(middle(points.map(\.x)), middle(points.map(\.y)), middle(points.map(\.z)))
    }

    /// A line of numbers for the log: where each end fell in the picture, the depth there, the
    /// phone's tilt, the height difference, and what the length would be if the depth were the
    /// distance along the ray instead of straight ahead.
    static func detail(frame: ARFrame, session: ARSession, depth: Depth, view: UIView, from p: CGPoint, to q: CGPoint, a: SIMD3<Float>, b: SIMD3<Float>) -> String {
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
        // ARKit's own idea of how far the same places are, from its estimated surfaces, to tell
        // whether the LiDAR depth or the phone's tracking is the one that is out.
        let inverse = frame.camera.transform.inverse
        func tracked(_ n: CGPoint) -> String {
            let query = frame.raycastQuery(from: n, allowing: .estimatedPlane, alignment: .any)
            guard let hit = session.raycast(query).first else { return "none" }
            let p = inverse * hit.worldTransform.columns.3
            return String(format: "%.3f", -p.z)
        }
        let raycast = "\(tracked(na))/\(tracked(nb))"
        let rangeLength = simd_distance(world(simd_normalize(ray(na)) * ma), world(simd_normalize(ray(nb)) * mb))
        let t = frame.camera.transform
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let pitch = asin(max(-1, min(1, forward.y))) * 180 / .pi
        return String(format: "view %@→%@ image (%.3f,%.3f)→(%.3f,%.3f) depth %.3f/%.3f m, pitch %.0f°, rise %.1f cm, along-ray length %.1f cm, f %.0f/%.0f c %.0f,%.0f res %.0fx%.0f depth %ldx%ld %@, ARKit surface depth %@",
                      "\(Int(p.x)),\(Int(p.y))", "\(Int(q.x)),\(Int(q.y))", na.x, na.y, nb.x, nb.y, ma, mb, pitch,
                      abs(a.y - b.y) * 100, rangeLength * 100, k[0][0], k[1][1], k[2][0], k[2][1], res.width, res.height,
                      depth.width, depth.height, "\(Screen.orientation.rawValue) view \(Int(size.width))x\(Int(size.height))", raycast)
    }

    /// `normalized`: where in the camera picture, 0 to 1 across and down in the sensor's layout.
    static func point(in frame: ARFrame, depth: Depth, normalized n: CGPoint) -> SIMD3<Float>? {
        guard (0...1).contains(n.x), (0...1).contains(n.y) else { return nil }
        // A plane fitted to the depth round the place, falling back to its middle reading.
        let metres = DepthMap.planeDepth(depth.values, width: depth.width, height: depth.height,
                                          x: Float(n.x) * Float(depth.width), y: Float(n.y) * Float(depth.height))
            ?? DepthMap.sample(depth.values, width: depth.width, height: depth.height,
                               x: Int(n.x * CGFloat(depth.width)), y: Int(n.y * CGFloat(depth.height)))
        guard let metres = metres.map({ $0 * depthScale }) else { return nil }
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
        return min(max(distance * 0.035 * textScale, 0.008), 0.6)
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
            pin.addChildNode(ModelDimensions.bubble(note.text, picked: picked, height: height * 0.8, at: note.spot + SIMD3(0, height * 0.2, 0)))
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
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.25), in: Capsule())
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
                    .offset(y: 34)
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
    /// iPhone on its side: the buttons stand in a column at the left edge instead of a row over the picture.
    @Environment(\.verticalSizeClass) private var verticalSize

    var body: some View {
        if measurer.active {
            let sideways = verticalSize == .compact
            let layout = sideways ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 16))
            layout {
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
                    if measurer.calibration != 1 {
                        small("scalemass", String(format: "×%.2f", measurer.calibration)) { measurer.resetCalibration() }
                    }
                }
                Button { measurer.addPoint() } label: {
                    Image(systemName: measurer.start == nil && measurer.moving == nil ? "plus" : "checkmark")
                        .font(.title3.bold())
                        .frame(width: 46, height: 46)
                        .background(Color.yellow.opacity(0.9), in: Circle())
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: sideways ? .infinity : nil, alignment: .leading)
            .shadow(color: .black.opacity(0.7), radius: 2)
            .confirmationDialog("Delete every dimension and note?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { measurer.clear() }
            }
        }
    }

    private func small(_ symbol: String, _ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.body)
                Text(title).font(.system(size: 9, weight: .semibold))
            }
            .frame(minWidth: 36)
            .foregroundStyle(tint.opacity(0.95))
        }
        .accessibilityLabel(title)
    }
}

/// While a line is being drawn: the aim point above the finger with a ring on it, a thin line down
/// to the finger, and a yellow ring where the corner snap put the point.
struct MeasurePointer: View {
    @ObservedObject var measurer: Measurer

    var body: some View {
        GeometryReader { _ in
            if let pointer = measurer.pointer {
                ZStack {
                    Path { path in
                        path.move(to: pointer.finger)
                        path.addLine(to: pointer.aim)
                    }
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    ring(at: pointer.start, colour: .white)
                    ring(at: pointer.aim, colour: .white)
                    if hypot(pointer.landed.x - pointer.aim.x, pointer.landed.y - pointer.aim.y) > 3 {
                        ring(at: pointer.landed, colour: .yellow)
                    }
                }
                .shadow(color: .black.opacity(0.7), radius: 2)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .hiddenInScreenshots()
    }

    private func ring(at point: CGPoint, colour: Color) -> some View {
        ZStack {
            Circle().stroke(colour, lineWidth: 2).frame(width: 28, height: 28)
            Circle().fill(colour).frame(width: 4, height: 4)
        }
        .position(point)
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
        ZStack(alignment: .top) {
            if let entry = measurer.entry {
                Color.black.opacity(0.35).ignoresSafeArea()
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

    /// Small and at the top, so the keyboard never covers the buttons, even on its side.
    private func lengthCard(_ id: UUID) -> some View {
        let guess = measurer.measurements.first { $0.id == id }?.measured
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                plainButton("Delete", fill: Color.red.opacity(0.85), text: .white) { measurer.deleteMark(id) }
                plainButton("Cancel", fill: Color.white.opacity(0.15), text: .white) { measurer.dismissEntry() }
                plainButton("Tape", fill: Color.green.opacity(0.85), text: .black) {
                    var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let last = typed.last, last.isNumber || last == "." { typed += unit }
                    guard let metres = LengthText.parse(typed), measurer.calibrate(id, to: metres) else {
                        Haptics.warning()
                        return
                    }
                    measurer.dismissEntry()
                }
                plainButton("Set", fill: .yellow, text: .black) {
                    var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Nothing typed keeps the phone's guess.
                    if typed.isEmpty {
                        measurer.dismissEntry()
                        return
                    }
                    if let last = typed.last, last.isNumber || last == "." { typed += unit }
                    guard let metres = LengthText.parse(typed) else {
                        Haptics.warning()
                        return
                    }
                    measurer.setLength(metres, for: id)
                    measurer.dismissEntry()
                }
            }
            TextField(guess.map { String(format: "%.4g", Double($0 / factor)) } ?? "0", text: $text)
                .keyboardType(.decimalPad)
                .focused($focused)
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 6) {
                ForEach(Self.units, id: \.name) { item in
                    Button { unit = item.name } label: {
                        Text(item.name).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(unit == item.name ? Color.yellow : Color.white.opacity(0.12), in: Capsule())
                            .foregroundStyle(unit == item.name ? Color.black : Color.white)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 460)
        .background(Color(white: 0.1).opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func plainButton(_ title: String, fill: Color, text color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(fill, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(color)
        }
    }

    private func noteCard(_ id: UUID?) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                if let id {
                    comicButton("DELETE", fill: Color(red: 1, green: 0.4, blue: 0.4)) { measurer.deleteMark(id) }
                }
                comicButton("CANCEL", fill: .white) { measurer.dismissEntry() }
                comicButton(id == nil ? "PLACE IT!" : "SAVE IT!", fill: .yellow) { measurer.saveNote(text, editing: id) }
            }
            ZStack {
                SpeechBubble().fill(Color.black).offset(x: 4, y: 4)
                SpeechBubble().fill(Color.white)
                SpeechBubble().stroke(Color.black, style: StrokeStyle(lineWidth: 4, lineJoin: .round))
                TextField("WRITE SOMETHING!", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focused)
                    .textInputAutocapitalization(.characters)
                    .font(comic(22))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                    .onChange(of: text) { _, value in
                        if value.count > 120 { text = String(value.prefix(120)) }
                    }
            }
            .frame(maxWidth: 420, minHeight: 92)
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func comicButton(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(comic(17))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(fill, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black, lineWidth: 3))
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black).offset(x: 3, y: 3))
        }
    }
}

/// A rounded speech bubble with a tail at the bottom left.
struct SpeechBubble: Shape {
    func path(in rect: CGRect) -> Path {
        let tail: CGFloat = 24
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
        let c: CGFloat = 22
        var p = Path()
        p.move(to: CGPoint(x: body.minX + c, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - c, y: body.minY))
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + c), control: CGPoint(x: body.maxX, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - c))
        p.addQuadCurve(to: CGPoint(x: body.maxX - c, y: body.maxY), control: CGPoint(x: body.maxX, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX + 80, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX + 38, y: rect.maxY))
        p.addLine(to: CGPoint(x: body.minX + 48, y: body.maxY))
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
