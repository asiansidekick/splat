import ARKit
import SceneKit
import UIKit
import simd

/// The alignment guide as two spheres in 3D, each split into hemispheres. One sits in the room
/// where it would have been in front of the reference camera; the other rides in front of the
/// phone. Standing and pointing where the reference was taken puts the solid sphere right in the
/// middle of the glass one, with their hemisphere lines level with each other. So the spheres show
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
    private var wasMatched = false

    init() {
        let solid = SCNSphere(radius: GuideSpheres.radius)
        solid.segmentCount = 48
        targetSphere = GuideSpheres.material(top: .systemYellow, bottom: UIColor(white: 0.12, alpha: 1), line: .black)
        solid.materials = [targetSphere]
        target.geometry = solid

        // A little bigger, so the solid sphere shows inside it with an even rim when lined up.
        let glass = SCNSphere(radius: GuideSpheres.radius * 1.2)
        glass.segmentCount = 48
        let glassMaterial = GuideSpheres.material(top: UIColor(white: 1, alpha: 1), bottom: UIColor(white: 0.6, alpha: 1), line: .white)
        glassMaterial.transparency = 0.35
        glassMaterial.writesToDepthBuffer = false
        glass.materials = [glassMaterial]
        fixed.geometry = glass

        // Always drawn on top of the set and of any models, the glass after the solid sphere.
        for (node, order) in [(target, 100), (fixed, 101)] {
            node.renderingOrder = order
            node.geometry?.firstMaterial?.readsFromDepthBuffer = false
        }
        root.addChildNode(target)
        root.opacity = 0
        target.opacity = 0
        fixed.opacity = 0
    }

    /// Puts the glass sphere in front of the AR view's camera, so it moves with the phone exactly.
    func attach(to view: ARSCNView) {
        guard let camera = view.pointOfView, fixed.parent !== camera else { return }
        fixed.removeFromParentNode()
        camera.addChildNode(fixed)
    }

    /// Places the solid sphere for the reference view and turns both to its up direction.
    /// `camera` is only used when the glass sphere could not ride on the view's camera node.
    func update(target keyframe: Keyframe, camera: simd_float4x4, matched: Bool) {
        let local = GuideSpheres.local(for: keyframe)
        target.simdTransform = keyframe.cameraToWorld * local
        if fixed.parent == nil || fixed.parent === root {
            if fixed.parent == nil { root.addChildNode(fixed) }
            fixed.simdTransform = camera * local
        } else {
            fixed.simdTransform = local
        }
        targetSphere.diffuse.contents = matched ? GuideSpheres.matchedImage : GuideSpheres.solidImage
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
        material.specular.contents = UIColor(white: 0.6, alpha: 1)
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
            context.fill(CGRect(x: 0, y: size.height / 2 - 3, width: size.width, height: 6))
        }
    }
}
