import CommonCrypto
import CryptoKit
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

    enum PackError: LocalizedError, Equatable {
        case notAPack, needsPasscode, wrongPasscode, damaged, tooNew

        var errorDescription: String? {
            switch self {
            case .notAPack: "This isn't a Match team pack."
            case .needsPasscode: "This pack is locked. Enter the team passcode."
            case .wrongPasscode: "That passcode doesn't open this pack."
            case .damaged: "This pack is damaged. Ask for it to be sent again."
            case .tooNew: "This pack was made by a newer Match. Update Match, then open it again."
            }
        }
    }

    private static let magic = Data("MATCHPK1".utf8)
    private static let iterations: UInt32 = 200_000
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
        var body = Data()
        append(manifestName, try encoder.encode(Manifest(made: made, from: from, boards: sent)), to: &body)
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
                    append("\(board.id.uuidString)/\(name)", clean, to: &body)
                }
            }
        }
        var out = magic
        if let passcode, !passcode.isEmpty {
            var salt = Data(count: 16)
            for i in 0..<16 { salt[i] = UInt8.random(in: 0...255) }
            out.append(1)
            out.append(salt)
            put(iterations, into: &out)
            let sealed = try AES.GCM.seal(body, using: key(passcode, salt: salt, iterations: iterations))
            guard let combined = sealed.combined else { throw PackError.damaged }
            out.append(combined)
        } else {
            out.append(0)
            out.append(body)
        }
        return out
    }

    /// Whether these bytes are a locked pack, so the passcode can be asked for before opening.
    static func isLocked(_ data: Data) -> Bool {
        data.count > magic.count && data.prefix(magic.count) == magic && data[data.startIndex + magic.count] == 1
    }

    // MARK: Opening

    static func open(_ data: Data, passcode: String?) throws -> Opened {
        let bytes = data.startIndex == 0 ? data : data.subdata(in: data.startIndex..<data.endIndex)
        guard bytes.count > magic.count, bytes.prefix(magic.count) == magic else { throw PackError.notAPack }
        var at = magic.count
        let flag = bytes[at]
        at += 1
        let body: Data
        switch flag {
        case 0:
            body = bytes.subdata(in: at..<bytes.count)
        case 1:
            guard let passcode, !passcode.isEmpty else { throw PackError.needsPasscode }
            guard bytes.count >= at + 20 else { throw PackError.damaged }
            let salt = bytes.subdata(in: at..<(at + 16))
            at += 16
            guard let rounds = word(bytes, at), rounds > 0, rounds <= 5_000_000 else { throw PackError.damaged }
            at += 4
            guard let box = try? AES.GCM.SealedBox(combined: bytes.subdata(in: at..<bytes.count)) else { throw PackError.damaged }
            guard let opened = try? AES.GCM.open(box, using: key(passcode, salt: salt, iterations: rounds)) else {
                throw PackError.wrongPasscode
            }
            body = opened
        default:
            throw PackError.tooNew
        }

        var files: [String: Data] = [:]
        var i = 0
        while i < body.count {
            guard let nameLength = word(body, i), i + 4 + Int(nameLength) + 8 <= body.count else { throw PackError.damaged }
            i += 4
            guard let name = String(data: body.subdata(in: i..<(i + Int(nameLength))), encoding: .utf8) else { throw PackError.damaged }
            i += Int(nameLength)
            guard let size = long(body, i), size <= UInt64(body.count - i - 8) else { throw PackError.damaged }
            i += 8
            files[name] = body.subdata(in: i..<(i + Int(size)))
            i += Int(size)
        }
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
        if board.notes.isEmpty {
            board.notes = incoming.notes
        } else if !incoming.notes.isEmpty && !board.notes.contains(incoming.notes) {
            board.notes += "\n" + incoming.notes
        }
        let have = Set(board.shots.map(\.id))
        for shot in arriving {
            if let index = board.shots.firstIndex(where: { $0.id == shot.id }) {
                if board.shots[index].note.isEmpty { board.shots[index].note = shot.note }
            } else if !have.contains(shot.id) {
                board.shots.append(shot)
            }
        }
        return board
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

    // MARK: Photos without metadata

    /// The picture with its longest side at most `maxPixels`, upright, with no details. Nil if it
    /// is already that small (send it as it is) or isn't a picture.
    static func smaller(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
            max(width, height) > maxPixels
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// The picture as it is if it carries nothing private, otherwise re-saved without the details.
    /// Photos Match takes are already clean, so they go untouched and lose no quality.
    static func cleaned(_ data: Data) -> Data? {
        isClean(data) ? data : stripped(data)
    }

    /// True for a picture with no location, camera, lens, serial number, time taken or caption.
    /// Nil-safe: anything that isn't a readable picture is not clean.
    static func isClean(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        if properties[kCGImagePropertyGPSDictionary] != nil || properties[kCGImagePropertyIPTCDictionary] != nil
            || properties[kCGImagePropertyMakerAppleDictionary] != nil { return false }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
            [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFSoftware,
             kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFHostComputer].contains(where: { tiff[$0] != nil }) { return false }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifLensModel,
             kCGImagePropertyExifLensMake, kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifCameraOwnerName,
             kCGImagePropertyExifUserComment, kCGImagePropertyExifSubjectArea].contains(where: { exif[$0] != nil }) { return false }
        return true
    }

    /// The same picture with no location, camera, date or other details: only the pixels and
    /// which way up they go. Nil if it isn't a picture.
    static func stripped(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var keep: [CFString: Any] = [:]
        if let orientation = properties[kCGImagePropertyOrientation] { keep[kCGImagePropertyOrientation] = orientation }
        keep[kCGImageDestinationLossyCompressionQuality] = 0.9
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, keep as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    // MARK: Bytes

    private static func append(_ name: String, _ data: Data, to body: inout Data) {
        let nameData = Data(name.utf8)
        put(UInt32(nameData.count), into: &body)
        body.append(nameData)
        var size = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &size) { body.append(contentsOf: $0) }
        body.append(data)
    }

    private static func put(_ value: UInt32, into data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func word(_ data: Data, _ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= data.count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + i + $1]) << (8 * $1) }
    }

    private static func long(_ data: Data, _ i: Int) -> UInt64? {
        guard i >= 0, i + 8 <= data.count else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[data.startIndex + i + $1]) << (8 * $1) }
    }

    /// A 256-bit key from the passcode, slow to guess (PBKDF2-SHA256).
    static func key(_ passcode: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        let password = Array(passcode.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        _ = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                passwordBytes.baseAddress!.withMemoryRebound(to: Int8.self, capacity: password.count) { pw in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, password.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count)
                }
            }
        }
        return SymmetricKey(data: derived)
    }
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
