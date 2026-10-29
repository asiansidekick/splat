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
            scale: scale)
    }
}

/// Compares camera frames with the reference a few times a second and publishes the guide.
/// Lined up counts only after holding still and lined up for half a second, as in Reset.
@MainActor
final class Guide: ObservableObject {
    @Published private(set) var reading: GuideReading?
    @Published private(set) var matched = false
    private var reference: CIImage?
    private var busy = false
    private var linedSince: Date?
    private nonisolated static let width: CGFloat = 480

    func setReference(_ image: UIImage?) {
        reference = image.flatMap { CIImage(image: $0) }.map(Self.prepared)
        reading = nil
        matched = false
        linedSince = nil
    }

    /// A live frame, upright the same way as saved photos. Dropped if the last is still being read.
    nonisolated func consider(_ frame: CIImage) {
        Task { @MainActor in
            guard !self.busy, let reference = self.reference else { return }
            self.busy = true
            let live = Self.prepared(frame)
            let reading = await Task.detached(priority: .utility) { Self.read(live: live, reference: reference) }.value
            self.busy = false
            guard self.reference != nil else { return }
            self.update(reading)
        }
    }

    private func update(_ reading: GuideReading?) {
        self.reading = reading
        if let reading, reading.lined {
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

    private nonisolated static func read(live: CIImage, reference: CIImage) -> GuideReading? {
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: live)
        let handler = VNImageRequestHandler(ciImage: reference, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let warp = request.results?.first?.warpTransform else { return nil }
        return GuideReading.from(warp: warp, reference: reference.extent.size, live: live.extent.size)
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

/// The guide drawn round the edges of the screen, leaving the face, hair and costume clear:
/// straight arrows to move left, right, up or down; curved arrows to turn; a turning arrow at the
/// top to level the phone; a word at the bottom to step closer or back. A green frame when lined up.
struct EdgeGuide: View {
    let reading: GuideReading?
    let matched: Bool
    /// Quarter turns clockwise from the photo's directions to the screen's (rotation lock).
    let quarterTurns: Int
    /// Front camera: the screen is a mirror.
    let mirrored: Bool

    enum Edge { case left, right, top, bottom }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if matched {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.green, lineWidth: 6)
                        .padding(3)
                } else if let reading {
                    ForEach(cues(reading), id: \.id) { cue in
                        cueView(cue, in: size)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(.easeOut(duration: 0.2), value: reading)
            .animation(.easeOut(duration: 0.2), value: matched)
        }
        .allowsHitTesting(false)
    }

    struct Cue: Identifiable {
        enum Kind { case move, turn }
        let kind: Kind
        let edge: Edge
        let strength: Double  // 0...1
        var id: String { "\(kind)-\(edge)" }
    }

    private func cues(_ r: GuideReading) -> [Cue] {
        var list: [Cue] = []
        func add(_ kind: Cue.Kind, _ value: CGFloat, _ tolerance: CGFloat, positive: Edge, negative: Edge) {
            guard abs(value) >= tolerance else { return }
            let strength = min(1, Double((abs(value) - tolerance) / (tolerance * 4)) + 0.35)
            list.append(Cue(kind: kind, edge: screen(value > 0 ? positive : negative), strength: strength))
        }
        add(.move, r.move.dx, GuideReading.moveTolerance, positive: .right, negative: .left)
        add(.move, r.move.dy, GuideReading.moveTolerance, positive: .bottom, negative: .top)
        add(.turn, r.turn.dx, GuideReading.turnTolerance, positive: .right, negative: .left)
        add(.turn, r.turn.dy, GuideReading.turnTolerance, positive: .bottom, negative: .top)
        return list
    }

    /// From the photo's directions to the screen's.
    private func screen(_ edge: Edge) -> Edge {
        var e = edge
        if mirrored {
            if e == .left { e = .right } else if e == .right { e = .left }
        }
        let order: [Edge] = [.top, .right, .bottom, .left]
        let turns = ((quarterTurns % 4) + 4) % 4
        return order[(order.firstIndex(of: e)! + turns) % 4]
    }

    /// Big but see-through, nudging gently the way to go, so they catch the eye without hiding
    /// the hair or makeup underneath.
    @ViewBuilder
    private func cueView(_ cue: Cue, in size: CGSize) -> some View {
        let shift: CGFloat = cue.kind == .turn ? 100 : 0
        let position: CGPoint = {
            let inset: CGFloat = 44
            switch cue.edge {
            case .left: return CGPoint(x: inset, y: size.height / 2 - shift)
            case .right: return CGPoint(x: size.width - inset, y: size.height / 2 - shift)
            case .top: return CGPoint(x: size.width / 2 + shift, y: inset)
            case .bottom: return CGPoint(x: size.width / 2 + shift, y: size.height - inset)
            }
        }()
        let angle: Double = {
            switch cue.edge {
            case .right: return 0
            case .bottom: return 90
            case .left: return 180
            case .top: return -90
            }
        }()
        VStack(spacing: 4) {
            Group {
                if cue.kind == .move {
                    Image(systemName: "arrowshape.right.fill")
                        .font(.system(size: 64, weight: .regular))
                } else {
                    TurnArrow()
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                        .frame(width: 64, height: 64)
                }
            }
            // Drifts towards the way to go and back, about once a second.
            .phaseAnimator([CGFloat(0), 12]) { content, nudge in
                content.offset(x: nudge)
            } animation: { _ in .easeInOut(duration: 0.6) }
            .rotationEffect(.degrees(angle))
            Text(label(cue))
                .font(.system(size: 11, weight: .heavy))
                .fixedSize()
        }
        .foregroundStyle(Color.yellow)
        .shadow(color: .black.opacity(0.35), radius: 1)
        .opacity(0.3 + 0.3 * cue.strength)
        .position(position)
    }

    private func label(_ cue: Cue) -> String {
        let word: String
        switch cue.edge {
        case .left: word = "LEFT"
        case .right: word = "RIGHT"
        case .top: word = "UP"
        case .bottom: word = "DOWN"
        }
        return (cue.kind == .move ? "MOVE " : "TURN ") + word
    }
}

/// The level and distance cues, kept to the bottom edge: a turning arrow to rotate the phone level,
/// and step closer or back.
struct EdgeGuideFooter: View {
    let reading: GuideReading?
    let matched: Bool
    let mirrored: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let reading, !matched {
                if abs(reading.tilt) >= GuideReading.tiltTolerance {
                    let clockwise = (reading.tilt > 0) != mirrored
                    Label("LEVEL", systemImage: clockwise ? "arrow.clockwise" : "arrow.counterclockwise")
                }
                if abs(reading.scale - 1) >= GuideReading.scaleTolerance {
                    Label(reading.scale > 1 ? "STEP BACK" : "STEP CLOSER",
                          systemImage: reading.scale > 1 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            } else if matched {
                Label("LINED UP", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green)
            }
        }
        .font(.system(size: 12, weight: .heavy))
        .foregroundStyle(Color.yellow)
        .shadow(color: .black.opacity(0.8), radius: 2)
        .allowsHitTesting(false)
    }
}

/// A curved arrow pointing right (rotate it for the other edges): turn, rather than move.
/// Drawn from points, so it looks the same whatever way the coordinate system runs.
struct TurnArrow: Shape {
    func path(in rect: CGRect) -> Path {
        // A quarter circle sweeping from the top middle round to the right, bowing outwards.
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
