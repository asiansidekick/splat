// Tests that run Apple's Vision on real pictures, on a Mac, as the phone does:
//   swiftc -O Sources/GuideCore.swift Sources/ActorCore.swift Sources/ActorVision.swift \
//     Sources/Registration.swift Tests/VisionTests/main.swift -o vision-tests
//   ./vision-tests [face.jpg]
// The room guide is checked on a made-up textured picture that is shifted, zoomed and turned.
// The actor lock is checked on a photo of a face (downloaded by CI; skipped if missing).

import CoreGraphics
import CoreImage
import Foundation
import Vision

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS  " : "FAIL  ") + message)
    if !condition { failures += 1 }
}

let context = CIContext()

/// Renders, so later steps see plain pixels as the camera gives them.
func flat(_ image: CIImage) -> CIImage {
    let cg = context.createCGImage(image, from: image.extent)!
    return CIImage(cgImage: cg)
}

/// What the camera would see if it moved: the picture moved by (dx, dy) of its width (y down),
/// zoomed about its middle and turned clockwise, cropped back to the original frame.
func view(_ scene: CIImage, frame: CGRect, dx: CGFloat = 0, dy: CGFloat = 0, zoom: CGFloat = 1, turn: CGFloat = 0) -> CIImage {
    let mid = CGPoint(x: frame.midX, y: frame.midY)
    var t = CGAffineTransform(translationX: -mid.x, y: -mid.y)
    t = t.concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
    t = t.concatenating(CGAffineTransform(rotationAngle: -turn * .pi / 180))  // Core Image counts up: clockwise is negative
    t = t.concatenating(CGAffineTransform(translationX: mid.x + dx * frame.width, y: mid.y - dy * frame.width))
    return flat(scene.transformed(by: t).cropped(to: frame).transformed(by: CGAffineTransform(translationX: -frame.minX, y: -frame.minY)))
}

// MARK: Room guide

do {
    // Big blotches of grey, like a set: plenty of detail for Vision to hold on to.
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
        .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 4, kCIInputSaturationKey: 0])
    let frame = CGRect(x: 400, y: 400, width: 960, height: 720)
    let scene = flat(noise.cropped(to: frame.insetBy(dx: -500, dy: -500)))
    let reference = Registration.prepared(view(scene, frame: frame))
    func read(dx: CGFloat = 0, dy: CGFloat = 0, zoom: CGFloat = 1, turn: CGFloat = 0) -> GuideReading? {
        Registration.read(live: Registration.prepared(view(scene, frame: frame, dx: dx, dy: dy, zoom: zoom, turn: turn)), reference: reference)
    }
    if let same = read() {
        expect(same.lined, "room: same view reads as lined up (move \(same.move), scale \(same.scale), tilt \(same.tilt))")
    } else {
        expect(false, "room: same view gives a reading")
    }
    // The picture slid right: the reference's middle now shows right of centre, so move right.
    if let r = read(dx: 0.08) {
        print("      slid right: move \(r.move)")
        expect(r.biggest == .move(.right), "room: picture slid right says move right")
    } else { expect(false, "room: slid right gives a reading") }
    if let r = read(dx: -0.08) { expect(r.biggest == .move(.left), "room: picture slid left says move left") } else { expect(false, "room: slid left gives a reading") }
    if let r = read(dy: 0.08) { expect(r.biggest == .move(.down), "room: picture slid down says move down") } else { expect(false, "room: slid down gives a reading") }
    if let r = read(zoom: 1.2) {
        print("      zoomed in: scale \(r.scale)")
        expect(r.cues.contains { $0.cue == .step(closer: false) }, "room: looks bigger says step back")
    } else { expect(false, "room: zoomed gives a reading") }
    if let r = read(zoom: 0.85) { expect(r.cues.contains { $0.cue == .step(closer: true) }, "room: looks smaller says step in") } else { expect(false, "room: zoomed out gives a reading") }
    if let r = read(turn: 6) {
        print("      turned: tilt \(r.tilt)")
        expect(r.cues.contains { $0.cue == .rotate(clockwise: true) }, "room: picture turned clockwise says rotate clockwise")
    } else { expect(false, "room: turned gives a reading") }
}

// MARK: Actor lock on a real face

let facePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "face.jpg"
if let photo = CIImage(contentsOf: URL(fileURLWithPath: facePath)) {
    let upright = flat(photo)
    let width = upright.extent.width, height = upright.extent.height
    let found = ActorVision.people(in: Registration.scaled(upright, to: Registration.actorWidth))
    expect(!found.faces.isEmpty, "face found in the photo (\(found.faces.count) faces, \(found.bodies.count) bodies)")
    if let face = found.faces.max(by: { $0.box.area < $1.box.area }) {
        print("      eyes \(face.left) \(face.right), nose \(face.middle), mouth \(String(describing: face.lower)), box \(face.box)")
        expect(face.left.x < face.right.x, "eyes in order left to right")
        expect(face.middle.y > face.centre.y, "nose below the eyes (y counts down)")
        if let mouth = face.lower { expect(mouth.y > face.middle.y, "mouth below the nose") }
        expect(face.box.contains(face.centre) && face.box.contains(face.middle), "face box holds the eyes and nose")
        let aspect = width / height
        // Same photo: lined up.
        if let r = ActorMatch.reading(reference: face, live: face, aspect: aspect) { expect(r.lined, "same face: lined up") }

        // The camera twisted: the picture turned 8 degrees clockwise about its middle.
        let mid = CGPoint(x: width / 2, y: height / 2)
        let turned = flat(upright.transformed(by: CGAffineTransform(translationX: -mid.x, y: -mid.y)
            .concatenating(CGAffineTransform(rotationAngle: -8 * .pi / 180))
            .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y))).cropped(to: upright.extent))
        if let live = ActorVision.people(in: Registration.scaled(turned, to: Registration.actorWidth)).faces.max(by: { $0.box.area < $1.box.area }),
            let r = ActorMatch.reading(reference: face, live: live, aspect: aspect)
        {
            print("      turned photo: tilt \(r.tilt)")
            expect(r.cues.contains { $0.cue == .rotate(clockwise: true) }, "real face turned clockwise: says rotate clockwise")
        } else { expect(false, "face found in the turned photo") }

        // The camera further away: the picture shrunk to 80% about its middle, grey round it.
        let small = flat(upright.transformed(by: CGAffineTransform(translationX: -mid.x, y: -mid.y)
            .concatenating(CGAffineTransform(scaleX: 0.8, y: 0.8))
            .concatenating(CGAffineTransform(translationX: mid.x, y: mid.y)))
            .composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: upright.extent)))
        if let live = ActorVision.people(in: Registration.scaled(small, to: Registration.actorWidth)).faces.max(by: { $0.box.area < $1.box.area }),
            let r = ActorMatch.reading(reference: face, live: live, aspect: aspect)
        {
            print("      smaller photo: scale \(r.scale)")
            expect(r.cues.contains { $0.cue == .step(closer: true) }, "real face further away: says step in")
        } else { expect(false, "face found in the smaller photo") }

        // The actor off to the right of the frame: the picture slid right.
        let slid = flat(upright.transformed(by: CGAffineTransform(translationX: width * 0.12, y: 0))
            .composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: upright.extent)).cropped(to: upright.extent))
        if let live = ActorVision.people(in: Registration.scaled(slid, to: Registration.actorWidth)).faces.max(by: { $0.box.area < $1.box.area }),
            let r = ActorMatch.reading(reference: face, live: live, aspect: aspect)
        {
            expect(r.biggest == .pan(.right), "real face further right in frame: says pan right")
        } else { expect(false, "face found in the slid photo") }

        // A mirror image still gives the eyes left to right.
        let mirrored = flat(upright.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -width, y: 0)))
        if let live = ActorVision.people(in: Registration.scaled(mirrored, to: Registration.actorWidth)).faces.first {
            expect(live.left.x < live.right.x, "mirror image: eyes still left to right")
        }
    }
} else {
    print("SKIP  no face photo at \(facePath)")
}

print(failures == 0 ? "All Vision tests passed" : "\(failures) Vision tests failed")
exit(failures == 0 ? 0 : 1)
