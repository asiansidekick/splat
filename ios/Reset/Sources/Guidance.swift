import Foundation
import simd
import UIKit

/// How to move the device from where it is to where a reference photo was taken.
struct Offset {
    /// Metres in screen directions: right and up as the person sees the screen, forward into it.
    let right: Float
    let up: Float
    let forward: Float
    /// Angle between where the camera looks now and where it looked, radians.
    let turn: Float

    static let matchDistance: Float = 0.05
    static let matchAngle: Float = 3 * .pi / 180

    var vector: SIMD3<Float> { SIMD3(right, up, forward) }

    var isMatched: Bool {
        simd_length(SIMD3(right, up, forward)) < Offset.matchDistance && turn < Offset.matchAngle
    }

    var description: String {
        if isMatched { return "Matched. Line the props up with the ghost." }
        var steps: [String] = []
        func add(_ value: Float, _ positive: String, _ negative: String) {
            let cm = Int((abs(value) * 100).rounded())
            if cm >= 3 { steps.append("\(cm) cm \(value > 0 ? positive : negative)") }
        }
        add(right, "right", "left")
        add(up, "up", "down")
        add(forward, "forward", "back")
        var text = steps.isEmpty ? "" : "Move " + steps.joined(separator: ", ")
        let degrees = Int((turn * 180 / .pi).rounded())
        if degrees >= 3 {
            text += (text.isEmpty ? "Turn " : ", then turn ") + "\(degrees)° to match the ghost"
        }
        return text
    }
}

/// The guidance graphic's numbers, kept apart from the rest of the screen so updating them every
/// frame redraws only the graphic.
@MainActor
final class AimState: ObservableObject {
    /// On screen, where the reference camera was pointing; far off screen when it is behind.
    @Published private(set) var point: CGPoint?
    /// How far to turn the phone about its own axis, radians, clockwise positive.
    @Published private(set) var roll: Double = 0
    @Published private(set) var offset: Offset?

    func update(point: CGPoint, roll: Double, offset: Offset) {
        if let old = self.point, hypot(old.x - point.x, old.y - point.y) < 1.5, abs(self.roll - roll) < 0.01,
            let previous = self.offset, simd_distance(previous.vector, offset.vector) < 0.003
        { return }
        self.point = point
        self.roll = roll
        self.offset = offset
    }

    func clear() {
        point = nil
        offset = nil
    }
}

enum Guidance {
    /// The screen's right and up directions in world space. ARKit's camera axes follow the sensor,
    /// which sits landscape (x right, y up with the device turned so the camera is top left).
    static func screenAxes(_ camera: simd_float4x4, orientation: UIInterfaceOrientation) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let x = camera.columns.0.xyz
        let y = camera.columns.1.xyz
        switch orientation {
        case .landscapeRight: return (x, y)
        case .landscapeLeft: return (-x, -y)
        case .portraitUpsideDown: return (-y, x)
        default: return (y, -x)  // portrait
        }
    }

    /// Distance score between a live camera and a reference view: metres, plus 0.5 m per 30° of turn.
    static func score(_ camera: simd_float4x4, _ keyframe: Keyframe) -> Float {
        let position = camera.columns.3.xyz
        let forward = -camera.columns.2.xyz
        let angle = acos(min(1, max(-1, simd_dot(forward, keyframe.forward))))
        return simd_distance(position, keyframe.position) + angle / (.pi / 6) * 0.5
    }

    /// The point the camera is looking at: the middle of its depth map, in world space.
    static func target(camera: simd_float4x4, depth: [Float], width: Int, height: Int) -> SIMD3<Float>? {
        var samples: [Float] = []
        for v in (height / 2 - 4)...(height / 2 + 4) {
            for u in (width / 2 - 4)...(width / 2 + 4) where u >= 0 && u < width && v >= 0 && v < height {
                let d = depth[v * width + u]
                if d > 0.1 && d < DepthDiff.maxRange { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return nil }
        let d = samples.sorted()[samples.count / 2]
        return camera.columns.3.xyz + -camera.columns.2.xyz * d
    }

    /// Reference views that had `point` in their picture, best first: those that looked at it
    /// from the direction most like the viewer's, so off-camera and closer or further views work.
    static func views(seeing point: SIMD3<Float>, from viewer: SIMD3<Float>, in keyframes: [Keyframe], count: Int) -> [Keyframe] {
        let wanted = simd_normalize(point - viewer)
        let scored = keyframes.compactMap { keyframe -> (Keyframe, Float)? in
            let p = keyframe.cameraToWorld.inverse * SIMD4<Float>(point, 1)
            let z = -p.z
            guard z > 0.1, z < DepthDiff.maxRange else { return nil }
            let k = keyframe.cameraIntrinsics
            let u = k[0][0] * p.x / z + k[2][0]
            let v = -k[1][1] * p.y / z + k[2][1]
            guard u >= 0, u < Float(keyframe.imageWidth), v >= 0, v < Float(keyframe.imageHeight) else { return nil }
            return (keyframe, simd_dot(simd_normalize(point - keyframe.position), wanted))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(count).map { $0.0 }
    }

    static func closest(to camera: simd_float4x4, in keyframes: [Keyframe]) -> Keyframe? {
        keyframes.min { score(camera, $0) < score(camera, $1) }
    }

    static func closest(to camera: simd_float4x4, in keyframes: [Keyframe], count: Int) -> [Keyframe] {
        Array(keyframes.sorted { score(camera, $0) < score(camera, $1) }.prefix(count))
    }

    static func offset(from camera: simd_float4x4, to keyframe: Keyframe, orientation: UIInterfaceOrientation) -> Offset {
        let worldDelta = keyframe.position - camera.columns.3.xyz
        let (right, up) = screenAxes(camera, orientation: orientation)
        let forward = -camera.columns.2.xyz
        let turn = acos(min(1, max(-1, simd_dot(forward, keyframe.forward))))
        return Offset(
            right: simd_dot(worldDelta, right),
            up: simd_dot(worldDelta, up),
            forward: simd_dot(worldDelta, forward),
            turn: turn)
    }
}
