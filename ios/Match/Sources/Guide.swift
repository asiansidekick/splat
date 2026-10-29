import CoreImage
import SwiftUI
import Vision
import simd

/// What the live picture needs to line up with the reference, worked out from the pictures alone
/// (no AR), so it works on any iPhone or iPad and on people as well as objects. Everything is in
/// the saved photo's own directions: x to the right, y down.
struct GuideReading: Equatable {
    /// How far the reference's middle sits from the live picture's middle, as a share of its width.
    /// Positive x: move right. Positive y: move down.
    var move: CGVector
    /// Perspective difference: positive x means turn right, positive y means turn down.
    var turn: CGVector
    /// Degrees to rotate the phone clockwise to level it with the reference.
    var tilt: Double
    /// Above 1: everything looks bigger than in the reference, so step back. Below 1: step closer.
    var scale: Double
    /// Where the reference's corners show in the live picture (0...1 across and down): top left,
    /// top right, bottom right, bottom left.
    var corners: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]

    static let moveTolerance: CGFloat = 0.035
    static let turnTolerance: CGFloat = 0.06
    static let tiltTolerance: Double = 3
    static let scaleTolerance: Double = 0.06

    var lined: Bool {
        abs(move.dx) < Self.moveTolerance && abs(move.dy) < Self.moveTolerance
            && abs(turn.dx) < Self.turnTolerance && abs(turn.dy) < Self.turnTolerance
            && abs(tilt) < Self.tiltTolerance && abs(scale - 1) < Self.scaleTolerance
    }

    /// Reads the guide from Vision's warp, which takes the live picture onto the reference
    /// (pixels counted up from the bottom, as Vision does).
    static func from(warp: simd_float3x3, reference: CGSize, live: CGSize) -> GuideReading? {
        guard abs(warp.determinant) > 1e-9, live.width > 0, live.height > 0 else { return nil }
        let inverse = warp.inverse
        let w = Float(reference.width)
        let h = Float(reference.height)
        // A reference point (0...1 across and down) to where it shows live (0...1 across and down).
        func toLive(_ x: Float, _ y: Float) -> SIMD2<Float>? {
            let p = inverse * SIMD3(x * w, (1 - y) * h, 1)
            guard abs(p.z) > 1e-6 else { return nil }
            return SIMD2(p.x / p.z / Float(live.width), 1 - p.y / p.z / Float(live.height))
        }
        guard let topLeft = toLive(0, 0), let topRight = toLive(1, 0), let bottomLeft = toLive(0, 1), let bottomRight = toLive(1, 1),
            let middle = toLive(0.5, 0.5), let leftMiddle = toLive(0, 0.5), let rightMiddle = toLive(1, 0.5)
        else { return nil }
        // Lengths in live-width units, so tall and wide pictures compare fairly.
        let aspect = Float(live.height / live.width)
        func length(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            simd_length(SIMD2(b.x - a.x, (b.y - a.y) * aspect))
        }
        let left = length(topLeft, bottomLeft)
        let right = length(topRight, bottomRight)
        let top = length(topLeft, topRight)
        let bottom = length(bottomLeft, bottomRight)
        guard left > 0, right > 0, top > 0, bottom > 0 else { return nil }
        // The far side of something looks smaller: a short right edge means the phone is turned
        // too far left, so turn right; a short top edge means it looks too far up, so turn down.
        let turnX = (left - right) / ((left + right) / 2)
        let turnY = (bottom - top) / ((bottom + top) / 2)
        let across = SIMD2(rightMiddle.x - leftMiddle.x, (rightMiddle.y - leftMiddle.y) * aspect)
        let tilt = Double(atan2(across.y, across.x)) * 180 / .pi
        let scale = Double((top + bottom) / 2)
        return GuideReading(
            move: CGVector(dx: CGFloat(middle.x - 0.5), dy: CGFloat((middle.y - 0.5) * aspect)),
            turn: CGVector(dx: CGFloat(turnX), dy: CGFloat(turnY)),
            tilt: tilt,
            scale: scale,
            corners: [topLeft, topRight, bottomRight, bottomLeft].map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
    }

    /// Eased towards a new reading, so the guide doesn't jump about with every frame.
    func blended(towards new: GuideReading, by k: CGFloat) -> GuideReading {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        return GuideReading(
            move: CGVector(dx: mix(move.dx, new.move.dx), dy: mix(move.dy, new.move.dy)),
            turn: CGVector(dx: mix(turn.dx, new.turn.dx), dy: mix(turn.dy, new.turn.dy)),
            tilt: Double(mix(CGFloat(tilt), CGFloat(new.tilt))),
            scale: Double(mix(CGFloat(scale), CGFloat(new.scale))),
            corners: zip(corners, new.corners).map { CGPoint(x: mix($0.x, $1.x), y: mix($0.y, $1.y)) })
    }

    /// The one thing most out of line. Nil when everything is within tolerance.
    var biggest: GuideCue? { cues.max { $0.size < $1.size }?.cue }

    /// Each correction still needed, with how many tolerances out it is.
    var cues: [(cue: GuideCue, size: Double)] {
        var list: [(cue: GuideCue, size: Double)] = []
        let mx = Double(abs(move.dx) / Self.moveTolerance)
        let my = Double(abs(move.dy) / Self.moveTolerance)
        if max(mx, my) >= 1 {
            let side: GuideCue.Side = mx >= my ? (move.dx > 0 ? .right : .left) : (move.dy > 0 ? .down : .up)
            list.append((cue: .move(side), size: max(mx, my)))
        }
        let ax = Double(abs(turn.dx) / Self.turnTolerance)
        let ay = Double(abs(turn.dy) / Self.turnTolerance)
        if ax >= 1 { list.append((cue: .pan(turn.dx > 0 ? .right : .left), size: ax)) }
        if ay >= 1 { list.append((cue: .tilt(turn.dy > 0 ? .down : .up), size: ay)) }
        let r = abs(tilt) / Self.tiltTolerance
        if r >= 1 { list.append((cue: .rotate(clockwise: tilt > 0), size: r)) }
        let d = abs(scale - 1) / Self.scaleTolerance
        if d >= 1 { list.append((cue: .step(closer: scale < 1), size: d)) }
        return list
    }
}

/// One instruction, in the saved photo's directions.
enum GuideCue: Equatable {
    enum Side { case left, right, up, down }
    case move(Side)
    case pan(Side)
    case tilt(Side)
    case rotate(clockwise: Bool)
    case step(closer: Bool)
}

/// Compares camera frames with the reference a few times a second and publishes the guide.
/// Lined up counts only after holding still and lined up for half a second, as in Reset.
@MainActor
final class Guide: ObservableObject {
    @Published private(set) var reading: GuideReading?
    @Published private(set) var matched = false
    /// The one instruction shown. Held for at least a second and a half so it can be read.
    @Published private(set) var cue: GuideCue?
    private var cueSince = Date.distantPast
    private var reference: CIImage?
    /// The part of the picture the screen shows (width over height, upright), so the guide lines up
    /// what you see rather than the whole camera frame.
    private var aspect: CGFloat?
    private var busy = false
    private var lastReading = Date.distantPast
    /// No reading for a second: shown so it is clear the guide is on but can't find the reference.
    @Published private(set) var searching = false
    private var linedSince: Date?
    private nonisolated static let width: CGFloat = 480

    func setReference(_ image: UIImage?, aspect: CGFloat?) {
        self.aspect = aspect
        reference = image.flatMap { CIImage(image: $0) }.map { Self.prepared(Self.centred($0, aspect: aspect)) }
        reading = nil
        cue = nil
        searching = false
        lastReading = .now
        matched = false
        linedSince = nil
    }

    /// A live frame, upright the same way as saved photos. Dropped if the last is still being read.
    nonisolated func consider(_ frame: CIImage) {
        Task { @MainActor in
            guard !self.busy, let reference = self.reference else { return }
            self.busy = true
            let live = Self.prepared(Self.centred(frame, aspect: self.aspect))
            let reading = await Task.detached(priority: .utility) { Self.read(live: live, reference: reference) }.value
            self.busy = false
            guard self.reference != nil else { return }
            self.update(reading)
        }
    }

    private func update(_ reading: GuideReading?) {
        if let reading {
            self.reading = self.reading.map { $0.blended(towards: reading, by: 0.4) } ?? reading
            lastReading = .now
        } else if Date.now.timeIntervalSince(lastReading) > 1.5 {
            // Keep the last reading through a few missed frames; clear it after a moment.
            self.reading = nil
        }
        pickCue()
        let lost = self.reading == nil
        if searching != lost { searching = lost }
        if let current = self.reading, current.lined {
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
        var q = p
        for _ in 0..<((quarterTurns % 4 + 4) % 4) { q = CGPoint(x: 1 - q.y, y: q.x) }
        if mirrored { q.x = 1 - q.x }
        return CGPoint(x: rect.minX + q.x * rect.width, y: rect.minY + q.y * rect.height)
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
        let angle: Double
        switch side {
        case .left: position = CGPoint(x: inset, y: size.height / 2); angle = 180
        case .right: position = CGPoint(x: size.width - inset, y: size.height / 2); angle = 0
        case .up: position = CGPoint(x: size.width / 2, y: inset); angle = -90
        case .down: position = CGPoint(x: size.width / 2, y: size.height - inset); angle = 90
        }
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

extension GuideCue.Side {
    var word: String {
        switch self {
        case .left: "LEFT"
        case .right: "RIGHT"
        case .up: "UP"
        case .down: "DOWN"
        }
    }

    var horizontal: Bool { self == .left || self == .right }
}

extension GuideCue {
    /// From the photo's directions to the screen's: quarter turns clockwise, then the mirror.
    static func screen(_ side: Side, turns: Int, mirrored: Bool) -> Side {
        let order: [Side] = [.up, .right, .down, .left]
        var s = order[((order.firstIndex(of: side) ?? 0) + (turns % 4 + 4) % 4) % 4]
        if mirrored {
            if s == .left { s = .right } else if s == .right { s = .left }
        }
        return s
    }

    /// Changes whenever what the screen shows changes, so a new instruction fades in fresh.
    func screenID(turns: Int, mirrored: Bool) -> String {
        switch self {
        case .move(let side): "move-\(Self.screen(side, turns: turns, mirrored: mirrored))"
        case .pan(let side), .tilt(let side): "aim-\(Self.screen(side, turns: turns, mirrored: mirrored))"
        case .rotate(let clockwise): "rotate-\(clockwise != mirrored)"
        case .step(let closer): "step-\(closer)"
        }
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
