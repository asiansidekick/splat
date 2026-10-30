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
    private var cueSince = Date.distantPast
    private var reference: CIImage?
    private var referenceFace: ActorPose?
    private var referenceBody: ActorPose?
    private var prefersBody = false
    /// Where the followed actor was last, or where the screen was tapped.
    private var followPoint: CGPoint?
    /// The part of the picture the screen shows (width over height, upright), so the guide lines up
    /// what you see rather than the whole camera frame.
    private var aspect: CGFloat?
    private var busy = false
    private var generation = 0
    private var lastReading = Date.distantPast
    private var linedSince: Date?
    private nonisolated static let width: CGFloat = 480
    private nonisolated static let actorWidth: CGFloat = 720

    var lockedToActor: Bool { reading?.actor == true }

    /// `prefersBody`: costume, where the whole body matters more than the face.
    func setReference(_ image: UIImage?, aspect: CGFloat?, prefersBody: Bool = false) {
        generation += 1
        self.aspect = aspect
        self.prefersBody = prefersBody
        let cropped = image.flatMap { CIImage(image: $0) }.map { Self.centred($0, aspect: aspect) }
        reference = cropped.map(Self.prepared)
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
        let picture = Self.scaled(cropped, to: Self.actorWidth)
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
    nonisolated func consider(_ frame: CIImage) {
        Task { @MainActor in
            guard !self.busy, let reference = self.reference else { return }
            self.busy = true
            let generation = self.generation
            let cropped = Self.centred(frame, aspect: self.aspect)
            let live = Self.prepared(cropped)
            let colour = Self.scaled(cropped, to: Self.actorWidth)
            let aspect = self.aspect ?? (cropped.extent.width / max(cropped.extent.height, 1))
            let kinds = self.kindsToTry()
            let follow = self.followPoint
            let result = await Task.detached(priority: .utility) { () -> ActorResult? in
                if !kinds.isEmpty, let found = Self.readActor(colour, kinds: kinds, follow: follow, aspect: aspect) {
                    return found
                }
                return Self.read(live: live, reference: reference).map { ActorResult(reading: $0) }
            }.value
            self.busy = false
            guard generation == self.generation, self.reference != nil else { return }
            self.update(result)
        }
    }

    /// The reference poses to look for live, the department's preferred kind first.
    private func kindsToTry() -> [ActorPose] {
        let order = prefersBody ? [referenceBody, referenceFace] : [referenceFace, referenceBody]
        return order.compactMap { $0 }
    }

    private struct ActorResult {
        var reading: GuideReading
        var anchor: GhostAnchor?
        var people: [CGRect] = []
        var followed: Int?
    }

    private nonisolated static func readActor(_ picture: CIImage, kinds: [ActorPose], follow: CGPoint?, aspect: CGFloat) -> ActorResult? {
        let found = ActorVision.people(in: picture)
        for reference in kinds {
            let live = reference.kind == .face ? found.faces : found.bodies
            guard let index = ActorMatch.pick(live, near: follow, like: reference),
                let reading = ActorMatch.reading(reference: reference, live: live[index], aspect: aspect)
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
            let new = result.reading
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
    }

    /// Changes the instruction only once the current one is done or has shown for 1.5 s.
    private func pickCue() {
        guard let reading else {
            cue = nil
            return
        }
        let wanted = reading.biggest
        guard wanted != cue else { return }
        let currentStillNeeded = cue.map { current in reading.cues.contains { $0.cue == current } } ?? false
        if currentStillNeeded, Date.now.timeIntervalSince(cueSince) < 1.5 { return }
        cue = wanted
        cueSince = .now
    }

    private nonisolated static func read(live: CIImage, reference: CIImage) -> GuideReading? {
        let handler = VNImageRequestHandler(ciImage: reference, options: [:])
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: live)
        if (try? handler.perform([request])) != nil, let warp = request.results?.first?.warpTransform,
            let reading = GuideReading.from(warp: warp, reference: reference.extent.size, live: live.extent.size),
            reading.scale > 0.4, reading.scale < 2.5, abs(reading.turn.dx) < 1, abs(reading.turn.dy) < 1
        {
            return reading
        }
        // Too far off for a full reading: a plain shift still gives move arrows.
        let shift = VNTranslationalImageRegistrationRequest(targetedCIImage: live)
        guard (try? handler.perform([shift])) != nil, let t = shift.results?.first?.alignmentTransform else { return nil }
        let width = live.extent.width
        let height = live.extent.height
        guard width > 0, height > 0 else { return nil }
        // Live shifted by t lands on the reference, so the reference middle sits at -t in live
        // pixels (Vision counts y up).
        let dx = -t.tx / width
        let dy = t.ty / height
        return GuideReading(move: CGVector(dx: dx, dy: dy * height / width), turn: .zero, tilt: 0, scale: 1,
                            corners: [CGPoint(x: dx, y: dy), CGPoint(x: 1 + dx, y: dy), CGPoint(x: 1 + dx, y: 1 + dy), CGPoint(x: dx, y: 1 + dy)])
    }

    /// The middle of a picture at the given width over height.
    nonisolated static func centred(_ image: CIImage, aspect: CGFloat?) -> CIImage {
        guard let aspect, aspect > 0 else { return image }
        let e = image.extent
        var width = e.width
        var height = e.height
        if width / height > aspect { width = height * aspect } else { height = width / aspect }
        return image.cropped(to: CGRect(x: e.midX - width / 2, y: e.midY - height / 2, width: width, height: height))
    }

    /// In colour, from the origin, at the given width: for finding faces and bodies.
    private nonisolated static func scaled(_ image: CIImage, to width: CGFloat) -> CIImage {
        let extent = image.extent
        let scale = min(1, width / max(extent.width, 1))
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
    }

    /// Grey and small, from the origin, so lighting colour does not matter and it is quick.
    private nonisolated static func prepared(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = width / max(extent.width, 1)
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    }
}

// MARK: - Drawing

/// The guide, kept to the edges and corners of the screen so the face, hair and costume stay clear.
/// Two things: a frame (where the reference's corners are now, in yellow, against the screen's
/// corners in white; when they meet, it's lined up), and one big instruction at a time in camera
/// words: MOVE (slide the phone), PAN or TILT (aim it), ROTATE (twist it level), STEP IN or BACK.
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
                if matched {
                    banner("LINED UP", systemImage: "checkmark.circle.fill", tint: .green)
                        .position(x: size.width / 2, y: 70)
                } else if let cue {
                    instruction(cue, in: size)
                        .id(cue.screenID(turns: quarterTurns, mirrored: mirrored))
                        .transition(.opacity)
                } else if people > 1 {
                    banner("TAP SOMEONE TO FOLLOW THEM", systemImage: "hand.tap", tint: .yellow)
                        .opacity(0.8)
                        .position(x: size.width / 2, y: 70)
                } else if searching {
                    banner("POINT AT THE REFERENCE", systemImage: "viewfinder", tint: .yellow)
                        .opacity(0.8)
                        .position(x: size.width / 2, y: 70)
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
        let q = ScreenMap(size: rect.size, quarterTurns: quarterTurns, mirrored: mirrored).toScreen(p)
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
            arrow(at: s, in: size, word: (s.horizontal ? "PAN " : "TILT ") + s.word) {
                TurnArrow()
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    .frame(width: 84, height: 84)
            }
        case .rotate(let clockwise):
            let turn = clockwise != mirrored
            centre(word: "ROTATE", in: size) {
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
            centre(word: closer ? "STEP IN" : "STEP BACK", in: size) {
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
        return VStack(spacing: 6) {
            glyph()
                .phaseAnimator([CGFloat(0), 18]) { content, nudge in
                    content.offset(x: nudge)
                } animation: { _ in .easeInOut(duration: 0.9) }
                .rotationEffect(.degrees(angle))
            label(word)
        }
        .foregroundStyle(Color.yellow)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .opacity(0.8)
        .position(position)
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

    private func centre<Glyph: View>(word: String, in size: CGSize, @ViewBuilder glyph: () -> Glyph) -> some View {
        VStack(spacing: 6) {
            glyph()
            label(word)
        }
        .foregroundStyle(Color.yellow)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .opacity(0.8)
        .position(x: size.width / 2, y: 90)
    }

    private func label(_ word: String) -> some View {
        Text(word)
            .font(.system(size: 17, weight: .heavy))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.35), in: Capsule())
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.4), in: Capsule())
    }
}

/// When following an actor with several people in view: a ring round each, the followed one in
/// yellow. Drawn over the whole camera picture, since the rings sit on the people.
struct PeopleRings: View {
    let people: [CGRect]
    let followed: Int?
    let quarterTurns: Int
    let mirrored: Bool

    var body: some View {
        GeometryReader { geometry in
            let map = ScreenMap(size: geometry.size, quarterTurns: quarterTurns, mirrored: mirrored)
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
