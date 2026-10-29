import ImageIO
import SwiftUI
import UIKit

/// Which department a board belongs to.
enum Department: String, Codable, CaseIterable, Identifiable {
    case hair, makeup, costume, props, set, other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .hair: "Hair"
        case .makeup: "Makeup"
        case .costume: "Costume"
        case .props: "Props"
        case .set: "Set"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .hair: "scissors"
        case .makeup: "paintbrush.pointed"
        case .costume: "tshirt"
        case .props: "cup.and.saucer"
        case .set: "sofa"
        case .other: "square.grid.2x2"
        }
    }

    /// The departments Match is made for. Props and Set stay readable on old boards and
    /// are only offered for a board that already uses them.
    static let main: [Department] = [.hair, .makeup, .costume, .other]

    static func picked(_ current: Department) -> [Department] {
        main.contains(current) ? main : main + [current]
    }
}

/// One continuity photo, taken in the app or imported (for example a QTake screenshot).
struct Shot: Codable, Identifiable, Equatable, Hashable {
    enum Source: String, Codable { case camera, imported }

    var id = UUID()
    var taken: Date
    var take: Int  // 0 is prep, before the first take
    var angle = ""
    var note = ""
    var isReference = false
    var source: Source = .camera

    init(taken: Date, take: Int, angle: String = "", source: Source = .camera) {
        self.taken = taken
        self.take = take
        self.angle = angle
        self.source = source
    }

    /// Missing fields fall back to defaults, so boards saved by an older build still open after an update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        taken = (try? c.decode(Date.self, forKey: .taken)) ?? .now
        take = (try? c.decode(Int.self, forKey: .take)) ?? 0
        angle = (try? c.decode(String.self, forKey: .angle)) ?? ""
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        isReference = (try? c.decode(Bool.self, forKey: .isReference)) ?? false
        source = (try? c.decode(Source.self, forKey: .source)) ?? .camera
    }

    var file: String { "\(id.uuidString).jpg" }
    var thumbnailFile: String { "\(id.uuidString)-thumb.jpg" }

    var label: String {
        [Slate.takeName(take), angle.isEmpty ? nil : angle, taken.formatted(date: .omitted, time: .shortened)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Everything for one subject in one scene, for example Sarah's hair in scene 12, or the desk props.
struct Board: Codable, Identifiable, Equatable {
    var id = UUID()
    var scene: String
    var subject: String
    var department: Department
    /// The costume change or look, for example "Change 2" or "Look B".
    var look = ""
    var notes = ""
    var created: Date
    var shots: [Shot] = []

    init(scene: String, subject: String, department: Department, created: Date) {
        self.scene = scene
        self.subject = subject
        self.department = department
        self.created = created
    }

    /// Missing or unknown fields fall back to defaults, so an update never hides saved boards.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        scene = (try? c.decode(String.self, forKey: .scene)) ?? ""
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        department = (try? c.decode(Department.self, forKey: .department)) ?? .other
        look = (try? c.decode(String.self, forKey: .look)) ?? ""
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        created = (try? c.decode(Date.self, forKey: .created)) ?? .now
        // A damaged photo entry is skipped rather than losing the whole board.
        shots = ((try? c.decode([Failable<Shot>].self, forKey: .shots)) ?? []).compactMap(\.value)
    }

    var title: String {
        [subject, look, department.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// Short enough for the camera's top bar, for example "Sarah Hair".
    var shortTitle: String { subject.isEmpty ? department.name : "\(subject) \(department.name)" }
    var references: [Shot] { shots.filter(\.isReference).sorted { $0.taken < $1.taken } }
    var takes: [Int] { Set(shots.map(\.take)).sorted(by: >) }
    var newest: Shot? { shots.max { $0.taken < $1.taken } }
    var cover: Shot? { references.first ?? newest }

    func shots(in take: Int) -> [Shot] {
        shots.filter { $0.take == take }.sorted { $0.taken < $1.taken }
    }

    /// What to compare a photo against: the reference from the same angle, else any reference,
    /// else the first photo on the board.
    func reference(for shot: Shot) -> Shot? {
        let others = shots.filter { $0.id != shot.id }
        let references = others.filter(\.isReference).sorted { $0.taken < $1.taken }
        return references.first { $0.angle == shot.angle } ?? references.first ?? others.min { $0.taken < $1.taken }
    }

    func matches(_ search: String) -> Bool {
        guard !search.isEmpty else { return true }
        let text = ([subject, look, notes, department.name, "scene \(scene)"] + shots.map(\.note)).joined(separator: " ")
        return text.localizedCaseInsensitiveContains(search)
    }
}

/// Decodes an element if it can, so one bad entry does not fail a whole list.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Scene and take numbering.
enum Slate {
    /// Angles round a person, in the order crew walk round them.
    static let angles = ["Front", "3/4 Left", "Left", "Back", "Right", "3/4 Right", "Close-up", "Full length"]

    /// The short label under the camera, for example "¾ L". Older angles show in capitals.
    static func angleLabel(_ angle: String) -> String {
        switch angle {
        case "": "ANY"
        case "3/4 Left": "¾ L"
        case "3/4 Right": "¾ R"
        case "Close-up": "CLOSE"
        case "Full length": "FULL"
        default: angle.uppercased()
        }
    }

    /// Text safe to use in a file name.
    static func fileSafe(_ text: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return text.components(separatedBy: bad).joined(separator: "-")
    }

    static func takeName(_ take: Int) -> String { take == 0 ? "Prep" : "Take \(take)" }
    static func shortTake(_ take: Int) -> String { take == 0 ? "Prep" : "Tk \(take)" }

    /// Orders scenes the way they read: 2 before 10, 12 before 12A.
    static func sortedScenes(_ scenes: some Sequence<String>) -> [String] {
        Set(scenes).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Boards on disk: Documents/Boards/<id>/board.json plus a JPEG and a thumbnail per photo.
/// Everything stays on the device; the folder is visible in the Files app.
@MainActor
final class BoardStore: ObservableObject {
    @Published private(set) var boards: [Board] = []
    /// The current take of each scene, shared by every board in that scene.
    @Published private var sceneTakes: [String: Int] = [:]
    private let thumbnails = NSCache<NSString, UIImage>()
    private static let takesKey = "sceneTakes"

    nonisolated static var root: URL { URL.documentsDirectory.appending(path: "Boards", directoryHint: .isDirectory) }
    nonisolated static func folder(for id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    nonisolated static func url(of shot: Shot, in boardID: UUID) -> URL { folder(for: boardID).appending(path: shot.file) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() { load() }

    func load() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let folders = (try? manager.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        boards = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "board.json")) else { return nil }
            return try? Self.decoder.decode(Board.self, from: data)
        }
        sceneTakes = UserDefaults.standard.dictionary(forKey: Self.takesKey) as? [String: Int] ?? [:]
    }

    func board(_ id: UUID) -> Board? { boards.first { $0.id == id } }

    var scenes: [String] { Slate.sortedScenes(boards.map(\.scene)) }

    /// A new board in the latest scene and department, since one person usually works through a scene.
    func newBoard() -> Board {
        let latest = boards.max { $0.created < $1.created }
        return Board(scene: latest?.scene ?? "1", subject: "", department: latest?.department ?? .hair, created: .now)
    }

    func save(_ board: Board) {
        if let index = boards.firstIndex(where: { $0.id == board.id }) {
            boards[index] = board
        } else {
            boards.append(board)
        }
        let folder = Self.folder(for: board.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.encoder.encode(board).write(to: folder.appending(path: "board.json"), options: .atomic)
        } catch {
            print("Could not save board: \(error)")
        }
    }

    func delete(_ board: Board) {
        try? FileManager.default.removeItem(at: Self.folder(for: board.id))
        boards.removeAll { $0.id == board.id }
    }

    // MARK: Takes

    func take(for scene: String) -> Int { sceneTakes[scene] ?? 0 }

    func setTake(_ take: Int, for scene: String) {
        sceneTakes[scene] = max(0, take)
        UserDefaults.standard.set(sceneTakes, forKey: Self.takesKey)
    }

    // MARK: Photos

    /// Saves a photo (JPEG, HEIC, PNG or RAW data) to the board at the scene's current take.
    /// The first photo from each angle becomes that angle's reference. Nil if it could not be read or saved.
    @discardableResult
    /// `crop` (width over height, upright) trims a camera photo to what the screen showed.
    func addShot(_ data: Data, to boardID: UUID, angle: String, source: Shot.Source, crop: CGFloat? = nil) async -> Shot? {
        guard let board = board(boardID) else { return nil }
        var shot = Shot(taken: .now, take: take(for: board.scene), angle: angle, source: source)
        let folder = Self.folder(for: boardID)
        let file = shot.file
        let thumbnail = shot.thumbnailFile
        let saved = await Task.detached(priority: .userInitiated) {
            ImageFile.write(data, to: folder, file: file, thumbnail: thumbnail, crop: crop)
        }.value
        guard saved, var latest = self.board(boardID) else { return nil }
        if !latest.shots.contains(where: { $0.isReference && $0.angle == angle }) {
            shot.isReference = true
        }
        latest.shots.append(shot)
        save(latest)
        return shot
    }

    func update(_ shot: Shot, in boardID: UUID) {
        guard var board = board(boardID), let index = board.shots.firstIndex(where: { $0.id == shot.id }) else { return }
        board.shots[index] = shot
        save(board)
    }

    func delete(_ shot: Shot, from boardID: UUID) {
        guard var board = board(boardID) else { return }
        let folder = Self.folder(for: boardID)
        try? FileManager.default.removeItem(at: folder.appending(path: shot.file))
        try? FileManager.default.removeItem(at: folder.appending(path: shot.thumbnailFile))
        thumbnails.removeObject(forKey: shot.id.uuidString as NSString)
        board.shots.removeAll { $0.id == shot.id }
        save(board)
    }

    func thumbnail(_ shot: Shot, in boardID: UUID) -> UIImage? {
        let key = shot.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let url = Self.folder(for: boardID).appending(path: shot.thumbnailFile)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    /// The photo at screen resolution. Slow, so call it off the main thread.
    nonisolated static func image(_ shot: Shot, in boardID: UUID, maxPixels: Int = 2400) -> UIImage? {
        ImageFile.load(url(of: shot, in: boardID), maxPixels: maxPixels)
    }
}

enum ImageFile {
    static let maxPixels = 3024

    /// Writes the photo upright as a JPEG, plus a small thumbnail for the grids. Decodes straight
    /// to the reduced size, so a 48 MP or RAW photo never sits in memory at full size.
    static func write(_ data: Data, to folder: URL, file: String, thumbnail: String, crop: CGFloat? = nil) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let full = downsample(source, maxPixels: maxPixels).flatMap({ centred($0, aspect: crop) }),
            let small = downsample(source, maxPixels: 640).flatMap({ centred($0, aspect: crop) }),
            let fullData = UIImage(cgImage: full).jpegData(compressionQuality: 0.85),
            let smallData = UIImage(cgImage: small).jpegData(compressionQuality: 0.8)
        else { return false }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try fullData.write(to: folder.appending(path: file), options: .atomic)
            try smallData.write(to: folder.appending(path: thumbnail), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The middle of the picture at the given width over height, as the screen fills with it.
    static func centred(_ image: CGImage, aspect: CGFloat?) -> CGImage? {
        guard let aspect, aspect > 0 else { return image }
        var width = CGFloat(image.width)
        var height = CGFloat(image.height)
        if width / height > aspect { width = height * aspect } else { height = width / aspect }
        let rect = CGRect(x: (CGFloat(image.width) - width) / 2, y: (CGFloat(image.height) - height) / 2,
                          width: width, height: height).integral
        return image.cropping(to: rect) ?? image
    }

    static func downsample(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func load(_ url: URL, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = downsample(source, maxPixels: maxPixels)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
