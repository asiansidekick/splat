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

/// What a placed mannequin is, kept with the model so it can be posed again.
struct MannequinSpec: Codable, Equatable {
    var body: MannequinBody
    var height: Float
    var pose: MannequinPose
}

