import Foundation

/// Match's boards as the shared sync sees them: each board is an item, its record is the board
/// (only the photos being shared), its files are each photo, thumbnail and LiDAR depth. Merging
/// follows the same rules as opening a team pack: nothing here is overwritten.
@MainActor
final class BoardSyncLibrary: SyncLibrary {
    let root: URL
    /// What this phone shares. It still takes in everything teammates share.
    var content: TeamPack.Content
    private let boards: @MainActor () -> [Board]
    private let save: @MainActor (Board) -> Void

    init(root: URL, content: TeamPack.Content, boards: @escaping @MainActor () -> [Board], save: @escaping @MainActor (Board) -> Void) {
        self.root = root
        self.content = content
        self.boards = boards
        self.save = save
    }

    enum Kind { case photo, thumbnail, depth }

    /// Match's own file names only: "<UUID>.jpg", "<UUID>-thumb.jpg", "<UUID>-depth.bin".
    static func kind(_ name: String) -> Kind? {
        for (suffix, kind) in [("-thumb.jpg", Kind.thumbnail), ("-depth.bin", .depth), (".jpg", .photo)] where name.hasSuffix(suffix) {
            return UUID(uuidString: String(name.dropLast(suffix.count))) != nil ? kind : nil
        }
        return nil
    }

    private func folder(_ itemID: String) -> URL? {
        guard let id = UUID(uuidString: itemID) else { return nil }
        return root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func syncItems() -> [SyncItem] {
        TeamPack.trimmed(boards(), content: content, root: root).compactMap { board in
            guard let record = try? TeamPack.encoder.encode(board) else { return nil }
            let folder = root.appending(path: board.id.uuidString)
            let files = board.shots.flatMap { [$0.file, $0.thumbnailFile, $0.depthFile] }.compactMap { name -> SyncFile? in
                let size = (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path))?[.size] as? NSNumber
                return size.map { SyncFile(name: name, size: $0.int64Value) }
            }
            return SyncItem(id: board.id.uuidString, record: record, files: files)
        }
    }

    func hasFile(itemID: String, name: String) -> Bool {
        guard let folder = folder(itemID) else { return false }
        return FileManager.default.fileExists(atPath: folder.appending(path: name).path)
    }

    func wants(itemID: String, file: SyncFile) -> Bool {
        folder(itemID) != nil && Self.kind(file.name) != nil && file.size < 200_000_000
    }

    func fileURL(itemID: String, name: String) -> URL? {
        guard let folder = folder(itemID), Self.kind(name) != nil else { return nil }
        let url = folder.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func keep(_ url: URL, itemID: String, name: String) -> Bool {
        guard let folder = folder(itemID), let kind = Self.kind(name), let data = try? Data(contentsOf: url) else { return false }
        let kept: Data?
        switch kind {
        case .photo, .thumbnail: kept = PhotoPrivacy.cleaned(data)
        case .depth: kept = DepthHeader.valid(data) ? data : nil
        }
        guard let kept else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try kept.write(to: folder.appending(path: name), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func merge(itemID: String, record: Data) -> Bool {
        guard let folder = folder(itemID), let incoming = try? TeamPack.decoder.decode(Board.self, from: record),
            incoming.id.uuidString == folder.lastPathComponent
        else { return false }
        let local = boards().first { $0.id == incoming.id }
        let manager = FileManager.default
        let present = incoming.shots.filter { manager.fileExists(atPath: folder.appending(path: $0.file).path) }
        // A photo whose thumbnail didn't come still needs one for the grids.
        for shot in present where !manager.fileExists(atPath: folder.appending(path: shot.thumbnailFile).path) {
            try? manager.copyItem(at: folder.appending(path: shot.file), to: folder.appending(path: shot.thumbnailFile))
        }
        if local == nil && present.isEmpty && !incoming.shots.isEmpty { return false }
        let merged = TeamPack.merged(local: local, incoming: incoming, accepted: Set(present.map(\.id)))
        guard merged != local else { return false }
        save(merged)
        return true
    }
}
