import Foundation
import simd

// Reset's saved data, kept free of ARKit and SwiftUI so the sync tests can run it on a Mac.

/// One saved camera view of the reference: a photo, where the camera was, and optionally LiDAR depth.
struct Keyframe: Codable, Identifiable, Equatable {
    var id: String { imageFile }
    let imageFile: String
    let depthFile: String?
    let transform: [Float]  // camera-to-world, 16 values, column major
    let intrinsics: [Float]  // 3x3, column major, in image pixels
    let imageWidth: Int
    let imageHeight: Int
    let depthWidth: Int
    let depthHeight: Int

    var cameraToWorld: simd_float4x4 { matrix4(transform) }
    var cameraIntrinsics: simd_float3x3 { matrix3(intrinsics) }
    var position: SIMD3<Float> { cameraToWorld.columns.3.xyz }
    /// The direction the camera looks (ARKit cameras look down -z).
    var forward: SIMD3<Float> { -cameraToWorld.columns.2.xyz }
}

/// A saved reference: the set as it should look for one setup, for example at the start of take 1.
struct Reference: Codable, Identifiable, Equatable {
    let id: UUID
    var scene: String  // "12"
    var setup: String  // "B", so the slate reads 12B
    var name: String  // optional description, "desk"
    let created: Date
    var keyframes: [Keyframe]
    var takes: [Take] = []
    /// Photos (and depth) taken later from the reset screen, in the same room coordinates.
    var snapshots: [Snapshot] = []
    /// USDZ models placed in the room, such as scans of props.
    var models: [PlacedModel] = []
    /// Imported from Photos: one photo with no room map, shown as a plain see-through ghost.
    var photoOnly = false
    /// When the scene, setup or description was last edited, so syncing phones keep the newest.
    var slateEdited: Date?
    /// Takes deleted on any phone, so syncing does not bring them back.
    var removedTakes: [UUID] = []

    var hasDepth: Bool { keyframes.contains { $0.depthFile != nil } }
    var slate: String { scene + setup }
    var title: String {
        if slate.isEmpty { return name }
        return name.isEmpty ? slate : "\(slate) · \(name)"
    }
    var nextTakeNumber: Int { (takes.map(\.number).max() ?? 0) + 1 }
}

extension Reference {
    /// References saved before scenes and takes existed have only a name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
        setup = try c.decodeIfPresent(String.self, forKey: .setup) ?? ""
        name = try c.decode(String.self, forKey: .name)
        created = try c.decode(Date.self, forKey: .created)
        keyframes = try c.decode([Keyframe].self, forKey: .keyframes)
        takes = try c.decodeIfPresent([Take].self, forKey: .takes) ?? []
        snapshots = try c.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
        models = try c.decodeIfPresent([PlacedModel].self, forKey: .models) ?? []
        photoOnly = try c.decodeIfPresent(Bool.self, forKey: .photoOnly) ?? false
        slateEdited = try c.decodeIfPresent(Date.self, forKey: .slateEdited)
        removedTakes = try c.decodeIfPresent([UUID].self, forKey: .removedTakes) ?? []
    }
}

/// A photo of the set taken during a reset, for example just before take 3, to compare later.
struct Snapshot: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var taken: Date
    var frame: Keyframe
}

/// One take shot on a setup, with the script supervisor style notes that go with it.
struct Take: Codable, Identifiable, Equatable {
    var id = UUID()
    var number: Int
    var logged: Date
    var note = ""
    var circled = false  // a good take, circled on the report
    var resetChecked = false  // the set matched the reference before this take
    /// When it was last edited, so syncing phones keep the newest version.
    var edited: Date?
}

/// A 3D model (USDZ) placed in a reference's room, for example a Polycam scan of a prop, kept in
/// the reference's room coordinates so it comes back in the same place.
struct PlacedModel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var file: String  // relative to the reference folder
    var transform: [Float]  // model-to-world, 16 values, column major
    /// When it was last moved, scaled or turned, so syncing phones keep the newest place.
    var moved: Date?
}

// MARK: - Matrix helpers

func flatten(_ m: simd_float4x4) -> [Float] {
    [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
}

func flatten(_ m: simd_float3x3) -> [Float] {
    [m.columns.0, m.columns.1, m.columns.2].flatMap { [$0.x, $0.y, $0.z] }
}

func matrix4(_ v: [Float]) -> simd_float4x4 {
    simd_float4x4(
        SIMD4(v[0], v[1], v[2], v[3]),
        SIMD4(v[4], v[5], v[6], v[7]),
        SIMD4(v[8], v[9], v[10], v[11]),
        SIMD4(v[12], v[13], v[14], v[15]))
}

func matrix3(_ v: [Float]) -> simd_float3x3 {
    simd_float3x3(SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]))
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
