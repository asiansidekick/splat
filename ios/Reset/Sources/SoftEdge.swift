import CoreGraphics
import Foundation
import SceneKit
import simd

/// Phil, 2026-11-26: a cropped scan fades out toward its cut edges instead of ending in a hard line (SoftEdgeMath
/// finds how far each point is from a cut edge). Done the plain SceneKit way, so it works with each model's own light
/// step and with lit or unlit materials: each point gets a second set of picture coordinates saying how solid it is,
/// and the triangles near a cut edge are drawn with a copy of their material whose see-through picture is a ramp from
/// clear to solid. Triangles away from the edges keep their own material, drawn exactly as before. Kept free of UIKit
/// so the soft edge tests can render it on a Mac.
enum SoftEdge {
    /// Clear on the left, solid on the right: the see-through picture of the fringe material.
    static let ramp: CGImage? = {
        let width = 256, height = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let a = UInt8(x * 255 / (width - 1))
                let i = (y * width + x) * 4
                // Premultiplied white: every part equals the alpha.
                pixels[i] = a
                pixels[i + 1] = a
                pixels[i + 2] = a
                pixels[i + 3] = a
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }()

    /// A triangle is drawn solid, with its own material, when all three corners are at least this solid.
    static let solid: Float = 0.999

    /// The extra picture coordinates: across the ramp by how solid each point is, through the middle of its texels.
    static func fadeSource(_ fade: [Float]) -> SCNGeometrySource {
        SCNGeometrySource(textureCoordinates: fade.map { f in
            let t = min(max(f, 0), 1)
            return CGPoint(x: CGFloat(0.5 / 256 + t * 255 / 256), y: 0.5)
        })
    }

    /// The model's geometry again, fading toward its cut edges. `sources` must all number their points the same way as
    /// `fade` (one value each); `elements` are each material's triangles.
    static func softened(sources: [SCNGeometrySource], elements: [[UInt32]], materials: [SCNMaterial], fade: [Float]) -> SCNGeometry {
        let channel = sources.filter { $0.semantic == .texcoord }.count
        var outElements: [SCNGeometryElement] = []
        var outMaterials: [SCNMaterial] = []
        for (e, list) in elements.enumerated() {
            let material = materials.isEmpty ? SCNMaterial() : materials[min(e, materials.count - 1)]
            var solidList: [UInt32] = [], fringe: [UInt32] = []
            solidList.reserveCapacity(list.count)
            var t = 0
            while t + 2 < list.count {
                let a = Int(list[t]), b = Int(list[t + 1]), c = Int(list[t + 2])
                let ok = a < fade.count && b < fade.count && c < fade.count
                if !ok || (fade[a] >= solid && fade[b] >= solid && fade[c] >= solid) {
                    solidList.append(contentsOf: list[t...(t + 2)])
                } else {
                    fringe.append(contentsOf: list[t...(t + 2)])
                }
                t += 3
            }
            if !solidList.isEmpty {
                outElements.append(SCNGeometryElement(indices: solidList, primitiveType: .triangles))
                outMaterials.append(material)
            }
            if !fringe.isEmpty {
                outElements.append(SCNGeometryElement(indices: fringe, primitiveType: .triangles))
                outMaterials.append(fringeMaterial(material, channel: channel))
            }
        }
        let geometry = SCNGeometry(sources: sources + [fadeSource(fade)], elements: outElements)
        geometry.materials = outMaterials
        return geometry
    }

    /// A copy of a material that is see-through by the ramp. It does not hide what is behind it from the depth
    /// buffer (a faded rim would otherwise cut holes in models behind it), but is still hidden by what is in front.
    static func fringeMaterial(_ material: SCNMaterial, channel: Int) -> SCNMaterial {
        let copy = (material.copy() as? SCNMaterial) ?? SCNMaterial()
        copy.transparent.contents = ramp
        copy.transparent.mappingChannel = channel
        copy.transparent.wrapS = .clamp
        copy.transparent.wrapT = .clamp
        copy.transparent.minificationFilter = .linear
        copy.transparent.magnificationFilter = .linear
        copy.transparent.mipFilter = .none
        copy.transparent.intensity = 1
        copy.transparencyMode = .aOne
        copy.blendMode = .alpha
        copy.writesToDepthBuffer = false
        return copy
    }

    // MARK: Reading a geometry

    /// Every point of a geometry, or nil if they are not plain floats.
    static func positions(of geometry: SCNGeometry) -> [SIMD3<Float>]? {
        guard let source = geometry.sources(for: .vertex).first, source.usesFloatComponents,
            source.bytesPerComponent == 4, source.componentsPerVector >= 3
        else { return nil }
        let stride = source.dataStride, offset = source.dataOffset, count = source.vectorCount
        let data = source.data
        guard stride > 0, count > 0, data.count >= offset + (count - 1) * stride + 12 else { return nil }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let base = offset + i * stride
                out.append(SIMD3(
                    raw.loadUnaligned(fromByteOffset: base, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                    raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)))
            }
        }
        return out
    }

    /// The corner numbers of every triangle, one list for each material; nil if any part is not triangles.
    static func triangles(of geometry: SCNGeometry) -> [[UInt32]]? {
        var all: [[UInt32]] = []
        for element in geometry.elements {
            guard element.primitiveType == .triangles else { return nil }
            let count = element.primitiveCount * 3, bytes = element.bytesPerIndex
            let data = element.data
            guard data.count >= count * bytes else { return nil }
            var out: [UInt32] = []
            out.reserveCapacity(count)
            data.withUnsafeBytes { raw in
                for i in 0..<count {
                    switch bytes {
                    case 1: out.append(UInt32(raw.load(fromByteOffset: i, as: UInt8.self)))
                    case 2: out.append(UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))
                    default: out.append(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                    }
                }
            }
            all.append(out)
        }
        return all
    }

    /// Whether every source numbers the same points (SceneKit can show a file whose picture coordinates outnumber its
    /// points, but a geometry rebuilt from those sources scrambles the picture: ScanTrim's build 1317 log).
    static func sourcesAgree(_ geometry: SCNGeometry) -> Bool {
        guard let first = geometry.sources.first?.vectorCount else { return false }
        return geometry.sources.allSatisfy { $0.vectorCount == first }
    }
}
