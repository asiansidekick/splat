import Foundation

/// Ready-made poses in groups (Phil, 2026-11-22): riding, driving, moving, sitting, moods, martial arts, shooting, lying
/// in bed and slumped dead. The groups keep each menu short; every pose works on a mannequin and on any character
/// with a skeleton (scanned people, Mixamo). Each was drawn and checked as a stick figure before going in.
struct PoseGroup {
    let name: String
    /// An SF Symbol beside the group's name.
    let symbol: String
    let poses: [(name: String, pose: MannequinPose)]
}

extension MannequinPose {
    /// Every ready-made pose, group by group.
    static let all: [(name: String, pose: MannequinPose)] = groups.flatMap(\.poses)

    private static func pose(_ edit: (inout MannequinPose) -> Void) -> MannequinPose {
        var p = MannequinPose()
        edit(&p)
        return p
    }

    /// Finger curls (thumb to little) for the ready-made poses; characters without finger bones ignore them.
    private enum Hands {
        static let fist: [Float] = [0.8, 1, 1, 1, 1]
        static let grip: [Float] = [0.6, 0.75, 0.8, 0.85, 0.9]
        static let point: [Float] = [0.8, 0, 1, 1, 1]
        static let relaxed: [Float] = [0.25, 0.3, 0.35, 0.4, 0.45]
        static let trigger: [Float] = [0.6, 0.25, 1, 1, 1]
        static let loose: [Float] = [0.15, 0.2, 0.25, 0.3, 0.35]
    }

    private static let standingPoses = PoseGroup(name: "Standing", symbol: "figure.stand", poses: [
        ("Standing", .standing),
        ("Weight on one leg", pose { p in
            p.spineSide = -4
            p.headTurn = 10
            p.left = Arm(out: 10)
            p.right = Arm(out: 10)
            p.leftLeg = Leg(out: -2, forward: 10, inward: -10, knee: 15)
            p.rightLeg = Leg(out: 4)
        }),
        ("Arms crossed", pose { p in
            p.left = Arm(out: 12, forward: 20, inward: 70, elbow: 110)
            p.right = Arm(out: 12, forward: 20, inward: 70, elbow: 105)
        }),
        ("Hands on hips", pose { p in
            p.left = Arm(out: 45, forward: -10, inward: 90, elbow: 100)
            p.right = p.left
        }),
        ("Pointing into the distance", pose { p in
            p.spineForward = 3
            p.headTurn = -12
            p.headDown = -5
            p.left = Arm(out: 10, forward: 5, inward: 10, elbow: 15)
            p.right = Arm(out: 160, forward: 78, inward: -155, elbow: 4)
            p.leftLeg = Leg(out: 4, forward: -8, knee: 4)
            p.rightLeg = Leg(forward: 12, knee: 6)
            p.detail.leftFingers = Hands.relaxed
            p.detail.rightFingers = Hands.point
        }),
    ])

    private static let movingPoses = PoseGroup(name: "Moving", symbol: "figure.walk", poses: [
        ("Walking", pose { p in
            p.left = Arm(forward: -18, elbow: 15)
            p.right = Arm(forward: 20, elbow: 25)
            p.leftLeg = Leg(forward: 22, knee: 8)
            p.rightLeg = Leg(forward: -15, knee: 20)
        }),
        ("Running", pose { p in
            p.spineForward = 14
            p.headDown = -8
            p.left = Arm(out: 12, forward: -45, elbow: 85)
            p.right = Arm(out: 12, forward: 50, inward: 20, elbow: 95)
            p.leftLeg = Leg(out: 4, forward: 55, knee: 85)
            p.rightLeg = Leg(forward: -22, knee: 70)
            p.detail.rightFoot = Foot(point: 30, turn: 0)
            p.detail.leftFingers = Hands.fist
            p.detail.rightFingers = Hands.fist
        }),
        ("Jumping", pose { p in
            p.spineForward = 8
            p.headDown = -15
            p.left = Arm(out: 150, forward: 25, elbow: 15)
            p.right = Arm(out: 150, forward: 25, elbow: 15)
            p.leftLeg = Leg(out: 3, forward: 45, knee: 80)
            p.rightLeg = Leg(out: 3, forward: 30, knee: 90)
            p.detail.leftFoot = Foot(point: 35, turn: 0)
            p.detail.rightFoot = Foot(point: 35, turn: 0)
        }),
        ("Leaping", pose { p in
            p.spineForward = 12
            p.left = Arm(out: 20, forward: -40, elbow: 20)
            p.right = Arm(out: 30, forward: 60, elbow: 25)
            p.leftLeg = Leg(out: 3, forward: 70, knee: 15)
            p.rightLeg = Leg(out: 3, forward: -20, knee: 95)
            p.detail.leftFoot = Foot(point: 10, turn: 0)
            p.detail.rightFoot = Foot(point: 40, turn: 0)
        }),
        ("Climbing stairs", pose { p in
            p.spineForward = 12
            p.headDown = 10
            p.left = Arm(forward: -15, elbow: 15)
            p.right = Arm(forward: 20, elbow: 25)
            p.leftLeg = Leg(forward: 45, knee: 70)
            p.rightLeg = Leg(forward: -8, knee: 10)
            p.detail.rightFoot = Foot(point: 25, turn: 0)
        }),
        ("Climbing a ladder", pose { p in
            p.spineForward = 4
            p.headDown = -10
            p.left = Arm(out: 0, forward: 70, elbow: 80)
            p.right = Arm(out: 5, forward: 45, elbow: 55)
            p.leftLeg = Leg(out: 3, forward: 60, knee: 95)
            p.rightLeg = Leg(out: 3, forward: 15, knee: 30)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.grip
        }),
        ("Pushing a cart", pose { p in
            p.spineForward = 16
            p.headDown = -12
            p.left = Arm(forward: 42, inward: 15, elbow: 45)
            p.right = Arm(forward: 42, inward: 15, elbow: 45)
            p.leftLeg = Leg(forward: 22, knee: 12)
            p.rightLeg = Leg(forward: -18, knee: 22)
            p.detail.rightFoot = Foot(point: 20, turn: 0)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.grip
        }),
    ])

    private static let sittingPoses = PoseGroup(name: "Sitting", symbol: "figure.seated.side", poses: [
        ("Sitting", .sitting),
        ("Leaning back", pose { p in
            p.spineForward = -15
            p.headDown = 8
            p.left = Arm(out: 14, forward: 20, inward: 25, elbow: 60)
            p.right = p.left
            p.leftLeg = Leg(out: 6, forward: 75, knee: 65)
            p.rightLeg = Leg(out: 4, forward: 80, knee: 75)
        }),
        ("Elbows on knees", pose { p in
            p.spineForward = 42
            p.headDown = -10
            p.left = Arm(out: 10, forward: 55, inward: 30, elbow: 95)
            p.right = p.left
            p.leftLeg = Leg(out: 8, forward: 90, knee: 100)
            p.rightLeg = p.leftLeg
        }),
        ("Reclining", pose { p in
            p.headDown = 20
            p.left = Arm(out: 150, elbow: 140)
            p.right = p.left
            p.leftLeg = Leg(out: 4, forward: 55, knee: 15)
            p.rightLeg = Leg(out: 4, forward: 60, knee: 40)
            p.detail.lie = Lie(over: 0, roll: -35)
        }),
        ("Cross-legged on the floor", pose { p in
            p.spineForward = 10
            p.headDown = 5
            p.left = Arm(out: 10, forward: 30, inward: 20, elbow: 60)
            p.right = p.left
            p.leftLeg = Leg(out: 75, forward: 40, inward: -155, knee: 130)
            p.rightLeg = Leg(out: 75, forward: 50, inward: -165, knee: 110)
            p.detail.leftFoot = Foot(point: 20, turn: 0)
            p.detail.rightFoot = Foot(point: 20, turn: 0)
        }),
        ("On the floor, knees up", pose { p in
            p.spineForward = 20
            p.headDown = 5
            p.left = Arm(out: 10, forward: 55, inward: 35, elbow: 55)
            p.right = p.left
            p.leftLeg = Leg(out: 4, forward: 100, knee: 125)
            p.rightLeg = p.leftLeg
            p.detail.leftFingers = Hands.relaxed
            p.detail.rightFingers = Hands.relaxed
        }),
    ])

    private static let moodsPoses = PoseGroup(name: "Moods", symbol: "theatermasks", poses: [
        ("Angry", pose { p in
            p.spineForward = 10
            p.headDown = 8
            p.left = Arm(out: 18, forward: 8, inward: 10, elbow: 35)
            p.right = Arm(out: 18, forward: 8, inward: 10, elbow: 35)
            p.leftLeg = Leg(out: 8, forward: 4, knee: 6)
            p.rightLeg = Leg(out: 8, forward: -4, knee: 6)
            p.detail.leftShoulder = Shoulder(shrug: 12, roll: 8)
            p.detail.rightShoulder = Shoulder(shrug: 12, roll: 8)
            p.detail.leftFingers = Hands.fist
            p.detail.rightFingers = Hands.fist
        }),
        ("Sad", pose { p in
            p.spineForward = 8
            p.headDown = 35
            p.detail.headTilt = 6
            p.left = Arm(out: 6, forward: 6, inward: 25, elbow: 12)
            p.right = p.left
            p.leftLeg = Leg(out: 1, inward: 8, knee: 4)
            p.rightLeg = Leg(out: 1, inward: 8, knee: 4)
            p.detail.leftShoulder = Shoulder(shrug: -6, roll: 15)
            p.detail.rightShoulder = Shoulder(shrug: -6, roll: 15)
            p.detail.leftFingers = Hands.loose
            p.detail.rightFingers = Hands.loose
        }),
        ("Depressed", pose { p in
            p.spineForward = 48
            p.headDown = 40
            p.left = Arm(forward: 62, inward: 15, elbow: 145)
            p.right = p.left
            p.leftLeg = Leg(out: 6, forward: 90, knee: 100)
            p.rightLeg = p.leftLeg
            p.detail.leftHand = Hand(bend: 25, side: 0)
            p.detail.rightHand = Hand(bend: 25, side: 0)
        }),
        ("Despair", pose { p in
            p.spineForward = 6
            p.headDown = 25
            p.left = Arm(out: 135, forward: 15, inward: -90, elbow: 120)
            p.right = p.left
            p.leftLeg = Leg(out: 4, forward: 6, knee: 10)
            p.rightLeg = Leg(out: 4, forward: -4, knee: 6)
        }),
    ])

    private static let ridingAndDrivingPoses = PoseGroup(name: "Riding and driving", symbol: "figure.outdoor.cycle", poses: [
        ("Motorbike", pose { p in
            p.spineForward = 30
            p.headDown = -25
            p.left = Arm(out: 14, forward: 62, elbow: 28)
            p.right = p.left
            p.leftLeg = Leg(out: 16, forward: 72, knee: 110)
            p.rightLeg = p.leftLeg
            p.detail.leftFoot = Foot(point: 10, turn: 0)
            p.detail.rightFoot = Foot(point: 10, turn: 0)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.grip
        }),
        ("Dirt bike", pose { p in
            p.spineForward = 35
            p.headDown = -28
            p.left = Arm(out: 45, forward: 55, inward: -15, elbow: 60)
            p.right = p.left
            p.leftLeg = Leg(out: 10, forward: 40, knee: 55)
            p.rightLeg = p.leftLeg
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.grip
        }),
        ("Scooter", pose { p in
            p.left = Arm(out: 10, forward: 45, inward: 10, elbow: 35)
            p.right = p.left
            p.leftLeg = Leg(out: 5, forward: 78, knee: 75)
            p.rightLeg = p.leftLeg
            p.detail.leftFoot = Foot(point: -10, turn: 0)
            p.detail.rightFoot = Foot(point: -10, turn: 0)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.grip
        }),
        ("Bicycle", pose { p in
            p.spineForward = 38
            p.headDown = -30
            p.left = Arm(out: 10, forward: 60, inward: 5, elbow: 20)
            p.right = Arm(out: 10, forward: 60, inward: 5, elbow: 20)
            p.leftLeg = Leg(out: 4, forward: 75, knee: 105)
            p.rightLeg = Leg(out: 4, forward: 30, knee: 45)
            p.detail.leftFoot = Foot(point: 10, turn: 0)
            p.detail.rightFoot = Foot(point: 25, turn: 0)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.grip
        }),
        ("Driving a car", pose { p in
            p.spineForward = -12
            p.headDown = 10
            p.left = Arm(out: 14, forward: 50, inward: 15, elbow: 55)
            p.right = Arm(out: 14, forward: 45, inward: 15, elbow: 60)
            p.leftLeg = Leg(out: 6, forward: 75, knee: 55)
            p.rightLeg = Leg(out: 3, forward: 72, knee: 45)
            p.detail.rightFoot = Foot(point: 15, turn: 0)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.grip
        }),
        ("Head out of the window", pose { p in
            p.spineSide = -24
            p.headTurn = 10
            p.headDown = -5
            p.detail.headTilt = -8
            p.left = Arm(out: 55, forward: 25, elbow: 95)
            p.right = Arm(out: 10, forward: 25, elbow: 55)
            p.leftLeg = Leg(out: 4, forward: 88, knee: 88)
            p.rightLeg = Leg(out: 4, forward: 90, knee: 90)
        }),
    ])

    private static let martialArtsPoses = PoseGroup(name: "Martial arts", symbol: "figure.martial.arts", poses: [
        ("Guard", pose { p in
            p.headDown = 10
            p.detail.hipTurn = 25
            p.left = Arm(out: 15, forward: 45, inward: 30, elbow: 115)
            p.right = Arm(out: 12, forward: 25, inward: 35, elbow: 130)
            p.leftLeg = Leg(out: 8, forward: 18, knee: 18)
            p.rightLeg = Leg(out: 8, forward: -12, knee: 25)
            p.detail.leftFingers = Hands.fist
            p.detail.rightFingers = Hands.fist
        }),
        ("Punch", pose { p in
            p.spineForward = 5
            p.detail.hipTurn = -15
            p.left = Arm(out: 10, forward: -35, elbow: 115)
            p.right = Arm(out: -90, forward: 72, elbow: 0)
            p.leftLeg = Leg(out: 6, forward: 30, knee: 35)
            p.rightLeg = Leg(out: 4, forward: -22)
            p.detail.leftFingers = Hands.fist
            p.detail.rightFingers = Hands.fist
        }),
        ("Front kick", pose { p in
            p.spineForward = -8
            p.left = Arm(out: 15, forward: 45, inward: 30, elbow: 115)
            p.right = Arm(out: 12, forward: 25, inward: 35, elbow: 130)
            p.leftLeg = Leg(out: 4, knee: 15)
            p.rightLeg = Leg(forward: 88, knee: 10)
            p.detail.rightFoot = Foot(point: 40, turn: 0)
            p.detail.leftFingers = Hands.fist
            p.detail.rightFingers = Hands.fist
        }),
        ("Side kick", pose { p in
            p.spineSide = -30
            p.headTurn = -30
            p.detail.hipTilt = -15
            p.left = Arm(out: 30, forward: 30, inward: 30, elbow: 110)
            p.right = Arm(out: 40, forward: 30, inward: 30, elbow: 120)
            p.leftLeg = Leg(out: 4, knee: 12)
            p.rightLeg = Leg(out: 62, forward: 30, knee: 5)
            p.detail.leftFingers = Hands.fist
            p.detail.rightFingers = Hands.fist
        }),
        ("Block", pose { p in
            p.left = Arm(out: 10, forward: -35, elbow: 115)
            p.right = Arm(out: 150, forward: 35, inward: -70, elbow: 90)
            p.leftLeg = Leg(out: 6, forward: 25, knee: 30)
            p.rightLeg = Leg(out: 4, forward: -20)
            p.detail.leftFingers = Hands.fist
            p.detail.rightFingers = Hands.fist
        }),
        ("Horse stance", pose { p in
            p.left = Arm(out: 10, forward: -30, elbow: 115)
            p.right = p.left
            p.leftLeg = Leg(out: 55, forward: 30, inward: -30, knee: 75)
            p.rightLeg = p.leftLeg
            p.detail.leftFingers = Hands.fist
            p.detail.rightFingers = Hands.fist
        }),
        ("Crane", pose { p in
            p.left = Arm(out: 110, forward: 20, elbow: 20)
            p.right = Arm(out: 110, forward: 20, elbow: 20)
            p.leftLeg = Leg(knee: 8)
            p.rightLeg = Leg(out: 4, forward: 95, knee: 110)
            p.detail.leftHand = Hand(bend: 70, side: 0)
            p.detail.rightHand = Hand(bend: 70, side: 0)
            p.detail.rightFoot = Foot(point: 40, turn: 0)
        }),
    ])

    private static let shootingPoses = PoseGroup(name: "Shooting", symbol: "scope", poses: [
        ("Aiming a pistol", pose { p in
            p.spineForward = 6
            p.headDown = 8
            p.left = Arm(out: -90, forward: 72)
            p.right = Arm(out: -90, forward: 72, elbow: 5)
            p.leftLeg = Leg(out: 6, forward: 10, knee: 12)
            p.rightLeg = Leg(out: 6, forward: -10, knee: 12)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.trigger
        }),
        ("Aiming a rifle", pose { p in
            p.headTurn = -8
            p.headDown = 10
            p.detail.headTilt = 10
            p.left = Arm(out: -60, forward: 75, elbow: 25)
            p.right = Arm(out: 70, forward: 35, elbow: 115)
            p.leftLeg = Leg(out: 6, forward: 12, knee: 10)
            p.rightLeg = Leg(out: 8, forward: -12, knee: 10)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.trigger
        }),
        ("Kneeling, aiming", pose { p in
            p.headTurn = -8
            p.headDown = 10
            p.detail.headTilt = 10
            p.left = Arm(out: -60, forward: 75, elbow: 25)
            p.right = Arm(out: 70, forward: 35, elbow: 115)
            p.leftLeg = Leg(out: 4, forward: 85, knee: 90)
            p.rightLeg = Leg(out: 4, forward: -10, knee: 100)
            p.detail.rightFoot = Foot(point: 40, turn: 0)
            p.detail.leftFingers = Hands.grip
            p.detail.rightFingers = Hands.trigger
        }),
    ])

    private static let lyingPoses = PoseGroup(name: "Lying", symbol: "bed.double", poses: [
        ("On back", pose { p in
            p.headDown = 15
            p.left = Arm(out: 14, elbow: 10)
            p.right = p.left
            p.leftLeg = Leg(out: 3, knee: 4)
            p.rightLeg = p.leftLeg
            p.detail.lie = Lie(over: 90, roll: -90)
        }),
        ("On side", pose { p in
            p.detail.headTilt = -12
            p.left = Arm(out: 10, forward: 40, inward: 20, elbow: 40)
            p.right = Arm(forward: 80, elbow: 100)
            p.leftLeg = Leg(forward: 45, knee: 55)
            p.rightLeg = Leg(forward: 30, knee: 45)
            p.detail.leftFoot = Foot(point: 30, turn: 0)
            p.detail.rightFoot = Foot(point: 30, turn: 0)
            p.detail.lie = Lie(over: 90, roll: 0)
        }),
        ("Curled up", pose { p in
            p.spineForward = 30
            p.headDown = 30
            p.detail.headTilt = -12
            p.left = Arm(out: 10, forward: 60, inward: 20, elbow: 130)
            p.right = Arm(forward: 70, inward: 10, elbow: 130)
            p.leftLeg = Leg(forward: 100, knee: 125)
            p.rightLeg = Leg(forward: 90, knee: 120)
            p.detail.leftFoot = Foot(point: 30, turn: 0)
            p.detail.rightFoot = Foot(point: 30, turn: 0)
            p.detail.lie = Lie(over: 90, roll: 0)
        }),
        ("Face down", pose { p in
            p.headTurn = 75
            p.left = Arm(out: 150, forward: 20, elbow: 90)
            p.right = Arm(out: 150, forward: 20, elbow: 90)
            p.leftLeg = Leg(out: 3)
            p.rightLeg = Leg(out: 10, forward: 15, inward: -30, knee: 50)
            p.detail.leftFoot = Foot(point: 45, turn: 0)
            p.detail.rightFoot = Foot(point: 45, turn: 0)
            p.detail.lie = Lie(over: 90, roll: 90)
        }),
    ])

    private static let slumpedDeadPoses = PoseGroup(name: "Slumped dead", symbol: "figure.fall", poses: [
        ("Dead on back", pose { p in
            p.headTurn = 55
            p.detail.headTilt = -15
            p.left = Arm(out: 80, elbow: 30)
            p.right = Arm(out: 110, elbow: 60)
            p.leftLeg = Leg(out: 12, knee: 8)
            p.rightLeg = Leg(out: 25, forward: 15, inward: -30, knee: 35)
            p.detail.leftFoot = Foot(point: 35, turn: 0)
            p.detail.rightFoot = Foot(point: 30, turn: 15)
            p.detail.leftFingers = Hands.loose
            p.detail.rightFingers = Hands.loose
            p.detail.lie = Lie(over: 90, roll: -90)
        }),
        ("Dead face down", pose { p in
            p.headTurn = 80
            p.left = Arm(out: 140, forward: 10, elbow: 40)
            p.right = Arm(out: 12, inward: -60, elbow: 10)
            p.leftLeg = Leg(out: 5)
            p.rightLeg = Leg(out: 40, forward: 35, inward: -40, knee: 80)
            p.detail.leftFoot = Foot(point: 45, turn: 0)
            p.detail.rightFoot = Foot(point: 45, turn: 0)
            p.detail.leftFingers = Hands.loose
            p.detail.rightFingers = Hands.loose
            p.detail.lie = Lie(over: 90, roll: 90)
        }),
        ("Dead on side", pose { p in
            p.spineForward = 10
            p.headDown = 15
            p.detail.headTilt = -20
            p.left = Arm(out: 30, forward: 50, inward: 10, elbow: 40)
            p.right = Arm(out: 10, forward: 85, elbow: 30)
            p.leftLeg = Leg(forward: 40, knee: 60)
            p.rightLeg = Leg(forward: 15, knee: 25)
            p.detail.leftFoot = Foot(point: 40, turn: 0)
            p.detail.rightFoot = Foot(point: 40, turn: 0)
            p.detail.leftFingers = Hands.loose
            p.detail.rightFingers = Hands.loose
            p.detail.lie = Lie(over: 90, roll: 15)
        }),
        ("Dead against a wall", pose { p in
            p.spineForward = 12
            p.headDown = 45
            p.detail.headTilt = 20
            p.left = Arm(out: 28, forward: 8, inward: -30, elbow: 20)
            p.right = Arm(out: 25, forward: 5, inward: -30, elbow: 25)
            p.leftLeg = Leg(out: 18, forward: 88, knee: 12)
            p.rightLeg = Leg(out: 12, forward: 85, inward: -10, knee: 30)
            p.detail.leftFoot = Foot(point: 30, turn: 0)
            p.detail.rightFoot = Foot(point: 30, turn: 0)
            p.detail.leftFingers = Hands.loose
            p.detail.rightFingers = Hands.loose
            p.detail.lie = Lie(over: 0, roll: -22)
        }),
        ("Dead in a chair", pose { p in
            p.spineForward = 8
            p.spineSide = 12
            p.headDown = 50
            p.detail.headTilt = 25
            p.left = Arm(out: 12, forward: -5, elbow: 5)
            p.right = Arm(out: 12, forward: -5, elbow: 5)
            p.leftLeg = Leg(out: 14, forward: 85, knee: 80)
            p.rightLeg = Leg(out: 14, forward: 85, knee: 85)
            p.detail.leftFingers = Hands.loose
            p.detail.rightFingers = Hands.loose
        }),
    ])

    static let groups: [PoseGroup] = [standingPoses, movingPoses, sittingPoses, moodsPoses, ridingAndDrivingPoses, martialArtsPoses, shootingPoses, lyingPoses, slumpedDeadPoses]
}
