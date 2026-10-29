import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

/// A coloured 3D point cloud of the reference set, built on the device from the keyframes' LiDAR
/// depth and photos. It sits in the reference's room coordinates, so it lines up with the real
/// set from wherever you stand, unlike a photo, which only lines up from where it was taken. The
/// maths lives in `GhostCore`, where the tests can reach it.
enum Ghost3D {
    static let maxPoints = 300_000
    static let maxKeyframes = 150

    struct Built: @unchecked Sendable {
        /// The surfaces, used to hide edges behind things and to spot what has gone.
        var cloud = GhostCore.Cloud()
        /// The edges of things: what the ghost draws.
        var edges = GhostCore.Cloud()
        /// What happened while building, for the feedback log.
        var note = ""
    }

    static func build(reference: Reference) -> Built {
        let folder = ReferenceStore.folder(for: reference.id)
        let withDepth = reference.keyframes.filter { $0.depthFile != nil }
        let keyframes = ReportPDF.spread(withDepth, count: maxKeyframes)
        var built = Built()
        var filled = [SIMD3<Int32>: Int32]()
        var edgeCells = [SIMD3<Int32>: Int32]()
        var noFile = 0, wrongSize = 0, readings = 0, values = 0

        for (view, keyframe) in keyframes.enumerated() {
            guard built.cloud.positions.count < maxPoints else { break }
            guard let depthFile = keyframe.depthFile,
                let data = try? Data(contentsOf: folder.appendingPathComponent(depthFile))
            else { noFile += 1; continue }
            let depth = DepthMap.floats(data)
            let w = keyframe.depthWidth
            let h = keyframe.depthHeight
            guard w > 0, depth.count == w * h else { wrongSize += 1; continue }
            values += depth.count
            let rgba = pixels(of: folder.appendingPathComponent(keyframe.imageFile), width: w, height: h)
            let camera = PinholeCamera(
                cameraToWorld: keyframe.cameraToWorld, intrinsics: keyframe.cameraIntrinsics,
                imageWidth: keyframe.imageWidth, width: w, height: h)
            readings += GhostCore.add(
                depth: depth, rgba: rgba, camera: camera, maxPoints: maxPoints, to: &built.cloud, filled: &filled)
            GhostCore.addEdges(
                GhostCore.edgePoints(depth: depth, camera: camera), view: view, maxPoints: maxPoints, to: &built.edges, filled: &edgeCells)
        }
        // With a walk round, every real edge is found from several views; lines only one view
        // found are noise.
        let allEdges = built.edges.positions.count
        if keyframes.count >= 4 { built.edges = GhostCore.agreedEdges(built.edges, filled: edgeCells, minViews: 3) }
        built.note = "\(keyframes.count) depth views (of \(reference.keyframes.count)), missing \(noFile), wrong size \(wrongSize), "
            + "\(readings) readings of \(values / 4) sampled, \(built.cloud.positions.count) points, \(built.edges.positions.count) edge points (of \(allEdges) before dropping lone ones)"
        return built
    }

    /// The tracked points ARKit kept in the saved room map, in one colour: sparser than LiDAR,
    /// but there for every reference, so the 3D ghost still shows when depth is missing.
    static func mapPoints(_ points: [SIMD3<Float>]) -> Built {
        var built = Built()
        built.cloud.positions = Array(points.prefix(maxPoints))
        built.cloud.colors = Array(repeating: SIMD3(0.55, 0.85, 1), count: built.cloud.positions.count)
        built.note = "\(built.cloud.positions.count) room map points"
        return built
    }

    /// The photo scaled down to the depth map's size, as RGBA bytes, top row first.
    private static func pixels(of url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Keeps each point's score between live checks and draws the ghost. Use from one queue.
    final class Viewer: @unchecked Sendable {
        let cloud: GhostCore.Cloud
        let edges: GhostCore.Cloud
        private var scores: [Int8]
        private let cells: [SIMD3<Int32>: Int32]
        private(set) var goneCount = 0

        init(cloud: GhostCore.Cloud, edges: GhostCore.Cloud) {
            self.cloud = cloud
            self.edges = edges
            scores = [Int8](repeating: 0, count: cloud.positions.count)
            cells = GhostCore.cells(of: cloud.positions)
        }

        /// Checks against the live LiDAR (when there is any) and draws the ghost in the live
        /// camera's image layout, ready to lay over the screen like the camera feed.
        func draw(live: DepthView?, camera: PinholeCamera, strength: Float) -> CIImage? {
            var states: [GhostCore.State]?
            if let live {
                let depthCamera = PinholeCamera(
                    cameraToWorld: live.cameraToWorld, intrinsics: live.intrinsics, imageWidth: live.imageWidth,
                    width: live.width, height: live.height)
                GhostCore.check(
                    positions: cloud.positions, scores: &scores, depth: live.depth, confidence: live.confidence,
                    camera: depthCamera, window: 2)
                let surface = GhostCore.states(scores: scores, positions: cloud.positions, cells: cells)
                states = GhostCore.edgeStates(edges: edges.positions, surfaceStates: surface, surfaceCells: cells)
            }
            let rgba = GhostCore.render(surface: cloud, edges: edges, states: states, camera: camera, strength: strength)
            // Counted from the drawing, so the banner only mentions blue lines that are showing.
            var blue = 0
            for o in stride(from: 0, to: rgba.count, by: 4) where rgba[o + 2] > 200 && rgba[o] < 100 { blue += 1 }
            goneCount = blue
            return Ghost3D.image(rgba, width: camera.width, height: camera.height)
        }
    }

    /// RGBA bytes (premultiplied, top row first) as an image whose top row is the top of the
    /// camera image, the same way round as the reference photos.
    static func image(_ rgba: [UInt8], width: Int, height: Int) -> CIImage? {
        guard rgba.count == width * height * 4, let provider = CGDataProvider(data: Data(rgba) as CFData),
            let cg = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return CIImage(cgImage: cg)
    }
}
