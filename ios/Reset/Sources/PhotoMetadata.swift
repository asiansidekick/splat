import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/// The slate details of a photo leaving the app for Photos: scene, shot, take, what it is, and notes.
struct PhotoStamp {
    var scene = ""
    var shot = ""
    var take = ""
    var name = ""
    var group = ""
    var notes: [String] = []
    var hero = false

    init(scene: String, shot: String, take: String, name: String, group: String = "", notes: [String] = [], hero: Bool = false) {
        self.scene = scene; self.shot = shot; self.take = take; self.name = name
        self.group = group; self.notes = notes; self.hero = hero
    }

    init(_ reference: Reference) {
        let takeNotes = reference.takes.sorted { $0.number < $1.number }.compactMap { take -> String? in
            let text = take.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "Take \(take.number): \(text)"
        }
        let roomNotes = reference.notes.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.init(scene: reference.scene, shot: reference.shot, take: reference.setup, name: reference.name,
                  group: reference.group, notes: takeNotes + roomNotes, hero: reference.hero)
    }

    var title: String {
        let slate = Reference.label(scene: scene, setup: take, shot: shot)
        return [slate, name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var caption: String {
        var lines = [title]
        if hero { lines.append("Hero reference") }
        if !group.isEmpty { lines.append("Group: \(group)") }
        lines += notes.map { "Note: \($0)" }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Writes a stamp into a photo's own metadata (title, caption, keywords, and Reset's own fields)
/// when it is saved to Photos. Never GPS, and the originals in the app are untouched.
enum PhotoMetadata {
    static let namespace = "https://asiansidekick.com/reset/1.0/"
    static let key = "stampMetadata"

    /// On unless switched off in Help.
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// JPEG data of the image with the stamp written in, or nil if that fails (the plain image is then saved).
    static func stamped(_ image: UIImage, with stamp: PhotoStamp) -> Data? {
        let data = NSMutableData()
        guard let cg = image.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }

        let metadata = CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace as CFString, "reset" as CFString, &error)
        func set(_ path: String, _ value: String) {
            guard !value.isEmpty else { return }
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value as CFString)
        }
        let slate = Reference.label(scene: stamp.scene, setup: stamp.take, shot: stamp.shot)
        let keywords = [slate, stamp.scene.isEmpty ? "" : "Scene \(stamp.scene)", stamp.shot.isEmpty ? "" : "Shot \(stamp.shot)",
                        stamp.take.isEmpty ? "" : "Take \(stamp.take)", stamp.name, stamp.group, stamp.hero ? "Hero" : ""]
            .filter { !$0.isEmpty }
        set("dc:title", stamp.title)
        set("dc:description", stamp.caption)
        set("exif:UserComment", stamp.caption)
        set("photoshop:Headline", stamp.title)
        if let list = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString,
                                               "subject" as CFString, .arrayUnordered, keywords as CFArray) {
            CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, list)
        }
        set("reset:Scene", stamp.scene)
        set("reset:Shot", stamp.shot)
        set("reset:Take", stamp.take)
        set("reset:Description", stamp.name)
        set("reset:Group", stamp.group)
        set("reset:Note", stamp.notes.joined(separator: "\n"))
        set("reset:Hero", stamp.hero ? "yes" : "no")

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyOrientation: CGImagePropertyOrientation(image.imageOrientation).rawValue,
        ]
        CGImageDestinationAddImageAndMetadata(destination, cg, metadata, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
