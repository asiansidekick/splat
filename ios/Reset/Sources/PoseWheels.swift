import SceneKit
import UIKit

/// The wheels shown round a selected pose handle, one for each way its joint turns (Phil, 2026-11-21), and dragging a
/// turning handle so its joint goes the way the finger goes. Shared by live view (imported characters) and the Pose
/// screen (mannequins); the maths is in PoseAxes.swift.
@MainActor
final class PoseWheelSet {
    /// Where a point riding on the joint is, and the point the joint turns about, read from the scene as it is shown.
    struct Anchor {
        var pivot: () -> SIMD3<Float>
        var probe: () -> SIMD3<Float>
    }

    private(set) var wheels: [PoseWheel] = []
    private(set) var joint: PoseDrag.Joint?
    private var holder: SCNNode?
    private var ratio: Float = 1
    private var colours: [UIColor] = []
    /// The wheel being turned: which, the spot grabbed on its rim, the pose then, and how far it has turned.
    private var grab: (index: Int, spot: SIMD3<Float>, pose: MannequinPose, turned: Float)?
    /// A turning handle being dragged: the pose and finger it started from.
    private var handleStart: (pose: MannequinPose, finger: SIMD2<Float>)?

    var turning: Bool { grab != nil }
    var turningWords: String? { grab.map { wheels[$0.index].axis.words } }

    /// Works out the wheels for `joint` at `pose`: each axis is turned a little and back, to see which way it moves
    /// things on this character. `show` puts a pose on the character at once (the caller puts its own pose back after).
    /// `anchor` is asked while `pose` is shown, so it can fix its points to the bones then.
    func build(_ joint: PoseDrag.Joint, pose: MannequinPose, ratio: Float, smallest: Float, colours: [UIColor],
               show: (MannequinPose) -> Void, anchor: (PoseAxis) -> Anchor?, parent: SCNNode?) {
        clear()
        self.joint = joint
        self.ratio = ratio
        self.colours = colours
        var made: [PoseWheel] = []
        for axis in PoseAxis.axes(for: joint) {
            show(pose)
            guard let a = anchor(axis) else { continue }
            let pivot = a.pivot(), before = a.probe()
            for step: Float in [4, -4] {
                show(axis.changed(pose, by: step, ratio: ratio))
                guard var wheel = PoseWheel.measured(axis, pivot: pivot, before: before, after: a.probe(), step: step, smallest: smallest) else { continue }
                // Measured turning the other way (the axis was at its limit): face the wheel so a positive turn of the
                // axis still turns right-handed about it.
                if step < 0 { wheel.normal = -wheel.normal }
                made.append(wheel)
                break
            }
        }
        show(pose)
        wheels = made
        draw(parent)
    }

    func clear() {
        holder?.removeFromParentNode()
        holder = nil
        wheels = []
        joint = nil
        grab = nil
        handleStart = nil
    }

    /// Thin hoops round the joint, drawn over everything so they can always be seen and grabbed.
    private func draw(_ parent: SCNNode?) {
        holder?.removeFromParentNode()
        guard let parent, !wheels.isEmpty else { return }
        let holder = SCNNode()
        holder.name = "posering"
        parent.addChildNode(holder)
        holder.simdWorldTransform = matrix_identity_float4x4
        for (index, wheel) in wheels.enumerated() {
            let hoop = SCNTorus(ringRadius: CGFloat(wheel.radius), pipeRadius: CGFloat(max(wheel.radius * 0.035, 0.002)))
            hoop.ringSegmentCount = 64
            hoop.pipeSegmentCount = 8
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = (index < colours.count ? colours[index] : .white).withAlphaComponent(0.9)
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            hoop.materials = [material]
            let ring = SCNNode(geometry: hoop)
            ring.name = "posering"
            ring.renderingOrder = 2100
            // A torus lies round its own Y.
            ring.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: wheel.normal)
            ring.simdPosition = wheel.centre
            holder.addChildNode(ring)
        }
        self.holder = holder
    }

    /// The wheel being turned stands out; the other one fades.
    private func highlight() {
        guard let rings = holder?.childNodes else { return }
        for (index, ring) in rings.enumerated() { ring.opacity = grab == nil || grab?.index == index ? 1 : 0.3 }
    }

    /// Grabs the wheel whose rim is under the finger (within about a thumb's width). True when one was grabbed.
    func pick(_ finger: SIMD2<Float>, pose: MannequinPose, project: (SIMD3<Float>) -> SIMD2<Float>?) -> Bool {
        grab = nil
        var best: (index: Int, spot: SIMD3<Float>, distance: Float)?
        for (index, wheel) in wheels.enumerated() {
            for spot in wheel.rim(72) {
                guard let shown = project(spot) else { continue }
                let distance = simd_length(shown - finger)
                if distance < (best?.distance ?? 28) { best = (index, spot, distance) }
            }
        }
        guard let best else { return false }
        grab = (best.index, best.spot, pose, 0)
        highlight()
        return true
    }

    /// The pose with the grabbed wheel turned so its grabbed spot comes under the finger.
    func turnWheel(to finger: SIMD2<Float>, project: (SIMD3<Float>) -> SIMD2<Float>?) -> MannequinPose? {
        guard var g = grab, g.index < wheels.count else { return nil }
        let wheel = wheels[g.index]
        let turned = wheel.turnToward(finger, grabbed: g.spot, near: g.turned, project: project)
        g.turned = turned
        grab = g
        return wheel.axis.changed(g.pose, by: turned / max(wheel.perDegree, 0.05), ratio: ratio)
    }

    func letGo() {
        grab = nil
        handleStart = nil
        highlight()
    }

    /// Starts dragging a turning handle (head, shoulder, wrist, ankle, hips) from `pose`.
    func beginHandle(_ pose: MannequinPose, finger: SIMD2<Float>) { handleStart = (pose, finger) }

    /// The pose with the handle's joint turned so the point it moves goes the way the finger has gone. `far` is set
    /// once the finger has gone a long way, when the wheels should be measured again from the pose now.
    func dragHandle(to finger: SIMD2<Float>, project: (SIMD3<Float>) -> SIMD2<Float>?) -> (pose: MannequinPose, far: Bool)? {
        guard let start = handleStart, !wheels.isEmpty else { return nil }
        var moves: [SIMD2<Float>] = []
        for wheel in wheels {
            guard let a = project(wheel.probe), let b = project(wheel.probeTurned) else { return nil }
            moves.append((b - a) / wheel.step)
        }
        let wanted = finger - start.finger
        let turns = PoseAxes.turns(for: wanted, moves: moves)
        var pose = start.pose
        for (wheel, turn) in zip(wheels, turns) { pose = wheel.axis.changed(pose, by: turn, ratio: ratio) }
        return (pose, simd_length(wanted) > 90)
    }
}
