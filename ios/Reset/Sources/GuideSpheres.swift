import ARKit
import UIKit
import simd

/// Where the alignment guide's two balls go. One hangs in the room where it would have been in
/// front of the reference camera; the other rides in front of the phone. Standing and pointing
/// where the reference was taken lays one exactly over the other, with their dividing lines
/// level. The balls are drawn flat on top of the ghost (`GuideBall`), so the ghost strength
/// slider never fades them.
enum GuideSpheres {
    /// How far in front of the camera the balls sit, metres.
    static let distance: Float = 0.6
    static let radius: Float = 0.035
    /// How much the phone's ball tips for each degree the phone is tilted off the reference.
    static let tiltGain: Float = 3

    /// The balls sit centred, low in the picture, metres below the middle at `distance`, so the
    /// middle stays clear for lining up the ghost. Less when landscape, where the picture is
    /// shorter.
    static func drop(_ orientation: UIInterfaceOrientation) -> Float {
        orientation.isLandscape ? 0.08 : 0.15
    }

    /// Where the reference's ball hangs in the room, for the phone held this way.
    static func position(for keyframe: Keyframe, orientation: UIInterfaceOrientation) -> SIMD3<Float> {
        (keyframe.cameraToWorld * SIMD4(spot(orientation), 1)).xyz
    }

    /// Where the phone's own ball is, in the room, for the phone held this way.
    static func livePosition(camera: simd_float4x4, orientation: UIInterfaceOrientation) -> SIMD3<Float> {
        (camera * SIMD4(spot(orientation), 1)).xyz
    }

    /// How much higher (positive) or lower the reference camera looked than the phone does now,
    /// radians, times `tiltGain`, kept within about 70 degrees.
    static func tip(camera: simd_float4x4, keyframe: Keyframe, orientation: UIInterfaceOrientation) -> Float {
        let (_, up) = axes(orientation)
        // The reference's view direction, in the phone camera's own axes.
        let toReference = camera.inverse * keyframe.cameraToWorld
        let forward = -toReference.columns.2.xyz
        let pitch = atan2(simd_dot(forward, up), -forward.z)
        return max(-1.2, min(1.2, pitch * tiltGain))
    }

    /// Right and up on the screen, in ARKit's camera axes (which follow the sensor), for the
    /// phone held this way.
    static func axes(_ orientation: UIInterfaceOrientation) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        switch orientation {
        case .landscapeRight: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .landscapeLeft: return (SIMD3(-1, 0, 0), SIMD3(0, -1, 0))
        case .portraitUpsideDown: return (SIMD3(0, -1, 0), SIMD3(1, 0, 0))
        default: return (SIMD3(0, 1, 0), SIMD3(-1, 0, 0))  // portrait
        }
    }

    /// In ARKit's camera axes: `distance` ahead, low in the middle of the screen.
    static func spot(_ orientation: UIInterfaceOrientation) -> SIMD3<Float> {
        let (_, up) = axes(orientation)
        return -up * drop(orientation) - SIMD3(0, 0, 1) * distance
    }
}
