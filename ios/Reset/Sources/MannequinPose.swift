import Foundation

// Kept free of SceneKit so the sync tests can build PlacedModel with it (see ios.yml).

enum MannequinBody: String, CaseIterable, Codable { case woman = "Woman", man = "Man" }

/// Joint angles in degrees. Limbs hang straight down at 0; the figure faces +Z and its left is +X.
struct MannequinPose: Codable, Equatable {
    struct Arm: Codable, Equatable { var out: Float = 8; var forward: Float = 0; var inward: Float = 0; var elbow: Float = 8 }
    struct Leg: Codable, Equatable { var out: Float = 2; var forward: Float = 0; var inward: Float = 0; var knee: Float = 0 }
    var spineForward: Float = 0
    var spineSide: Float = 0
    var headTurn: Float = 0
    var headDown: Float = 0
    var left = Arm(), right = Arm()
    var leftLeg = Leg(), rightLeg = Leg()
    /// Phil, 2026-11-19 (Magic Poser): hips, wrists and ankles. Kept apart so poses saved before them still open.
    struct Hand: Codable, Equatable { var bend: Float = 0; var side: Float = 0 }
    struct Foot: Codable, Equatable { var point: Float = 0; var turn: Float = 0 }
    struct Detail: Codable, Equatable {
        var hipTilt: Float = 0
        var hipTurn: Float = 0
        var leftHand = Hand(), rightHand = Hand()
        var leftFoot = Foot(), rightFoot = Foot()
    }
    var detail = Detail()

    static let standing = MannequinPose()
    static let sitting: MannequinPose = {
        var p = MannequinPose()
        p.left = Arm(out: 10, forward: 25, elbow: 55)
        p.right = p.left
        p.leftLeg = Leg(forward: 90, knee: 90)
        p.rightLeg = p.leftLeg
        return p
    }()
    static let armsCrossed: MannequinPose = {
        var p = MannequinPose()
        p.left = Arm(out: 12, forward: 20, inward: 70, elbow: 110)
        p.right = Arm(out: 12, forward: 20, inward: 70, elbow: 105)
        return p
    }()
    static let handsOnHips: MannequinPose = {
        var p = MannequinPose()
        p.left = Arm(out: 45, forward: -10, inward: 90, elbow: 100)
        p.right = p.left
        return p
    }()
    static let walking: MannequinPose = {
        var p = MannequinPose()
        p.left = Arm(forward: -18, elbow: 15)
        p.right = Arm(forward: 20, elbow: 25)
        p.leftLeg = Leg(forward: 22, knee: 8)
        p.rightLeg = Leg(forward: -15, knee: 20)
        return p
    }()
    static let weightOnOneLeg: MannequinPose = {
        var p = MannequinPose()
        p.spineSide = -4
        p.headTurn = 10
        p.left = Arm(out: 10)
        p.right = Arm(out: 10)
        p.leftLeg = Leg(out: -2, forward: 10, inward: -10, knee: 15)
        p.rightLeg = Leg(out: 4)
        return p
    }()

    static let all: [(name: String, pose: MannequinPose)] = [
        ("Standing", standing), ("Sitting", sitting), ("Arms crossed", armsCrossed),
        ("Hands on hips", handsOnHips), ("Walking", walking), ("Weight on one leg", weightOnOneLeg),
    ]
}

extension MannequinPose {
    private enum Keys: String, CodingKey {
        case spineForward, spineSide, headTurn, headDown, left, right, leftLeg, rightLeg, detail
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: Keys.self)
        spineForward = try c.decodeIfPresent(Float.self, forKey: .spineForward) ?? 0
        spineSide = try c.decodeIfPresent(Float.self, forKey: .spineSide) ?? 0
        headTurn = try c.decodeIfPresent(Float.self, forKey: .headTurn) ?? 0
        headDown = try c.decodeIfPresent(Float.self, forKey: .headDown) ?? 0
        left = try c.decodeIfPresent(Arm.self, forKey: .left) ?? Arm()
        right = try c.decodeIfPresent(Arm.self, forKey: .right) ?? Arm()
        leftLeg = try c.decodeIfPresent(Leg.self, forKey: .leftLeg) ?? Leg()
        rightLeg = try c.decodeIfPresent(Leg.self, forKey: .rightLeg) ?? Leg()
        detail = try c.decodeIfPresent(Detail.self, forKey: .detail) ?? Detail()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(spineForward, forKey: .spineForward)
        try c.encode(spineSide, forKey: .spineSide)
        try c.encode(headTurn, forKey: .headTurn)
        try c.encode(headDown, forKey: .headDown)
        try c.encode(left, forKey: .left)
        try c.encode(right, forKey: .right)
        try c.encode(leftLeg, forKey: .leftLeg)
        try c.encode(rightLeg, forKey: .rightLeg)
        try c.encode(detail, forKey: .detail)
    }

    /// The same pose the other way round (left and right swapped), like Magic Poser's flip.
    var mirrored: MannequinPose {
        var p = self
        p.left = right
        p.right = left
        p.leftLeg = rightLeg
        p.rightLeg = leftLeg
        p.spineSide = -spineSide
        p.headTurn = -headTurn
        p.detail.hipTilt = -detail.hipTilt
        p.detail.hipTurn = -detail.hipTurn
        p.detail.leftHand = detail.rightHand
        p.detail.rightHand = detail.leftHand
        p.detail.leftFoot = detail.rightFoot
        p.detail.rightFoot = detail.leftFoot
        return p
    }
}

/// What a placed mannequin is, kept with the model so it can be posed again.
struct MannequinSpec: Codable, Equatable {
    var body: MannequinBody
    var height: Float
    var pose: MannequinPose
}


extension MannequinPose {
    /// Phil, 2026-11-10: hand posing keeps to what a body can do. Elbows and knees bend one way only and
    /// not fully shut, limbs twist only so far, a hip swings forward more than back or out. A leg raised
    /// past level (written the other way round, out beyond 90°) keeps its swing.
    var limited: MannequinPose {
        func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float { min(max(value, low), high) }
        func arm(_ a: Arm) -> Arm {
            var a = a
            a.elbow = clamp(a.elbow, 0, 150)
            a.inward = clamp(a.inward, -80, 110)
            return a
        }
        func leg(_ l: Leg) -> Leg {
            var l = l
            l.knee = clamp(l.knee, 0, 145)
            // Phil, 2026-11-18: a raised leg twisted unnaturally. The hip turns in and out only a little, and less
            // the higher the leg is lifted.
            let lifted = abs(l.out) > 90 || l.forward > 60
            // A bent knee leaves little room to twist the thigh, and a thigh raised forward can't also swing far out.
            let twist: Float = l.knee > 60 ? 10 : (lifted ? 12 : 25)
            l.inward = clamp(l.inward, -twist, min(twist + 5, 30))
            if abs(l.out) <= 90 {
                l.forward = clamp(l.forward, -30, 100)
                l.out = clamp(l.out, -25, l.forward > 45 ? 20 : 45)
            }
            return l
        }
        var p = self
        p.left = arm(left)
        p.right = arm(right)
        p.leftLeg = leg(leftLeg)
        p.rightLeg = leg(rightLeg)
        func hand(_ h: Hand) -> Hand { Hand(bend: clamp(h.bend, -60, 80), side: clamp(h.side, -20, 30)) }
        func foot(_ f: Foot) -> Foot { Foot(point: clamp(f.point, -20, 50), turn: clamp(f.turn, -25, 25)) }
        p.detail.hipTilt = clamp(detail.hipTilt, -15, 15)
        p.detail.hipTurn = clamp(detail.hipTurn, -35, 35)
        p.detail.leftHand = hand(detail.leftHand)
        p.detail.rightHand = hand(detail.rightHand)
        p.detail.leftFoot = foot(detail.leftFoot)
        p.detail.rightFoot = foot(detail.rightFoot)
        p.spineForward = clamp(spineForward, -30, 60)
        p.spineSide = clamp(spineSide, -30, 30)
        p.headTurn = clamp(headTurn, -80, 80)
        p.headDown = clamp(headDown, -40, 60)
        return p
    }
}
