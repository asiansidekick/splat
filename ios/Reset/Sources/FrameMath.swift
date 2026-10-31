import Foundation
import simd

// Where things in the room show in a saved frame, kept free of UIKit so the tests can run it on a Mac.

/// How a frame's photo (stored in the sensor's landscape layout) is turned to show upright.
enum FrameTurn {
    case asShot, half, clockwise, counterclockwise

    /// From which way was up when the frame was taken (same rule as `Keyframe.uprightOrientation`).
    init(cameraToWorld t: simd_float4x4) {
        let up = SIMD3<Float>(0, 1, 0)
        let alongX = simd_dot(t.columns.0.xyz, up)
        let alongY = simd_dot(t.columns.1.xyz, up)
        if abs(alongY) >= abs(alongX) {
            self = alongY >= 0 ? .asShot : .half
        } else {
            self = alongX < 0 ? .clockwise : .counterclockwise
        }
    }

    /// A place in the sensor picture (0 to 1 across and down) as it shows upright.
    func upright(fromSensor s: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .asShot: return s
        case .half: return SIMD2(1 - s.x, 1 - s.y)
        case .clockwise: return SIMD2(1 - s.y, s.x)
        case .counterclockwise: return SIMD2(s.y, 1 - s.x)
        }
    }

    /// The other way: a place in the upright picture as it sits in the sensor picture.
    func sensor(fromUpright u: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .asShot: return u
        case .half: return SIMD2(1 - u.x, 1 - u.y)
        case .clockwise: return SIMD2(u.y, 1 - u.x)
        case .counterclockwise: return SIMD2(1 - u.y, u.x)
        }
    }

    /// Whether width and height swap when the picture is turned upright.
    var swapsSides: Bool { self == .clockwise || self == .counterclockwise }
}

extension Keyframe {
    var turn: FrameTurn { FrameTurn(cameraToWorld: cameraToWorld) }

    /// Width over height of the picture as it shows upright.
    var uprightAspect: Float {
        let w = Float(max(imageWidth, 1)), h = Float(max(imageHeight, 1))
        return turn.swapsSides ? h / w : w / h
    }

    /// Where a point of the room shows in this frame's picture (0 to 1 across and down, sensor
    /// layout); nil when it is behind the camera or too close to place.
    func project(_ world: SIMD3<Float>) -> SIMD2<Float>? {
        let local = cameraToWorld.inverse * SIMD4(world.x, world.y, world.z, 1)
        let depth = -local.z
        guard depth > 0.05, imageWidth > 0, imageHeight > 0, intrinsics.count >= 9 else { return nil }
        let k = cameraIntrinsics
        let px = k[0][0] * local.x / depth + k[2][0]
        let py = -k[1][1] * local.y / depth + k[2][1]
        return SIMD2(px / Float(imageWidth), py / Float(imageHeight))
    }

    /// The point in the room `metres` straight out from a place in this frame's picture
    /// (0 to 1 across and down, sensor layout).
    func point(atSensor n: SIMD2<Float>, metres: Float) -> SIMD3<Float>? {
        guard imageWidth > 0, imageHeight > 0, intrinsics.count >= 9, metres > 0 else { return nil }
        let k = cameraIntrinsics
        let x = (n.x * Float(imageWidth) - k[2][0]) / k[0][0]
        let y = -(n.y * Float(imageHeight) - k[2][1]) / k[1][1]
        let world = cameraToWorld * SIMD4(x * metres, y * metres, -metres, 1)
        return SIMD3(world.x, world.y, world.z)
    }
}
