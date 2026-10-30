import ImageIO
import SwiftUI
import UIKit

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
    func addShot(_ data: Data, to boardID: UUID, angle: String, source: Shot.Source, crop: CGFloat? = nil,
                 depth: DepthGrid? = nil) async -> Shot? {
        guard let board = board(boardID) else { return nil }
        var shot = Shot(taken: .now, take: take(for: board.scene), angle: angle, source: source)
        let folder = Self.folder(for: boardID)
        let file = shot.file
        let thumbnail = shot.thumbnailFile
        let depthFile = shot.depthFile
        let saved = await Task.detached(priority: .userInitiated) {
            let written = ImageFile.write(data, to: folder, file: file, thumbnail: thumbnail, crop: crop)
            if written, let depth { try? depth.data.write(to: folder.appending(path: depthFile), options: .atomic) }
            return written
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
        try? FileManager.default.removeItem(at: folder.appending(path: shot.depthFile))
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

    /// The LiDAR depth saved with a photo, if it has one.
    nonisolated static func depth(_ shot: Shot, in boardID: UUID) -> DepthGrid? {
        (try? Data(contentsOf: folder(for: boardID).appending(path: shot.depthFile))).flatMap(DepthGrid.init(data:))
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
