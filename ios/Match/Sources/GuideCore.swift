import CoreGraphics
import Foundation
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
    /// Locked to an actor rather than the room: the offset is fixed by aiming (pan and tilt), not
    /// by sliding the phone.
    var actor = false
    /// Actor lock only: how much more the face shows turned to the picture's right than in the
    /// reference (share of the eye spacing). Below zero: walk round to the left.
    var orbit: CGFloat = 0
    /// Actor lock only: how much lower the nose sits between eyes and mouth than in the reference.
    /// Above zero: the phone is too high, so lower it.
    var height: CGFloat = 0

    static let moveTolerance: CGFloat = 0.035
    static let turnTolerance: CGFloat = 0.06
    static let tiltTolerance: Double = 3
    static let scaleTolerance: Double = 0.06
    static let orbitTolerance: CGFloat = 0.06
    static let heightTolerance: CGFloat = 0.06

    var lined: Bool { cues.isEmpty }

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
            corners: zip(corners, new.corners).map { CGPoint(x: mix($0.x, $1.x), y: mix($0.y, $1.y)) },
            actor: new.actor,
            orbit: mix(orbit, new.orbit),
            height: mix(height, new.height))
    }

    /// The one thing most out of line. Nil when everything is within tolerance.
    var biggest: GuideCue? { cues.max { $0.size < $1.size }?.cue }

    /// Each correction still needed, with how many tolerances out it is.
    var cues: [(cue: GuideCue, size: Double)] {
        var list: [(cue: GuideCue, size: Double)] = []
        let mx = Double(abs(move.dx) / Self.moveTolerance)
        let my = Double(abs(move.dy) / Self.moveTolerance)
        if max(mx, my) >= 1 {
            if actor {
                // The actor sits off where they were in the frame: aim the phone at them.
                if mx >= my {
                    list.append((cue: .pan(move.dx > 0 ? .right : .left), size: mx))
                } else {
                    list.append((cue: .tilt(move.dy > 0 ? .down : .up), size: my))
                }
            } else {
                let side: GuideCue.Side = mx >= my ? (move.dx > 0 ? .right : .left) : (move.dy > 0 ? .down : .up)
                list.append((cue: .move(side), size: max(mx, my)))
            }
        }
        let o = Double(abs(orbit) / Self.orbitTolerance)
        if o >= 1 { list.append((cue: .circle(orbit > 0 ? .right : .left), size: o)) }
        let h = Double(abs(height) / Self.heightTolerance)
        if h >= 1 { list.append((cue: .height(raise: height < 0), size: h)) }
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
    /// Walk round the actor, keeping the phone on them.
    case circle(Side)
    /// Hold the phone higher or lower.
    case height(raise: Bool)
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
        case .circle(let side): "circle-\(Self.screen(side, turns: turns, mirrored: mirrored))"
        case .height(let raise): "height-\(raise)"
        }
    }
}
