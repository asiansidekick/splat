import Foundation
import simd

/// How to move the device from where it is to where a reference photo was taken.
struct Offset {
    /// In the current camera's axes, metres: x right, y up, z forward.
    let right: Float
    let up: Float
    let forward: Float
    /// Angle between where the camera looks now and where it looked, radians.
    let turn: Float

    static let matchDistance: Float = 0.05
    static let matchAngle: Float = 3 * .pi / 180

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

enum Guidance {
    /// Distance score between a live camera and a reference view: metres, plus 0.5 m per 30° of turn.
    static func score(_ camera: simd_float4x4, _ keyframe: Keyframe) -> Float {
        let position = camera.columns.3.xyz
        let forward = -camera.columns.2.xyz
        let angle = acos(min(1, max(-1, simd_dot(forward, keyframe.forward))))
        return simd_distance(position, keyframe.position) + angle / (.pi / 6) * 0.5
    }

    static func closest(to camera: simd_float4x4, in keyframes: [Keyframe]) -> Keyframe? {
        keyframes.min { score(camera, $0) < score(camera, $1) }
    }

    static func closest(to camera: simd_float4x4, in keyframes: [Keyframe], count: Int) -> [Keyframe] {
        Array(keyframes.sorted { score(camera, $0) < score(camera, $1) }.prefix(count))
    }

    static func offset(from camera: simd_float4x4, to keyframe: Keyframe) -> Offset {
        let worldDelta = keyframe.position - camera.columns.3.xyz
        let right = camera.columns.0.xyz
        let up = camera.columns.1.xyz
        let forward = -camera.columns.2.xyz
        let turn = acos(min(1, max(-1, simd_dot(forward, keyframe.forward))))
        return Offset(
            right: simd_dot(worldDelta, right),
            up: simd_dot(worldDelta, up),
            forward: simd_dot(worldDelta, forward),
            turn: turn)
    }
}
