import CoreImage
import SwiftUI
import Vision
import simd

/// Where the ghost is pinned when it follows an actor: the reference's eyes (or shoulders) and
/// where the same points are live, in 0...1 picture points.
struct GhostAnchor: Equatable {
    var from: (CGPoint, CGPoint)
    var to: (CGPoint, CGPoint)

    static func == (a: GhostAnchor, b: GhostAnchor) -> Bool {
        a.from.0 == b.from.0 && a.from.1 == b.from.1 && a.to.0 == b.to.0 && a.to.1 == b.to.1
    }

    func blended(towards new: GhostAnchor, by k: CGFloat) -> GhostAnchor {
        func mix(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k) }
        return GhostAnchor(from: new.from, to: (mix(to.0, new.to.0), mix(to.1, new.to.1)))
    }
}

/// Compares camera frames with the reference a few times a second and publishes the guide.
/// When the reference has a person in it and the same kind of person is in view (a face for hair
/// and makeup, a body for costume), the guide locks to the actor rather than the room, so it
/// follows them wherever they stand. Otherwise it lines up the whole picture.
/// Lined up counts only after holding still and lined up for half a second, as in Reset.
@MainActor
final class Guide: ObservableObject {
    @Published private(set) var reading: GuideReading?
    @Published private(set) var matched = false
    /// The one instruction shown. Held for at least a second and a half so it can be read.
    @Published private(set) var cue: GuideCue?
    /// Following an actor: where to pin the ghost.
    @Published private(set) var anchor: GhostAnchor?
    /// Everyone in view of the kind being followed, and which one is followed, so a tap can switch.
    @Published private(set) var people: [CGRect] = []
    @Published private(set) var followed: Int?
    /// No reading for a second: shown so it is clear the guide is on but can't find the reference.
    @Published private(set) var searching = false
    /// Working out how to size and place an imported photo on the live view.
    @Published private(set) var fitting = false
    /// The fit found for an imported photo, in the whole photo's units, for the app to keep.
    @Published private(set) var fitted: OverlayFit?
    /// The last fit read, kept until a second agrees with it.
    private var pendingFit: OverlayFit?
    /// The share of the whole reference that the guide's crop of it keeps.
    private var fitShare = CGSize(width: 1, height: 1)
    private var cueSince = Date.distantPast
    private var reference: CIImage?
    private var referenceFace: ActorPose?
    private var referenceBody: ActorPose?
    /// The reference's LiDAR depth, saved with the photo, if it was taken with LiDAR.
    private var referenceDepth: DepthGrid?
    /// How the reference was held (pitch and roll), and how the phone is held now.
    private var referenceAttitude: Attitude?
    var liveAttitude: (@MainActor () -> Attitude?)?
    /// The newest live LiDAR depth, for the change colours.
    private var liveDepth: DepthGrid?
    /// Red and blue where the set differs from the reference, once lined up (see DepthChange).
    @Published private(set) var changes: CGImage?
    /// Whether to work out the change colours at all (Changes in the ••• menu).
    var showChanges = false {
        didSet { if !showChanges { changes = nil } }
    }
    private var prefersBody = false
    /// Where the followed actor was last, or where the screen was tapped.
    private var followPoint: CGPoint?
    /// The part of the picture the screen shows (width over height, upright), so the guide lines up
    /// what you see rather than the whole camera frame.
    private var aspect: CGFloat?
    /// A portrait reference checked in landscape (or the other way round) is shown whole in a
    /// centred box: the reference is read whole, and only that box of the live picture.
    private var referenceCrop: CGFloat?
    private var liveBox: CGFloat?
    private var busy = false
    private var generation = 0
    private var lastReading = Date.distantPast
    private var linedSince: Date?

    var lockedToActor: Bool { reading?.actor == true }

    /// `prefersBody`: costume, where the whole body matters more than the face.
    /// `aspect`: the screen's picture, width over height in the photo's directions. `whole`: the
    /// reference is shown whole in a box rather than filling the screen.
    /// `fit`: an imported photo's size and place on the live view, applied before reading.
    /// `needsFit`: an imported photo with no fit yet, so frames work one out instead of guiding.
    func setReference(_ image: UIImage?, depth: DepthGrid? = nil, aspect: CGFloat?, whole: Bool = false, prefersBody: Bool = false,
                      fit: OverlayFit? = nil, needsFit: Bool = false, attitude: Attitude? = nil) {
        generation += 1
        referenceAttitude = image == nil ? nil : attitude
        changes = nil
        referenceDepth = image == nil ? nil : depth
        let referenceAspect = image.map { $0.size.width / max($0.size.height, 1) }
        self.aspect = aspect
        referenceCrop = whole ? nil : aspect
        liveBox = whole ? referenceAspect : nil
        self.prefersBody = prefersBody
        fitShare = OverlayFit.cropShare(photo: referenceAspect ?? 1, crop: whole ? nil : aspect)
        let share = fitShare
        let cropped = image.flatMap { CIImage(image: $0) }.map { Registration.centred($0, aspect: whole ? nil : aspect) }
            .map { picture in fit.map { Registration.fitted(picture, by: $0.inCrop(share)) } ?? picture }
        reference = cropped.map(Registration.prepared)
        fitting = image != nil && needsFit
        fitted = nil
        pendingFit = nil
        referenceFace = nil
        referenceBody = nil
        followPoint = nil
        reading = nil
        anchor = nil
        people = []
        followed = nil
        cue = nil
        searching = false
        lastReading = .now
        matched = false
        linedSince = nil
        guard let cropped else { return }
        let generation = self.generation
        let picture = Registration.scaled(cropped, to: Registration.actorWidth)
        Task {
            let found = await Task.detached(priority: .userInitiated) { ActorVision.people(in: picture) }.value
            guard generation == self.generation else { return }
            // The biggest face and body in the reference are the actor it was taken for.
            self.referenceFace = found.faces.max { $0.box.area < $1.box.area }
            self.referenceBody = found.bodies.max { $0.box.area < $1.box.area }
        }
    }

    /// Follow the actor nearest this point (0...1 across and down in the photo), from a tap.
    func follow(at point: CGPoint) {
        guard people.count > 1 else { return }
        followPoint = point
        Haptics.tap()
    }

    /// A live frame, upright the same way as saved photos. Dropped if the last is still being read.
    nonisolated func consider(_ frame: CIImage, depth: DepthGrid? = nil) {
        Task { @MainActor in
            guard !self.busy, let reference = self.reference else { return }
            if depth != nil { self.liveDepth = depth }
            self.busy = true
            let generation = self.generation
            let visible = Registration.centred(frame, aspect: self.aspect)
            let cropped = Registration.centred(visible, aspect: self.liveBox)
            let live = Registration.prepared(cropped)
            let colour = Registration.scaled(cropped, to: Registration.actorWidth)
            let aspect = cropped.extent.width / max(cropped.extent.height, 1)
            // Depth is read in the screen's picture; the live box sits in its middle.
            let depthSpace = LiveDepth(depth: depth, visible: self.aspect,
                                       box: Fit.centredBox(outer: visible.extent.width / max(visible.extent.height, 1), inner: aspect))
            let referenceCrop = self.referenceCrop
            let kinds = self.kindsToTry()
            let follow = self.followPoint
            let referenceDepth = self.referenceDepth
            if self.fitting {
                let fit = await Task.detached(priority: .utility) { () -> OverlayFit? in
                    // A person in both: their eyes (or shoulders) give the size and place exactly.
                    if !kinds.isEmpty {
                        let found = ActorVision.people(in: colour)
                        for reference in kinds {
                            let live = reference.kind == .face ? found.faces : found.bodies
                            if let index = ActorMatch.pick(live, near: nil, like: reference),
                                let fit = OverlayFit.from(reference: (reference.left, reference.right),
                                                          live: (live[index].left, live[index].right), aspect: aspect)
                            {
                                return fit
                            }
                        }
                    }
                    return Registration.fitRoom(live: live, reference: reference)
                }.value
                self.busy = false
                guard generation == self.generation, self.fitting else { return }
                self.consider(fit: fit)
                return
            }
            let result = await Task.detached(priority: .utility) { () -> ActorResult? in
                if !kinds.isEmpty, let found = Self.readActor(colour, kinds: kinds, follow: follow, aspect: aspect,
                                                             depth: depthSpace, referenceDepth: referenceDepth, referenceCrop: referenceCrop) {
                    return found
                }
                guard var reading = Registration.read(live: live, reference: reference) else { return nil }
                // LiDAR on both: compare the distance to the reference's middle with the distance to
                // where that middle shows now.
                if let referenceDepth, abs(reading.move.dx) < 0.15, abs(reading.move.dy) < 0.15 {
                    let now = CGPoint(x: 0.5 + reading.move.dx, y: 0.5 + reading.move.dy * aspect)
                    reading.useDistances(live: depthSpace.distance(at: now),
                                         reference: referenceDepth.distance(at: CGPoint(x: 0.5, y: 0.5), aspect: referenceCrop).map(Double.init))
                }
                return ActorResult(reading: reading)
            }.value
            self.busy = false
            guard generation == self.generation, self.reference != nil else { return }
            self.update(result)
        }
    }

    /// Two fits in a row that agree are kept, so one odd frame can't set it.
    private func consider(fit: OverlayFit?) {
        guard let fit else {
            pendingFit = nil
            return
        }
        if let pendingFit, pendingFit.agrees(with: fit) {
            fitting = false
            fitted = pendingFit.averaged(with: fit).fromCrop(fitShare)
            Haptics.success()
        } else {
            pendingFit = fit
        }
    }

    /// The reference poses to look for live, the department's preferred kind first.
    private func kindsToTry() -> [ActorPose] {
        let order = prefersBody ? [referenceBody, referenceFace] : [referenceFace, referenceBody]
        return order.compactMap { $0 }
    }

    /// The live LiDAR depth, read at points given in the live box.
    private struct LiveDepth {
        var depth: DepthGrid?
        var visible: CGFloat?
        var box: CGRect

        func distance(at point: CGPoint) -> Double? {
            depth?.distance(at: box.point(point), aspect: visible).map(Double.init)
        }
    }

    private struct ActorResult {
        var reading: GuideReading
        var anchor: GhostAnchor?
        var people: [CGRect] = []
        var followed: Int?
    }

    private nonisolated static func readActor(_ picture: CIImage, kinds: [ActorPose], follow: CGPoint?, aspect: CGFloat,
                                              depth: LiveDepth, referenceDepth: DepthGrid?, referenceCrop: CGFloat?) -> ActorResult? {
        let found = ActorVision.people(in: picture)
        for reference in kinds {
            let live = reference.kind == .face ? found.faces : found.bodies
            guard let index = ActorMatch.pick(live, near: follow, like: reference) else { continue }
            // LiDAR: distance to the eyes (or shoulders) now and in the reference.
            let liveDistance = depth.distance(at: live[index].centre)
            let referenceDistance = referenceDepth?.distance(at: reference.centre, aspect: referenceCrop).map(Double.init)
            guard let reading = ActorMatch.reading(reference: reference, live: live[index], aspect: aspect,
                                                   referenceDistance: referenceDistance, liveDistance: liveDistance)
            else { continue }
            return ActorResult(
                reading: reading,
                anchor: GhostAnchor(from: (reference.left, reference.right), to: (live[index].left, live[index].right)),
                people: live.map(\.box),
                followed: index)
        }
        return nil
    }

    private func update(_ result: ActorResult?) {
        if let result {
            var new = result.reading
            // Pitch and roll from the motion sensors, when the reference was shot with them.
            if let reference = referenceAttitude, let live = liveAttitude?() {
                let errors = live.errors(to: reference)
                new.pitchError = errors.pitch
                new.rollError = errors.roll
            }
            // Switching between actor and room starts afresh rather than easing between them.
            if let old = reading, old.actor == new.actor {
                reading = old.blended(towards: new, by: 0.4)
            } else {
                reading = new
            }
            if let fresh = result.anchor {
                anchor = anchor.map { $0.blended(towards: fresh, by: 0.5) } ?? fresh
            } else {
                anchor = nil
            }
            if people != result.people { people = result.people }
            if followed != result.followed { followed = result.followed }
            if let index = result.followed, result.people.indices.contains(index) {
                let box = result.people[index]
                if followPoint != nil { followPoint = CGPoint(x: box.midX, y: box.midY) }
            }
            lastReading = .now
        } else if Date.now.timeIntervalSince(lastReading) > 1.5 {
            // Keep the last reading through a few missed frames; clear it after a moment.
            reading = nil
            anchor = nil
            people = []
            followed = nil
        }
        pickCue()
        let lost = reading == nil
        if searching != lost { searching = lost }
        if let current = reading, current.lined {
            let since = linedSince ?? .now
            linedSince = since
            if !matched, Date.now.timeIntervalSince(since) >= 0.5 {
                matched = true
                Haptics.success()
            }
        } else {
            linedSince = nil
            matched = false
        }
        refreshChanges()
    }

    /// Only when lined up on a reference that has depth, and the camera has depth now.
    private func refreshChanges() {
        guard showChanges, matched, liveBox == nil, let referenceDepth, let liveDepth else {
            if changes != nil { changes = nil }
            return
        }
        changes = DepthChange.mask(live: liveDepth, reference: referenceDepth, aspect: aspect)
    }

    /// Changes the instruction only once the current one is done or has shown for 1.5 s.
    private func pickCue() {
        guard let reading else {
            cue = nil
            return
        }
        let wanted = reading.biggestArrow
        guard wanted != cue else { return }
        let currentStillNeeded = cue.map { current in reading.cues.contains { $0.cue == current } } ?? false
        if currentStillNeeded, Date.now.timeIntervalSince(cueSince) < 1.5 { return }
        cue = wanted
        cueSince = .now
    }

}

// MARK: - Drawing

/// The guide, kept to the edges and corners of the screen so the face, hair and costume stay clear.
/// Two things: a frame (where the reference's corners are now, in yellow, against the screen's
/// corners in white; when they meet, it's lined up), and one big arrow at a time, with no words so
/// the eyes stay on the picture: slide the phone, aim it (a curved arrow), or step in or back
/// (arrows closing in or opening out; on the front camera the phone moves instead). Pitch and
/// roll are two level lines at the screen's sides: white is where the reference was, yellow where
/// the phone is now, and they meet when the phone is held the same way.
struct EdgeGuide: View {
    let reading: GuideReading?
    let cue: GuideCue?
    let matched: Bool
    let searching: Bool
    /// How many people are in view when following an actor; with several, a tap picks one.
    var people = 0
    /// Quarter turns clockwise from the photo's directions to the screen's (rotation lock).
    let quarterTurns: Int
    /// Front camera: the screen is a mirror.
    let mirrored: Bool
    /// Where the reference sits within the screen's picture (see ScreenMap).
    var inner = CGRect(x: 0, y: 0, width: 1, height: 1)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let target = CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 18)
            ZStack {
                Brackets(corners: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                    .map { place($0, in: target) })
                    .stroke(matched ? Color.green : Color.white.opacity(0.55),
                            style: StrokeStyle(lineWidth: matched ? 6 : 3, lineCap: .round, lineJoin: .round))
                if let reading, !matched {
                    Brackets(corners: reading.corners.map { place($0, in: target) })
                        .stroke(Color.yellow.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                if !matched, let reading, reading.pitchError != nil || reading.rollError != nil {
                    LevelLines(pitchError: reading.pitchError, rollError: reading.rollError,
                               quarterTurns: quarterTurns, mirrored: mirrored)
                }
                if matched {
                    badge("LINED UP", systemImage: "checkmark.circle.fill", tint: .green)
                        .position(x: size.width - 52, y: 52)
                } else if let cue, !(reading?.drawnAsLines(cue) ?? false) {
                    instruction(cue, in: size)
                        .id(cue.screenID(turns: quarterTurns, mirrored: mirrored))
                        .transition(.opacity)
                } else if people > 1 {
                    badge("Tap someone to follow them", systemImage: "hand.tap", tint: .yellow)
                        .opacity(0.8)
                        .position(x: 52, y: 52)
                } else if searching {
                    badge("Point at the reference", systemImage: "viewfinder", tint: .yellow)
                        .opacity(0.8)
                        .position(x: 52, y: 52)
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeInOut(duration: 0.35), value: reading)
            .animation(.easeInOut(duration: 0.3), value: cue)
            .animation(.easeInOut(duration: 0.3), value: matched)
        }
        .allowsHitTesting(false)
    }

    /// A point in the photo (0...1 across and down) to the screen.
    private func place(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        let q = ScreenMap(size: rect.size, quarterTurns: quarterTurns, mirrored: mirrored, inner: inner).toScreen(p)
        return CGPoint(x: rect.minX + q.x, y: rect.minY + q.y)
    }

    private func screen(_ side: GuideCue.Side) -> GuideCue.Side {
        GuideCue.screen(side, turns: quarterTurns, mirrored: mirrored)
    }

    @ViewBuilder
    private func instruction(_ cue: GuideCue, in size: CGSize) -> some View {
        switch cue {
        case .move(let side):
            let s = screen(side)
            arrow(at: s, in: size, word: "MOVE " + s.word) {
                Image(systemName: "arrowshape.right.fill").font(.system(size: 88, weight: .regular))
            }
        case .pan(let side), .tilt(let side):
            let s = screen(side)
            let amount = s.horizontal ? "" : Self.degrees(reading?.pitchError)
            arrow(at: s, in: size, word: (s.horizontal ? "PAN " : "TILT ") + s.word + amount) {
                TurnArrow()
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    .frame(width: 84, height: 84)
            }
        case .rotate(let clockwise):
            let turn = clockwise != mirrored
            corner(word: "ROTATE" + Self.degrees(reading?.rollError), right: true, in: size) {
                Image(systemName: turn ? "arrow.clockwise" : "arrow.counterclockwise")
                    .font(.system(size: 80, weight: .bold))
                    .phaseAnimator([0.0, turn ? 25.0 : -25.0]) { content, angle in
                        content.rotationEffect(.degrees(angle))
                    } animation: { _ in .easeInOut(duration: 0.9) }
            }
        case .circle(let side):
            // Words in the photographer's terms; the arrow points that way on screen.
            let s = screen(side)
            arrow(at: s, in: size, word: "WALK ROUND " + side.word) {
                // Kept upright whichever edge it sits on.
                Image(systemName: "rotate.3d").font(.system(size: 76, weight: .bold))
                    .rotationEffect(.degrees(-Self.edgeAngle(s)))
            }
        case .height(let raise):
            arrow(at: screen(raise ? .up : .down), in: size, word: raise ? "RAISE PHONE" : "LOWER PHONE") {
                Image(systemName: "arrow.right.to.line").font(.system(size: 76, weight: .bold))
            }
        case .step(let closer):
            // Front camera: the phone is usually at arm's length facing the person, so it's the
            // phone that moves, not the photographer's feet.
            let words = mirrored ? (closer ? "BRING PHONE CLOSER" : "HOLD PHONE FURTHER") : (closer ? "STEP IN" : "STEP BACK")
            corner(word: words + Self.metres(reading?.stepMetres), right: false, in: size) {
                Image(systemName: closer ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 72, weight: .bold))
                    .phaseAnimator([1.0, closer ? 0.8 : 1.2]) { content, scale in
                        content.scaleEffect(scale)
                    } animation: { _ in .easeInOut(duration: 0.9) }
            }
        }
    }

    /// A big see-through arrow at one edge, drifting slowly the way to go, with its word.
    private func arrow<Glyph: View>(at side: GuideCue.Side, in size: CGSize, word: String,
                                    @ViewBuilder glyph: () -> Glyph) -> some View {
        let inset: CGFloat = 62
        let position: CGPoint
        switch side {
        case .left: position = CGPoint(x: inset, y: size.height / 2)
        case .right: position = CGPoint(x: size.width - inset, y: size.height / 2)
        case .up: position = CGPoint(x: size.width / 2, y: inset)
        case .down: position = CGPoint(x: size.width / 2, y: size.height - inset)
        }
        let angle = Self.edgeAngle(side)
        return glyph()
            .phaseAnimator([CGFloat(0), 18]) { content, nudge in
                content.offset(x: nudge)
            } animation: { _ in .easeInOut(duration: 0.9) }
            .rotationEffect(.degrees(angle))
            .accessibilityLabel(word)
            .foregroundStyle(Color.yellow)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .opacity(0.8)
        .position(position)
    }

    /// " 30 CM" from LiDAR, to the nearest 5 cm; nothing without it.
    static func metres(_ value: Double?) -> String {
        guard let value else { return "" }
        let cm = Int((abs(value) * 20).rounded()) * 5
        return cm >= 5 ? " \(cm) CM" : ""
    }

    /// " 6°" from the motion sensors, to the nearest degree; nothing without them.
    static func degrees(_ value: Double?) -> String {
        guard let value else { return "" }
        let whole = Int(abs(value).rounded())
        return whole >= 1 ? " \(whole)°" : ""
    }

    /// How far a right-pointing glyph turns to point at that edge.
    static func edgeAngle(_ side: GuideCue.Side) -> Double {
        switch side {
        case .right: 0
        case .down: 90
        case .left: 180
        case .up: -90
        }
    }

    /// In a top corner, out of the picture's way: step in or back on the left, twist on the right.
    private func corner<Glyph: View>(word: String, right: Bool, in size: CGSize, @ViewBuilder glyph: () -> Glyph) -> some View {
        glyph()
            .accessibilityLabel(word)
            .foregroundStyle(Color.yellow)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .opacity(0.8)
        .position(x: right ? size.width - 56 : 56, y: 56)
    }

    /// A symbol alone, so the eyes stay on the picture; the words are for VoiceOver.
    private func badge(_ text: String, systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 26, weight: .heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.4), in: Capsule())
            .accessibilityLabel(text)
    }
}

/// Pitch and roll as two level lines, short at each side so the middle of the picture stays clear.
/// White is where the reference was held; yellow is the phone now. Twisting the phone turns the
/// yellow line, aiming it up or down slides it, and they meet (turning green) when the phone is
/// held the same way. Drawn in the photo's directions, then turned to the screen's.
struct LevelLines: View {
    let pitchError: Double?
    let rollError: Double?
    let quarterTurns: Int
    let mirrored: Bool

    /// Points the line moves for each degree of aim, about 50 degrees across the picture's height.
    private static let degreeLength: (CGFloat) -> CGFloat = { $0 / 50 }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let sideways = abs(quarterTurns) % 2 == 1
            let photo = sideways ? CGSize(width: size.height, height: size.width) : size
            let aim = max(-photo.height * 0.3, min(photo.height * 0.3, Self.degreeLength(photo.height) * CGFloat(pitchError ?? 0)))
            let near = abs(pitchError ?? 0) < GuideReading.pitchTolerance && abs(rollError ?? 0) < GuideReading.tiltTolerance
            ZStack {
                Marks()
                    .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                Marks()
                    .stroke(near ? Color.green : Color.yellow, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .rotationEffect(.degrees(rollError ?? 0))
                    .offset(y: -aim)
            }
            .frame(width: photo.width, height: photo.height)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .rotationEffect(.degrees(Double(quarterTurns) * 90))
            .frame(width: size.width, height: size.height)
            .animation(.easeOut(duration: 0.15), value: pitchError)
            .animation(.easeOut(duration: 0.15), value: rollError)
        }
        .allowsHitTesting(false)
    }

    /// A horizontal line through the middle with the middle left out.
    struct Marks: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let reach = min(rect.width * 0.2, 90)
            path.move(to: CGPoint(x: rect.minX + 6, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + 6 + reach, y: rect.midY))
            path.move(to: CGPoint(x: rect.maxX - 6 - reach, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.midY))
            return path
        }
    }
}

/// When following an actor with several people in view: a ring round each, the followed one in
/// yellow. Drawn over the whole camera picture, since the rings sit on the people.
struct PeopleRings: View {
    let people: [CGRect]
    let followed: Int?
    let quarterTurns: Int
    let mirrored: Bool
    var inner = CGRect(x: 0, y: 0, width: 1, height: 1)

    var body: some View {
        GeometryReader { geometry in
            let map = ScreenMap(size: geometry.size, quarterTurns: quarterTurns, mirrored: mirrored, inner: inner)
            ForEach(people.indices, id: \.self) { index in
                let box = map.toScreen(people[index])
                let side = max(box.width, box.height) * 1.2
                Circle()
                    .stroke(index == followed ? Color.yellow.opacity(0.8) : Color.white.opacity(0.45),
                            style: StrokeStyle(lineWidth: 2, dash: index == followed ? [] : [6, 5]))
                    .frame(width: side, height: side)
                    .position(x: box.midX, y: box.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Corner brackets of a four-sided frame: a short line from each corner towards its neighbours.
struct Brackets: Shape {
    let corners: [CGPoint]
    var length: CGFloat = 34

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard corners.count == 4 else { return path }
        for i in 0..<4 {
            let corner = corners[i]
            for neighbour in [corners[(i + 3) % 4], corners[(i + 1) % 4]] {
                let dx = neighbour.x - corner.x
                let dy = neighbour.y - corner.y
                let distance = max((dx * dx + dy * dy).squareRoot(), 0.001)
                let reach = min(length, distance / 3)
                path.move(to: corner)
                path.addLine(to: CGPoint(x: corner.x + dx / distance * reach, y: corner.y + dy / distance * reach))
            }
        }
        return path
    }
}

/// A curved arrow pointing right (rotate it for the other edges): aim the phone, rather than slide it.
/// Drawn from points, so it looks the same whatever way the coordinate system runs.
struct TurnArrow: Shape {
    func path(in rect: CGRect) -> Path {
        // An arc sweeping from the top round to the right, bowing outwards.
        let centre = CGPoint(x: rect.minX + rect.width * 0.1, y: rect.maxY - rect.height * 0.05)
        let radius = rect.width * 0.75
        var path = Path()
        let steps = 16
        var last = CGPoint.zero
        var before = CGPoint.zero
        for step in 0...steps {
            let degrees = -90 + 70 * CGFloat(step) / CGFloat(steps)  // up, sweeping clockwise on screen
            let radians = degrees * .pi / 180
            let point = CGPoint(x: centre.x + radius * cos(radians), y: centre.y + radius * sin(radians))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            before = last
            last = point
        }
        // Arrowhead along the direction of travel at the end.
        let dx = last.x - before.x
        let dy = last.y - before.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / length
        let uy = dy / length
        let head = rect.width * 0.3
        for side: CGFloat in [-1, 1] {
            let angle = 0.55 * side
            let bx = -(ux * cos(angle) - uy * sin(angle))
            let by = -(ux * sin(angle) + uy * cos(angle))
            path.move(to: last)
            path.addLine(to: CGPoint(x: last.x + bx * head, y: last.y + by * head))
        }
        return path
    }
}
