import ImageIO
import UIKit

/// Writes the slate details into a photo's own metadata when it leaves the app (Photos, a saved copy),
/// so scene, shot, take, character and notes travel with the picture. The pixels are not touched:
/// the JPEG is copied across with the new tags. Never GPS, and the original in the app is unchanged.
enum PhotoMetadata {
    static let namespace = "https://asiansidekick.com/match/1.0/"
    static let key = "stampMetadata"

    /// On unless switched off in the ••• menu.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func title(_ shot: Shot, in board: Board) -> String {
        "\(Slate.sceneName(board.scene, shot: board.shotLetter)) · \(board.shortTitle) · \(Slate.takeName(shot.take))"
    }

    /// The details as readable lines, for a caption.
    static func caption(_ shot: Shot, in board: Board) -> String {
        var lines = [title(shot, in: board)]
        if shot.isReference { lines.append("Reference") }
        if !board.look.isEmpty { lines.append("Look: \(board.look)") }
        if !shot.note.isEmpty { lines.append("Note: \(shot.note)") }
        if !board.notes.isEmpty { lines.append("Board notes: \(board.notes)") }
        return lines.joined(separator: "\n")
    }

    /// A copy of the JPEG at `file` with the details written in, or `file` itself if that fails or it is off.
    static func stamped(_ file: URL, shot: Shot, in board: Board) -> URL {
        guard enabled, let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source) else { return file }
        let out = FileManager.default.temporaryDirectory.appending(path: "stamped-\(UUID().uuidString)-\(file.lastPathComponent)")
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { return file }

        let metadata = CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, "match" as CFString, &error)
        func set(_ path: String, _ value: String) {
            guard !value.isEmpty else { return }
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
        }
        let keywords = [Slate.sceneName(board.scene, shot: board.shotLetter), board.subject, board.department.name, Slate.takeName(shot.take)]
            .filter { !$0.isEmpty }
        let caption = caption(shot, in: board)
        set("dc:title", title(shot, in: board))
        set("dc:description", caption)
        set("exif:UserComment", caption)
        set("photoshop:Headline", title(shot, in: board))
        let list = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString,
                                            "dc" as CFString, "subject" as CFString, .arrayUnordered, keywords as CFArray)
        if let list { CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, list) }
        set("match:Scene", board.scene)
        set("match:Shot", board.shotLetter)
        set("match:Take", Slate.takeName(shot.take))
        set("match:Character", board.subject)
        set("match:Department", board.department.name)
        set("match:Look", board.look)
        set("match:Note", shot.note)
        set("match:Reference", shot.isReference ? "yes" : "no")

        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: out)
            return file
        }
        return out
    }
}

extension PhotoLibrary {
    /// Saves photos to Photos with their slate details in the metadata, then tidies the copies.
    static func saveStamped(_ items: [(file: URL, shot: Shot)], board: Board) async -> Bool {
        let files = items.map { PhotoMetadata.stamped($0.file, shot: $0.shot, in: board) }
        let saved = await save(files)
        for (file, original) in zip(files, items) where file != original.file { try? FileManager.default.removeItem(at: file) }
        return saved
    }
}
