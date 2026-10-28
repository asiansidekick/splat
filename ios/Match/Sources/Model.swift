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
    var notes = ""
    var created: Date
    var shots: [Shot] = []

    var title: String { subject.isEmpty ? department.name : "\(subject) · \(department.name)" }
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
        let text = ([subject, notes, department.name, "scene \(scene)"] + shots.map(\.note)).joined(separator: " ")
        return text.localizedCaseInsensitiveContains(search)
    }
}

/// Scene and take numbering.
enum Slate {
    static let angles = ["Front", "Left", "Right", "Back", "Detail", "Wide"]

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

    /// Saves a photo to the board at the scene's current take. The first photo from each angle
    /// becomes that angle's reference.
    @discardableResult
    func addShot(_ image: UIImage, to boardID: UUID, angle: String, source: Shot.Source) async -> Shot? {
        guard let board = board(boardID) else { return nil }
        var shot = Shot(taken: .now, take: take(for: board.scene), angle: angle, source: source)
        let folder = Self.folder(for: boardID)
        let file = shot.file
        let thumbnail = shot.thumbnailFile
        let saved = await Task.detached(priority: .userInitiated) {
            ImageFile.write(image, to: folder, file: file, thumbnail: thumbnail)
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
    static let maxPixels: CGFloat = 3024

    /// Writes the photo upright as a JPEG, plus a small thumbnail for the grids.
    static func write(_ image: UIImage, to folder: URL, file: String, thumbnail: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let full = resized(image, maxSide: maxPixels).jpegData(compressionQuality: 0.85),
                let small = resized(image, maxSide: 480).jpegData(compressionQuality: 0.8)
            else { return false }
            try full.write(to: folder.appending(path: file), options: .atomic)
            try small.write(to: folder.appending(path: thumbnail), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Redraws the image upright with its longest side at most `maxSide` pixels.
    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, maxSide / max(pixels.width, pixels.height, 1))
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func load(_ url: URL, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
