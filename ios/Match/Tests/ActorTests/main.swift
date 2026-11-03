// Tests for the actor lock and the guide's maths, run on a Mac by CI:
//   swiftc -O Sources/GuideCore.swift Sources/ActorCore.swift Sources/Depth.swift Sources/Cast.swift Tests/ActorTests/main.swift -o actor-tests
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

// MARK: LiDAR depth

do {
    // 4 wide, 3 tall, numbered so turns can be followed.
    let grid = DepthGrid(width: 4, height: 3, values: (0..<12).map(Float.init))
    let turned = grid.rotated(quarterTurns: 1)
    expect(turned.width == 3 && turned.height == 4, "a quarter turn swaps width and height")
    expect(turned.value(2, 0) == 0, "a quarter turn puts the top left at the top right")
    expect(turned.value(0, 0) == 8, "a quarter turn brings the bottom left to the top left")
    expect(grid.rotated(quarterTurns: 4) == grid && grid.rotated(quarterTurns: -1) == grid.rotated(quarterTurns: 3),
           "four quarter turns change nothing")
    let tall = grid.cropped(aspect: 0.5)
    expect(tall.width == 2 && tall.height == 3 && tall.value(0, 0) == 1, "cropping keeps the middle")
    expect(DepthGrid(data: grid.data) == grid, "saved depth reads back the same")
    expect(DepthGrid(data: Data([1, 2, 3])) == nil, "a broken depth file reads as nothing")

    // A wall at 2 m with the actor's face at 1.2 m in the middle.
    var values = [Float](repeating: 2, count: 256 * 192)
    for y in 80..<112 { for x in 112..<144 { values[y * 256 + x] = 1.2 } }
    values[96 * 256 + 128] = .nan
    let room = DepthGrid(width: 256, height: 192, values: values)
    expect(abs((room.distance(at: CGPoint(x: 0.5, y: 0.5)) ?? 0) - 1.2) < 0.001, "distance to the face in the middle")
    expect(abs((room.distance(at: CGPoint(x: 0.1, y: 0.1)) ?? 0) - 2) < 0.001, "distance to the wall")
    expect(abs((room.distance(at: CGPoint(x: 0.5, y: 0.5), aspect: 9.0 / 19.5) ?? 0) - 1.2) < 0.001,
           "distance in the middle of a tall crop")
    expect(DepthGrid(width: 10, height: 10, values: [Float](repeating: 0, count: 100)).distance(at: CGPoint(x: 0.5, y: 0.5)) == nil,
           "no readings, no distance")

    // The guide goes by LiDAR when it can: 30 cm too far back, though the face looks the same size.
    let reading = ActorMatch.reading(reference: reference, live: photo(from: home), aspect: 1,
                                     referenceDistance: 1.0, liveDistance: 1.3)!
    expect(reading.cues.map(\.cue) == [.step(closer: true)], "LiDAR 30 cm further: says step in")
    expect(abs((reading.stepMetres ?? 0) - 0.3) < 1e-9, "LiDAR says how far: 30 cm")
    expect(ActorMatch.reading(reference: reference, live: photo(from: home), aspect: 1, referenceDistance: 1.0, liveDistance: 1.02)!.lined,
           "LiDAR 2 cm off: lined up")
}

// MARK: Portrait and landscape

do {
    let box = Fit.centredBox(outer: 19.5 / 9, inner: 3.0 / 4)
    expect(abs(box.height - 1) < 1e-9 && abs(box.width - (0.75 / (19.5 / 9))) < 1e-9 && abs(box.midX - 0.5) < 1e-9,
           "portrait reference on a landscape screen: full height, centred")
    let wide = Fit.centredBox(outer: 9 / 19.5, inner: 4.0 / 3)
    expect(abs(wide.width - 1) < 1e-9 && abs(wide.midY - 0.5) < 1e-9, "landscape reference on a portrait screen: full width, centred")
    expect(Fit.showsWhole(reference: 0.75, screen: 2.1) && Fit.showsWhole(reference: 1.33, screen: 0.46), "other way round: shown whole")
    expect(!Fit.showsWhole(reference: 0.75, screen: 0.46) && !Fit.showsWhole(reference: 1.33, screen: 2.1), "same way round: fills the screen")
    expect(!Fit.showsWhole(reference: 1, screen: 2.1), "square reference: fills the screen")

    for turns in [0, 1, -1] {
        let screen = ScreenMap(size: CGSize(width: 844, height: 390), quarterTurns: turns, mirrored: false, inner: box)
        let p = CGPoint(x: 0.3, y: 0.8)
        expect(close(screen.toPhoto(screen.toScreen(p)), p), "box: screen and back, turns \(turns)")
        let from = (CGPoint(x: 0.4, y: 0.3), CGPoint(x: 0.6, y: 0.3))
        let to = (CGPoint(x: 0.45, y: 0.35), CGPoint(x: 0.62, y: 0.37))
        let t = screen.ghostTransform(from: from, to: to)
        let centre = CGPoint(x: 422, y: 195)
        func moved(_ q: CGPoint) -> CGPoint {
            let s = screen.toScreen(q)
            let x = s.x - centre.x, y = s.y - centre.y
            let c = cos(t.angle) * t.scale, n = sin(t.angle) * t.scale
            return CGPoint(x: centre.x + c * x - n * y + t.offset.width, y: centre.y + n * x + c * y + t.offset.height)
        }
        expect(close(moved(from.0), screen.toScreen(to.0), 0.01) && close(moved(from.1), screen.toScreen(to.1), 0.01),
               "box: ghost lands on the actor, turns \(turns)")
    }
    let upright = ScreenMap(size: CGSize(width: 844, height: 390), quarterTurns: 0, mirrored: false, inner: box)
    expect(close(upright.toScreen(CGPoint(x: 0, y: 0)), CGPoint(x: box.minX * 844, y: 0)), "box: the reference's top left sits at the box's top left")

    // A portrait reference and the same view checked in landscape: the live box is the reference's
    // shape, so the guide reads lined up, and still finds a twist.
    let aspect: CGFloat = 0.75
    let ref = photo(from: home, aspect: aspect)
    expect(ActorMatch.reading(reference: ref, live: photo(from: home, aspect: aspect), aspect: aspect)!.lined,
           "portrait reference checked in landscape: lined up")
    expect(cues(photo(from: home, roll: 9, aspect: aspect), aspect: aspect, ref: ref) == [.rotate(clockwise: true)],
           "portrait reference checked in landscape, turned: only says rotate")

    // Depth read through the box lands in the middle of the screen's picture.
    let middle = box.point(CGPoint(x: 0.5, y: 0.5))
    expect(close(middle, CGPoint(x: 0.5, y: 0.5)), "the box's middle is the screen's middle")
}

// MARK: Fitting imported photos

do {
    // The actor's eyes are half the size live and lower down: the photo shrinks to half and moves.
    let fit = OverlayFit.from(reference: (CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4)),
                              live: (CGPoint(x: 0.45, y: 0.6), CGPoint(x: 0.55, y: 0.6)), aspect: 0.75)
    expect(fit.map { abs($0.scale - 0.5) < 1e-6 } == true, "fit: eyes half as far apart give half size")
    if let fit {
        expect(close(fit.place(CGPoint(x: 0.4, y: 0.4)), CGPoint(x: 0.45, y: 0.6)) && close(fit.place(CGPoint(x: 0.6, y: 0.4)), CGPoint(x: 0.55, y: 0.6)),
               "fit: the photo's eyes land on the live eyes")
    }
    // Tall pictures: a slant between the eyes is measured in real proportions.
    let slanted = OverlayFit.from(reference: (CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.5)),
                                  live: (CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.6, y: 0.4)), aspect: 0.5)
    expect(slanted.map { abs($0.scale - 0.5) < 1e-6 } == true, "fit: lengths count width and height in the same units")
    expect(OverlayFit.from(reference: (CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)), live: (.zero, CGPoint(x: 1, y: 1)), aspect: 1) == nil,
           "fit: one point can't give a size")
    expect(OverlayFit.from(reference: (CGPoint(x: 0.49, y: 0.5), CGPoint(x: 0.5, y: 0.5)), live: (.zero, CGPoint(x: 1, y: 0)), aspect: 1) == nil,
           "fit: a wild answer is refused")
    // The screen crops a wide photo to a tall screen: offsets convert both ways.
    let share = OverlayFit.cropShare(photo: 16.0 / 9.0, crop: 9.0 / 16.0)
    expect(abs(share.width - (9.0 / 16.0) / (16.0 / 9.0)) < 1e-9 && share.height == 1, "fit: crop share of a wide photo on a tall screen")
    let whole = OverlayFit(scale: 0.7, x: 0.05, y: -0.02)
    let back = whole.inCrop(share).fromCrop(share)
    expect(abs(back.x - whole.x) < 1e-9 && abs(back.y - whole.y) < 1e-9 && back.scale == whole.scale, "fit: crop units and back agree")
    expect(OverlayFit.cropShare(photo: 1.5, crop: nil) == CGSize(width: 1, height: 1), "fit: no crop keeps it all")
    let a = OverlayFit(scale: 1.0, x: 0.1, y: 0.1)
    expect(a.agrees(with: OverlayFit(scale: 1.03, x: 0.12, y: 0.09)) && !a.agrees(with: OverlayFit(scale: 1.2, x: 0.1, y: 0.1)),
           "fit: close answers agree, far ones don't")
}

// MARK: Trimming black bars

do {
    func picture(width: Int, height: Int, bars: (top: Int, bottom: Int, left: Int, right: Int), edgeShade: CGFloat = 0) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Context y counts up: the top bar is at the high end.
        let inner = CGRect(x: bars.left, y: bars.bottom, width: width - bars.left - bars.right, height: height - bars.top - bars.bottom)
        context.setFillColor(CGColor(red: 0.6, green: 0.5, blue: 0.4, alpha: 1))
        context.fill(inner)
        // Some dark detail inside the picture, which must not be taken for a bar.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: inner.minX + 30, y: inner.minY + 20, width: 40, height: inner.height - 40))
        return context.makeImage()!
    }
    func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 5) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance * 2 && abs(a.height - b.height) <= tolerance * 2
    }
    let letterbox = BorderTrim.content(of: picture(width: 1600, height: 1200, bars: (150, 150, 0, 0)))
    print("      letterbox kept \(letterbox)")
    expect(near(letterbox, CGRect(x: 0, y: 150, width: 1600, height: 900), 8), "bars: letterbox bars top and bottom are cut off")
    let pillar = BorderTrim.content(of: picture(width: 1600, height: 900, bars: (0, 0, 200, 260)))
    print("      pillarbox kept \(pillar)")
    expect(near(pillar, CGRect(x: 200, y: 0, width: 1140, height: 900), 8), "bars: uneven bars left and right are cut off")
    let topOnly = BorderTrim.content(of: picture(width: 800, height: 600, bars: (90, 0, 0, 0)))
    expect(near(topOnly, CGRect(x: 0, y: 90, width: 800, height: 510), 6), "bars: a top bar alone is cut off at the top (y counts down)")
    let none = BorderTrim.content(of: picture(width: 800, height: 600, bars: (0, 0, 0, 0)))
    expect(none == CGRect(x: 0, y: 0, width: 800, height: 600), "bars: a picture without bars is kept whole")
    let thin = BorderTrim.content(of: picture(width: 800, height: 600, bars: (2, 2, 0, 0)))
    expect(thin == CGRect(x: 0, y: 0, width: 800, height: 600), "bars: a hairline dark edge is left alone")
    let mostlyBlack = BorderTrim.content(of: picture(width: 800, height: 600, bars: (250, 250, 300, 300)))
    expect(mostlyBlack == CGRect(x: 0, y: 0, width: 800, height: 600), "bars: a mostly dark picture isn't cut to a sliver")
}


// MARK: LiDAR changes

do {
    func grid(_ value: (Int, Int) -> Float) -> DepthGrid {
        var values = [Float]()
        for y in 0..<40 { for x in 0..<60 { values.append(value(x, y)) } }
        return DepthGrid(width: 60, height: 40, values: values)
    }
    let room = grid { _, _ in 2.0 }
    let same = DepthChange.flags(live: room, reference: room)
    expect(!same.flags.contains { $0 != 0 }, "changes: an unchanged room flags nothing")
    // A box 20 cm nearer (added) in one block, a hole 30 cm farther (gone) in another.
    let moved = grid { x, y in
        if (10..<22).contains(x), (10..<22).contains(y) { return 1.8 }
        if (35..<50).contains(x), (15..<30).contains(y) { return 2.3 }
        return 2.0
    }
    let diff = DepthChange.flags(live: moved, reference: room)
    expect(diff.flags[15 * 60 + 15] == 1, "changes: something now nearer is red (+1)")
    expect(diff.flags[20 * 60 + 40] == -1, "changes: a surface now farther is blue (-1)")
    expect(diff.flags[2 * 60 + 2] == 0, "changes: untouched areas stay clear")
    // 3 cm of LiDAR noise is not a change.
    let noisy = grid { x, y in 2.0 + ((x + y) % 2 == 0 ? 0.03 : -0.03) }
    expect(!DepthChange.flags(live: noisy, reference: room).flags.contains { $0 != 0 }, "changes: 3 cm of noise is ignored")
    // One stray pixel is not a solid area.
    let speck = grid { x, y in x == 30 && y == 20 ? 1.0 : 2.0 }
    expect(!DepthChange.flags(live: speck, reference: room).flags.contains { $0 != 0 }, "changes: a lone speck is dropped")
    // Missing readings never flag.
    let holes = grid { _, _ in 0 }
    expect(!DepthChange.flags(live: holes, reference: room).flags.contains { $0 != 0 }, "changes: no reading, no change")
    expect(DepthChange.mask(live: moved, reference: room, aspect: nil) != nil, "changes: a mask is drawn when something moved")
    expect(DepthChange.mask(live: room, reference: room, aspect: nil) == nil, "changes: no mask when nothing moved")
    // A reference at a different resolution still compares by place.
    let coarse = DepthGrid(width: 30, height: 20, values: [Float](repeating: 2.0, count: 600))
    expect(!DepthChange.flags(live: room, reference: coarse).flags.contains { $0 != 0 }, "changes: a coarser reference map still lines up")
}

// MARK: Cast list

do {
    let one = CastList.merged([], adding: ["Sarah", " Tom ", "", "sarah"])
    expect(one.map(\.character) == ["Sarah", "Tom"], "cast: names are trimmed, blanks dropped, repeats (any case) merged")
    let again = CastList.merged(one, adding: ["TOM", "Ana"])
    expect(again.map(\.character) == ["Sarah", "Tom", "Ana"], "cast: new names are added after the ones kept")
    let round = CastList.decode(CastList.encode(again))
    expect(round == again, "cast: the list survives saving and loading")
    expect(CastList.decode("not json").isEmpty, "cast: a damaged list loads as empty")
    let old = CastList.decode("[{\"character\":\"Sam\"}]")
    expect(old.count == 1 && old[0].actor.isEmpty, "cast: an entry without an actor still loads")
}

// MARK: Pitch and roll

do {
    func rad(_ d: Double) -> Double { d * .pi / 180 }
    func near(_ a: Double?, _ b: Double, _ t: Double = 0.01) -> Bool { a.map { abs($0 - b) < t } ?? false }
    // Portrait (the photo turned 90), rear camera, phone upright: gravity is straight down the screen.
    let level = Attitude.from(gravity: (0, -1, 0), uprightAngle: 90, front: false)
    expect(near(level?.pitch, 0) && near(level?.roll, 0), "attitude: an upright phone is level")
    // Camera aimed 20 degrees up: the back of the phone tips away, so gravity gains +z.
    let up = Attitude.from(gravity: (0, -cos(rad(20)), sin(rad(20))), uprightAngle: 90, front: false)
    expect(near(up?.pitch, 20), "attitude: aiming up 20 degrees reads +20 pitch")
    let down = Attitude.from(gravity: (0, -cos(rad(15)), -sin(rad(15))), uprightAngle: 90, front: false)
    expect(near(down?.pitch, -15), "attitude: aiming down 15 degrees reads -15 pitch")
    // Phone twisted clockwise 10 degrees: gravity leans towards the phone's right edge.
    let twisted = Attitude.from(gravity: (sin(rad(10)), -cos(rad(10)), 0), uprightAngle: 90, front: false)
    expect(near(twisted?.roll, 10), "attitude: twisting clockwise reads positive roll")
    // Landscape, the sensor's own way up (phone top to the left).
    let sideways = Attitude.from(gravity: (1, 0, 0), uprightAngle: 0, front: false)
    expect(near(sideways?.roll, 0) && near(sideways?.pitch, 0), "attitude: landscape held level reads level")
    let sidewaysTwist = Attitude.from(gravity: (cos(rad(10)), sin(rad(10)), 0), uprightAngle: 0, front: false)
    expect(near(sidewaysTwist?.roll, 10), "attitude: landscape twisted clockwise reads positive roll")
    let otherSide = Attitude.from(gravity: (-1, 0, 0), uprightAngle: 180, front: false)
    expect(near(otherSide?.roll, 0), "attitude: landscape the other way up is level too")
    let upsideDown = Attitude.from(gravity: (0, 1, 0), uprightAngle: 270, front: false)
    expect(near(upsideDown?.roll, 0), "attitude: upside down is level too")
    // Front camera looks the other way: aiming it up needs gravity -z, and twists read the photo's way.
    let front = Attitude.from(gravity: (0, -cos(rad(12)), -sin(rad(12))), uprightAngle: 90, front: true)
    expect(near(front?.pitch, 12), "attitude: the front camera aims the other way round")
    let frontTwist = Attitude.from(gravity: (sin(rad(10)), -cos(rad(10)), 0), uprightAngle: 90, front: true)
    expect(near(frontTwist?.roll, -10), "attitude: the front camera's unmirrored photo twists the other way")
    expect(Attitude.from(gravity: (0, 0, -1), uprightAngle: 90, front: false) == nil, "attitude: flat on a table has no roll")
    expect(Attitude.from(gravity: (0, 0, 0), uprightAngle: 90, front: false) == nil, "attitude: no gravity, no reading")

    // What to do to match the reference.
    let reference = Attitude(pitch: 5, roll: 2)
    let now = Attitude(pitch: -3, roll: 8)
    let errors = now.errors(to: reference)
    expect(near(errors.pitch, 8) && near(errors.roll, -6), "attitude: tilt up 8, twist back 6 to match")
    let wrap = Attitude(pitch: 0, roll: 175).errors(to: Attitude(pitch: 0, roll: -175))
    expect(near(wrap.roll, 10), "attitude: twisting takes the short way round")

    // The guide's cues.
    func reading(pitch: Double? = nil, roll: Double? = nil, actor: Bool = false, turnY: CGFloat = 0, tilt: Double = 0) -> GuideReading {
        var r = GuideReading(move: .zero, turn: CGVector(dx: 0, dy: turnY), tilt: tilt, scale: 1)
        r.actor = actor
        r.pitchError = pitch
        r.rollError = roll
        return r
    }
    expect(reading(pitch: 8).biggest == .tilt(.up), "attitude cues: 8 degrees too low says tilt up")
    expect(reading(pitch: -8).biggest == .tilt(.down), "attitude cues: too high says tilt down")
    expect(reading(roll: -6).biggest == .rotate(clockwise: false), "attitude cues: twisted clockwise says rotate back")
    expect(reading(roll: 6).biggest == .rotate(clockwise: true), "attitude cues: twisted back says rotate clockwise")
    expect(reading(pitch: 1.5, roll: 2).lined, "attitude cues: inside the tolerances is lined up")
    expect(reading(pitch: 1, turnY: 0.3).lined, "attitude cues: the picture's own tilt guess is ignored when sensors say level")
    expect(reading(roll: 0, tilt: 12).lined, "attitude cues: the picture's own roll guess is ignored when sensors say level")
    expect(reading(turnY: 0.3).biggest == .tilt(.down), "attitude cues: without sensors the picture's guess still works")
    // An actor lock keeps its own aiming cue and doesn't add a second, possibly opposite, one.
    var actorMove = reading(pitch: -9, actor: true)
    actorMove.move = CGVector(dx: 0, dy: 0.2)
    expect(actorMove.cues.filter { if case .tilt = $0.cue { true } else { false } }.count == 1, "attitude cues: an actor lock shows one tilt cue, not two")
}

print(failures == 0 ? "All actor tests passed" : "\(failures) actor tests failed")
exit(failures == 0 ? 0 : 1)
