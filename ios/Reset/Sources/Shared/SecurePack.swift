import CommonCrypto
import CryptoKit
import Foundation

// Shared by Match and Reset (copy this file unchanged into the other app). Foundation and
// CryptoKit only: nothing here knows about boards or references.

/// Keys from the team passcode. The passcode never leaves the phone; only things locked with it do.
enum TeamKey {
    static let iterations: UInt32 = 200_000

    /// A 256-bit key from the passcode, slow to guess (PBKDF2-SHA256).
    static func derive(_ passcode: String, salt: Data, iterations: UInt32 = iterations) -> SymmetricKey {
        let password = Array(passcode.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        guard !password.isEmpty else { return SymmetricKey(data: derived) }
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

    static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}

/// One file holding named entries, optionally locked with the team passcode (AES-GCM, a fresh
/// salt each time). Each app gives its own 8-byte magic, so a Reset pack never opens in Match.
/// Layout: magic, a flag (0 open, 1 locked), then for locked packs a 16-byte salt and the
/// PBKDF2 rounds, then the entries (name length, name, size, bytes), sealed if locked.
enum SecurePack {
    enum Failure: LocalizedError, Equatable {
        case notAPack, needsPasscode, wrongPasscode, damaged, tooNew

        var errorDescription: String? {
            switch self {
            case .notAPack: "This isn't a team pack for this app."
            case .needsPasscode: "This pack is locked. Enter the team passcode."
            case .wrongPasscode: "That passcode doesn't open this pack."
            case .damaged: "This pack is damaged. Ask for it to be sent again."
            case .tooNew: "This pack was made by a newer version of the app. Update, then open it again."
            }
        }
    }

    static func make(_ entries: [(name: String, data: Data)], magic: Data, passcode: String?) throws -> Data {
        var body = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            put(UInt32(name.count), into: &body)
            body.append(name)
            put(UInt64(entry.data.count), into: &body)
            body.append(entry.data)
        }
        var out = magic
        if let passcode, !passcode.isEmpty {
            let salt = TeamKey.randomBytes(16)
            out.append(1)
            out.append(salt)
            put(TeamKey.iterations, into: &out)
            let sealed = try AES.GCM.seal(body, using: TeamKey.derive(passcode, salt: salt))
            guard let combined = sealed.combined else { throw Failure.damaged }
            out.append(combined)
        } else {
            out.append(0)
            out.append(body)
        }
        return out
    }

    static func isLocked(_ data: Data, magic: Data) -> Bool {
        data.count > magic.count && data.prefix(magic.count) == magic && data[data.startIndex + magic.count] == 1
    }

    /// The entries by name. A name that appears twice keeps its last copy.
    static func open(_ data: Data, magic: Data, passcode: String?) throws -> [String: Data] {
        let bytes = data.startIndex == 0 ? data : data.subdata(in: data.startIndex..<data.endIndex)
        guard bytes.count > magic.count, bytes.prefix(magic.count) == magic else { throw Failure.notAPack }
        var at = magic.count
        let flag = bytes[at]
        at += 1
        let body: Data
        switch flag {
        case 0:
            body = bytes.subdata(in: at..<bytes.count)
        case 1:
            guard let passcode, !passcode.isEmpty else { throw Failure.needsPasscode }
            guard bytes.count >= at + 20 else { throw Failure.damaged }
            let salt = bytes.subdata(in: at..<(at + 16))
            at += 16
            guard let rounds = word(bytes, at), rounds > 0, rounds <= 5_000_000 else { throw Failure.damaged }
            at += 4
            guard let box = try? AES.GCM.SealedBox(combined: bytes.subdata(in: at..<bytes.count)) else { throw Failure.damaged }
            guard let opened = try? AES.GCM.open(box, using: TeamKey.derive(passcode, salt: salt, iterations: rounds)) else {
                throw Failure.wrongPasscode
            }
            body = opened
        default:
            throw Failure.tooNew
        }

        var entries: [String: Data] = [:]
        var i = 0
        while i < body.count {
            guard let nameLength = word(body, i), i + 4 + Int(nameLength) + 8 <= body.count else { throw Failure.damaged }
            i += 4
            guard let name = String(data: body.subdata(in: i..<(i + Int(nameLength))), encoding: .utf8) else { throw Failure.damaged }
            i += Int(nameLength)
            guard let size = long(body, i), size <= UInt64(body.count - i - 8) else { throw Failure.damaged }
            i += 8
            entries[name] = body.subdata(in: i..<(i + Int(size)))
            i += Int(size)
        }
        return entries
    }

    // MARK: Bytes

    static func put(_ value: UInt32, into data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func put(_ value: UInt64, into data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func word(_ data: Data, _ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= data.count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + i + $1]) << (8 * $1) }
    }

    static func long(_ data: Data, _ i: Int) -> UInt64? {
        guard i >= 0, i + 8 <= data.count else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[data.startIndex + i + $1]) << (8 * $1) }
    }
}

/// The team key for syncing nearby: messages and files between phones are sealed with it, so a
/// phone without the team passcode can't read or send anything. Every phone on the team gets
/// the same key from the same passcode, so there's nothing to exchange first.
struct SyncKey {
    let key: SymmetricKey
    /// A short label phones show while looking for each other, so teammates find each other and
    /// skip other teams. It can't be turned back into the passcode.
    let tag: String

    /// Slow (PBKDF2), so make it off the main thread. `service` keeps apps apart, e.g. "match-sync".
    init(passcode: String, service: String) {
        key = TeamKey.derive(passcode, salt: Data("splat-team-sync/\(service)".utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("team-tag".utf8), using: key)
        tag = Data(mac).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    func seal(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data("message".utf8)).combined else {
            throw SecurePack.Failure.damaged
        }
        return combined
    }

    /// Nil if it wasn't sealed with this team's key, or was changed on the way.
    func open(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Data("message".utf8))
    }

    // MARK: Files, a megabyte at a time, so big LiDAR or USDZ files never sit in memory whole

    static let chunk = 1 << 20
    private static let fileMagic = Data("SYNCF1\0\0".utf8)

    /// Each piece is sealed with the file's name, its number and whether it's the last, so pieces
    /// can't be swapped, dropped or cut short without it showing.
    private func label(_ name: String, _ index: UInt64, last: Bool) -> Data {
        Data("\(name)|\(index)|\(last ? 1 : 0)".utf8)
    }

    func sealFile(at source: URL, to destination: URL, name: String) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: Self.fileMagic)
        var index: UInt64 = 0
        var piece = try input.read(upToCount: Self.chunk) ?? Data()
        while true {
            let next = try input.read(upToCount: Self.chunk) ?? Data()
            let last = next.isEmpty
            guard let sealed = try AES.GCM.seal(piece, using: key, authenticating: label(name, index, last: last)).combined else {
                throw SecurePack.Failure.damaged
            }
            var length = Data()
            SecurePack.put(UInt32(sealed.count), into: &length)
            try output.write(contentsOf: length)
            try output.write(contentsOf: sealed)
            if last { break }
            piece = next
            index += 1
        }
    }

    /// False if anything about it is wrong: another team's key, another file's name, a missing
    /// or changed piece. Nothing is left at `destination` then.
    @discardableResult
    func openFile(at source: URL, to destination: URL, name: String) -> Bool {
        guard let input = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: destination) else { return false }
        var ok = false
        defer {
            try? output.close()
            if !ok { try? FileManager.default.removeItem(at: destination) }
        }
        guard (try? input.read(upToCount: Self.fileMagic.count)) == Self.fileMagic else { return false }
        var index: UInt64 = 0
        while true {
            guard let lengthData = try? input.read(upToCount: 4), lengthData.count == 4,
                let length = SecurePack.word(lengthData, 0), length >= 28, Int(length) <= Self.chunk + 64,
                let sealed = try? input.read(upToCount: Int(length)), sealed.count == Int(length),
                let box = try? AES.GCM.SealedBox(combined: sealed)
            else { return false }
            let piece: Data
            var last = false
            if let opened = try? AES.GCM.open(box, using: key, authenticating: label(name, index, last: false)) {
                piece = opened
            } else if let opened = try? AES.GCM.open(box, using: key, authenticating: label(name, index, last: true)) {
                piece = opened
                last = true
            } else {
                return false
            }
            guard (try? output.write(contentsOf: piece)) != nil else { return false }
            if last {
                // Nothing may follow the last piece.
                ok = ((try? input.read(upToCount: 1)) ?? Data()).isEmpty
                return ok
            }
            index += 1
        }
    }
}
