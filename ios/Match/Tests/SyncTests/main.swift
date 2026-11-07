// Tests for syncing with nearby phones, run on a Mac by CI:
//   swiftc -O Sources/Board.swift Sources/TeamPack.swift Sources/BoardSync.swift Sources/Shared/PhotoPrivacy.swift \
//     Sources/Shared/SecurePack.swift Sources/Shared/SyncEngine.swift Tests/SyncTests/main.swift -o sync-tests
//   ./sync-tests
// Three phones, each with its own boards folder, run the real sync engine and Match's board
// library; the radio is replaced by a queue that seals and unseals files exactly as NearbySync
// does. Checks boards and photos spread both ways and through a middle phone, edits settle
// instead of bouncing for ever, other passcodes get nothing, and bad files or names are refused.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS  " : "FAIL  ") + message)
    if !condition { failures += 1 }
}

let manager = FileManager.default
let scratch = manager.temporaryDirectory.appending(path: "sync-tests-\(UUID().uuidString)")
try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: scratch) }

func jpeg(shade: CGFloat, gps: Bool = false) -> Data {
    let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: shade, green: 0.4, blue: 1 - shade, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [:]
    if gps { properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"] }
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return out as Data
}

func depthData() -> Data {
    var out = Data()
    func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    put(0x4450_5448); put(2); put(2)
    for _ in 0..<4 { put(Float(1.5).bitPattern) }
    return out
}

// MARK: Sealed files

let teamKey = SyncKey(passcode: "blue-door-42", service: "match-sync")
let sameKey = SyncKey(passcode: "blue-door-42", service: "match-sync")
let otherKey = SyncKey(passcode: "red-door-7", service: "match-sync")
expect(teamKey.tag == sameKey.tag && teamKey.tag.count == 12, "same passcode, same team tag (\(teamKey.tag))")
expect(teamKey.tag != otherKey.tag, "another passcode, another tag")
expect(teamKey.tag != SyncKey(passcode: "blue-door-42", service: "reset-sync").tag, "Match and Reset teams stay apart")
let message = try teamKey.seal(Data("hello".utf8))
expect(sameKey.open(message) == Data("hello".utf8), "a teammate opens a message")
expect(otherKey.open(message) == nil, "another passcode can't")

let big = scratch.appending(path: "big.bin")
let bigData = TeamKey.randomBytes(3 * SyncKey.chunk + 12345)
try bigData.write(to: big)
let sealedBig = scratch.appending(path: "big.sealed")
try teamKey.sealFile(at: big, to: sealedBig, name: "item/big.bin")
let sealedBytes = try Data(contentsOf: sealedBig)
expect(sealedBytes.range(of: bigData.prefix(64)) == nil, "a sealed file shows none of its bytes")
let openedBig = scratch.appending(path: "big.opened")
expect(sameKey.openFile(at: sealedBig, to: openedBig, name: "item/big.bin") && (try? Data(contentsOf: openedBig)) == bigData,
       "a 3 MB file goes in pieces and comes back whole")
expect(!otherKey.openFile(at: sealedBig, to: scratch.appending(path: "x1"), name: "item/big.bin"), "another passcode can't open a file")
expect(!manager.fileExists(atPath: scratch.appending(path: "x1").path), "and nothing is left behind")
expect(!teamKey.openFile(at: sealedBig, to: scratch.appending(path: "x2"), name: "item/other.bin"), "a file sent under another name is refused")
let cut = scratch.appending(path: "cut.sealed")
try sealedBytes.prefix(sealedBytes.count - (SyncKey.chunk / 2)).write(to: cut)
expect(!teamKey.openFile(at: cut, to: scratch.appending(path: "x3"), name: "item/big.bin"), "a file cut short is refused")
// Drop the last piece entirely: the one before it isn't marked last.
var pieces: [Range<Int>] = []
var at = 8
while at < sealedBytes.count {
    let length = Int(SecurePack.word(sealedBytes, at)!)
    pieces.append(at..<(at + 4 + length))
    at += 4 + length
}
let dropped = scratch.appending(path: "dropped.sealed")
try sealedBytes.prefix(pieces[pieces.count - 1].lowerBound).write(to: dropped)
expect(pieces.count == 4 && !teamKey.openFile(at: dropped, to: scratch.appending(path: "x4"), name: "item/big.bin"), "a missing last piece is caught")
var swapped = sealedBytes.prefix(8)
swapped.append(sealedBytes[pieces[1]])
swapped.append(sealedBytes[pieces[0]])
for piece in pieces.dropFirst(2) { swapped.append(sealedBytes[piece]) }
let swappedURL = scratch.appending(path: "swapped.sealed")
try swapped.write(to: swappedURL)
expect(!teamKey.openFile(at: swappedURL, to: scratch.appending(path: "x5"), name: "item/big.bin"), "pieces in the wrong order are caught")
var flipped = sealedBytes
flipped[flipped.count / 2] ^= 1
let flippedURL = scratch.appending(path: "flipped.sealed")
try flipped.write(to: flippedURL)
expect(!teamKey.openFile(at: flippedURL, to: scratch.appending(path: "x6"), name: "item/big.bin"), "a changed byte is caught")
let empty = scratch.appending(path: "empty.bin")
try Data().write(to: empty)
try teamKey.sealFile(at: empty, to: scratch.appending(path: "empty.sealed"), name: "e")
expect(teamKey.openFile(at: scratch.appending(path: "empty.sealed"), to: scratch.appending(path: "empty.opened"), name: "e")
    && (try? Data(contentsOf: scratch.appending(path: "empty.opened")))?.isEmpty == true, "an empty file goes too")

expect(SyncEngine.safe("8F1C2D3E-0000-4000-8000-000000000000.jpg") && !SyncEngine.safe("../evil") && !SyncEngine.safe(".hidden")
    && !SyncEngine.safe("a/b") && !SyncEngine.safe(""), "only plain file names")
expect(TeamPack.mergedNotes("a\nb", "b\na") == "a\nb" && TeamPack.mergedNotes("a", "b") == "a\nb" && TeamPack.mergedNotes("", "x") == "x",
       "notes merge line by line and settle")

// MARK: Phones

/// The radio: everything goes in a queue and is delivered in order, files sealed on the way.
@MainActor
final class Air {
    var queue: [() -> Void] = []
    var steps = 0
    func run(limit: Int = 20_000) -> Bool {
        while !queue.isEmpty {
            steps += 1
            if steps > limit { return false }
            queue.removeFirst()()
        }
        return true
    }
}

@MainActor
final class Phone {
    let name: String
    let root: URL
    var boards: [Board] = []
    var library: BoardSyncLibrary!
    var engine: SyncEngine!
    var strangers = 0
    let key: SyncKey

    init(_ name: String, key: SyncKey = teamKey, content: TeamPack.Content = .all) throws {
        self.name = name
        self.key = key
        root = scratch.appending(path: "\(name)/Boards")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        library = BoardSyncLibrary(root: root, content: content, boards: { [unowned self] in self.boards }, save: { [unowned self] board in
            if let i = self.boards.firstIndex(where: { $0.id == board.id }) { self.boards[i] = board } else { self.boards.append(board) }
        })
        engine = SyncEngine(library: library, key: key, name: name)
        engine.onStranger = { [unowned self] _ in self.strangers += 1 }
    }

    func board(_ subject: String, scene: String = "12", shots: Int, references: Int = 1, gps: Bool = false) throws -> Board {
        var board = Board(scene: scene, subject: subject, department: .hair, created: .now)
        board.notes = "\(subject) notes from \(name)"
        let folder = root.appending(path: board.id.uuidString)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<shots { try add(to: &board, take: i, reference: i < references, gps: gps && i == 0, folder: folder) }
        boards.append(board)
        return board
    }

    func add(to board: inout Board, take: Int, reference: Bool = false, gps: Bool = false, folder: URL? = nil) throws {
        let folder = folder ?? root.appending(path: board.id.uuidString)
        var shot = Shot(taken: Date(timeIntervalSince1970: 1_800_000_000 + Double(take) * 60), take: take, angle: "Front")
        shot.isReference = reference
        try jpeg(shade: CGFloat(take % 10) / 10, gps: gps).write(to: folder.appending(path: shot.file))
        try jpeg(shade: 0.5).write(to: folder.appending(path: shot.thumbnailFile))
        if take == 0 { try depthData().write(to: folder.appending(path: shot.depthFile)) }
        board.shots.append(shot)
    }

    func update(_ board: Board) {
        if let i = boards.firstIndex(where: { $0.id == board.id }) { boards[i] = board }
    }

    func has(_ board: Board) -> Board? { boards.first { $0.id == board.id } }

    func filesComplete(_ board: Board) -> Bool {
        let folder = root.appending(path: board.id.uuidString)
        return board.shots.allSatisfy {
            manager.fileExists(atPath: folder.appending(path: $0.file).path) && manager.fileExists(atPath: folder.appending(path: $0.thumbnailFile).path)
        }
    }
}

/// Wires two phones together through the air, as NearbySync does with the radio.
@MainActor
func link(_ a: Phone, _ b: Phone, air: Air) {
    // Each phone may be linked to several others: route by peer name.
    for (from, to) in [(a, b), (b, a)] {
        let previousMessage = from.engine.sendMessage
        let previousFile = from.engine.sendFile
        from.engine.sendMessage = { [unowned air] peer, data in
            guard peer == to.name else { return previousMessage(peer, data) }
            air.queue.append { to.engine.received(data, from: from.name) }
        }
        from.engine.sendFile = { [unowned air] peer, url, resource in
            guard peer == to.name else { return previousFile(peer, url, resource) }
            let sealed = scratch.appending(path: "air-\(UUID().uuidString)")
            let ok = (try? from.key.sealFile(at: url, to: sealed, name: resource)) != nil
            air.queue.append {
                let plain = scratch.appending(path: "plain-\(UUID().uuidString)")
                let opened = ok && to.key.openFile(at: sealed, to: plain, name: resource)
                to.engine.receivedFile(opened ? plain : nil, resource: resource, from: from.name)
                try? manager.removeItem(at: sealed)
                try? manager.removeItem(at: plain)
            }
        }
    }
    air.queue.append { a.engine.connected(b.name) }
    air.queue.append { b.engine.connected(a.name) }
}

@MainActor
func runSyncTests() throws {
    // Two phones, different boards.
    let air = Air()
    let a = try Phone("A")
    let b = try Phone("B")
    let sarah = try a.board("Sarah", shots: 4, references: 2, gps: false)
    let tom = try a.board("Tom", shots: 1)
    let ana = try b.board("Ana", scene: "14", shots: 2)
    link(a, b, air: air)
    expect(air.run(), "A and B finish syncing (\(air.steps) steps)")
    expect(a.boards.count == 3 && b.boards.count == 3, "both phones have all three boards")
    expect(b.has(sarah)?.shots.map(\.id) == sarah.shots.map(\.id) && b.filesComplete(sarah), "Sarah's 4 photos reached B with their files")
    expect(a.has(ana).map(a.filesComplete) == true && a.has(ana)?.notes == ana.notes, "Ana's board came back the other way")
    expect(b.has(tom).map { (try? Data(contentsOf: b.root.appending(path: tom.id.uuidString).appending(path: $0.shots[0].depthFile))) == depthData() } == true,
           "LiDAR depth came with its photo")
    expect(a.engine.progress.waiting == 0 && b.engine.progress.waiting == 0, "nothing left waiting")
    expect(a.engine.progress.teammates == ["B"] && b.engine.progress.teammates == ["A"], "each sees the other by name")
    expect(b.engine.progress.received == 4 * 2 + 1 * 2 + 2, "B received 4+1 photos, their thumbnails and 2 depth maps (\(b.engine.progress.received))")

    // Both edit Sarah; A takes a new photo. The change goes once each way and settles.
    var aSarah = a.has(sarah)!
    aSarah.notes += "\nA: clip moved left"
    try a.add(to: &aSarah, take: 5)
    a.update(aSarah)
    var bSarah = b.has(sarah)!
    bSarah.notes += "\nB: lipstick retouched"
    bSarah.shots[0].note = "B's note"
    b.update(bSarah)
    a.engine.localChanged()
    b.engine.localChanged()
    air.steps = 0
    expect(air.run(limit: 2_000), "edits settle instead of bouncing (\(air.steps) steps)")
    let finalA = a.has(sarah)!, finalB = b.has(sarah)!
    expect(finalA.shots.count == 5 && finalB.shots.count == 5 && b.filesComplete(finalA), "A's new photo reached B")
    expect(finalA.notes.contains("A: clip moved left") && finalA.notes.contains("B: lipstick retouched")
        && finalB.notes.contains("A: clip moved left") && finalB.notes.contains("B: lipstick retouched"), "both notes on both phones")
    expect(finalA.shots[0].note == "B's note" && finalB.shots[0].note == "B's note", "a note added on one phone fills the blank on the other")

    // A third phone joins B only. A's next photo reaches C through B.
    let c = try Phone("C")
    link(b, c, air: air)
    expect(air.run(), "C joins through B")
    expect(c.boards.count == 3 && c.has(sarah).map(c.filesComplete) == true, "C has everything B had")
    var again = a.has(sarah)!
    try a.add(to: &again, take: 6)
    a.update(again)
    a.engine.localChanged()
    expect(air.run(), "a new photo spreads")
    expect(c.has(sarah)?.shots.count == 6 && c.has(sarah).map(c.filesComplete) == true, "A's new photo reached C through B")

    // A phone with another passcode gets nothing and can't send anything in.
    let air2 = Air()
    let d = try Phone("D", key: otherKey)
    let dBoard = try d.board("Intruder", shots: 1)
    let e = try Phone("E")
    let eBoard = try e.board("Private", shots: 2)
    link(d, e, air: air2)
    expect(air2.run(), "a stranger's connection ends")
    expect(d.boards.count == 1 && e.boards.count == 1, "no boards cross between teams")
    expect(e.strangers > 0 && d.strangers > 0, "each side sees the other isn't on the team")
    expect(!manager.fileExists(atPath: d.root.appending(path: eBoard.id.uuidString).path)
        && !manager.fileExists(atPath: e.root.appending(path: dBoard.id.uuidString).path), "no files cross either")
    expect(e.engine.progress.teammates.isEmpty, "a stranger isn't listed as a teammate")

    // A teammate whose photo is damaged: it's refused once, not asked for again and again.
    let air3 = Air()
    let f = try Phone("F")
    let g = try Phone("G")
    let fBoard = try f.board("Lee", shots: 3)
    try Data("not a picture".utf8).write(to: f.root.appending(path: fBoard.id.uuidString).appending(path: fBoard.shots[1].file))
    link(f, g, air: air3)
    expect(air3.run(limit: 2_000), "a bad photo doesn't loop (\(air3.steps) steps)")
    expect(g.engine.progress.refused == 1, "the bad photo was refused")
    expect(g.has(fBoard)?.shots.count == 2 && g.has(fBoard).map(g.filesComplete) == true, "the board arrives without it")

    // Photos with a location are cleaned on the way in.
    let air4 = Air()
    let h = try Phone("H")
    let i = try Phone("I")
    let located = try h.board("Kim", shots: 1, gps: true)
    link(h, i, air: air4)
    expect(air4.run(), "H and I sync")
    let received = try? Data(contentsOf: i.root.appending(path: located.id.uuidString).appending(path: located.shots[0].file))
    expect(received.map(PhotoPrivacy.isClean) == true, "a photo with a location arrives without it")

    // References only: J shares just references, but still takes in everything.
    let air5 = Air()
    let j = try Phone("J", content: .references)
    let k = try Phone("K")
    let jBoard = try j.board("Mo", shots: 4, references: 1)
    let kBoard = try k.board("Viv", shots: 3, references: 1)
    link(j, k, air: air5)
    expect(air5.run(), "J and K sync")
    expect(k.has(jBoard)?.shots.count == 1, "J shares only its reference")
    expect(j.has(kBoard)?.shots.count == 3, "J still takes in all of K's photos")

    // A teammate sending odd names and unasked-for files: nothing lands outside a board folder.
    let air6 = Air()
    let m = try Phone("M")
    let n = try Phone("N")
    link(m, n, air: air6)
    expect(air6.run(), "M and N connect")
    let hostile = SyncItem(id: "../../escape", record: Data("{}".utf8), files: [SyncFile(name: "../evil.jpg", size: 3)])
    let fake = try teamKey.seal(JSONEncoder().encode(SyncMessage(kind: .inventory, items: [hostile])))
    n.engine.received(fake, from: "M")
    let stray = scratch.appending(path: "stray.jpg")
    try jpeg(shade: 0.2).write(to: stray)
    n.engine.receivedFile(stray, resource: "\(UUID().uuidString)/\(UUID().uuidString).jpg", from: "M")
    n.engine.receivedFile(stray, resource: "../../evil.jpg", from: "M")
    let want = try teamKey.seal(JSONEncoder().encode(SyncMessage(kind: .want, wants: [SyncWant(itemID: "..", names: ["board.json"])])))
    var served = 0
    m.engine.sendFile = { _, _, _ in served += 1 }
    m.engine.received(want, from: "N")
    expect(air6.run(), "hostile messages handled")
    let everything = (manager.enumerator(atPath: scratch.path)?.allObjects as? [String]) ?? []
    expect(!everything.contains { $0.hasSuffix("evil.jpg") } && !manager.fileExists(atPath: scratch.appending(path: "escape").path),
           "odd names write nothing")
    expect((manager.enumerator(atPath: n.root.path)?.allObjects as? [String] ?? []).isEmpty, "unasked-for files are ignored")
    expect(served == 0, "a file that isn't offered isn't sent")
}

try MainActor.assumeIsolated { try runSyncTests() }

print(failures == 0 ? "All sync tests passed" : "\(failures) sync test(s) failed")
exit(failures == 0 ? 0 : 1)
