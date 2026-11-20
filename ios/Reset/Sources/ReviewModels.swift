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

    @Published var hidesBehindSet: Bool {
        didSet {
            UserDefaults.standard.set(hidesBehindSet, forKey: BehindReal.key)
            occluder.isHidden = !hidesBehindSet
        }
    }

    init(modelRoot: SCNNode) {
        let camera = SCNCamera()
        camera.zNear = 0.03
        camera.zFar = 30
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        hidesBehindSet = BehindReal.on
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

/// The saved depth of one frame as an invisible mesh (OccluderMath.swift), and SceneKit geometry for any occluder.
extension OccluderMesh {
    static func build(frame: Keyframe, folder: URL) -> OccluderMesh? {
        guard let depthFile = frame.depthFile, frame.depthWidth > 8, frame.depthHeight > 8,
              frame.imageWidth > 0, frame.imageHeight > 0, frame.intrinsics.count >= 9,
              let data = try? Data(contentsOf: folder.appendingPathComponent(depthFile)) else { return nil }
        return build(depth: DepthMap.floats(data), width: frame.depthWidth, height: frame.depthHeight,
                     intrinsics: frame.cameraIntrinsics, pose: frame.cameraToWorld,
                     imageWidth: Float(frame.imageWidth), imageHeight: Float(frame.imageHeight))
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
