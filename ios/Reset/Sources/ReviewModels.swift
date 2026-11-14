import Metal
import SceneKit
import SwiftUI
import simd

/// The 3D models drawn over a saved frame in Review all frames (Phil, 2026-11-02): a SceneKit scene
/// whose camera takes the frame's saved pose and intrinsics, so the models sit in the photo as they
/// would live, and can be placed, moved, scaled and turned away from the set.
@MainActor
final class ReviewStage: ObservableObject {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Phil, 2026-11-10: models must stay put from frame to frame, which means passing behind the real
    /// things in front of them. An invisible copy of the set, made from the frame's saved depth, fills the
    /// depth buffer before the models are drawn, so a pillar nearer than a model hides it.
    private let occluder = SCNNode()
    private var shownFile: String?
    private var cache: [String: SCNGeometry] = [:]
    private var cacheOrder: [String] = []

    private static let hidesKey = "review.hidesBehindSet"
    @Published var hidesBehindSet: Bool {
        didSet {
            UserDefaults.standard.set(hidesBehindSet, forKey: Self.hidesKey)
            occluder.isHidden = !hidesBehindSet
        }
    }

    init(modelRoot: SCNNode) {
        let camera = SCNCamera()
        camera.zNear = 0.03
        camera.zFar = 30
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        hidesBehindSet = UserDefaults.standard.object(forKey: Self.hidesKey) as? Bool ?? true
        occluder.name = "review.occluder"
        occluder.renderingOrder = -10
        occluder.categoryBitMask = ReviewPick.occluderMask
        occluder.isHidden = !hidesBehindSet
        scene.rootNode.addChildNode(occluder)
        scene.rootNode.addChildNode(modelRoot)
    }

    /// Puts the camera where this frame was taken, looking the way it looked, and the set's depth in front.
    func show(_ frame: Keyframe, folder: URL) {
        cameraNode.simdTransform = frame.cameraToWorld
        if let projection = frame.uprightProjection() {
            cameraNode.camera?.projectionTransform = SCNMatrix4(projection)
        }
        let file = frame.imageFile
        guard file != shownFile else { return }
        shownFile = file
        occluder.geometry = cache[file]
        guard occluder.geometry == nil, frame.depthFile != nil else { return }
        Task.detached(priority: .userInitiated) {
            let mesh = OccluderMesh.build(frame: frame, folder: folder)
            await MainActor.run { [weak self] in
                guard let self, let mesh, let geometry = mesh.geometry() else { return }
                self.cache[file] = geometry
                self.cacheOrder.append(file)
                if self.cacheOrder.count > 12 { self.cache[self.cacheOrder.removeFirst()] = nil }
                if self.shownFile == file { self.occluder.geometry = geometry }
                Diagnostics.log("Review: set depth for \(file), \(mesh.indices.count / 3) triangles")
            }
        }
    }

    /// The frame's photo with the models drawn into it as they show, for saving to Photos.
    func render(over photo: UIImage, size: CGSize) -> UIImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = true
        scene.background.contents = photo
        defer { scene.background.contents = nil }
        return renderer.snapshot(atTime: CACurrentMediaTime(), with: size, antialiasingMode: .multisampling4X)
    }
}

/// Hits on Review's invisible set are ignored, so a model behind a pillar can still be picked.
enum ReviewPick {
    static let occluderMask = 1 << 20
    static var options: [SCNHitTestOption: Any] { [.categoryBitMask: ~occluderMask] }
}

/// The saved depth of one frame as a mesh in room coordinates, pushed back (5 cm, more far away where the
/// depth is rougher) so a model standing against a wall is not cut by it. Jumps in depth (the edge of a
/// pillar) are left open. Phil, 2026-11-11: feet and legs were chopped into blocks by the floor, so the
/// floor itself never hides anything (a table top still does), and the mesh uses every depth reading.
struct OccluderMesh: Sendable {
    var positions: [Float] = []
    var indices: [UInt32] = []

    static func build(frame: Keyframe, folder: URL) -> OccluderMesh? {
        guard let depthFile = frame.depthFile, frame.depthWidth > 8, frame.depthHeight > 8,
              frame.imageWidth > 0, frame.imageHeight > 0, frame.intrinsics.count >= 9,
              let data = try? Data(contentsOf: folder.appendingPathComponent(depthFile)) else { return nil }
        let depth = DepthMap.floats(data)
        let dw = frame.depthWidth, dh = frame.depthHeight
        guard depth.count >= dw * dh else { return nil }
        let k = frame.cameraIntrinsics
        let pose = frame.cameraToWorld
        let w = Float(frame.imageWidth), h = Float(frame.imageHeight)
        let step = 1
        let cols = (dw - 1) / step + 1, rows = (dh - 1) / step + 1
        var mesh = OccluderMesh()
        mesh.positions.reserveCapacity(cols * rows * 3)
        var valid = [Bool](repeating: false, count: cols * rows)
        var values = [Float](repeating: 0, count: cols * rows)
        for gy in 0..<rows {
            for gx in 0..<cols {
                let x = gx * step, y = gy * step
                let d = depth[y * dw + x]
                var p = SIMD3<Float>.zero
                if d.isFinite, d > 0.12, d < 8 {
                    let back = d + 0.05 + 0.03 * d
                    let u = (Float(x) + 0.5) / Float(dw) * w, v = (Float(y) + 0.5) / Float(dh) * h
                    let world = pose * SIMD4((u - k[2][0]) / k[0][0] * back, -(v - k[2][1]) / k[1][1] * back, -back, 1)
                    p = SIMD3(world.x, world.y, world.z)
                    valid[gy * cols + gx] = true
                    values[gy * cols + gx] = d
                }
                mesh.positions.append(contentsOf: [p.x, p.y, p.z])
            }
        }
        // The floor: the lowest level that much of the picture sits on.
        var heights: [Float] = []
        heights.reserveCapacity(cols * rows / 4)
        for i in stride(from: 0, to: cols * rows, by: 4) where valid[i] { heights.append(mesh.positions[i * 3 + 1]) }
        heights.sort()
        let floor: Float? = heights.count > 50 ? heights[heights.count / 50] : nil
        func point(_ i: Int) -> SIMD3<Float> { SIMD3(mesh.positions[i * 3], mesh.positions[i * 3 + 1], mesh.positions[i * 3 + 2]) }
        for gy in 0..<(rows - 1) {
            for gx in 0..<(cols - 1) {
                let a = gy * cols + gx, b = a + 1, c = a + cols, e = c + 1
                guard valid[a], valid[b], valid[c], valid[e] else { continue }
                let ds = [values[a], values[b], values[c], values[e]]
                let low = ds.min() ?? 0, high = ds.max() ?? 0
                guard high - low < 0.03 + 0.05 * low else { continue }
                if let floor {
                    let pa = point(a), pe = point(e)
                    let normal = simd_cross(point(c) - pa, point(b) - pa)
                    let length = simd_length(normal)
                    let flat = length > 0 && abs(normal.y) / length > 0.8
                    if flat, (pa.y + pe.y) / 2 < floor + 0.12 { continue }
                }
                mesh.indices.append(contentsOf: [UInt32(a), UInt32(c), UInt32(b), UInt32(b), UInt32(c), UInt32(e)])
            }
        }
        return mesh.indices.isEmpty ? nil : mesh
    }

    func geometry() -> SCNGeometry? {
        guard !indices.isEmpty else { return nil }
        let data = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let source = SCNGeometrySource(data: data, semantic: .vertex, vectorCount: positions.count / 3, usesFloatComponents: true,
                                       componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.colorBufferWriteMask = []
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        material.lightingModel = .constant
        geometry.materials = [material]
        return geometry
    }
}

/// A transparent SceneKit view over the photo, the size of the photo as it shows upright.
struct ReviewModelsView: UIViewRepresentable {
    let stage: ReviewStage
    let placer: ModelPlacer
    let frame: Keyframe
    let folder: URL

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = stage.scene
        view.pointOfView = stage.cameraNode
        view.backgroundColor = .clear
        view.isOpaque = false
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        stage.show(frame, folder: folder)
        placer.attachGestures(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        stage.show(frame, folder: folder)
    }
}
