import CoreGraphics
import Foundation

/// One person in a picture, found by Vision: either their face (eyes, nose, mouth) or, when the
/// face can't be seen, their body (shoulders, neck, hips). Points are 0...1 across and down.
struct ActorPose: Equatable {
    enum Kind { case face, body }
    var kind: Kind
    /// The pair the ghost is pinned to: the eyes, or the shoulders, left and right in the picture.
    var left: CGPoint
    var right: CGPoint
    /// The nose (face) or neck (body).
    var middle: CGPoint
    /// The middle of the mouth (face) or of the hips (body), when found.
    var lower: CGPoint?
    /// Where the face or body is, for picking one actor among several.
    var box: CGRect

    var centre: CGPoint { CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2) }
}

/// Lines a live actor up with the same actor in the reference. All the geometry is done with the
/// picture's height scaled to its width ("even" units), so tall and wide pictures measure fairly.
enum ActorMatch {
    /// The guide reading for the live actor against the reference: where to aim, how far to step,
    /// how to twist the phone, and (for faces) which way to walk round and whether to raise or
    /// lower the phone. `aspect` is the pictures' width over height (both cropped alike).
    static func reading(reference ref: ActorPose, live: ActorPose, aspect: CGFloat,
                        referenceDistance: Double? = nil, liveDistance: Double? = nil) -> GuideReading? {
        guard aspect > 0 else { return nil }
        func even(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y / aspect) }
        let a1 = even(ref.left), b1 = even(ref.right), a2 = even(live.left), b2 = even(live.right)
        let v1 = CGVector(dx: b1.x - a1.x, dy: b1.y - a1.y)
        let v2 = CGVector(dx: b2.x - a2.x, dy: b2.y - a2.y)
        let l1 = hypot(v1.dx, v1.dy), l2 = hypot(v2.dx, v2.dy)
        guard l1 > 1e-4, l2 > 1e-4 else { return nil }
        let scale = l2 / l1
        // Positive: the live picture shows the actor turned clockwise, so turn the phone clockwise.
        var angle = atan2(v2.dy, v2.dx) - atan2(v1.dy, v1.dx)
        if angle > .pi { angle -= 2 * .pi }
        if angle < -.pi { angle += 2 * .pi }

        let map = Similarity(from: (ref.left, ref.right), to: (live.left, live.right), aspect: aspect)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(map.apply)

        let c1 = ref.centre, c2 = live.centre
        var reading = GuideReading(
            move: CGVector(dx: c2.x - c1.x, dy: (c2.y - c1.y) / aspect),
            turn: .zero,
            tilt: Double(angle) * 180 / .pi,
            scale: Double(scale),
            corners: corners,
            actor: true)
        reading.useDistances(live: liveDistance, reference: referenceDistance)
        if ref.kind == .face, live.kind == .face {
            reading.orbit = turnAcross(live, aspect: aspect) - turnAcross(ref, aspect: aspect)
            if let r = noseDrop(ref, aspect: aspect), let l = noseDrop(live, aspect: aspect) {
                reading.height = l - r
            }
        }
        return reading
    }

    /// How far the nose sits to the picture's right of the eyes' middle, along the eye line, as a
    /// share of the eye spacing. Walking round to the actor's left (the photographer's right)
    /// makes it smaller.
    static func turnAcross(_ pose: ActorPose, aspect: CGFloat) -> CGFloat {
        let (axis, length, middle) = eyeAxis(pose, aspect: aspect)
        let nose = CGPoint(x: pose.middle.x, y: pose.middle.y / aspect)
        return ((nose.x - middle.x) * axis.dx + (nose.y - middle.y) * axis.dy) / length
    }

    /// Where the nose sits between the eyes (0) and the mouth (1), across the eye line. Seen from
    /// higher up it sits lower, nearer the mouth.
    static func noseDrop(_ pose: ActorPose, aspect: CGFloat) -> CGFloat? {
        guard let lower = pose.lower else { return nil }
        let (axis, _, middle) = eyeAxis(pose, aspect: aspect)
        let down = CGVector(dx: -axis.dy, dy: axis.dx)  // a quarter turn clockwise: down the face
        func along(_ p: CGPoint) -> CGFloat {
            let q = CGPoint(x: p.x, y: p.y / aspect)
            return (q.x - middle.x) * down.dx + (q.y - middle.y) * down.dy
        }
        let mouth = along(lower)
        guard mouth > 1e-4 else { return nil }
        return along(pose.middle) / mouth
    }

    private static func eyeAxis(_ pose: ActorPose, aspect: CGFloat) -> (CGVector, CGFloat, CGPoint) {
        let a = CGPoint(x: pose.left.x, y: pose.left.y / aspect)
        let b = CGPoint(x: pose.right.x, y: pose.right.y / aspect)
        let length = max(hypot(b.x - a.x, b.y - a.y), 1e-4)
        let axis = CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length)
        return (axis, length, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    }

    /// The actor to follow among those in the live picture: the one nearest the point tapped (or
    /// last followed), else the one most like the reference in place and size.
    static func pick(_ people: [ActorPose], near point: CGPoint?, like ref: ActorPose?) -> Int? {
        guard !people.isEmpty else { return nil }
        if let point {
            return people.indices.min { distance(people[$0].box, point) < distance(people[$1].box, point) }
        }
        guard let ref else { return people.indices.max { people[$0].box.area < people[$1].box.area } }
        func score(_ p: ActorPose) -> CGFloat {
            let shift = hypot(p.box.midX - ref.box.midX, p.box.midY - ref.box.midY)
            let size = abs(log(max(p.box.area, 1e-6) / max(ref.box.area, 1e-6)))
            return shift + 0.3 * size
        }
        return people.indices.min { score(people[$0]) < score(people[$1]) }
    }

    /// Zero inside the box, else how far outside.
    static func distance(_ box: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = max(box.minX - point.x, 0, point.x - box.maxX)
        let dy = max(box.minY - point.y, 0, point.y - box.maxY)
        return hypot(dx, dy)
    }
}

/// Moves, turns and scales so one pair of points lands on another (the reference's eyes onto the
/// live eyes), in 0...1 picture points.
struct Similarity {
    var scale: CGFloat
    var angle: CGFloat
    var fromA: CGPoint
    var toA: CGPoint
    var aspect: CGFloat

    init(from: (CGPoint, CGPoint), to: (CGPoint, CGPoint), aspect: CGFloat) {
        self.aspect = aspect
        let a1 = CGPoint(x: from.0.x, y: from.0.y / aspect), b1 = CGPoint(x: from.1.x, y: from.1.y / aspect)
        let a2 = CGPoint(x: to.0.x, y: to.0.y / aspect), b2 = CGPoint(x: to.1.x, y: to.1.y / aspect)
        let l1 = max(hypot(b1.x - a1.x, b1.y - a1.y), 1e-6)
        scale = hypot(b2.x - a2.x, b2.y - a2.y) / l1
        angle = atan2(b2.y - a2.y, b2.x - a2.x) - atan2(b1.y - a1.y, b1.x - a1.x)
        fromA = a1
        toA = a2
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let x = p.x - fromA.x, y = p.y / aspect - fromA.y
        let c = cos(angle) * scale, s = sin(angle) * scale
        return CGPoint(x: toA.x + c * x - s * y, y: (toA.y + s * x + c * y) * aspect)
    }
}

/// Between the saved photo's directions (0...1 across and down) and the screen's, for rotation
/// lock (quarter turns clockwise) and the front camera's mirror.
struct ScreenMap {
    var size: CGSize
    var quarterTurns: Int
    var mirrored: Bool
    /// Where the photo sits within the screen's picture (0...1, in the photo's directions): all of
    /// it, or a centred box when a portrait reference is shown whole on a landscape screen, or the
    /// other way round.
    var inner = CGRect(x: 0, y: 0, width: 1, height: 1)

    private var turns: Int { (quarterTurns % 4 + 4) % 4 }

    func toScreen(_ p: CGPoint) -> CGPoint {
        var q = CGPoint(x: inner.minX + p.x * inner.width, y: inner.minY + p.y * inner.height)
        for _ in 0..<turns { q = CGPoint(x: 1 - q.y, y: q.x) }
        if mirrored { q.x = 1 - q.x }
        return CGPoint(x: q.x * size.width, y: q.y * size.height)
    }

    func toPhoto(_ s: CGPoint) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        var q = CGPoint(x: s.x / size.width, y: s.y / size.height)
        if mirrored { q.x = 1 - q.x }
        for _ in 0..<turns { q = CGPoint(x: q.y, y: 1 - q.x) }
        guard inner.width > 0, inner.height > 0 else { return q }
        return CGPoint(x: (q.x - inner.minX) / inner.width, y: (q.y - inner.minY) / inner.height)
    }

    func toScreen(_ box: CGRect) -> CGRect {
        let a = toScreen(CGPoint(x: box.minX, y: box.minY))
        let b = toScreen(CGPoint(x: box.maxX, y: box.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Scale, turn (radians, clockwise) and offset, about the screen's middle, that carry the
    /// overlay's reference points onto the live ones, so the ghost sits on the actor.
    func ghostTransform(from: (CGPoint, CGPoint), to: (CGPoint, CGPoint)) -> (scale: CGFloat, angle: CGFloat, offset: CGSize) {
        let a1 = toScreen(from.0), b1 = toScreen(from.1), a2 = toScreen(to.0), b2 = toScreen(to.1)
        let l1 = max(hypot(b1.x - a1.x, b1.y - a1.y), 1e-6)
        let scale = hypot(b2.x - a2.x, b2.y - a2.y) / l1
        let angle = atan2(b2.y - a2.y, b2.x - a2.x) - atan2(b1.y - a1.y, b1.x - a1.x)
        // The middle of the reference pair, after scaling and turning about the screen's middle,
        // must land on the middle of the live pair.
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let m1 = CGPoint(x: (a1.x + b1.x) / 2 - centre.x, y: (a1.y + b1.y) / 2 - centre.y)
        let m2 = CGPoint(x: (a2.x + b2.x) / 2, y: (a2.y + b2.y) / 2)
        let c = cos(angle) * scale, s = sin(angle) * scale
        let moved = CGPoint(x: centre.x + c * m1.x - s * m1.y, y: centre.y + s * m1.x + c * m1.y)
        return (scale, angle, CGSize(width: m2.x - moved.x, height: m2.y - moved.y))
    }
}

extension CGRect {
    var area: CGFloat { width * height }

    /// A point given 0...1 across and down this box, as 0...1 of the whole.
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: minX + p.x * width, y: minY + p.y * height) }
}

/// Fitting a picture of one shape whole inside another, centred, as the screen shows a portrait
/// reference on a landscape screen.
enum Fit {
    /// The box (0...1 of the outer picture) that a centred picture of `inner` width over height
    /// fills when fitted whole inside one of `outer` width over height.
    static func centredBox(outer: CGFloat, inner: CGFloat) -> CGRect {
        guard outer > 0, inner > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if inner > outer {
            let h = outer / inner
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        } else {
            let w = inner / outer
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
    }

    /// Whether a reference this shape is shown whole (rather than filling the screen) on a screen
    /// showing this shape: when one is portrait and the other landscape.
    static func showsWhole(reference: CGFloat, screen: CGFloat) -> Bool {
        abs(reference - 1) > 0.01 && (reference > 1) != (screen > 1)
    }
}
