// Tests that run Apple's Vision on real pictures, on a Mac, as the phone does:
//   swiftc -O Sources/GuideCore.swift Sources/ActorCore.swift Sources/ActorVision.swift \
//     Sources/Registration.swift Sources/OverlayFit.swift Tests/VisionTests/main.swift -o vision-tests
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
    diagnose("noise slid right", live: Registration.prepared(view(scene, frame: frame, dx: 0.08)), reference: reference)
    diagnose("noise slid right, rendered", live: flat(Registration.prepared(view(scene, frame: frame, dx: 0.08))), reference: flat(reference))
    // Random speckle is a picture Vision can't match. It must never read as lined up when the
    // view has moved (it used to, because Vision hands back "no change").
    let moved = read(dx: 0.08)
    expect(moved == nil || !moved!.lined, "room: a picture Vision can't match never reads as lined up")
}

// MARK: Raw Vision registration, printed to see what it gives

func diagnose(_ name: String, live: CIImage, reference: CIImage) {
    let handler = VNImageRequestHandler(ciImage: reference, options: [:])
    let homography = VNHomographicImageRegistrationRequest(targetedCIImage: live)
    let translation = VNTranslationalImageRegistrationRequest(targetedCIImage: live)
    do { try handler.perform([homography, translation]) } catch { print("      \(name): error \(error)") }
    let h = homography.results?.first
    let t = translation.results?.first
    print("      \(name): live \(live.extent) ref \(reference.extent)")
    print("        homography conf \(h?.confidence ?? -1) warp \(String(describing: h?.warpTransform))")
    print("        translation conf \(t?.confidence ?? -1) \(String(describing: t?.alignmentTransform))")
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
        // The room guide on a real photo, as if the camera had moved.
        let frame = upright.extent.insetBy(dx: width * 0.15, dy: height * 0.15)
        let ref = Registration.prepared(view(upright, frame: frame))
        func room(dx: CGFloat = 0, dy: CGFloat = 0, zoom: CGFloat = 1, turn: CGFloat = 0) -> GuideReading? {
            Registration.read(live: Registration.prepared(view(upright, frame: frame, dx: dx, dy: dy, zoom: zoom, turn: turn)), reference: ref)
        }
        diagnose("photo slid right", live: Registration.prepared(view(upright, frame: frame, dx: 0.06)), reference: ref)
        if let r = room() { expect(r.lined, "room on a photo: same view lined up") } else { expect(false, "room on a photo: same view gives a reading") }
        for (name, dx, dy, want) in [("right", 0.06, 0.0, GuideCue.move(.right)), ("left", -0.06, 0.0, .move(.left)),
                                     ("down", 0.0, 0.06, .move(.down)), ("up", 0.0, -0.06, .move(.up))] as [(String, CGFloat, CGFloat, GuideCue)] {
            if let r = room(dx: dx, dy: dy) {
                print("      photo slid \(name): move \(r.move)")
                expect(r.biggest == want, "room on a photo: slid \(name) says \(want)")
                expect(abs(r.move.dx - dx) < 0.015 && abs(r.move.dy - dy) < 0.015, "room on a photo: slid \(name) measured within 1.5%")
            } else { expect(false, "room on a photo: slid \(name) gives a reading") }
        }
        if let r = room(zoom: 1.15) {
            print("      photo zoomed in: scale \(r.scale)")
            expect(r.cues.contains { $0.cue == .step(closer: false) }, "room on a photo: zoomed in says step back")
        } else { expect(false, "room on a photo: zoomed in gives a reading") }
        if let r = room(zoom: 0.87) {
            print("      photo zoomed out: scale \(r.scale)")
            expect(r.cues.contains { $0.cue == .step(closer: true) }, "room on a photo: zoomed out says step in")
        } else { expect(false, "room on a photo: zoomed out gives a reading") }
        diagnose("photo turned", live: Registration.prepared(view(upright, frame: frame, turn: 6)), reference: ref)
        if let r = room(turn: 6) {
            print("      photo turned: tilt \(r.tilt)")
            expect(r.cues.contains { $0.cue == .rotate(clockwise: true) }, "room on a photo: turned clockwise says rotate clockwise")
        } else { expect(false, "room on a photo: turned gives a reading") }
        // An imported photo from a longer lens: a tighter, off-centre part of the view, graded
        // differently. Fitting must find it at about 1/1.6 the size, right and down of the middle.
        func region(dx: CGFloat, dy: CGFloat, size k: CGFloat, grade: Bool) -> CIImage {
            let w = frame.width * k, h = frame.height * k
            let r = CGRect(x: frame.midX + dx * frame.width - w / 2, y: frame.midY - dy * frame.height - h / 2, width: w, height: h)
            var picture = upright.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY)
                .concatenating(CGAffineTransform(scaleX: frame.width / w, y: frame.height / h)))
            if grade {
                picture = picture.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.3, kCIInputBrightnessKey: 0.06])
            }
            return flat(picture)
        }
        let liveView = Registration.prepared(view(upright, frame: frame))
        let tele = Registration.prepared(region(dx: 0.08, dy: 0.05, size: 1 / 1.6, grade: true))
        if let fit = Registration.fitRoom(live: liveView, reference: tele) {
            print("      tele photo fit: \(fit)")
            expect(abs(fit.scale - 1 / 1.6) < 0.05, "fit: a longer-lens photo is shrunk to about 1/1.6")
            expect(abs(fit.x - 0.08) < 0.03 && abs(fit.y - 0.05) < 0.03, "fit: and placed right and down of the middle")
            expect(Registration.correlation(Registration.fitted(tele, by: fit), liveView) > 0.5, "fit: once fitted it looks like the live view")
        } else { expect(false, "fit: a longer-lens photo is fitted") }
        let wide = Registration.prepared(region(dx: -0.04, dy: 0, size: 1.3, grade: false))
        if let fit = Registration.fitRoom(live: liveView, reference: wide) {
            print("      wide photo fit: \(fit)")
            expect(abs(fit.scale - 1.3) < 0.08, "fit: a wider photo is enlarged to about 1.3")
            expect(abs(fit.x + 0.04) < 0.03 && abs(fit.y) < 0.03, "fit: and placed a little left")
        } else { expect(false, "fit: a wider photo is fitted") }
        let blank = Registration.prepared(flat(CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))))
        expect(Registration.fitRoom(live: blank, reference: tele) == nil, "fit: pointed at nothing, no fit")

        // Pointed somewhere else entirely: never lined up.
        let elsewhere = Registration.prepared(flat(CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))))
        let wrong = Registration.read(live: elsewhere, reference: ref)
        expect(wrong == nil || !wrong!.lined, "room on a photo: a blank view never reads as lined up")

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

        // The imported-photo fit from the actor: the face 80% the size, so the photo shrinks to 80%.
        if let live = ActorVision.people(in: Registration.scaled(small, to: Registration.actorWidth)).faces.max(by: { $0.box.area < $1.box.area }),
            let fit = OverlayFit.from(reference: (face.left, face.right), live: (live.left, live.right), aspect: aspect)
        {
            print("      actor fit: \(fit)")
            expect(abs(fit.scale - 0.8) < 0.05, "actor fit: a face 80% the size fits at about 80%")
            let landed = fit.place(face.centre)
            expect(abs(landed.x - live.centre.x) < 0.01 && abs(landed.y - live.centre.y) < 0.01, "actor fit: the eyes land on the live eyes")
        } else { expect(false, "actor fit: worked out from the face") }

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
