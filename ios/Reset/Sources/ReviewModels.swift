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

    init(modelRoot: SCNNode) {
        let camera = SCNCamera()
        camera.zNear = 0.03
        camera.zFar = 30
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(modelRoot)
    }

    /// Puts the camera where this frame was taken, looking the way it looked.
    func show(_ frame: Keyframe) {
        cameraNode.simdTransform = frame.cameraToWorld
        if let projection = frame.uprightProjection() {
            cameraNode.camera?.projectionTransform = SCNMatrix4(projection)
        }
    }
}

/// A transparent SceneKit view over the photo, the size of the photo as it shows upright.
struct ReviewModelsView: UIViewRepresentable {
    let stage: ReviewStage
    let placer: ModelPlacer
    let frame: Keyframe

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = stage.scene
        view.pointOfView = stage.cameraNode
        view.backgroundColor = .clear
        view.isOpaque = false
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        stage.show(frame)
        placer.attachGestures(to: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        stage.show(frame)
    }
}
