import CoreGraphics
import Foundation
import ImageIO
import SceneKit
import UIKit
import simd

/// A coloured 3D point cloud of the reference set, built on the device from the keyframes' LiDAR
/// depth and photos. Placed in the reference's room coordinates, it lines up with the real set
/// from wherever you stand, unlike a photo, which only lines up from where it was taken.
enum Ghost3D {
    /// Points closer together than this are merged.
    static let voxel: Float = 0.015  // metres
    static let maxPoints = 400_000
    static let maxKeyframes = 150
    static let maxRange: Float = 4

    struct Cloud: @unchecked Sendable {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
    }

    static func build(reference: Reference) -> Cloud {
        let folder = ReferenceStore.folder(for: reference.id)
        let withDepth = reference.keyframes.filter { $0.depthFile != nil }
        let keyframes = ReportPDF.spread(withDepth, count: maxKeyframes)
        var cloud = Cloud()
        var filled = Set<SIMD3<Int32>>()

        for keyframe in keyframes {
            guard cloud.positions.count < maxPoints,
                let depthFile = keyframe.depthFile,
                let data = try? Data(contentsOf: folder.appendingPathComponent(depthFile))
            else { continue }
            let depth = DepthMap.floats(data)
            let w = keyframe.depthWidth
            let h = keyframe.depthHeight
            guard depth.count == w * h,
                let rgba = pixels(of: folder.appendingPathComponent(keyframe.imageFile), width: w, height: h)
            else { continue }

            let scale = Float(w) / Float(keyframe.imageWidth)
            let k = keyframe.cameraIntrinsics
            let fx = k[0][0] * scale, fy = k[1][1] * scale, cx = k[2][0] * scale, cy = k[2][1] * scale
            let toWorld = keyframe.cameraToWorld

            for v in stride(from: 0, to: h, by: 2) {
                for u in stride(from: 0, to: w, by: 2) {
                    let d = depth[v * w + u]
                    guard d > 0.1, d < maxRange else { continue }
                    // ARKit camera space: x right, y up, looking down -z (same as DepthDiff).
                    let local = SIMD4<Float>((Float(u) - cx) / fx * d, -(Float(v) - cy) / fy * d, -d, 1)
                    let world = toWorld * local
                    let point = SIMD3(world.x, world.y, world.z)
                    let cell = SIMD3<Int32>(point / voxel, rounding: .down)
                    guard filled.insert(cell).inserted else { continue }
                    let o = (v * w + u) * 4
                    cloud.positions.append(point)
                    cloud.colors.append(SIMD4(Float(rgba[o]) / 255, Float(rgba[o + 1]) / 255, Float(rgba[o + 2]) / 255, 1))
                }
            }
        }
        return cloud
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

    /// A SceneKit node drawing the cloud as unlit dots.
    static func node(for cloud: Cloud) -> SCNNode {
        let node = SCNNode()
        guard !cloud.positions.isEmpty else { return node }
        let vertices = SCNGeometrySource(vertices: cloud.positions.map { SCNVector3($0.x, $0.y, $0.z) })
        let colorData = cloud.colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colors = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: cloud.colors.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let indices = (0..<Int32(cloud.positions.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 0.012
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 12
        let geometry = SCNGeometry(sources: [vertices, colors], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        geometry.materials = [material]
        node.geometry = geometry
        return node
    }
}
