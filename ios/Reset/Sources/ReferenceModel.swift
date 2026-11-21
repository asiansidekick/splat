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
    var setup: String  // the take number, "3" (or "3B" for a redo); an old letter-only one reads 12B
    /// QTAKE's middle level: the shot letter, "A", between scene and take. Empty for none.
    var shot = ""
    /// Starred as a hero reference, like favouriting a photo: the one that is right for the scene.
    var hero = false
    var name: String  // optional description, "desk"
    /// A sub-group within the scene, such as "Hair" or "Kitchen angle" (Phil, 2026-11-05); empty for none.
    var group = ""
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
    /// Lines measured in the room, and notes pinned in it (Phil, 2026-10-30).
    var measurements: [RoomMeasurement] = []
    var notes: [RoomNote] = []
    /// Measurements and notes deleted on any phone, so syncing does not bring them back.
    var removedMarks: [UUID] = []
    /// The torch level it was shot with, nil when the torch was off.
    var torch: Float?
    /// For a photo with no depth: how far out (metres) a length typed along something known puts the flat
    /// scene, so lines drawn on it afterwards read true. Keyed by the frame's image file.
    var planeDepths: [String: Float] = [:]

    var hasDepth: Bool { keyframes.contains { $0.depthFile != nil } }
    var slate: String { Reference.label(scene: scene, setup: setup, shot: shot) }
    /// Just the take number for small thumbnails: "18", "3B", or "12B" for an old letter-only setup.
    var number: String { setup.first?.isNumber == true ? setup : scene + setup }

    /// How a scene and setup read: "Sc 1 · Tk 3", or "Sc 1 · Tk 3B" with a letter after the
    /// number; a setup that is only a letter reads the way old ones were slated, "12B".
    static func label(scene: String, setup: String, shot: String = "") -> String {
        guard setup.first?.isNumber == true else { return scene + shot + setup }
        if !shot.isEmpty {
            return scene.isEmpty ? "Shot \(shot) · Tk \(setup)" : "Sc \(scene) · Shot \(shot) · Tk \(setup)"
        }
        return scene.isEmpty ? "Tk \(setup)" : "Sc \(scene) · Tk \(setup)"
    }
    var title: String {
        if slate.isEmpty { return name }
        return name.isEmpty ? slate : "\(slate) · \(name)"
    }
    /// Words for a thumbnail, most useful first: its description, then the latest take note, then a note
    /// pinned in the room, then its group. Empty ones are skipped.
    func captionLines(count: Int) -> [String] {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let takeNote = takes.sorted { $0.logged > $1.logged }.map { trim($0.note) }.first { !$0.isEmpty }
        let roomNote = notes.map { trim($0.text) }.first { !$0.isEmpty }
        let all = [trim(name), takeNote ?? "", roomNote ?? "", trim(group)].filter { !$0.isEmpty }
        var seen = Set<String>()
        return Array(all.filter { seen.insert($0).inserted }.prefix(count))
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
        shot = try c.decodeIfPresent(String.self, forKey: .shot) ?? ""
        hero = try c.decodeIfPresent(Bool.self, forKey: .hero) ?? false
        name = try c.decode(String.self, forKey: .name)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        created = try c.decode(Date.self, forKey: .created)
        keyframes = try c.decode([Keyframe].self, forKey: .keyframes)
        takes = try c.decodeIfPresent([Take].self, forKey: .takes) ?? []
        snapshots = try c.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
        models = try c.decodeIfPresent([PlacedModel].self, forKey: .models) ?? []
        photoOnly = try c.decodeIfPresent(Bool.self, forKey: .photoOnly) ?? false
        slateEdited = try c.decodeIfPresent(Date.self, forKey: .slateEdited)
        removedTakes = try c.decodeIfPresent([UUID].self, forKey: .removedTakes) ?? []
        measurements = try c.decodeIfPresent([RoomMeasurement].self, forKey: .measurements) ?? []
        notes = try c.decodeIfPresent([RoomNote].self, forKey: .notes) ?? []
        removedMarks = try c.decodeIfPresent([UUID].self, forKey: .removedMarks) ?? []
        torch = try c.decodeIfPresent(Float.self, forKey: .torch)
        planeDepths = try c.decodeIfPresent([String: Float].self, forKey: .planeDepths) ?? [:]
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
    /// Set for an example mannequin, so it can be posed again (Examples.swift).
    var mannequin: MannequinSpec?
    /// The pose given to an imported rigged character (an FBX file), nil while it stands as its file has it.
    var rigPose: MannequinPose?
    /// Made from one of Reset's own scans (its colours are photographs, shown unlit), whatever it is now called.
    var scan: Bool?
    /// Phil, 2026-11-21: "control over lighting of each model". Nil while it is lit as it always was.
    var light: ModelLight?
}

/// How one placed model is lit (ModelLighting.swift): brighter or darker, warmer or cooler, and optionally a light from
/// one side of the room, so it matches the set's lamps. Plain numbers, so it saves and syncs with the model.
struct ModelLight: Codable, Equatable {
    /// 1 as it was; 0.2 (very dark) to 3 (very bright).
    var brightness: Float = 1
    /// 0 as it was; up to 1 for tungsten-warm, down to -1 for daylight-blue.
    var warmth: Float = 0
    /// Where the light comes from, round the room from the north of the room's map (radians); nil for no side light.
    var around: Float?
    /// How high the light is: 0 level with the model, up to 1.4 (almost overhead), down to -0.3 (from below).
    var height: Float = 0.6

    static let brightnessRange: ClosedRange<Float> = 0.2...3
    static let warmthRange: ClosedRange<Float> = -1...1
    static let heightRange: ClosedRange<Float> = -0.3...1.4

    /// Nothing changed from how the model always looked.
    var isPlain: Bool { abs(brightness - 1) < 0.01 && abs(warmth) < 0.01 && around == nil }

    /// The colour the model's own colours are multiplied by: brightness times a warm or cool tint, gentle enough
    /// that a costume never turns orange or blue.
    var tint: SIMD3<Float> {
        let w = min(max(warmth, Self.warmthRange.lowerBound), Self.warmthRange.upperBound)
        let colour = w >= 0
            ? SIMD3<Float>(1, 1 - 0.14 * w, 1 - 0.42 * w)
            : SIMD3<Float>(1 - 0.32 * -w, 1 - 0.1 * -w, 1)
        return colour * min(max(brightness, Self.brightnessRange.lowerBound), Self.brightnessRange.upperBound)
    }

    /// The way to the light from the model, in room coordinates (y up), or nil for no side light.
    var direction: SIMD3<Float>? {
        guard let around else { return nil }
        let up = min(max(height, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        return SIMD3(cos(up) * sin(around), sin(up), cos(up) * cos(around))
    }

    /// How much a point of the surface facing `normal` is lit by the side light: 1 where no side light is set, about
    /// 1.3 facing the light, 0.45 turned away from it. The same sum as the shader in ModelLighting.swift.
    func shade(normal: SIMD3<Float>) -> Float {
        guard let direction else { return 1 }
        let facing = min(max(simd_dot(simd_normalize(normal), direction), 0), 1)
        return 0.45 + 0.85 * facing
    }

    /// A drag on the picture: right or up raises the value, as on every other control.
    mutating func change(_ part: Part, by moved: SIMD2<Float>) {
        switch part {
        case .brightness:
            brightness = min(max(brightness * exp((moved.x - moved.y) * 0.004), Self.brightnessRange.lowerBound), Self.brightnessRange.upperBound)
            if abs(brightness - 1) < 0.03 { brightness = 1 }
        case .warmth:
            warmth = min(max(warmth + (moved.x - moved.y) * 0.004, Self.warmthRange.lowerBound), Self.warmthRange.upperBound)
            if abs(warmth) < 0.03 { warmth = 0 }
        case .direction:
            // Sideways swings the light round the model; up raises it.
            let next = (around ?? 0) + moved.x * 0.012
            around = atan2(sin(next), cos(next))
            height = min(max(height - moved.y * 0.008, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        }
    }

    /// What one finger changes while the Light tool is on.
    enum Part: String, CaseIterable { case direction = "Direction", brightness = "Brightness", warmth = "Warmth" }

    /// A few words for the value now, for example "140%" or "warmer 30".
    func words(_ part: Part) -> String {
        switch part {
        case .brightness: return "\(Int((brightness * 100).rounded()))%"
        case .warmth:
            let amount = Int((abs(warmth) * 100).rounded())
            return amount == 0 ? "as shot" : (warmth > 0 ? "warmer \(amount)" : "cooler \(amount)")
        case .direction: return around == nil ? "off" : "on"
        }
    }
}

/// A straight line measured in the room, between two points in its coordinates (metres).
struct RoomMeasurement: Codable, Identifiable, Equatable {
    var id = UUID()
    var a: [Float]  // x, y, z
    var b: [Float]
    var created: Date
    /// A length typed in by the person (metres), shown instead of the measured one.
    var typed: Float?
    /// When the typed length was last changed, so syncing phones keep the newest.
    var edited: Date?
    /// The tape or A4 correction in force when the line was drawn. It stretches the length only: the two
    /// points stay exactly where the camera saw the surface, so the line keeps sticking to it as the phone moves.
    var scale: Float?
    /// The reading was doubtful when it was drawn (dark, shiny, or depth and ARKit disagreed), so it is not used to learn from.
    var unsure: Bool?

    var start: SIMD3<Float> { vector3(a) }
    var end: SIMD3<Float> { vector3(b) }
    /// What the phone measured between the two points, after the tape or A4 correction.
    var measured: Float { simd_distance(start, end) * (scale ?? 1) }
    /// What is shown: the typed length if there is one, else the measured one.
    var length: Float { typed ?? measured }
}

/// Lengths typed and shown by people: "29.7", "29.7 cm", "0.3 m", "300 mm", "12 in", "2 ft".
enum LengthText {
    /// Metres from what was typed; a bare number is centimetres. Nil if it isn't a sensible length.
    static func parse(_ text: String) -> Float? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty else { return nil }
        var unit: Float = 0.01
        for (suffix, metres) in [("mm", Float(0.001)), ("cm", 0.01), ("m", 1), ("in", 0.0254), ("\"", 0.0254), ("ft", 0.3048), ("'", 0.3048)] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            unit = metres
            break
        }
        guard let value = Float(t), value.isFinite else { return nil }
        let metres = value * unit
        return metres >= 0.001 && metres <= 100 ? metres : nil
    }

    /// Tenths of a centimetre up to a metre, then metres.
    static func format(_ metres: Float) -> String {
        metres < 1 ? String(format: "%.1f cm", metres * 100) : String(format: "%.2f m", metres)
    }
}

/// A note pinned to a spot in the room, such as "cup handle faces camera".
struct RoomNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var position: [Float]  // x, y, z
    var created: Date
    /// When the text or place was last changed, so syncing phones keep the newest.
    var edited: Date?

    var spot: SIMD3<Float> { vector3(position) }
}

/// A point saved as three numbers; nonsense (too few) reads as the origin.
func vector3(_ v: [Float]) -> SIMD3<Float> {
    v.count >= 3 ? SIMD3(v[0], v[1], v[2]) : .zero
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
