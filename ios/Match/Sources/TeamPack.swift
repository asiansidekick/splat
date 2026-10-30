import Foundation
import ImageIO

/// A team pack: boards and their photos in one file, sent phone to phone by AirDrop with no
/// internet and no cloud. Cast photos are sensitive, so a pack can be locked with the team
/// passcode (AES-GCM, key from the passcode with PBKDF2), and photos go without location or
/// camera details. Opening a pack adds what's new and never overwrites a teammate's work.
enum TeamPack {
    static let fileExtension = "matchpack"
    static let typeIdentifier = "com.asiansidekick.match.pack"

    /// What each board sends.
    enum Content: String, CaseIterable, Identifiable {
        case references, all
        var id: String { rawValue }
        var name: String { self == .references ? "References only" : "All photos" }
    }

    struct Manifest: Codable {
        var version = 1
        var made: Date
        /// The sender's name as they typed it, for "From Sam". Empty if they didn't.
        var from: String
        var boards: [Board]
    }

    /// A pack read back: the manifest and its files, by "<board id>/<file name>".
    struct Opened {
        var manifest: Manifest
        var files: [String: Data]
    }

    typealias PackError = SecurePack.Failure

    static let magic = Data("MATCHPK1".utf8)
    private static let manifestName = "manifest.json"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Making

    /// The boards as they'll be sent: only the chosen photos, and only photos whose file is there.
    static func trimmed(_ boards: [Board], content: Content, root: URL) -> [Board] {
        boards.map { board in
            var board = board
            let chosen = content == .references ? board.references : board.shots
            board.shots = chosen.filter {
                FileManager.default.fileExists(atPath: root.appending(path: board.id.uuidString).appending(path: $0.file).path)
            }
            return board
        }
    }

    /// The pack's bytes. `root` holds a folder per board, as BoardStore keeps them. `maxPixels`
    /// makes the photos smaller (longest side), for Messages and Mail.
    static func make(boards: [Board], content: Content, from: String, passcode: String?, root: URL,
                     maxPixels: Int? = nil, made: Date = .now) throws -> Data {
        let sent = trimmed(boards, content: content, root: root)
        var entries: [(name: String, data: Data)] = [(manifestName, try encoder.encode(Manifest(made: made, from: from, boards: sent)))]
        for board in sent {
            let folder = root.appending(path: board.id.uuidString)
            for shot in board.shots {
                for name in [shot.file, shot.thumbnailFile, shot.depthFile] {
                    guard let data = try? Data(contentsOf: folder.appending(path: name)) else { continue }
                    let photo: Data?
                    switch name {
                    case shot.depthFile: photo = data
                    case shot.file: photo = maxPixels.flatMap { smaller(data, maxPixels: $0) } ?? cleaned(data)
                    default: photo = cleaned(data)
                    }
                    guard let clean = photo else { continue }
                    entries.append(("\(board.id.uuidString)/\(name)", clean))
                }
            }
        }
        return try SecurePack.make(entries, magic: magic, passcode: passcode)
    }

    /// Whether these bytes are a locked pack, so the passcode can be asked for before opening.
    static func isLocked(_ data: Data) -> Bool {
        SecurePack.isLocked(data, magic: magic)
    }

    // MARK: Opening

    static func open(_ data: Data, passcode: String?) throws -> Opened {
        var files = try SecurePack.open(data, magic: magic, passcode: passcode)
        guard let manifestData = files.removeValue(forKey: manifestName) else { throw PackError.damaged }
        let manifest: Manifest
        do {
            manifest = try decoder.decode(Manifest.self, from: manifestData)
        } catch {
            throw PackError.damaged
        }
        guard manifest.version <= 1 else { throw PackError.tooNew }
        return Opened(manifest: manifest, files: files)
    }

    // MARK: Adding to this phone

    struct Report: Equatable {
        var newBoards = 0
        var updatedBoards = 0
        var newPhotos = 0
        var skipped = 0

        var summary: String {
            if newBoards == 0 && newPhotos == 0 { return "Nothing new: you already have everything in this pack." }
            var parts: [String] = []
            if newBoards > 0 { parts.append("\(newBoards) new board\(newBoards == 1 ? "" : "s")") }
            if newPhotos > 0 { parts.append("\(newPhotos) new photo\(newPhotos == 1 ? "" : "s")") }
            return "Added " + parts.joined(separator: " and ") + "."
        }
    }

    /// A teammate's board added to the one here, if there is one. Photos already here stay as
    /// they are; new ones are added. Board details here win, and blanks are filled in from theirs.
    static func merged(local: Board?, incoming: Board, accepted: Set<UUID>) -> Board {
        let arriving = incoming.shots.filter { accepted.contains($0.id) }
        guard var board = local else {
            var board = incoming
            board.shots = arriving
            return board
        }
        if board.subject.isEmpty { board.subject = incoming.subject }
        if board.look.isEmpty { board.look = incoming.look }
        board.notes = mergedNotes(board.notes, incoming.notes)
        let have = Set(board.shots.map(\.id))
        for shot in arriving {
            if let index = board.shots.firstIndex(where: { $0.id == shot.id }) {
                if board.shots[index].note.isEmpty { board.shots[index].note = shot.note }
                if board.shots[index].fit == nil { board.shots[index].fit = shot.fit }
            } else if !have.contains(shot.id) {
                board.shots.append(shot)
            }
        }
        return board
    }

    /// Their lines added below ours, skipping lines we already have. Merging twice, or each way
    /// round between two phones, settles rather than growing.
    static func mergedNotes(_ ours: String, _ theirs: String) -> String {
        var lines = ours.isEmpty ? [] : ours.components(separatedBy: "\n")
        for line in theirs.components(separatedBy: "\n") where !line.isEmpty && !lines.contains(line) {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Writes the pack's photos into `root` and gives back the boards to save. Only files that
    /// belong to a photo in the manifest are written, under that board's own folder, so a
    /// damaged or hostile pack can't put files anywhere else.
    static func install(_ opened: Opened, into root: URL, existing: [Board]) throws -> (boards: [Board], report: Report) {
        var report = Report()
        var boards: [Board] = []
        let manager = FileManager.default
        for incoming in opened.manifest.boards {
            let folder = root.appending(path: incoming.id.uuidString, directoryHint: .isDirectory)
            let local = existing.first { $0.id == incoming.id }
            let have = Set(local?.shots.map(\.id) ?? [])
            var accepted = Set<UUID>()
            for shot in incoming.shots {
                if have.contains(shot.id) {
                    accepted.insert(shot.id)
                    continue
                }
                let prefix = incoming.id.uuidString + "/"
                guard let photo = opened.files[prefix + shot.file], let clean = cleaned(photo),
                    CGImageSourceCreateWithData(clean as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true
                else {
                    report.skipped += 1
                    continue
                }
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try clean.write(to: folder.appending(path: shot.file), options: .atomic)
                if let thumb = opened.files[prefix + shot.thumbnailFile] {
                    try (cleaned(thumb) ?? clean).write(to: folder.appending(path: shot.thumbnailFile), options: .atomic)
                } else {
                    try clean.write(to: folder.appending(path: shot.thumbnailFile), options: .atomic)
                }
                if let depth = opened.files[prefix + shot.depthFile], DepthHeader.valid(depth) {
                    try depth.write(to: folder.appending(path: shot.depthFile), options: .atomic)
                }
                accepted.insert(shot.id)
                report.newPhotos += 1
            }
            if local == nil && accepted.isEmpty && !incoming.shots.isEmpty { continue }
            if local == nil { report.newBoards += 1 } else if accepted.count > have.intersection(accepted).count { report.updatedBoards += 1 }
            boards.append(merged(local: local, incoming: incoming, accepted: accepted))
        }
        return (boards, report)
    }

    // MARK: Photos without metadata (shared with Reset)

    static func smaller(_ data: Data, maxPixels: Int) -> Data? { PhotoPrivacy.smaller(data, maxPixels: maxPixels) }
    static func cleaned(_ data: Data) -> Data? { PhotoPrivacy.cleaned(data) }
    static func isClean(_ data: Data) -> Bool { PhotoPrivacy.isClean(data) }
    static func stripped(_ data: Data) -> Data? { PhotoPrivacy.stripped(data) }
}

/// Checks a saved LiDAR map's header without decoding it all.
enum DepthHeader {
    static func valid(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        guard b.count == 12 else { return false }
        func word(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        let w = word(4), h = word(8)
        return word(0) == 0x4450_5448 && w > 0 && h > 0 && w * h <= 4_000_000 && data.count == 12 + w * h * 4
    }
}
