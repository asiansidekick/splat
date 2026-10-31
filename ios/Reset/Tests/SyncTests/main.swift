// Tests for syncing references with nearby phones, run on a Mac by CI:
//   swiftc -O Sources/ReferenceModel.swift Sources/ReferenceSync.swift Sources/Shared/PhotoPrivacy.swift \
//     Sources/Shared/SecurePack.swift Sources/Shared/SyncEngine.swift Tests/SyncTests/main.swift -o sync-tests
//   ./sync-tests
// Phones, each with its own references folder (written and read back as JSON, as on the
// phone), run the shared sync engine and Reset's reference library; the radio is a queue that
// seals and unseals files as NearbySync does. Checks references, photos, depth, room maps and
// models spread both ways and through a middle phone, edits and deletions settle on the same
// answer everywhere instead of bouncing, the no-depth option, other passcodes, and bad files.

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
let scratch = manager.temporaryDirectory.appendingPathComponent("reset-sync-tests-\(UUID().uuidString)")
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

let depthBytes = Data((0..<4 * 6).map { UInt8($0) })
let mapBytes = Data("bplist00".utf8) + Data(repeating: 7, count: 40)
let modelBytes = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 1, count: 60)

let teamKey = SyncKey(passcode: "blue-door-42", service: "reset-sync")
let otherKey = SyncKey(passcode: "red-door-7", service: "reset-sync")

// MARK: File names

expect(ReferenceSyncLibrary.kind("frame_0003.jpg") == .photo && ReferenceSyncLibrary.kind("depth_0003.bin") == .depth
    && ReferenceSyncLibrary.kind("snap_1A2B3C4D.jpg") == .photo && ReferenceSyncLibrary.kind("worldmap.arexperience") == .map,
    "Reset's own file names are known")
let modelID = UUID().uuidString
expect(ReferenceSyncLibrary.kind("model-\(modelID).usdz") == .model && ReferenceSyncLibrary.path("model-\(modelID).usdz") == "models/\(modelID).usdz"
    && ReferenceSyncLibrary.syncName(modelFile: "models/\(modelID).usdz") == "model-\(modelID).usdz", "models travel as model-<id>.usdz")
expect(ReferenceSyncLibrary.kind("../frame.jpg") == nil && ReferenceSyncLibrary.kind("reference.json") == nil
    && ReferenceSyncLibrary.kind("evil.sh") == nil && ReferenceSyncLibrary.kind("model-x.usdz") == nil
    && ReferenceSyncLibrary.kind(".jpg") == nil && ReferenceSyncLibrary.kind("frame 1.jpg") == nil, "anything else is refused")

// MARK: Merge rules on their own

let base = Date(timeIntervalSince1970: 1_800_000_000)
func frame(_ i: Int, depth: Bool = true) -> Keyframe {
    Keyframe(
        imageFile: String(format: "frame_%04d.jpg", i), depthFile: depth ? String(format: "depth_%04d.bin", i) : nil,
        transform: Array(repeating: 0, count: 16), intrinsics: Array(repeating: 1, count: 9),
        imageWidth: 40, imageHeight: 30, depthWidth: 2, depthHeight: 3)
}
var one = Reference(id: UUID(), scene: "12", setup: "A", name: "desk", created: base, keyframes: [frame(0)])
let t1 = Take(number: 1, logged: base)
one.takes = [t1]
var mine = one, theirs = one
mine.scene = "12"; mine.setup = "B"; mine.slateEdited = base.addingTimeInterval(10)
theirs.name = "kitchen"; theirs.slateEdited = base.addingTimeInterval(20)
let everything: (String) -> Bool = { _ in true }
let ab = ReferenceSyncLibrary.merged(local: mine, incoming: theirs, has: everything)!
let ba = ReferenceSyncLibrary.merged(local: theirs, incoming: mine, has: everything)!
expect(Reference.label(scene: "1", setup: "3") == "Sc 1 · Take 3" && Reference.label(scene: "12", setup: "B") == "12B" && Reference.label(scene: "", setup: "2") == "Take 2" && Reference.label(scene: "1", setup: "2C") == "Sc 1 · Take 2C",
    "numbered takes read Sc 1 · Take 3, old letters still read 12B")
expect(ab.slate == ba.slate && ab.name == "kitchen" && ab.setup == "A", "the newest slate edit wins on both phones")
var tie1 = one, tie2 = one
tie1.name = "aaa"; tie2.name = "zzz"
expect(ReferenceSyncLibrary.merged(local: tie1, incoming: tie2, has: everything)!.name
    == ReferenceSyncLibrary.merged(local: tie2, incoming: tie1, has: everything)!.name, "unedited differences settle the same way")
expect(ReferenceSyncLibrary.merged(local: ab, incoming: ab, has: everything) == ab, "merging the same thing changes nothing")
var noDepth = one
noDepth.keyframes = [frame(0, depth: false)]
expect(ReferenceSyncLibrary.merged(local: noDepth, incoming: one, has: { $0 != "depth_0000.bin" })!.keyframes[0].depthFile == nil,
       "depth stays off until its file is here")
expect(ReferenceSyncLibrary.merged(local: noDepth, incoming: one, has: everything)!.keyframes[0].depthFile == "depth_0000.bin",
       "and is added once it is")
expect(ReferenceSyncLibrary.merged(local: nil, incoming: one, has: { $0 != "worldmap.arexperience" }) == nil,
       "a new reference waits for its room map")
expect(ReferenceSyncLibrary.merged(local: nil, incoming: one, has: { $0 != "frame_0000.jpg" }) == nil, "and for its photos")

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
    var library: ReferenceSyncLibrary!
    var engine: SyncEngine!
    var strangers = 0
    let key: SyncKey

    init(_ name: String, key: SyncKey = teamKey, withDepth: Bool = true) throws {
        self.name = name
        self.key = key
        root = scratch.appendingPathComponent("\(name)/References")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        library = ReferenceSyncLibrary(root: root, withDepth: withDepth, references: { [unowned self] in self.references }, save: { [unowned self] in
            self.store($0)
        })
        engine = SyncEngine(library: library, key: key, name: name)
        engine.onStranger = { [unowned self] _ in self.strangers += 1 }
    }

    /// Read from reference.json in each folder, as ReferenceStore.all() does.
    var references: [Reference] {
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("reference.json")))
                .flatMap { try? ReferenceSyncLibrary.decoder.decode(Reference.self, from: $0) }
        }
        .sorted { $0.created > $1.created }
    }

    func store(_ reference: Reference) {
        let folder = root.appendingPathComponent(reference.id.uuidString)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? ReferenceSyncLibrary.encoder.encode(reference).write(to: folder.appendingPathComponent("reference.json"))
    }

    func reference(_ setup: String, views: Int, gps: Bool = false, models: Int = 0) throws -> Reference {
        var reference = Reference(id: UUID(), scene: "12", setup: setup, name: "", created: base, keyframes: [])
        let folder = root.appendingPathComponent(reference.id.uuidString)
        try manager.createDirectory(at: folder.appendingPathComponent("models"), withIntermediateDirectories: true)
        for i in 0..<views {
            let view = frame(i)
            try jpeg(shade: CGFloat(i) / 10, gps: gps && i == 0).write(to: folder.appendingPathComponent(view.imageFile))
            try depthBytes.write(to: folder.appendingPathComponent(view.depthFile!))
            reference.keyframes.append(view)
        }
        try mapBytes.write(to: folder.appendingPathComponent("worldmap.arexperience"))
        for _ in 0..<models {
            let id = UUID()
            try modelBytes.write(to: folder.appendingPathComponent("models/\(id.uuidString).usdz"))
            reference.models.append(PlacedModel(id: id, name: "chair", file: "models/\(id.uuidString).usdz", transform: Array(repeating: 1, count: 16)))
        }
        store(reference)
        return reference
    }

    func has(_ reference: Reference) -> Reference? { references.first { $0.id == reference.id } }

    func update(_ id: UUID, _ change: (inout Reference) -> Void) {
        guard var reference = references.first(where: { $0.id == id }) else { return }
        change(&reference)
        store(reference)
    }

    func file(_ reference: Reference, _ name: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(reference.id.uuidString).appendingPathComponent(name))
    }
}

@MainActor
func link(_ a: Phone, _ b: Phone, air: Air) {
    for (from, to) in [(a, b), (b, a)] {
        let previousMessage = from.engine.sendMessage
        let previousFile = from.engine.sendFile
        from.engine.sendMessage = { [unowned air] peer, data in
            guard peer == to.name else { return previousMessage(peer, data) }
            air.queue.append { to.engine.received(data, from: from.name) }
        }
        from.engine.sendFile = { [unowned air] peer, url, resource in
            guard peer == to.name else { return previousFile(peer, url, resource) }
            let sealed = scratch.appendingPathComponent("air-\(UUID().uuidString)")
            let ok = (try? from.key.sealFile(at: url, to: sealed, name: resource)) != nil
            air.queue.append {
                let plain = scratch.appendingPathComponent("plain-\(UUID().uuidString)")
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
    // Two phones, different references.
    let air = Air()
    let a = try Phone("A")
    let b = try Phone("B")
    let desk = try a.reference("A", views: 3, models: 1)
    let door = try b.reference("B", views: 2)
    link(a, b, air: air)
    expect(air.run(), "A and B finish syncing (\(air.steps) steps)")
    expect(a.references.count == 2 && b.references.count == 2, "both phones have both references")
    let bDesk = b.has(desk)
    expect(bDesk?.keyframes == desk.keyframes && (0..<3).allSatisfy { b.file(desk, frame($0).imageFile) != nil },
           "A's three views reached B with their photos")
    expect(b.file(desk, "depth_0002.bin") == depthBytes && b.file(desk, "worldmap.arexperience") == mapBytes, "with LiDAR depth and the room map")
    expect(bDesk?.models.count == 1 && b.file(desk, desk.models[0].file) == modelBytes, "and the 3D model, in the models folder")
    expect(a.has(door) != nil && a.file(door, "frame_0001.jpg") != nil, "B's reference came back the other way")
    expect(a.engine.progress.waiting == 0 && b.engine.progress.waiting == 0, "nothing left waiting")

    // Both phones log and edit at once; everything settles to the same answer.
    let take2 = Take(number: 2, logged: base.addingTimeInterval(120))
    let take3 = Take(number: 3, logged: base.addingTimeInterval(240))
    a.update(desk.id) { $0.takes.append(take2) }
    b.update(desk.id) {
        $0.takes.append(take3)
        $0.name = "desk wide"
        $0.slateEdited = base.addingTimeInterval(300)
        $0.models[0].transform = Array(repeating: 2, count: 16)
        $0.models[0].moved = base.addingTimeInterval(300)
    }
    a.engine.localChanged()
    b.engine.localChanged()
    air.steps = 0
    expect(air.run(limit: 2_000), "edits settle instead of bouncing (\(air.steps) steps)")
    let finalA = a.has(desk)!, finalB = b.has(desk)!
    expect(Set(finalA.takes.map(\.id)) == [take2.id, take3.id] && Set(finalB.takes.map(\.id)) == [take2.id, take3.id], "takes from both phones on both")
    expect(finalA.name == "desk wide" && finalB.name == "desk wide", "the slate edit reached A")
    expect(finalA.models[0].transform == Array(repeating: 2, count: 16), "the moved model moved on A too")

    // A take edited on A and deleted on B: deleted wins everywhere and doesn't come back.
    a.update(desk.id) {
        $0.takes[$0.takes.firstIndex { $0.id == take2.id }!].note = "boom in shot"
        $0.takes[$0.takes.firstIndex { $0.id == take2.id }!].edited = base.addingTimeInterval(400)
        if let i = $0.takes.firstIndex(where: { $0.id == take3.id }) { $0.takes[i].circled = true; $0.takes[i].edited = base.addingTimeInterval(400) }
    }
    b.update(desk.id) {
        $0.takes.removeAll { $0.id == take3.id }
        $0.removedTakes.append(take3.id)
    }
    a.engine.localChanged()
    b.engine.localChanged()
    air.steps = 0
    expect(air.run(limit: 2_000), "a deletion settles (\(air.steps) steps)")
    expect(a.has(desk)!.takes.map(\.id) == [take2.id] && b.has(desk)!.takes.map(\.id) == [take2.id], "the deleted take is gone from both")
    expect(b.has(desk)!.takes[0].note == "boom in shot", "the edited note reached B")
    expect(a.has(desk)! == b.has(desk)!, "both phones end with the same reference")

    // Measurements and notes go across; one deleted on B goes everywhere.
    let line = RoomMeasurement(a: [0, 0, 0], b: [0.3, 0.4, 0], created: base)
    let pin = RoomNote(text: "cup handle faces camera", position: [0.1, 0.8, -1], created: base)
    let spare = RoomMeasurement(a: [0, 0, 0], b: [1, 0, 0], created: base)
    a.update(desk.id) {
        $0.measurements += [line, spare]
        $0.notes.append(pin)
    }
    a.engine.localChanged()
    expect(air.run(limit: 2_000), "measurements sync")
    expect(b.has(desk)!.measurements.map(\.id) == [line.id, spare.id] && b.has(desk)!.notes == [pin], "B has A's measurements and note")
    expect(abs(line.length - 0.5) < 0.0001, "a 30-40-50 line measures 50 cm")
    func near(_ text: String, _ metres: Float) -> Bool { abs((LengthText.parse(text) ?? -1) - metres) < 0.00001 }
    expect(near("29.7", 0.297) && near("29,7 cm", 0.297) && near("0.3 m", 0.3) && near("12 in", 0.3048) && near("300mm", 0.3) && near("2 ft", 0.6096),
        "typed lengths read in cm, mm, m, in and ft")
    expect(LengthText.parse("") == nil && LengthText.parse("abc") == nil && LengthText.parse("0") == nil && LengthText.parse("50000") == nil,
        "nonsense isn't a length")
    // A length typed on B reaches A; a later one typed on A wins everywhere.
    b.update(desk.id) {
        $0.measurements[$0.measurements.firstIndex { $0.id == line.id }!].typed = 0.52
        $0.measurements[$0.measurements.firstIndex { $0.id == line.id }!].edited = base.addingTimeInterval(500)
    }
    b.engine.localChanged()
    expect(air.run(limit: 2_000), "a typed length settles")
    expect(a.has(desk)!.measurements.first { $0.id == line.id }?.length == 0.52, "A shows the length typed on B")
    expect(abs((a.has(desk)!.measurements.first { $0.id == line.id }?.measured ?? 0) - 0.5) < 0.0001, "and still knows what was measured")
    a.update(desk.id) {
        $0.measurements[$0.measurements.firstIndex { $0.id == line.id }!].typed = 0.49
        $0.measurements[$0.measurements.firstIndex { $0.id == line.id }!].edited = base.addingTimeInterval(600)
    }
    a.engine.localChanged()
    expect(air.run(limit: 2_000), "a later edit settles")
    expect(b.has(desk)!.measurements.first { $0.id == line.id }?.length == 0.49, "the newest typed length wins on B")
    b.update(desk.id) {
        $0.notes[0].position = [0.5, 1, -2]
        $0.notes[0].text = "cup handle faces left"
        $0.notes[0].edited = base.addingTimeInterval(700)
    }
    b.engine.localChanged()
    expect(air.run(limit: 2_000), "a moved note settles")
    expect(a.has(desk)!.notes.first?.position == [0.5, 1, -2] && a.has(desk)!.notes.first?.text == "cup handle faces left",
        "A shows the note moved and reworded on B")
    b.update(desk.id) {
        $0.measurements.removeAll { $0.id == spare.id }
        $0.removedMarks.append(spare.id)
    }
    b.engine.localChanged()
    expect(air.run(limit: 2_000), "a deleted measurement settles")
    expect(a.has(desk)!.measurements.map(\.id) == [line.id] && b.has(desk)!.measurements.map(\.id) == [line.id], "the deleted one is gone from both")
    expect(a.has(desk)! == b.has(desk)!, "both phones still match")

    // A third phone joins B only, and gets A's things through B.
    let c = try Phone("C")
    link(b, c, air: air)
    expect(air.run(), "C joins through B")
    expect(c.references.count == 2 && c.has(desk) == b.has(desk), "C has everything B had")

    // No depth: photos and room maps only, then depth on a later sync.
    let air2 = Air()
    let d = try Phone("D", withDepth: false)
    let e = try Phone("E")
    let set = try e.reference("C", views: 2, models: 1)
    link(d, e, air: air2)
    expect(air2.run(), "D and E sync")
    let quick = d.has(set)
    expect(quick != nil && d.file(set, "frame_0001.jpg") != nil && d.file(set, "worldmap.arexperience") != nil, "D got the photos and room map")
    expect(d.file(set, "depth_0000.bin") == nil && quick?.keyframes.allSatisfy { $0.depthFile == nil } == true, "but no depth")
    expect(quick?.models.isEmpty == true && d.file(set, set.models[0].file) == nil, "and no 3D models")
    expect(e.has(set)?.keyframes == set.keyframes, "E's own reference keeps its depth")
    let d2 = try Phone("D2", withDepth: true)
    try manager.removeItem(at: d2.root)
    try manager.copyItem(at: d.root, to: d2.root)
    let air3 = Air()
    link(d2, e, air: air3)
    expect(air3.run(), "D syncs again with depth")
    expect(d2.has(set)?.keyframes == set.keyframes && d2.file(set, "depth_0001.bin") == depthBytes, "depth comes in later")
    expect(d2.has(set)?.models.count == 1 && d2.file(set, set.models[0].file) == modelBytes, "and so does the model")

    // Another passcode: nothing crosses.
    let air4 = Air()
    let f = try Phone("F", key: otherKey)
    let g = try Phone("G")
    let secret = try g.reference("D", views: 1)
    link(f, g, air: air4)
    expect(air4.run(), "a stranger's connection ends")
    expect(f.references.isEmpty && !manager.fileExists(atPath: f.root.appendingPathComponent(secret.id.uuidString).path),
           "no references or files cross between teams")
    expect(g.strangers > 0, "G sees the other phone isn't on the team")

    // Bad files: a damaged photo blocks only its reference, once; a fake room map is refused.
    let air5 = Air()
    let h = try Phone("H")
    let i = try Phone("I")
    let broken = try h.reference("E", views: 2)
    let fine = try h.reference("F", views: 1, gps: true)
    try Data("not a picture".utf8).write(to: h.root.appendingPathComponent(broken.id.uuidString).appendingPathComponent("frame_0001.jpg"))
    link(h, i, air: air5)
    expect(air5.run(limit: 2_000), "a bad photo doesn't loop (\(air5.steps) steps)")
    expect(i.has(broken) == nil && i.has(fine) != nil, "the damaged reference waits; the good one arrives")
    expect(i.file(fine, "frame_0000.jpg").map(PhotoPrivacy.isClean) == true, "a photo with a location arrives without it")
    let fakeMap = scratch.appendingPathComponent("fake.map")
    try Data("#!/bin/sh".utf8).write(to: fakeMap)
    expect(!i.library.keep(fakeMap, itemID: UUID().uuidString, name: "worldmap.arexperience"), "a room map that isn't one is refused")
    expect(!i.library.keep(fakeMap, itemID: UUID().uuidString, name: "model-\(UUID().uuidString).usdz"), "so is a model that isn't a USDZ")
    expect(!i.library.keep(fakeMap, itemID: "../..", name: "frame_0000.jpg"), "and anything outside a reference folder")
}

try MainActor.assumeIsolated { try runSyncTests() }

print(failures == 0 ? "All sync tests passed" : "\(failures) sync test(s) failed")
exit(failures == 0 ? 0 : 1)
