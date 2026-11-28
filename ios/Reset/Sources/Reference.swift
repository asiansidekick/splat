import ARKit
import Foundation
import simd

/// Stores references in the app's Documents folder, one folder per reference.
/// Everything stays on the device.
enum ReferenceStore {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("References", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func worldMapURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("worldmap.arexperience")
    }

    static func all() -> [Reference] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? load(metaURL: $0.appendingPathComponent("reference.json")) }
            .sorted { $0.created > $1.created }
    }

    static func load(metaURL: URL) throws -> Reference {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Reference.self, from: Data(contentsOf: metaURL))
    }

    static func save(_ reference: Reference) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let url = folder(for: reference.id).appendingPathComponent("reference.json")
        try encoder.encode(reference).write(to: url, options: .atomic)
    }

    static func saveWorldMap(_ map: ARWorldMap, for id: UUID) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try data.write(to: worldMapURL(for: id), options: .atomic)
    }

    static func loadWorldMap(for id: UUID) throws -> ARWorldMap {
        let data = try Data(contentsOf: worldMapURL(for: id))
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return map
    }

    static func delete(_ reference: Reference) {
        try? FileManager.default.removeItem(at: folder(for: reference.id))
    }
}
