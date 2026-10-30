import Foundation

/// Reset's references as the shared sync sees them: each reference is an item (its folder), its
/// record is the reference, and its files are the photos, LiDAR depth, room map and 3D models.
/// Merging keeps everything from both phones; where both edited the same take, slate or model,
/// the newest edit wins, so every phone settles on the same answer whatever order things arrive.
/// Kept free of ARKit so the sync tests run it on a Mac.
@MainActor
final class ReferenceSyncLibrary: SyncLibrary {
    let root: URL
    /// False to fetch only photos and room maps (no LiDAR depth or 3D models), which is much
    /// quicker. Everything this phone has is still offered to teammates.
    var withDepth: Bool
    private let references: @MainActor () -> [Reference]
    private let save: @MainActor (Reference) -> Void

    init(root: URL, withDepth: Bool, references: @escaping @MainActor () -> [Reference], save: @escaping @MainActor (Reference) -> Void) {
        self.root = root
        self.withDepth = withDepth
        self.references = references
        self.save = save
    }

    static let mapFile = "worldmap.arexperience"
    /// Files over this size are not fetched.
    static let largest: Int64 = 500_000_000

    enum Kind { case photo, depth, map, model }

    /// Reset's own file names only: "frame_0001.jpg", "depth_0001.bin", "snap_1A2B3C4D.jpg",
    /// the room map, and "model-<UUID>.usdz" for a model stored as "models/<UUID>.usdz".
    nonisolated static func kind(_ name: String) -> Kind? {
        guard SyncEngine.safe(name) else { return nil }
        if name == mapFile { return .map }
        if name.hasPrefix("model-"), name.hasSuffix(".usdz") {
            return UUID(uuidString: String(name.dropFirst(6).dropLast(5))) != nil ? .model : nil
        }
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let stem = name[..<dot]
        guard !stem.isEmpty, stem.count <= 60, stem.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" || $0 == "-" })
        else { return nil }
        switch name[name.index(after: dot)...] {
        case "jpg": return .photo
        case "bin": return .depth
        default: return nil
        }
    }

    /// Where a file sits in the reference's folder: models are in a "models" folder.
    nonisolated static func path(_ name: String) -> String {
        kind(name) == .model ? "models/" + name.dropFirst(6) : name
    }

    /// The name a model file ("models/<UUID>.usdz") travels under.
    nonisolated static func syncName(modelFile file: String) -> String? {
        guard file.hasPrefix("models/") else { return nil }
        let name = "model-" + file.dropFirst(7)
        return kind(name) == .model ? name : nil
    }

    /// Dates to the second, as ReferenceStore saves them; keys sorted, so a record reads the
    /// same every time.
    nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func folder(_ itemID: String) -> URL? {
        guard let id = UUID(uuidString: itemID) else { return nil }
        return root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func syncItems() -> [SyncItem] {
        references().compactMap { reference in
            guard let record = try? Self.encoder.encode(reference) else { return nil }
            let folder = root.appendingPathComponent(reference.id.uuidString, isDirectory: true)
            var names: [String] = []
            for frame in reference.keyframes + reference.snapshots.map(\.frame) {
                names.append(frame.imageFile)
                if let depth = frame.depthFile { names.append(depth) }
            }
            if !reference.photoOnly { names.append(Self.mapFile) }
            names += reference.models.compactMap { Self.syncName(modelFile: $0.file) }
            var seen: Set<String> = []
            let files = names.compactMap { name -> SyncFile? in
                guard Self.kind(name) != nil, seen.insert(name).inserted else { return nil }
                let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(Self.path(name)).path)
                return (attributes?[.size] as? NSNumber).map { SyncFile(name: name, size: $0.int64Value) }
            }
            return SyncItem(id: reference.id.uuidString, record: record, files: files)
        }
    }

    func hasFile(itemID: String, name: String) -> Bool {
        guard let folder = folder(itemID), Self.kind(name) != nil else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.path(name)).path)
    }

    func wants(itemID: String, file: SyncFile) -> Bool {
        guard folder(itemID) != nil, let kind = Self.kind(file.name), file.size < Self.largest else { return false }
        return withDepth || (kind != .depth && kind != .model)
    }

    func fileURL(itemID: String, name: String) -> URL? {
        guard let folder = folder(itemID), Self.kind(name) != nil else { return nil }
        let url = folder.appendingPathComponent(Self.path(name))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func keep(_ url: URL, itemID: String, name: String) -> Bool {
        guard let folder = folder(itemID), let kind = Self.kind(name) else { return false }
        let target = folder.appendingPathComponent(Self.path(name))
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if kind == .photo {
                // Pictures are read and checked, and lose any location or camera details.
                guard let cleaned = PhotoPrivacy.cleaned(try Data(contentsOf: url)) else { return false }
                try cleaned.write(to: target, options: .atomic)
                return true
            }
            // Depth, maps and models can be big: check how they start and copy them as they are.
            guard Self.looksRight(url, kind: kind) else { return false }
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: url, to: target)
            return true
        } catch {
            return false
        }
    }

    /// Depth is whole 32-bit numbers; a room map is a binary property list (what ARKit's map
    /// archive is); a USDZ model is a zip.
    nonisolated static func looksRight(_ url: URL, kind: Kind) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
            size.int64Value > 0, size.int64Value < largest,
            let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        let start = (try? handle.read(upToCount: 8)) ?? Data()
        switch kind {
        case .depth: return size.int64Value % 4 == 0
        case .map: return start.starts(with: Data("bplist00".utf8))
        case .model: return start.starts(with: [0x50, 0x4B, 0x03, 0x04])
        case .photo: return true
        }
    }

    func merge(itemID: String, record: Data) -> Bool {
        guard let folder = folder(itemID), let incoming = try? Self.decoder.decode(Reference.self, from: record),
            incoming.id == UUID(uuidString: itemID)
        else { return false }
        let local = references().first { $0.id == incoming.id }
        let manager = FileManager.default
        let merged = Self.merged(local: local, incoming: incoming) { name in
            manager.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        guard let merged, merged != local else { return false }
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        save(merged)
        return true
    }

    /// This phone's reference with a teammate's folded in. `has` says whether a file (by its
    /// path in the folder) is here. Nil while a new reference's photos or room map are missing.
    /// Views and snapshots never change once taken; takes, the slate and models keep the newest
    /// edit (ties go the same way on every phone); deleted takes stay deleted.
    nonisolated static func merged(local: Reference?, incoming: Reference, has: @escaping (String) -> Bool) -> Reference? {
        /// A view as far as its files are here: nil without its photo, no depth without its depth.
        func arrived(_ frame: Keyframe) -> Keyframe? {
            guard has(frame.imageFile) else { return nil }
            guard let depth = frame.depthFile, !has(depth) else { return frame }
            return Keyframe(
                imageFile: frame.imageFile, depthFile: nil, transform: frame.transform, intrinsics: frame.intrinsics,
                imageWidth: frame.imageWidth, imageHeight: frame.imageHeight, depthWidth: frame.depthWidth, depthHeight: frame.depthHeight)
        }
        /// This phone's view, given the teammate's depth for it once that is here.
        func upgraded(_ mine: Keyframe, from theirs: [Keyframe]) -> Keyframe {
            guard mine.depthFile == nil, let other = theirs.first(where: { $0.imageFile == mine.imageFile }),
                let depth = other.depthFile, has(depth)
            else { return mine }
            return other
        }

        var result: Reference
        if let local {
            result = local
        } else {
            let keyframes = incoming.keyframes.compactMap(arrived)
            guard !keyframes.isEmpty, keyframes.count == incoming.keyframes.count, incoming.photoOnly || has(mapFile) else { return nil }
            result = incoming
            result.keyframes = keyframes
            result.takes = []
            result.snapshots = []
            result.models = []
            result.removedTakes = []
            result.measurements = []
            result.notes = []
            result.removedMarks = []
        }

        result.keyframes = result.keyframes.map { upgraded($0, from: incoming.keyframes) }

        if newer(incoming.slateEdited, slateKey(incoming), than: result.slateEdited, slateKey(result)) {
            result.scene = incoming.scene
            result.setup = incoming.setup
            result.name = incoming.name
            result.slateEdited = incoming.slateEdited
        }

        let removed = Set(result.removedTakes)
        result.removedTakes += incoming.removedTakes.filter { !removed.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        let gone = Set(result.removedTakes)
        for take in incoming.takes where !gone.contains(take.id) {
            if let index = result.takes.firstIndex(where: { $0.id == take.id }) {
                let mine = result.takes[index]
                if newer(take.edited, key(take), than: mine.edited, key(mine)) { result.takes[index] = take }
            } else {
                result.takes.append(take)
            }
        }
        result.takes.removeAll { gone.contains($0.id) }

        result.snapshots = result.snapshots.map { mine in
            guard let theirs = incoming.snapshots.first(where: { $0.id == mine.id }) else { return mine }
            var kept = mine
            kept.frame = upgraded(mine.frame, from: [theirs.frame])
            return kept
        }
        for snapshot in incoming.snapshots where !result.snapshots.contains(where: { $0.id == snapshot.id }) {
            guard let frame = arrived(snapshot.frame) else { continue }
            var kept = snapshot
            kept.frame = frame
            result.snapshots.append(kept)
        }

        for model in incoming.models {
            if let index = result.models.firstIndex(where: { $0.id == model.id }) {
                let mine = result.models[index]
                if newer(model.moved, key(model), than: mine.moved, key(mine)) {
                    // Only where it is: the file stays the one this phone has.
                    result.models[index].transform = model.transform
                    result.models[index].moved = model.moved
                }
            } else if model.file.hasPrefix("models/"), has(model.file) {
                result.models.append(model)
            }
        }
        // Measurements and notes never change once made: new ones are added, deleted ones go.
        let unmarked = Set(result.removedMarks)
        result.removedMarks += incoming.removedMarks.filter { !unmarked.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        let goneMarks = Set(result.removedMarks)
        for measurement in incoming.measurements where !goneMarks.contains(measurement.id) && !result.measurements.contains(where: { $0.id == measurement.id }) {
            result.measurements.append(measurement)
        }
        for note in incoming.notes where !goneMarks.contains(note.id) && !result.notes.contains(where: { $0.id == note.id }) {
            result.notes.append(note)
        }
        result.measurements.removeAll { goneMarks.contains($0.id) }
        result.notes.removeAll { goneMarks.contains($0.id) }
        return result
    }

    /// Whether the teammate's version wins: the later edit, or on a tie (or never edited) the
    /// one that sorts last, so every phone makes the same choice.
    nonisolated static func newer(_ theirs: Date?, _ theirKey: String, than mine: Date?, _ myKey: String) -> Bool {
        let a = theirs ?? .distantPast
        let b = mine ?? .distantPast
        return a != b ? a > b : theirKey > myKey
    }

    nonisolated static func slateKey(_ reference: Reference) -> String {
        [reference.scene, reference.setup, reference.name].joined(separator: "\u{1F}")
    }

    nonisolated static func key<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
