import Foundation
import ImageIO
import SceneKit
import simd

/// One recorded frame hung in the room where it was shot (Phil, 2026-11-13: a navigable set from recorded frames).
struct BackdropPiece: @unchecked Sendable {
    let image: CGImage
    /// Plane-to-world: the camera's pose, then out along its view to the plane's centre.
    let transform: simd_float4x4
    let width: Float
    let height: Float
}

/// Builds a "virtual set" out of a reference's frames: each photo is hung as a flat picture out along the
/// ray it was shot on, sized so that from where it was taken it looks exactly like the photo. Standing near
/// where a frame was shot, you see the recorded place around you. Offline, no training.
enum Backdrop {
    /// More frames than this are thinned evenly (memory: 1024 px × 40 frames crashed Reset on 1289 after a few openings; now 768 px × 24).
    static let maxFrames = 24
    static let maxPixels = 768
    static let fallbackDistance: Float = 3.5

    /// The pieces for every frame and snapshot of the reference. Reads files: call off the main thread.
    static func pieces(reference: Reference, mapPoints: [SIMD3<Float>]) -> [BackdropPiece] {
        var frames = reference.keyframes + reference.snapshots.map(\.frame)
        if frames.count > maxFrames {
            let step = Double(frames.count) / Double(maxFrames)
            frames = (0..<maxFrames).map { frames[Int(Double($0) * step)] }
        }
        let folder = ReferenceStore.folder(for: reference.id)
        return frames.compactMap { piece(for: $0, folder: folder, mapPoints: mapPoints) }
    }

    private static func piece(for frame: Keyframe, folder: URL, mapPoints: [SIMD3<Float>]) -> BackdropPiece? {
        guard frame.imageWidth > 0, frame.imageHeight > 0,
            let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(frame.imageFile) as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ] as CFDictionary)
        else { return nil }
        let k = frame.cameraIntrinsics
        let fx = k.columns.0.x, fy = k.columns.1.y, cx = k.columns.2.x, cy = k.columns.2.y
        guard fx > 1, fy > 1 else { return nil }
        let d = distance(for: frame, folder: folder, mapPoints: mapPoints)
        let w = Float(frame.imageWidth), h = Float(frame.imageHeight)
        // Image pixel (u, v) sits at camera x = (u - cx) / fx * d, y = -(v - cy) / fy * d, z = -d.
        let centre = SIMD3<Float>((w / 2 - cx) / fx * d, -(h / 2 - cy) / fy * d, -d)
        var local = matrix_identity_float4x4
        local.columns.3 = SIMD4(centre, 1)
        return BackdropPiece(image: image, transform: frame.cameraToWorld * local, width: w / fx * d, height: h / fy * d)
    }

    /// How far out the picture hangs: the median real depth of the frame, else the median distance of the
    /// room map's points that fall inside the frame, else a middling guess.
    static func distance(for frame: Keyframe, folder: URL, mapPoints: [SIMD3<Float>]) -> Float {
        if let file = frame.depthFile, frame.depthWidth > 0, frame.depthHeight > 0,
            let data = try? Data(contentsOf: folder.appendingPathComponent(file)) {
            let depth = DepthMap.floats(data)
            if depth.count == frame.depthWidth * frame.depthHeight {
                let good = depth.filter { $0 >= 0.3 && $0 <= 8 }
                if good.count > depth.count / 10 { return clamp(median(good)) }
            }
        }
        let k = frame.cameraIntrinsics
        let fx = k.columns.0.x, fy = k.columns.1.y, cx = k.columns.2.x, cy = k.columns.2.y
        let toCamera = frame.cameraToWorld.inverse
        var inView: [Float] = []
        for point in mapPoints {
            let p = toCamera * SIMD4(point, 1)
            let z = -p.z
            guard z > 0.3, z < 12 else { continue }
            let u = fx * p.x / z + cx
            let v = cy - fy * p.y / z
            if u >= 0, u < Float(frame.imageWidth), v >= 0, v < Float(frame.imageHeight) { inView.append(z) }
        }
        if inView.count >= 20 { return clamp(median(inView)) }
        return fallbackDistance
    }

    private static func clamp(_ value: Float) -> Float { min(max(value, 1), 8) }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// The pictures as scene nodes, ready to add to the room.
    @MainActor static func nodes(from pieces: [BackdropPiece]) -> [SCNNode] {
        pieces.map { piece in
            let plane = SCNPlane(width: CGFloat(piece.width), height: CGFloat(piece.height))
            let material = SCNMaterial()
            material.diffuse.contents = piece.image
            material.lightingModel = .constant
            material.isDoubleSided = false
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.simdTransform = piece.transform
            return node
        }
    }
}
