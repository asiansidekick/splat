// Tests for the actor lock and the guide's maths, run on a Mac by CI:
//   swiftc -O Sources/GuideCore.swift Sources/ActorCore.swift Tests/ActorTests/main.swift -o actor-tests
//   ./actor-tests
// A head (eyes, nose tip, mouth) is photographed from different places with a simple pinhole
// camera, and the guide must say the right thing: walk round, raise or lower, step in or back,
// rotate, pan or tilt.

import CoreGraphics
import Foundation
import simd

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS  " : "FAIL  ") + message)
    if !condition { failures += 1 }
}

func close(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 1e-4) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

// MARK: A head and a camera

/// Metres, y up, the actor at the origin looking along +z (towards the first camera).
let leftEye = SIMD3<Double>(-0.032, 0, 0)
let rightEye = SIMD3<Double>(0.032, 0, 0)
let noseTip = SIMD3<Double>(0, -0.035, 0.03)
let mouth = SIMD3<Double>(0, -0.07, 0.008)

/// A photo (0...1 across and down, square) of the head from `camera`, aimed at `target`, turned
/// `roll` degrees clockwise in the picture.
func photo(from camera: SIMD3<Double>, target: SIMD3<Double> = SIMD3(0, -0.03, 0), roll: Double = 0,
           shift: CGPoint = .zero, aspect: CGFloat = 1) -> ActorPose {
    let forward = simd_normalize(target - camera)
    let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
    let up = simd_cross(right, forward)
    let focal = 1.6
    func project(_ p: SIMD3<Double>) -> CGPoint {
        let d = p - camera
        let x = simd_dot(d, right), y = simd_dot(d, up), z = simd_dot(d, forward)
        // In even units (height scaled to width), then turned and shifted, then to 0...1.
        var u = focal * x / z
        var v = -focal * y / z
        let r = roll * .pi / 180
        (u, v) = (u * cos(r) - v * sin(r), u * sin(r) + v * cos(r))
        return CGPoint(x: 0.5 + u + shift.x, y: (0.5 / aspect + v + shift.y) * aspect)
    }
    let a = project(leftEye), b = project(rightEye)
    let all = [a, b, project(noseTip), project(mouth)]
    let xs = all.map(\.x), ys = all.map(\.y)
    return ActorPose(kind: .face, left: a.x < b.x ? a : b, right: a.x < b.x ? b : a,
                     middle: project(noseTip), lower: project(mouth),
                     box: CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
}

let home = SIMD3<Double>(0, -0.03, 0.6)
let reference = photo(from: home)

func cues(_ live: ActorPose, aspect: CGFloat = 1, ref: ActorPose = reference) -> [GuideCue] {
    guard let reading = ActorMatch.reading(reference: ref, live: live, aspect: aspect) else { return [] }
    return reading.cues.map(\.cue)
}

// MARK: Same place

do {
    let reading = ActorMatch.reading(reference: reference, live: photo(from: home), aspect: 1)!
    expect(reading.lined, "same place reads as lined up")
    expect(reading.actor, "reading is marked as an actor lock")
    expect(reading.corners.enumerated().allSatisfy { close($1, [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)][$0]) },
           "same place keeps the frame on the screen corners")
}

// MARK: Walking round

do {
    // The photographer has walked to their right (the actor's left).
    let live = photo(from: SIMD3(0.2, -0.03, 0.57))
    let reading = ActorMatch.reading(reference: reference, live: live, aspect: 1)!
    print("      walked right: orbit \(reading.orbit)")
    expect(cues(live).contains(.circle(.left)), "walked to the right: says walk round left")
    let back = photo(from: SIMD3(-0.2, -0.03, 0.57))
    expect(cues(back).contains(.circle(.right)), "walked to the left: says walk round right")
}

// MARK: Higher and lower

do {
    let high = photo(from: SIMD3(0, 0.15, 0.58))
    let reading = ActorMatch.reading(reference: reference, live: high, aspect: 1)!
    print("      held high: height \(reading.height)")
    expect(cues(high).contains(.height(raise: false)), "phone held higher: says lower phone")
    let low = photo(from: SIMD3(0, -0.2, 0.56))
    expect(cues(low).contains(.height(raise: true)), "phone held lower: says raise phone")
}

// MARK: Nearer and further

do {
    expect(cues(photo(from: SIMD3(0, -0.03, 0.9))).contains(.step(closer: true)), "further away: says step in")
    expect(cues(photo(from: SIMD3(0, -0.03, 0.45))).contains(.step(closer: false)), "too close: says step back")
    let far = ActorMatch.reading(reference: reference, live: photo(from: SIMD3(0, -0.03, 0.9)), aspect: 1)!
    expect(far.biggest == .step(closer: true), "further away: stepping in comes first")
    expect(abs(far.orbit) < GuideReading.orbitTolerance, "further away: no walking round")
}

// MARK: Twisted and aimed off

do {
    let twisted = photo(from: home, roll: 10)
    expect(cues(twisted) == [.rotate(clockwise: true)], "picture turned clockwise: only says rotate clockwise")
    expect(cues(photo(from: home, roll: -10)) == [.rotate(clockwise: false)], "picture turned anticlockwise: only says rotate anticlockwise")
    expect(cues(photo(from: home, shift: CGPoint(x: 0.12, y: 0))) == [.pan(.right)], "actor too far right in frame: only says pan right")
    expect(cues(photo(from: home, shift: CGPoint(x: -0.12, y: 0))) == [.pan(.left)], "actor too far left in frame: only says pan left")
    expect(cues(photo(from: home, shift: CGPoint(x: 0, y: -0.12))) == [.tilt(.up)], "actor too high in frame: only says tilt up")
    expect(cues(photo(from: home, shift: CGPoint(x: 0, y: 0.12))) == [.tilt(.down)], "actor too low in frame: only says tilt down")
}

// MARK: Tall pictures

do {
    let aspect: CGFloat = 9.0 / 19.5
    let ref = photo(from: home, aspect: aspect)
    expect(ActorMatch.reading(reference: ref, live: photo(from: home, aspect: aspect), aspect: aspect)!.lined,
           "tall picture, same place: lined up")
    expect(cues(photo(from: home, roll: 8, aspect: aspect), aspect: aspect, ref: ref) == [.rotate(clockwise: true)],
           "tall picture, turned: only says rotate")
    expect(cues(photo(from: SIMD3(0, -0.03, 0.9), aspect: aspect), aspect: aspect, ref: ref).contains(.step(closer: true)),
           "tall picture, further: says step in")
}

// MARK: Pinning the ghost

do {
    let from = (CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.5, y: 0.42))
    let to = (CGPoint(x: 0.55, y: 0.6), CGPoint(x: 0.7, y: 0.5))
    for aspect: CGFloat in [1, 0.46, 2.1] {
        let map = Similarity(from: from, to: to, aspect: aspect)
        expect(close(map.apply(from.0), to.0) && close(map.apply(from.1), to.1), "similarity lands the pair (aspect \(aspect))")
    }
    for turns in -1...3 {
        for mirrored in [false, true] {
            let screen = ScreenMap(size: CGSize(width: 390, height: 844), quarterTurns: turns, mirrored: mirrored)
            let p = CGPoint(x: 0.23, y: 0.71)
            expect(close(screen.toPhoto(screen.toScreen(p)), p), "screen and back: turns \(turns), mirrored \(mirrored)")
            // The ghost transform is about the screen's middle, as SwiftUI's scale and rotation are.
            let t = screen.ghostTransform(from: from, to: to)
            let centre = CGPoint(x: 195, y: 422)
            func moved(_ q: CGPoint) -> CGPoint {
                let s = screen.toScreen(q)
                let x = s.x - centre.x, y = s.y - centre.y
                let c = cos(t.angle) * t.scale, n = sin(t.angle) * t.scale
                return CGPoint(x: centre.x + c * x - n * y + t.offset.width, y: centre.y + n * x + c * y + t.offset.height)
            }
            expect(close(moved(from.0), screen.toScreen(to.0), 0.01) && close(moved(from.1), screen.toScreen(to.1), 0.01),
                   "ghost lands on the actor: turns \(turns), mirrored \(mirrored)")
        }
    }
    let upright = ScreenMap(size: CGSize(width: 100, height: 200), quarterTurns: 1, mirrored: false)
    expect(close(upright.toScreen(CGPoint(x: 0, y: 0)), CGPoint(x: 100, y: 0)), "a quarter turn puts the photo's top left at the screen's top right")
}

// MARK: Directions on screen

do {
    expect(GuideCue.screen(.left, turns: 0, mirrored: false) == .left, "no turn: left stays left")
    expect(GuideCue.screen(.left, turns: 0, mirrored: true) == .right, "mirror: left shows right")
    expect(GuideCue.screen(.up, turns: 1, mirrored: false) == .right, "quarter turn: up shows right")
    expect(GuideCue.screen(.up, turns: -1, mirrored: false) == .left, "quarter turn back: up shows left")
}

// MARK: Picking an actor

do {
    func person(_ x: CGFloat, _ size: CGFloat) -> ActorPose {
        ActorPose(kind: .face, left: CGPoint(x: x - size / 4, y: 0.4), right: CGPoint(x: x + size / 4, y: 0.4),
                  middle: CGPoint(x: x, y: 0.45), lower: CGPoint(x: x, y: 0.5),
                  box: CGRect(x: x - size / 2, y: 0.3, width: size, height: size))
    }
    let people = [person(0.2, 0.1), person(0.5, 0.2), person(0.8, 0.1)]
    expect(ActorMatch.pick(people, near: CGPoint(x: 0.82, y: 0.35), like: nil) == 2, "a tap picks the person tapped")
    expect(ActorMatch.pick(people, near: nil, like: person(0.22, 0.1)) == 0, "with no tap, the one most like the reference")
    expect(ActorMatch.pick(people, near: nil, like: nil) == 1, "with nothing else, the biggest")
    expect(ActorMatch.pick([], near: nil, like: nil) == nil, "nobody, no pick")
}

// MARK: Body (costume)

do {
    func body(_ shift: CGFloat) -> ActorPose {
        ActorPose(kind: .body, left: CGPoint(x: 0.4 + shift, y: 0.3), right: CGPoint(x: 0.6 + shift, y: 0.3),
                  middle: CGPoint(x: 0.5 + shift, y: 0.28), lower: CGPoint(x: 0.5 + shift, y: 0.6),
                  box: CGRect(x: 0.35 + shift, y: 0.2, width: 0.3, height: 0.7))
    }
    let reading = ActorMatch.reading(reference: body(0), live: body(0.1), aspect: 0.5)!
    expect(reading.orbit == 0 && reading.height == 0, "body: no walking round or height from shoulders alone")
    expect(reading.cues.map(\.cue) == [.pan(.right)], "body further right: pan right")
}

print(failures == 0 ? "All actor tests passed" : "\(failures) actor tests failed")
exit(failures == 0 ? 0 : 1)
