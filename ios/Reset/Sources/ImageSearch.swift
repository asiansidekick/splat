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
    static let version = 2

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
            for observation in (classify.results ?? []).prefix(60) where observation.confidence >= 0.04 {
                scores[observation.identifier, default: 0] = max(scores[observation.identifier, default: 0], observation.confidence)
            }
            for line in read.results ?? [] {
                if let best = line.topCandidates(1).first, best.confidence > 0.4 { words.insert(best.string) }
            }
        }
        var entry = SearchEntry()
        entry.labels = scores.sorted { $0.value > $1.value }.prefix(90).map { $0.key.replacingOccurrences(of: "_", with: " ") }
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

    /// Words that mean the same thing to a person searching, whatever the classifier calls them.
    private static let groups: [[String]] = [
        ["watch", "wristwatch", "clock", "timepiece"],
        ["sword", "blade", "knife", "dagger", "machete", "saber", "sabre", "katana", "weapon", "axe"],
        ["gun", "pistol", "rifle", "firearm", "revolver", "weapon", "shotgun"],
        ["phone", "telephone", "mobile", "cellphone", "smartphone", "iphone"],
        ["laptop", "computer", "notebook", "macbook", "keyboard", "monitor", "screen"],
        ["tv", "television", "screen", "monitor", "display"],
        ["sofa", "couch", "settee", "loveseat"],
        ["chair", "stool", "armchair", "seat", "bench"],
        ["table", "desk", "counter", "bench", "nightstand", "dresser"],
        ["bed", "mattress", "pillow", "bedding", "blanket", "duvet", "sheet", "sheets"],
        ["hat", "cap", "helmet", "beanie", "fedora", "hood", "bonnet"],
        ["glasses", "sunglasses", "eyeglasses", "spectacles", "goggles"],
        ["shoe", "shoes", "sneaker", "sneakers", "boot", "boots", "footwear", "sandal", "heel", "slipper"],
        ["jacket", "coat", "blazer", "hoodie", "parka", "cardigan", "jumper", "sweater"],
        ["shirt", "tshirt", "blouse", "top", "polo", "jersey"],
        ["trousers", "pants", "jeans", "shorts", "skirt", "dress", "gown"],
        ["suit", "tuxedo", "uniform", "costume", "outfit", "clothes", "clothing", "garment", "wardrobe"],
        ["bag", "handbag", "purse", "backpack", "suitcase", "luggage", "briefcase", "satchel"],
        ["jewellery", "jewelry", "necklace", "ring", "bracelet", "earring", "chain", "pendant"],
        ["hair", "hairstyle", "wig", "haircut", "ponytail", "braid", "beard", "moustache", "mustache"],
        ["makeup", "lipstick", "cosmetic", "cosmetics", "mascara", "foundation", "powder", "lipgloss"],
        ["face", "person", "man", "woman", "actor", "actress", "portrait", "people", "child", "boy", "girl"],
        ["hand", "hands", "finger", "fingers", "arm"],
        ["car", "vehicle", "automobile", "sedan", "van", "truck", "suv", "taxi"],
        ["motorbike", "motorcycle", "scooter", "moped"],
        ["bike", "bicycle", "cycle"],
        ["boat", "ship", "yacht", "canoe", "kayak", "vessel"],
        ["plane", "aeroplane", "airplane", "aircraft", "jet", "helicopter"],
        ["cup", "mug", "glass", "tumbler", "teacup", "coffee"],
        ["bottle", "flask", "jar", "can", "carton"],
        ["drink", "beer", "wine", "cocktail", "juice", "water", "soda", "alcohol"],
        ["food", "meal", "plate", "dish", "bowl", "snack", "fruit", "bread", "pizza", "cake"],
        ["lamp", "light", "lantern", "chandelier", "bulb", "lighting"],
        ["door", "gate", "doorway", "entrance"],
        ["window", "curtain", "blind", "blinds", "drapes"],
        ["picture", "painting", "frame", "poster", "artwork", "photo", "mirror"],
        ["book", "books", "magazine", "newspaper", "paper", "document", "letter", "notebook"],
        ["plant", "flower", "flowers", "tree", "leaf", "pot", "vase", "bouquet"],
        ["cable", "wire", "cord", "lead", "plug", "charger", "adapter", "socket"],
        ["camera", "lens", "tripod", "microphone", "boom", "slate", "clapper"],
        ["toy", "doll", "teddy", "puppet", "figurine", "statue"],
        ["tool", "hammer", "screwdriver", "wrench", "drill", "saw", "spanner"],
        ["box", "crate", "package", "carton", "parcel", "case"],
        ["towel", "robe", "bathrobe", "napkin", "cloth"],
        ["umbrella", "parasol"],
        ["key", "keys", "lock", "padlock"],
        ["money", "cash", "coin", "coins", "banknote", "wallet"],
        ["dog", "puppy", "pet"],
        ["cat", "kitten"],
        ["bird", "parrot", "owl", "eagle"],
        ["room", "bedroom", "hotel", "interior", "indoor"],
        ["outdoor", "beach", "sea", "ocean", "sand", "shore", "sky", "garden", "street", "road"],
    ]

    /// A word and the other words it can stand for.
    private static func options(for word: String) -> [String] {
        var found = [word]
        if word.count > 3, word.hasSuffix("ies") { found.append(String(word.dropLast(3)) + "y") }
        if word.count > 3, word.hasSuffix("s") { found.append(String(word.dropLast())) }
        if word.count > 4, word.hasSuffix("es") { found.append(String(word.dropLast(2))) }
        for group in groups where group.contains(where: { found.contains($0) }) { found += group }
        return Array(Set(found))
    }

    /// Whether `word` is in the text, allowing one slip of the finger in longer words.
    private static func found(_ word: String, in text: String, tokens: Set<String>) -> Bool {
        // Short words must be whole words ("car" is not in "card"); longer ones may be part of one.
        if word.count <= 4 { return tokens.contains(word) }
        if text.contains(word) { return true }
        guard word.count >= 5 else { return false }
        return tokens.contains { token in
            abs(token.count - word.count) <= 1 && token.first == word.first && distance(token, word) <= 1
        }
    }

    /// Edit distance, capped: enough to know whether two words differ by at most one letter.
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var row = [i]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                row.append(min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)))
            }
            previous = row
        }
        return previous.last ?? 0
    }

    /// Whether every word typed is found in the reference's labels, text, slate, name, group or notes.
    static func matches(_ query: String, reference: Reference, entry: SearchEntry?) -> Bool {
        var hay = [reference.scene, reference.setup, reference.name, reference.group, reference.title]
        hay += reference.takes.map(\.note)
        hay += reference.notes.map(\.text)
        if let entry { hay += entry.labels; hay.append(entry.text) }
        let all = hay.joined(separator: " ").lowercased()
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return true }
        let tokens = Set(all.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return words.allSatisfy { word in
            options(for: word).contains { found($0, in: all, tokens: tokens) }
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
