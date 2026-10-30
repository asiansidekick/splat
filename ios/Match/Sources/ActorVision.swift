import CoreGraphics
import CoreImage
import Vision

/// Finds people in a picture with Vision, on the device and offline: faces with their eyes, nose
/// and mouth, and bodies with their shoulders, neck and hips. This finds faces; it never works out
/// who anyone is.
enum ActorVision {
    /// Everyone found, faces and bodies, in 0...1 picture points (y down).
    static func people(in image: CIImage) -> (faces: [ActorPose], bodies: [ActorPose]) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return ([], []) }
        // Vision counts from the image's own origin, so start it at zero.
        let picture = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let faceRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(ciImage: picture, options: [:])
        try? handler.perform([faceRequest, bodyRequest])
        let size = extent.size
        let faces = (faceRequest.results ?? []).compactMap { face(from: $0, size: size) }
        let bodies = (bodyRequest.results ?? []).compactMap(body(from:))
        return (faces, bodies)
    }

    /// Vision's points count up from the bottom; ours count down from the top.
    private static func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }

    private static func face(from observation: VNFaceObservation, size: CGSize) -> ActorPose? {
        guard let landmarks = observation.landmarks else { return nil }
        func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let points = region.pointsInImage(imageSize: size)
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return flip(CGPoint(x: sum.x / CGFloat(points.count) / size.width, y: sum.y / CGFloat(points.count) / size.height))
        }
        guard let eyeA = centre(landmarks.leftPupil) ?? centre(landmarks.leftEye),
            let eyeB = centre(landmarks.rightPupil) ?? centre(landmarks.rightEye),
            let nose = centre(landmarks.nose) ?? centre(landmarks.noseCrest)
        else { return nil }
        let box = observation.boundingBox
        return ActorPose(
            kind: .face,
            left: eyeA.x <= eyeB.x ? eyeA : eyeB,
            right: eyeA.x <= eyeB.x ? eyeB : eyeA,
            middle: nose,
            lower: centre(landmarks.outerLips) ?? centre(landmarks.innerLips),
            box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
    }

    private static func body(from observation: VNHumanBodyPoseObservation) -> ActorPose? {
        func joint(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let point = try? observation.recognizedPoint(name), point.confidence > 0.3 else { return nil }
            return flip(point.location)
        }
        guard let a = joint(.leftShoulder), let b = joint(.rightShoulder) else { return nil }
        let neck = joint(.neck) ?? CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        var hips: CGPoint?
        if let l = joint(.leftHip), let r = joint(.rightHip) { hips = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2) }
        let all = (try? observation.recognizedPoints(.all))?.values.filter { $0.confidence > 0.3 }.map { flip($0.location) } ?? [a, b]
        let xs = all.map(\.x), ys = all.map(\.y)
        let box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                         width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        return ActorPose(
            kind: .body,
            left: a.x <= b.x ? a : b,
            right: a.x <= b.x ? b : a,
            middle: neck,
            lower: hips,
            box: box)
    }
}
