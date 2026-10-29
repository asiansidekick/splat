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
    static let radius: CGFloat = 0.035
    /// The balls sit centred, low in the picture, metres below the middle at `distance`, so the
    /// middle stays clear for lining up the ghost. Less when landscape, where the picture is
    /// shorter.
    static func drop(_ orientation: UIInterfaceOrientation) -> Float {
        orientation.isLandscape ? 0.08 : 0.15
    }

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
        liveMaterial.transparency = 0.75
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

    /// Places the room's ball for the reference view and the phone's ball in front of the
    /// phone, both turned to the way the phone is held now, so holding it landscape for a
    /// portrait reference still lines up. The phone's ball also tips forward or back,
    /// exaggerated, by how much higher or lower the reference looked: more yellow showing means
    /// tilt up, more dark means tilt down. `camera` is only used when the phone's ball could
    /// not ride on the view's camera node.
    func update(target keyframe: Keyframe, camera: simd_float4x4, orientation: UIInterfaceOrientation, matched: Bool) {
        let (right, up) = GuideSpheres.axes(orientation)
        target.simdTransform = keyframe.cameraToWorld * GuideSpheres.local(orientation)
        // The reference's view direction, in the phone camera's own axes.
        let toReference = camera.inverse * keyframe.cameraToWorld
        let forward = -SIMD3(toReference.columns.2.x, toReference.columns.2.y, toReference.columns.2.z)
        let pitch = atan2(simd_dot(forward, up), -forward.z)
        let tip = max(-1.2, min(1.2, pitch * GuideSpheres.tiltGain))
        if let view, let eye = view.pointOfView, fixed.parent !== eye { attach(to: view) }
        if fixed.parent == nil || fixed.parent === root {
            if fixed.parent == nil { root.addChildNode(fixed) }
            fixed.simdTransform = camera * GuideSpheres.local(orientation, tip: simd_quatf(angle: tip, axis: right))
        } else {
            // The AR view's camera node is already turned to the screen: x right, y up,
            // whichever way the phone is held. (Using the sensor's axes here turned the ball
            // 90 degrees and put it off to the side when upright.)
            let screenRight = SIMD3<Float>(1, 0, 0)
            fixed.simdTransform = GuideSpheres.local(
                right: screenRight, up: SIMD3(0, 1, 0), drop: GuideSpheres.drop(orientation),
                tip: simd_quatf(angle: tip, axis: screenRight))
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

    /// How much the phone's ball tips for each degree the phone is tilted off the reference.
    static let tiltGain: Float = 3

    /// Where the reference's ball hangs in the room, for the phone held this way.
    static func position(for keyframe: Keyframe, orientation: UIInterfaceOrientation) -> SIMD3<Float> {
        let p = keyframe.cameraToWorld * local(orientation).columns.3
        return SIMD3(p.x, p.y, p.z)
    }

    /// Right and up on the screen, in the camera's own axes, for the phone held this way.
    static func axes(_ orientation: UIInterfaceOrientation) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        switch orientation {
        case .landscapeRight: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .landscapeLeft: return (SIMD3(-1, 0, 0), SIMD3(0, -1, 0))
        case .portraitUpsideDown: return (SIMD3(0, -1, 0), SIMD3(1, 0, 0))
        default: return (SIMD3(0, 1, 0), SIMD3(-1, 0, 0))  // portrait
        }
    }

    /// In ARKit's camera axes: the spot `distance` ahead and low in the middle of the screen,
    /// turned so the ball's top points up the screen, then tipped by `tip`.
    static func local(_ orientation: UIInterfaceOrientation, tip: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))) -> simd_float4x4 {
        let (right, up) = axes(orientation)
        return local(right: right, up: up, drop: drop(orientation), tip: tip)
    }

    static func local(right: SIMD3<Float>, up: SIMD3<Float>, drop: Float, tip: simd_quatf) -> simd_float4x4 {
        let back = SIMD3<Float>(0, 0, 1)
        let centre = -up * drop - back * distance
        return simd_float4x4(
            SIMD4(tip.act(right), 0), SIMD4(tip.act(up), 0), SIMD4(tip.act(back), 0), SIMD4(centre, 1))
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
