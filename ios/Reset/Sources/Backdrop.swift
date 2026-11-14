import Foundation
import ImageIO
import SceneKit
import simd

/// One recorded frame hung in the room where it was shot (Phil, 2026-11-13: a navigable set from recorded frames).
struct BackdropPiece: @unchecked Sendable {
    let image: CGImage
    /// Plane-to-world: the camera's pose, then out along its view to the plane's centre.
    let transform: simd_float4x4
    /// Where the camera was, and which way it faced, when the frame was shot.
    let camera: simd_float4x4
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
    static func pieces(reference: Reference, mapPoints: [SIMD3<Float>], limit: Int = maxFrames) -> [BackdropPiece] {
        var frames = reference.keyframes + reference.snapshots.map(\.frame)
        if frames.count > limit {
            let step = Double(frames.count) / Double(limit)
            frames = (0..<limit).map { frames[Int(Double($0) * step)] }
        }
        let folder = ReferenceStore.folder(for: reference.id)
        return frames.compactMap { piece(for: $0, folder: folder, mapPoints: mapPoints) }
    }

    /// One frame hung `distance` metres out with no feathering and a larger picture: the ghost, locked to the room
    /// at the display's own rate instead of redrawn as a bitmap a few times a second (Phil, 2026-11-14: jitter).
    static func ghostPiece(for frame: Keyframe, folder: URL, distance: Float) -> BackdropPiece? {
        piece(for: frame, folder: folder, mapPoints: [], fixedDistance: distance, feather: false, pixels: 1280)
    }

    /// The picture with its outer tenth fading to clear, so neighbouring frames blend instead of showing hard seams.
    private static func feathered(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        let fx = max(Float(w) * 0.1, 1), fy = max(Float(h) * 0.1, 1)
        var gray = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            let ay = min(1, Float(min(y, h - 1 - y)) / fy)
            for x in 0..<w {
                let ax = min(1, Float(min(x, w - 1 - x)) / fx)
                gray[y * w + x] = UInt8(255 * min(ax, ay))
            }
        }
        let mask: CGImage? = gray.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
        guard let mask,
            let context = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        context.clip(to: rect, mask: mask)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    private static func piece(
        for frame: Keyframe, folder: URL, mapPoints: [SIMD3<Float>],
        fixedDistance: Float? = nil, feather: Bool = true, pixels: Int = maxPixels
    ) -> BackdropPiece? {
        guard frame.imageWidth > 0, frame.imageHeight > 0,
            let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(frame.imageFile) as CFURL, nil),
            let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ] as CFDictionary)
        else { return nil }
        let image = feather ? feathered(raw) : raw
        let k = frame.cameraIntrinsics
        let fx = k.columns.0.x, fy = k.columns.1.y, cx = k.columns.2.x, cy = k.columns.2.y
        guard fx > 1, fy > 1 else { return nil }
        let d = fixedDistance ?? distance(for: frame, folder: folder, mapPoints: mapPoints)
        let w = Float(frame.imageWidth), h = Float(frame.imageHeight)
        // Image pixel (u, v) sits at camera x = (u - cx) / fx * d, y = -(v - cy) / fy * d, z = -d.
        let centre = SIMD3<Float>((w / 2 - cx) / fx * d, -(h / 2 - cy) / fy * d, -d)
        var local = matrix_identity_float4x4
        local.columns.3 = SIMD4(centre, 1)
        return BackdropPiece(image: image, transform: frame.cameraToWorld * local, camera: frame.cameraToWorld, width: w / fx * d, height: h / fy * d)
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
            // Feathered edges blend where frames overlap; no depth writes, so overlapping pictures never flicker against each other.
            material.writesToDepthBuffer = false
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.simdTransform = piece.transform
            return node
        }
    }
}
