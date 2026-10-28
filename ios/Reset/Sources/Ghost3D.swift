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
                    let cell = Ghost3D.cell(point)
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

    static func cell(_ point: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(point / voxel, rounding: .down)
    }

    /// Draws the cloud as unlit dots in two groups: faint for parts not checked yet (or every
    /// point when there is no live LiDAR), and solid with a blue halo for parts the live LiDAR
    /// finds are gone. Parts it finds still in place are left out, so only what changed shows.
    @MainActor
    final class Display {
        let node = SCNNode()
        private let ghostNode = SCNNode()
        private let haloNode = SCNNode()
        private let vertices: SCNGeometrySource
        private let colors: SCNGeometrySource
        private let faintMaterial = Display.material()
        private let solidMaterial = Display.material()
        private let haloMaterial = Display.material()
        static let haloColor = UIColor(red: 0.25, green: 0.6, blue: 1, alpha: 1)

        /// How strong the faint group is (the ghost strength slider).
        var faintOpacity: CGFloat {
            get { faintMaterial.transparency }
            set { faintMaterial.transparency = newValue }
        }

        init(cloud: Cloud) {
            vertices = SCNGeometrySource(vertices: cloud.positions.map { SCNVector3($0.x, $0.y, $0.z) })
            let colorData = cloud.colors.withUnsafeBufferPointer { Data(buffer: $0) }
            colors = SCNGeometrySource(
                data: colorData, semantic: .color, vectorCount: cloud.colors.count, usesFloatComponents: true,
                componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride)
            faintMaterial.transparency = 0.5
            haloMaterial.diffuse.contents = Display.haloColor
            // The halo is drawn first and the dots on top of it, so each gone dot gets a blue rim.
            haloMaterial.writesToDepthBuffer = false
            haloNode.renderingOrder = 10
            ghostNode.renderingOrder = 11
            node.addChildNode(haloNode)
            node.addChildNode(ghostNode)
            show(faint: (0..<Int32(cloud.positions.count)).map { $0 }, missing: [])
        }

        func show(faint: [Int32], missing: [Int32]) {
            var elements: [SCNGeometryElement] = []
            var materials: [SCNMaterial] = []
            if !faint.isEmpty {
                elements.append(Display.element(faint, size: 0.012, minRadius: 1.5, maxRadius: 12))
                materials.append(faintMaterial)
            }
            if !missing.isEmpty {
                elements.append(Display.element(missing, size: 0.014, minRadius: 2, maxRadius: 14))
                materials.append(solidMaterial)
            }
            if elements.isEmpty {
                ghostNode.geometry = nil
            } else {
                let ghost = SCNGeometry(sources: [vertices, colors], elements: elements)
                ghost.materials = materials
                ghostNode.geometry = ghost
            }
            if missing.isEmpty {
                haloNode.geometry = nil
            } else {
                let halo = SCNGeometry(
                    sources: [vertices], elements: [Display.element(missing, size: 0.028, minRadius: 4, maxRadius: 22)])
                halo.materials = [haloMaterial]
                haloNode.geometry = halo
            }
        }

        private static func element(_ indices: [Int32], size: CGFloat, minRadius: CGFloat, maxRadius: CGFloat) -> SCNGeometryElement {
            let element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = size
            element.minimumPointScreenSpaceRadius = minRadius
            element.maximumPointScreenSpaceRadius = maxRadius
            return element
        }

        private nonisolated static func material() -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            return material
        }
    }

    /// Checks the cloud against the live LiDAR, point by point. Each point keeps a score so one
    /// noisy reading does not flip it: the live depth landing on the point counts towards "still
    /// there", seeing through to something further away counts towards "gone".
    final class Checker: @unchecked Sendable {
        /// A gone point needs this many gone neighbours (of 26) to show, so only solid patches do.
        static let minNeighbours = 3
        private let positions: [SIMD3<Float>]
        private var score: [Int8]
        private let cells: [SIMD3<Int32>: Int32]

        init(cloud: Cloud) {
            positions = cloud.positions
            score = [Int8](repeating: 0, count: cloud.positions.count)
            var cells = [SIMD3<Int32>: Int32](minimumCapacity: cloud.positions.count)
            for (index, point) in cloud.positions.enumerated() {
                cells[Ghost3D.cell(point)] = Int32(index)
            }
            self.cells = cells
        }

        /// Call from one queue at a time. Returns the points to show faint and the gone ones.
        func update(live: DepthView) -> (faint: [Int32], missing: [Int32])? {
            let w = live.width
            let h = live.height
            guard w > 0, h > 0, live.depth.count == w * h else { return nil }
            let k = live.depthIntrinsics
            let worldToLive = live.cameraToWorld.inverse
            let confidence = live.confidence?.count == w * h ? live.confidence : nil

            for index in positions.indices {
                let p = worldToLive * SIMD4<Float>(positions[index], 1)
                let z = -p.z
                guard z > 0.1, z < DepthDiff.maxRange else { continue }
                let u = Int((k.fx * p.x / z + k.cx).rounded())
                let v = Int((-k.fy * p.y / z + k.cy).rounded())
                guard u >= 0, u < w, v >= 0, v < h else { continue }
                let pixel = v * w + u
                if let confidence, confidence[pixel] < 2 { continue }
                let d = live.depth[pixel]
                guard d > 0.1 else { continue }
                let limit = DepthDiff.threshold + DepthDiff.perMetre * z
                if d > z + limit {
                    score[index] = min(score[index] + 1, 4)
                } else if d >= z - limit {
                    score[index] = max(score[index] - 2, -4)
                }
                // Nearer than the point: something stands in front of it, which says nothing.
            }

            var faint: [Int32] = []
            var gone = [Bool](repeating: false, count: positions.count)
            for index in positions.indices {
                if score[index] >= 2 {
                    gone[index] = true
                } else if score[index] >= 0 {
                    faint.append(Int32(index))
                }
            }
            var missing: [Int32] = []
            for index in positions.indices where gone[index] {
                let cell = Ghost3D.cell(positions[index])
                var neighbours = 0
                for dz: Int32 in -1...1 {
                    for dy: Int32 in -1...1 {
                        for dx: Int32 in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                            if let other = cells[cell &+ SIMD3(dx, dy, dz)], gone[Int(other)] { neighbours += 1 }
                        }
                    }
                }
                if neighbours >= Checker.minNeighbours {
                    missing.append(Int32(index))
                } else {
                    faint.append(Int32(index))
                }
            }
            return (faint, missing)
        }
    }
}
