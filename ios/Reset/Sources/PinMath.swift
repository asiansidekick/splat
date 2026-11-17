import simd

/// Pinning a placed object's distance from two views (Phil, 2026-11-17: "objects drift in parallax"). Seen from one
/// place, an object set too near or too far still looks right; it only slides once the phone moves. So the first
/// view's line of sight is kept, and from a step to the side the object is slid along that line until it covers its
/// spot again: where the two lines of sight meet is its true place.
enum PinMath {
    /// How far along the first line (from `origin`, along the unit `direction`) it comes closest to a second line.
    /// Nil when the two run nearly side by side, or meet behind the first camera.
    static func along(origin: SIMD3<Float>, direction: SIMD3<Float>, from second: SIMD3<Float>, toward look: SIMD3<Float>) -> Float? {
        let b = simd_dot(direction, look)
        let spread = 1 - b * b
        guard spread > 0.0004 else { return nil }
        let w = origin - second
        let t = (b * simd_dot(look, w) - simd_dot(direction, w)) / spread
        return t > 0 ? t : nil
    }

    /// How far a camera has stepped to the side of a line of sight.
    static func aside(origin: SIMD3<Float>, direction: SIMD3<Float>, camera: SIMD3<Float>) -> Float {
        let w = camera - origin
        return simd_length(w - direction * simd_dot(w, direction))
    }

    /// The step to the side that is enough for an object `distance` away: a tenth of the way, between 12 and 50 cm.
    static func stepNeeded(distance: Float) -> Float { min(max(distance * 0.1, 0.12), 0.5) }
}
