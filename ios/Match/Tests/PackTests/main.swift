// Tests for team packs (AirDrop sharing), run on a Mac by CI:
//   swiftc -O Sources/Board.swift Sources/TeamPack.swift Tests/PackTests/main.swift -o pack-tests
//   ./pack-tests
// Boards are written to a folder the way the app keeps them, packed, opened and added to a
// second "phone". Checks the passcode lock, that photos lose their location and camera details,
// that nothing a teammate already has is overwritten, and that damaged or hostile packs are refused.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS  " : "FAIL  ") + message)
    if !condition { failures += 1 }
}

func error(of work: () throws -> Void) -> TeamPack.PackError? {
    do {
        try work()
        return nil
    } catch let error as TeamPack.PackError {
        return error
    } catch {
        return nil
    }
}

let manager = FileManager.default
let scratch = manager.temporaryDirectory.appending(path: "pack-tests-\(UUID().uuidString)")
let phoneA = scratch.appending(path: "A/Boards")
let phoneB = scratch.appending(path: "B/Boards")
try manager.createDirectory(at: phoneA, withIntermediateDirectories: true)
try manager.createDirectory(at: phoneB, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: scratch) }

/// A small JPEG, a different colour for each photo, optionally with a location and camera details
/// as an iPhone photo imported from the Photos library would have.
func jpeg(shade: CGFloat, private details: Bool = false, width: Int = 64, height: Int = 48) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 8, y: 8, width: 20, height: 10))
    let image = context.makeImage()!
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if details {
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: 51.5014, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.1419, kCGImagePropertyGPSLongitudeRef: "W",
        ]
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro"]
        properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:30 07:12:00",
                                                     kCGImagePropertyExifBodySerialNumber: "SERIAL123"]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return out as Data
}

func properties(_ data: Data) -> [CFString: Any] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
}

/// A saved depth map, as Depth.swift writes it.
func depthData(width: Int = 4, height: Int = 3) -> Data {
    var out = Data()
    func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    put(0x4450_5448)
    put(UInt32(width))
    put(UInt32(height))
    for i in 0..<(width * height) { put(Float(1 + Double(i) * 0.01).bitPattern) }
    return out
}

/// A board on "phone A": photos written to its folder like BoardStore does.
func makeBoard(scene: String, subject: String, department: Department, shots: [(angle: String, reference: Bool, take: Int, details: Bool, depth: Bool)]) throws -> Board {
    var board = Board(scene: scene, subject: subject, department: department, created: .now)
    board.notes = "Hair pinned left, \(subject)"
    let folder = phoneA.appending(path: board.id.uuidString)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    for (i, s) in shots.enumerated() {
        var shot = Shot(taken: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60), take: s.take, angle: s.angle,
                        source: s.details ? .imported : .camera)
        shot.isReference = s.reference
        shot.note = "Note \(i)"
        try jpeg(shade: CGFloat(i) / 10, private: s.details).write(to: folder.appending(path: shot.file))
        try jpeg(shade: CGFloat(i) / 10, private: s.details).write(to: folder.appending(path: shot.thumbnailFile))
        if s.depth { try depthData().write(to: folder.appending(path: shot.depthFile)) }
        board.shots.append(shot)
    }
    try TeamPack.encoder.encode(board).write(to: folder.appending(path: "board.json"))
    return board
}

let sarah = try makeBoard(scene: "12", subject: "Sarah", department: .hair, shots: [
    ("Front", true, 0, false, true),
    ("Left", true, 0, true, false),  // imported from Photos: has a location
    ("Front", false, 1, false, false),
    ("Front", false, 2, false, false),
])
let tom = try makeBoard(scene: "12", subject: "Tom", department: .costume, shots: [
    ("Full length", true, 0, false, false),
])

// MARK: Metadata

let gpsPhoto = jpeg(shade: 0.3, private: true)
expect(properties(gpsPhoto)[kCGImagePropertyGPSDictionary] != nil, "test photo starts with a location")
expect(!TeamPack.isClean(gpsPhoto), "a photo with a location is not clean")
let stripped = TeamPack.stripped(gpsPhoto)
expect(stripped != nil, "stripping gives a picture back")
if let stripped {
    let p = properties(stripped)
    expect(p[kCGImagePropertyGPSDictionary] == nil, "stripped photo has no location")
    expect((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil, "stripped photo has no phone model")
    expect((p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifBodySerialNumber] == nil, "stripped photo has no serial number")
    expect(TeamPack.isClean(stripped), "stripped photo counts as clean")
    expect((p[kCGImagePropertyPixelWidth] as? Int) == 64 && (p[kCGImagePropertyPixelHeight] as? Int) == 48, "stripped photo keeps its size")
}
let plainPhoto = jpeg(shade: 0.1)
expect(TeamPack.isClean(plainPhoto), "a photo Match took counts as clean")
expect(TeamPack.cleaned(plainPhoto) == plainPhoto, "a clean photo is sent untouched (no quality lost)")
expect(TeamPack.cleaned(Data("not a picture".utf8)) == nil, "text is not a picture")

// MARK: An open pack

let open = try TeamPack.make(boards: [sarah, tom], content: .all, from: "Sam", passcode: nil, root: phoneA)
expect(!TeamPack.isLocked(open), "pack without a passcode is not locked")
let opened = try TeamPack.open(open, passcode: nil)
expect(opened.manifest.from == "Sam", "pack says who sent it")
expect(opened.manifest.boards.map(\.id) == [sarah.id, tom.id], "pack holds both boards")
expect(opened.manifest.boards[0].shots.map(\.id) == sarah.shots.map(\.id), "all photos sent with All photos")
expect(opened.manifest.boards[0].notes == sarah.notes && opened.manifest.boards[0].shots[1].note == "Note 1", "notes travel with the board and photos")
expect(opened.files.count == 5 * 2 + 1, "photos, thumbnails and one depth map in the pack (got \(opened.files.count))")
let sentLeft = opened.files["\(sarah.id.uuidString)/\(sarah.shots[1].file)"]
expect(sentLeft.map { properties($0)[kCGImagePropertyGPSDictionary] == nil } == true, "imported photo goes without its location")
expect(sentLeft.map(TeamPack.isClean) == true, "every sent photo is clean")
let sentFront = opened.files["\(sarah.id.uuidString)/\(sarah.shots[0].file)"]
let frontOnDisk = try Data(contentsOf: phoneA.appending(path: sarah.id.uuidString).appending(path: sarah.shots[0].file))
expect(sentFront == frontOnDisk, "a photo Match took is sent byte for byte")
expect(opened.files["\(sarah.id.uuidString)/\(sarah.shots[0].depthFile)"] == depthData(), "LiDAR depth goes with its photo")

let refs = try TeamPack.open(TeamPack.make(boards: [sarah], content: .references, from: "", passcode: nil, root: phoneA), passcode: nil)
expect(refs.manifest.boards[0].shots.count == 2 && refs.manifest.boards[0].shots.allSatisfy(\.isReference), "References only sends just the references")
expect(refs.files.count == 2 * 2 + 1, "References only leaves the take photos behind")

// MARK: A locked pack

let locked = try TeamPack.make(boards: [sarah, tom], content: .all, from: "Sam", passcode: "blue-door-42", root: phoneA)
expect(TeamPack.isLocked(locked), "pack with a passcode is locked")
expect(locked.range(of: Data("Sarah".utf8)) == nil && locked.range(of: Data("manifest.json".utf8)) == nil, "locked pack shows no names or notes inside")
expect(locked.range(of: frontOnDisk.prefix(200)) == nil, "locked pack shows no photo bytes")
expect(error { _ = try TeamPack.open(locked, passcode: nil) } == .needsPasscode, "locked pack asks for the passcode")
expect(error { _ = try TeamPack.open(locked, passcode: "blue-door-41") } == .wrongPasscode, "wrong passcode doesn't open it")
let unlocked = try? TeamPack.open(locked, passcode: "blue-door-42")
expect(unlocked?.manifest.boards.count == 2 && unlocked?.files.count == opened.files.count, "right passcode opens everything")
let locked2 = try TeamPack.make(boards: [sarah], content: .all, from: "", passcode: "blue-door-42", root: phoneA)
let locked3 = try TeamPack.make(boards: [sarah], content: .all, from: "", passcode: "blue-door-42", root: phoneA)
expect(locked2 != locked3, "the same boards locked twice look different (fresh salt and nonce)")
var tampered = locked
tampered[tampered.count - 40] ^= 0xFF
expect(error { _ = try TeamPack.open(tampered, passcode: "blue-door-42") } != nil, "a changed byte is caught, not opened")

// MARK: Damaged and hostile packs

expect(error { _ = try TeamPack.open(Data("hello".utf8), passcode: nil) } == .notAPack, "random file is not a pack")
expect(error { _ = try TeamPack.open(open.prefix(open.count / 2), passcode: nil) } == .damaged, "half a pack is damaged, no crash")
expect(error { _ = try TeamPack.open(open.prefix(9), passcode: nil) } == .damaged, "header only is damaged")
expect(error { _ = try TeamPack.open((Data([0]) + open).dropFirst(), passcode: nil) } == nil, "a slice of a pack still opens")
var future = open
future[8] = 7
expect(error { _ = try TeamPack.open(future, passcode: nil) } == .tooNew, "a pack from a newer Match says so")
var huge = open.prefix(9)
huge.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x7F])
expect(error { _ = try TeamPack.open(huge, passcode: nil) } == .damaged, "a giant name length is caught")

// An extra file trying to escape the board folder, and one for a board not in the manifest.
func entry(_ name: String, _ data: Data) -> Data {
    var out = Data()
    let n = Data(name.utf8)
    withUnsafeBytes(of: UInt32(n.count).littleEndian) { out.append(contentsOf: $0) }
    out.append(n)
    withUnsafeBytes(of: UInt64(data.count).littleEndian) { out.append(contentsOf: $0) }
    out.append(data)
    return out
}
var hostile = open
hostile.append(entry("../../evil.jpg", plainPhoto))
hostile.append(entry("\(UUID().uuidString)/\(UUID().uuidString).jpg", plainPhoto))
hostile.append(entry("\(sarah.id.uuidString)/board.json", Data("{}".utf8)))
let hostileOpened = try TeamPack.open(hostile, passcode: nil)
let hostileRoot = scratch.appending(path: "C/Boards")
try manager.createDirectory(at: hostileRoot, withIntermediateDirectories: true)
_ = try TeamPack.install(hostileOpened, into: hostileRoot, existing: [])
expect(!manager.fileExists(atPath: scratch.appending(path: "evil.jpg").path)
    && !manager.fileExists(atPath: scratch.appending(path: "C/evil.jpg").path), "a file can't climb out of the boards folder")
let written = (manager.enumerator(atPath: hostileRoot.path)?.allObjects as? [String]) ?? []
expect(written.allSatisfy { $0.hasPrefix(sarah.id.uuidString) || $0.hasPrefix(tom.id.uuidString) }, "only the manifest's boards get folders")
expect(!written.contains("\(sarah.id.uuidString)/board.json"), "a pack can't write a board file directly")

// A board whose photo is not a picture: that photo is skipped, the rest arrive.
var broken = opened
broken.files["\(sarah.id.uuidString)/\(sarah.shots[2].file)"] = Data("garbage".utf8)
broken.files.removeValue(forKey: "\(sarah.id.uuidString)/\(sarah.shots[3].file)")
let brokenRoot = scratch.appending(path: "D/Boards")
try manager.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
let brokenResult = try TeamPack.install(broken, into: brokenRoot, existing: [])
expect(brokenResult.report.skipped == 2 && brokenResult.report.newPhotos == 3, "bad or missing photos are skipped, the rest arrive")
expect(brokenResult.boards.first { $0.id == sarah.id }?.shots.count == 2, "a skipped photo isn't listed on the board")

// MARK: Adding to another phone

let first = try TeamPack.install(unlocked ?? opened, into: phoneB, existing: [])
expect(first.report.newBoards == 2 && first.report.newPhotos == 5, "both boards and all 5 photos arrive (\(first.report))")
expect(first.report.summary == "Added 2 new boards and 5 new photos.", "summary reads well: \(first.report.summary)")
let arrived = first.boards.first { $0.id == sarah.id }
expect(arrived?.shots.map(\.id) == sarah.shots.map(\.id), "photos keep their ids, takes and order")
expect(arrived?.shots.map(\.take) == [0, 0, 1, 2] && arrived?.references.count == 2, "takes and references survive")
let folderB = phoneB.appending(path: sarah.id.uuidString)
expect(sarah.shots.allSatisfy { manager.fileExists(atPath: folderB.appending(path: $0.file).path)
    && manager.fileExists(atPath: folderB.appending(path: $0.thumbnailFile).path) }, "photos and thumbnails written")
expect((try? Data(contentsOf: folderB.appending(path: sarah.shots[0].depthFile))) == depthData(), "depth written beside its photo")
expect((try? Data(contentsOf: folderB.appending(path: sarah.shots[1].file))).map(TeamPack.isClean) == true, "received photos are clean")

let again = try TeamPack.install(opened, into: phoneB, existing: first.boards)
expect(again.report.newPhotos == 0 && again.report.newBoards == 0, "the same pack twice adds nothing")
expect(again.report.summary.hasPrefix("Nothing new"), "and says so")
expect(again.boards.first { $0.id == sarah.id }?.shots.count == 4, "no duplicate photos")

// Phone B has worked on Sarah: notes, a photo of its own, a note on a shared photo. Phone A
// then takes another photo and sends again.
var bSarah = first.boards.first { $0.id == sarah.id }!
bSarah.notes = "B: clip moved for scene 14"
bSarah.shots[0].note = "B's own note"
var bShot = Shot(taken: .now, take: 3, angle: "Back")
bShot.note = "Taken on B"
bSarah.shots.append(bShot)
var aSarah = sarah
var aShot = Shot(taken: .now, take: 3, angle: "Front")
aShot.note = "Taken on A"
try jpeg(shade: 0.9).write(to: phoneA.appending(path: sarah.id.uuidString).appending(path: aShot.file))
aSarah.shots.append(aShot)
let update = try TeamPack.open(TeamPack.make(boards: [aSarah], content: .all, from: "Sam", passcode: nil, root: phoneA), passcode: nil)
let merged = try TeamPack.install(update, into: phoneB, existing: [bSarah, first.boards.first { $0.id == tom.id }!])
let m = merged.boards[0]
expect(merged.report.newPhotos == 1 && merged.report.updatedBoards == 1 && merged.report.newBoards == 0, "only the new photo arrives (\(merged.report))")
expect(m.shots.count == 6 && m.shots.contains { $0.id == bShot.id } && m.shots.contains { $0.id == aShot.id }, "B keeps its own photo and gets A's")
expect(m.shots.first { $0.id == sarah.shots[0].id }?.note == "B's own note", "B's note on a shared photo is kept")
expect(m.notes.hasPrefix("B: clip moved") && m.notes.contains(sarah.notes), "board notes kept, A's added below")
let twice = TeamPack.merged(local: m, incoming: aSarah, accepted: Set(aSarah.shots.map(\.id)))
expect(twice.notes == m.notes, "A's notes aren't added twice")
expect(manager.fileExists(atPath: folderB.appending(path: aShot.thumbnailFile).path), "a photo with no thumbnail sent gets one")

// An empty board (References only, nothing marked yet) still arrives, so the team has the slot.
let empty = Board(scene: "14", subject: "Extra 3", department: .makeup, created: .now)
let emptyPack = try TeamPack.open(TeamPack.make(boards: [empty], content: .references, from: "", passcode: nil, root: phoneA), passcode: nil)
let emptyResult = try TeamPack.install(emptyPack, into: phoneB, existing: [])
expect(emptyResult.boards.count == 1 && emptyResult.report.newBoards == 1, "an empty board arrives")

// MARK: Smaller photos for Messages and Mail

let big = jpeg(shade: 0.4, private: true, width: 3000, height: 2000)
expect(TeamPack.smaller(jpeg(shade: 0.4), maxPixels: 1600) == nil, "a photo already small isn't made smaller")
if let small = TeamPack.smaller(big, maxPixels: 1600) {
    let p = properties(small)
    expect((p[kCGImagePropertyPixelWidth] as? Int) == 1600 && (p[kCGImagePropertyPixelHeight] as? Int) == 1067,
           "a big photo shrinks to 1600 on its long side, same shape (\(p[kCGImagePropertyPixelWidth] ?? 0)x\(p[kCGImagePropertyPixelHeight] ?? 0))")
    expect(TeamPack.isClean(small), "the smaller photo has no location or camera details")
    expect(small.count < big.count, "and is a smaller file")
} else {
    expect(false, "a big photo can be made smaller")
}
var wide = Board(scene: "20", subject: "Ana", department: .costume, created: .now)
let wideShot = Shot(taken: .now, take: 0, angle: "Front")
let wideFolder = phoneA.appending(path: wide.id.uuidString)
try manager.createDirectory(at: wideFolder, withIntermediateDirectories: true)
try big.write(to: wideFolder.appending(path: wideShot.file))
try jpeg(shade: 0.4, private: true).write(to: wideFolder.appending(path: wideShot.thumbnailFile))
wide.shots = [wideShot]
let mailPack = try TeamPack.make(boards: [wide], content: .all, from: "", passcode: "blue-door-42", root: phoneA, maxPixels: 1600)
let mailOpened = try TeamPack.open(mailPack, passcode: "blue-door-42")
let mailPhoto = mailOpened.files["\(wide.id.uuidString)/\(wideShot.file)"]
expect(mailPhoto.map { (properties($0)[kCGImagePropertyPixelWidth] as? Int) == 1600 } == true, "Messages and Mail pack carries the smaller photo")
expect(mailPhoto.map(TeamPack.isClean) == true && mailOpened.files["\(wide.id.uuidString)/\(wideShot.thumbnailFile)"].map(TeamPack.isClean) == true,
       "and it and its thumbnail are clean")
let mailInstalled = try TeamPack.install(mailOpened, into: phoneB, existing: [])
expect(mailInstalled.report.newPhotos == 1, "a smaller-photo pack installs like any other")

print(failures == 0 ? "All pack tests passed" : "\(failures) pack test(s) failed")
exit(failures == 0 ? 0 : 1)
