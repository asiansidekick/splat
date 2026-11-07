import Foundation

/// How a phone is held, from gravity alone, so it means the same in a trailer, on set or on
/// location: no room map needed. Both angles are in the saved photo's own directions.
struct Attitude: Codable, Equatable, Hashable {
    /// Degrees the camera looks above the horizon (below is negative).
    var pitch: Double
    /// Degrees the phone is twisted clockwise from level, as the photo shows it.
    var roll: Double

    /// From the gravity vector in the phone's own axes (x right, y up, z out of the screen, as
    /// CoreMotion gives it), the angle the camera turns frames upright by (0, 90, 180 or 270, as
    /// AVFoundation counts it) and whether it is the front camera. Nil when the camera points
    /// nearly straight up or down, where "level" means nothing.
    static func from(gravity g: (x: Double, y: Double, z: Double), uprightAngle: Double, front: Bool) -> Attitude? {
        let length = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard length > 0.5, length.isFinite else { return nil }
        let x = g.x / length, y = g.y / length, z = g.z / length
        guard abs(z) < 0.94 else { return nil }
        // The photo's up and right, in the phone's x and y: the sensor's own right is the phone's
        // +y and its up the phone's -x; each quarter turn swings them round.
        let quarter = ((Int((uprightAngle / 90).rounded()) % 4) + 4) % 4
        var up: (Double, Double)
        var right: (Double, Double)
        switch quarter {
        case 0: (up, right) = ((-1, 0), (0, 1))
        case 1: (up, right) = ((0, 1), (1, 0))
        case 2: (up, right) = ((1, 0), (0, -1))
        default: (up, right) = ((0, -1), (-1, 0))
        }
        // The front camera looks the other way, and its unmirrored picture runs the other way.
        if front { right = (-right.0, -right.1) }
        let roll = atan2(x * right.0 + y * right.1, -(x * up.0 + y * up.1)) * 180 / .pi
        let pitch = asin(max(-1, min(1, front ? -z : z))) * 180 / .pi
        return Attitude(pitch: pitch, roll: roll)
    }

    /// What to do to hold the phone the way `reference` was held: tilt up (above zero) or down, and
    /// twist clockwise (above zero) or back. Twist is the short way round.
    func errors(to reference: Attitude) -> (pitch: Double, roll: Double) {
        var turn = (reference.roll - roll).truncatingRemainder(dividingBy: 360)
        if turn > 180 { turn -= 360 }
        if turn < -180 { turn += 360 }
        return (reference.pitch - pitch, turn)
    }
}
