import ARKit
import SceneKit
import UIKit
import simd

/// The alignment guide as two identical spheres in 3D, each split into hemispheres. One sits in
/// the room where it would have been in front of the reference camera; the other, see-through,
/// rides in front of the phone. Standing and pointing where the reference was taken lays one
/// exactly over the other, with their hemisphere lines level. So the spheres show
/// every axis at once: where they sit (aim and step), how big the solid one looks (forward or
/// back) and how the line tilts (turn).
@MainActor
final class GuideSpheres {
    /// How far in front of the camera the spheres sit, metres.
    static let distance: Float = 0.6
    static let radius: CGFloat = 0.07

    /// In the room, where the reference camera's sphere was.
    let target = SCNNode()
    /// Rides in front of the phone: a child of the AR view's camera node.
    let fixed = SCNNode()
    /// Both, so they can be shown and hidden together.
    let root = SCNNode()
    private let targetSphere: SCNMaterial
    private var shown = false
    /// The AR view the see-through sphere rides on. Its camera node can appear after the view is made,
    /// and a new view is made if the screen is rebuilt, so every update checks it.
    private weak var view: ARSCNView?
    private var wasMatched = false

    init() {
        let solid = SCNSphere(radius: GuideSpheres.radius)
        solid.segmentCount = 48
        targetSphere = GuideSpheres.material(top: .systemYellow, bottom: UIColor(white: 0.12, alpha: 1), line: .black)
        solid.materials = [targetSphere]
        target.geometry = solid

        // The same ball riding on the phone, see-through, so lining up means making the two
        // balls one: same size, same place, the same line across the middle.
        let live = SCNSphere(radius: GuideSpheres.radius)
        live.segmentCount = 48
        let liveMaterial = GuideSpheres.material(top: .systemYellow, bottom: UIColor(white: 0.12, alpha: 1), line: .black)
        liveMaterial.transparency = 0.5
        liveMaterial.writesToDepthBuffer = false
        live.materials = [liveMaterial]
        fixed.geometry = live

        // Always drawn on top of the set and of any models: the room's ball first, then the
        // see-through one over it.
        for (node, order) in [(target, 100), (fixed, 101)] {
            node.renderingOrder = order
            node.geometry?.firstMaterial?.readsFromDepthBuffer = false
        }
        root.addChildNode(target)
        root.opacity = 0
        target.opacity = 0
        fixed.opacity = 0
    }

    /// Puts the see-through sphere in front of the AR view's camera, so it moves with the phone exactly.
    func attach(to view: ARSCNView) {
        self.view = view
        guard let camera = view.pointOfView, fixed.parent !== camera else { return }
        fixed.removeFromParentNode()
        camera.addChildNode(fixed)
    }

    /// Places the solid sphere for the reference view and turns both to its up direction.
    /// `camera` is only used when the see-through sphere could not ride on the view's camera node.
    func update(target keyframe: Keyframe, camera: simd_float4x4, matched: Bool) {
        let local = GuideSpheres.local(for: keyframe)
        if let view, let eye = view.pointOfView, fixed.parent !== eye { attach(to: view) }
        target.simdTransform = keyframe.cameraToWorld * local
        if fixed.parent == nil || fixed.parent === root {
            if fixed.parent == nil { root.addChildNode(fixed) }
            fixed.simdTransform = camera * local
        } else {
            fixed.simdTransform = local
        }
        let image = matched ? GuideSpheres.matchedImage : GuideSpheres.solidImage
        targetSphere.diffuse.contents = image
        targetSphere.emission.contents = image
        if matched != wasMatched || !shown {
            wasMatched = matched
            shown = true
            // Gone once lined up, back as soon as it is not.
            let opacity: CGFloat = matched ? 0 : 1
            for node in [target, fixed] {
                node.removeAction(forKey: "fade")
                node.runAction(.fadeOpacity(to: opacity, duration: matched ? 0.6 : 0.2), forKey: "fade")
            }
            root.opacity = 1
        }
    }

    func hide() {
        guard shown else { return }
        shown = false
        for node in [target, fixed] {
            node.removeAction(forKey: "fade")
            node.opacity = 0
        }
    }

    /// In the camera's own axes: the spot `distance` ahead, turned so the sphere's top points the
    /// way that was up on the screen when the reference was taken.
    static func local(for keyframe: Keyframe) -> simd_float4x4 {
        let up: SIMD3<Float>
        switch keyframe.uprightOrientation {
        case .up: up = SIMD3(0, 1, 0)  // landscape, camera on the left
        case .down: up = SIMD3(0, -1, 0)
        case .right: up = SIMD3(-1, 0, 0)  // portrait
        default: up = SIMD3(1, 0, 0)
        }
        let back = SIMD3<Float>(0, 0, 1)
        let right = simd_cross(up, back)
        return simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(0, 0, -distance, 1))
    }

    static let solidImage = hemispheres(top: .systemYellow, bottom: UIColor(white: 0.12, alpha: 1), line: .black)
    static let matchedImage = hemispheres(top: .systemGreen, bottom: UIColor(white: 0.12, alpha: 1), line: .black)

    private static func material(top: UIColor, bottom: UIColor, line: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = hemispheres(top: top, bottom: bottom, line: line)
        material.lightingModel = .blinn
        material.specular.contents = UIColor(white: 0.25, alpha: 1)
        // Glows a little so it stays bright in a dim room, keeping some shading to look round.
        material.emission.contents = material.diffuse.contents
        material.emission.intensity = 0.6
        return material
    }

    /// A sphere texture: the top half one colour, the bottom half another, a line at the equator.
    /// SceneKit wraps the image's top edge to the sphere's top.
    private static func hemispheres(top: UIColor, bottom: UIColor, line: UIColor) -> UIImage {
        let size = CGSize(width: 256, height: 128)
        return UIGraphicsImageRenderer(size: size).image { context in
            top.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            bottom.setFill()
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
            line.setFill()
            context.fill(CGRect(x: 0, y: size.height / 2 - 4, width: size.width, height: 8))
        }
    }
}
