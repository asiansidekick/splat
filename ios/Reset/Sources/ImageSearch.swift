import ImageIO
import SwiftUI
import UIKit
import Vision

/// Text search over the reference photos (Phil, 2026-11-05), like the iPhone gallery's: typing "watch"
/// finds the pictures with one in. Entirely on the device. Apple's Vision classifier names what is in
/// each picture (a fixed list of about 1,300 everyday things) and text recognition reads any writing; a
/// small index of both is kept in each reference's folder, and slate names and notes are searched too.
struct SearchEntry: Codable, Equatable {
    var version = SearchIndexer.version
    var labels: [String] = []
    var text = ""
}

enum SearchIndexer {
    static let version = 1

    static func url(for id: UUID) -> URL {
        ReferenceStore.folder(for: id).appendingPathComponent("search.json")
    }

    static func load(_ id: UUID) -> SearchEntry? {
        guard let data = try? Data(contentsOf: url(for: id)),
              let entry = try? JSONDecoder().decode(SearchEntry.self, from: data), entry.version == version else { return nil }
        return entry
    }

    /// Looks at up to five of the keyframes and three snapshots. Slow: run it off the main thread.
    static func index(_ reference: Reference) -> SearchEntry {
        let folder = ReferenceStore.folder(for: reference.id)
        var frames = Self.spread(reference.keyframes, count: 5)
        frames += Self.spread(reference.snapshots.map(\.frame), count: 3)
        var scores: [String: Float] = [:]
        var words = Set<String>()
        for frame in frames {
            let file = folder.appendingPathComponent(frame.imageFile)
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1280,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                  ] as CFDictionary) else { continue }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: Self.orientation(frame.uprightOrientation), options: [:])
            let classify = VNClassifyImageRequest()
            let read = VNRecognizeTextRequest()
            read.recognitionLevel = .accurate
            read.usesLanguageCorrection = true
            try? handler.perform([classify, read])
            for observation in (classify.results ?? []).prefix(25) where observation.confidence >= 0.1 {
                scores[observation.identifier, default: 0] = max(scores[observation.identifier, default: 0], observation.confidence)
            }
            for line in read.results ?? [] {
                if let best = line.topCandidates(1).first, best.confidence > 0.4 { words.insert(best.string) }
            }
        }
        var entry = SearchEntry()
        entry.labels = scores.sorted { $0.value > $1.value }.prefix(40).map { $0.key.replacingOccurrences(of: "_", with: " ") }
        entry.text = words.sorted().joined(separator: " ")
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: url(for: reference.id), options: .atomic) }
        return entry
    }

    private static func orientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private static func spread<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count else { return items }
        return (0..<count).map { items[$0 * (items.count - 1) / (count - 1)] }
    }

    /// Words people type, and what the classifier calls them.
    private static let synonyms: [String: [String]] = [
        "watch": ["wristwatch", "watch", "clock"],
        "sword": ["sword", "knife", "weapon", "blade", "dagger"],
        "phone": ["telephone", "mobile phone", "cellphone"],
        "laptop": ["laptop", "computer", "notebook"],
        "tv": ["television", "screen", "monitor"],
        "sofa": ["couch", "sofa"],
        "couch": ["couch", "sofa"],
        "hat": ["hat", "cap", "helmet"],
        "glasses": ["glasses", "sunglasses", "eyeglasses"],
        "shoe": ["shoe", "sneaker", "boot", "footwear"],
        "shoes": ["shoe", "sneaker", "boot", "footwear"],
        "car": ["car", "vehicle", "automobile"],
        "bike": ["bicycle", "bike"],
        "motorbike": ["motorcycle", "motorbike"],
        "motorcycle": ["motorcycle", "motorbike"],
    ]

    /// Whether every word typed is found in the reference's labels, text, slate, name, group or notes.
    static func matches(_ query: String, reference: Reference, entry: SearchEntry?) -> Bool {
        var hay = [reference.scene, reference.setup, reference.name, reference.group, reference.title]
        hay += reference.takes.map(\.note)
        hay += reference.notes.map(\.text)
        if let entry { hay += entry.labels; hay.append(entry.text) }
        let all = hay.joined(separator: " ").lowercased()
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            var options = synonyms[word] ?? []
            options.append(word)
            if word.count > 3, word.hasSuffix("s") { options.append(String(word.dropLast())) }
            return options.contains { all.contains($0) }
        }
    }
}

@MainActor
final class ImageIndex: ObservableObject {
    static let shared = ImageIndex()
    @Published private(set) var entries: [UUID: SearchEntry] = [:]
    /// Pictures still to be looked at, shown while the first pass runs.
    @Published private(set) var remaining = 0
    private var working = Set<UUID>()

    /// Reads saved indexes and indexes the rest, one at a time in the background.
    func refresh(_ references: [Reference]) {
        var todo: [Reference] = []
        for reference in references where entries[reference.id] == nil && !working.contains(reference.id) {
            if let saved = SearchIndexer.load(reference.id) {
                entries[reference.id] = saved
            } else {
                todo.append(reference)
            }
        }
        guard !todo.isEmpty else { return }
        remaining += todo.count
        for reference in todo { working.insert(reference.id) }
        Task {
            for reference in todo {
                let entry = await Task.detached(priority: .utility) { SearchIndexer.index(reference) }.value
                entries[reference.id] = entry
                working.remove(reference.id)
                remaining -= 1
            }
        }
    }

    func matches(_ query: String, _ reference: Reference) -> Bool {
        SearchIndexer.matches(query, reference: reference, entry: entries[reference.id])
    }
}
