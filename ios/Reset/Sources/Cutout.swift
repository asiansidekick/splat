import Foundation
import simd

// Scrapbook cut-outs: a few photos of a person or thing from different sides, each lifted off its background,
// stood up in the room like a cardboard cut-out. Foundation only, so the sync tests can run it on a Mac.

/// One cut-out as saved in a reference's `models` folder ("models/<UUID>.cutout"): JSON, so it travels
/// between phones like a model does.
struct CutoutPackage: Codable, Equatable {
    struct View: Codable, Equatable {
        /// The side of the thing this photo shows, in degrees: 0 front, 90 its left, 180 back, -90 its right.
        var angle: Float
        /// The lifted picture, transparent around the thing and cropped to it (PNG).
        var png: Data
        /// Width over height of that picture.
        var aspect: Float
    }

    var name: String
    /// How tall the thing really is (metres): every photo is scaled so the thing stands this tall.
    var height: Float
    var views: [View]
}

enum Cutout {
    static let fileExtension = "cutout"

    /// Where the camera is around the cut-out, in degrees: 0 in front of it, positive toward its left,
    /// 180 behind. `front` is the way it faces; only the flat (x, z) directions count.
    static func viewAngle(camera: SIMD3<Float>, position: SIMD3<Float>, front: SIMD3<Float>) -> Float {
        let toCamera = SIMD2<Float>(camera.x - position.x, camera.z - position.z)
        let facing = SIMD2<Float>(front.x, front.z)
        guard simd_length(toCamera) > 0.0001, simd_length(facing) > 0.0001 else { return 0 }
        let v = simd_normalize(toCamera), f = simd_normalize(facing)
        // Its left is the front turned a quarter toward +x when it faces +z: (f.y, -f.x) in (x, z).
        let left = SIMD2<Float>(f.y, -f.x)
        return atan2(simd_dot(v, left), simd_dot(v, f)) * 180 / .pi
    }

    /// Smallest turn between two angles, 0 to 180.
    static func gap(_ a: Float, _ b: Float) -> Float {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return abs(d)
    }

    /// The photo that shows the side nearest to where the camera is.
    static func nearest(_ angles: [Float], to angle: Float) -> Int? {
        angles.indices.min { gap(angles[$0], angle) < gap(angles[$1], angle) }
    }

    /// A facing for a new cut-out standing at `position`, turned to look at the camera.
    static func frontFacing(camera: SIMD3<Float>, position: SIMD3<Float>) -> simd_float4x4 {
        var f = SIMD3<Float>(camera.x - position.x, 0, camera.z - position.z)
        f = simd_length(f) > 0.0001 ? simd_normalize(f) : SIMD3(0, 0, 1)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(f.z, 0, -f.x, 0)
        m.columns.2 = SIMD4(f.x, 0, f.z, 0)
        m.columns.3 = SIMD4(position, 1)
        return m
    }
}
