import Combine
import Foundation

// Scenes read off a call sheet. Foundation only, so the sync tests can run it on a Mac.

/// One scene from a call sheet: its number as slated ("12", "14A") and what it is ("INT. KITCHEN - DAY").
struct CallSheetScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var scene: String
    var title: String
}

/// One piece of text the reader found, with where it sits on its page (0 to 1, from the top left).
struct CallSheetText: Equatable {
    var text: String
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
}

enum CallSheetParser {
    private static let place = "(?:INT|EXT|I\\/E|INT\\/EXT|EXT\\/INT)"
    /// A table cell that starts with a scene heading: "EXT - VILLAGE NEAR DOCK", "I/E - DOCK STRUCTURE".
    private static let headingCell = try! NSRegularExpression(
        pattern: "^\\s*(?:INT\\/EXT|EXT\\/INT|INT|EXT|[I1l]\\/E)\\b\\.?\\s*[\\-–—:.]?\\s*[A-Z].*$", options: [.caseInsensitive])
    /// One scene number in a table's scene column: "94A", "95aA", "96pt" (a part of 96).
    private static let numberToken = try! NSRegularExpression(pattern: "^(\\d{1,3}[A-Za-z]{0,2}?)(?:pt|PT|Pt)?$")
    /// "SC 12 ...", "Scene 12A - ...", "Sc. 3: ..."
    private static let named = try! NSRegularExpression(
        pattern: "^\\s*(?:scene|scn|sc)\\.?\\s*#?\\s*(\\d{1,3}[A-Z]{0,2})\\b[\\s\\-–—:.)]*(.*)$", options: [.caseInsensitive])
    /// "12 INT. KITCHEN - DAY", "12A. EXT PARK" (a number straight before a scene heading)
    private static let heading = try! NSRegularExpression(
        pattern: "^\\s*(\\d{1,3}[A-Z]{0,2})\\s*[\\-–—:.)]?\\s+(\(place)\\b.*)$", options: [.caseInsensitive])

    /// Scenes found in the lines a text reader returned, in order, each number once.
    static func parse(_ lines: [String]) -> [CallSheetScene] {
        var found: [CallSheetScene] = []
        var seen = Set<String>()
        for raw in lines {
            let line = raw.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            for regex in [named, heading] {
                guard let match = regex.firstMatch(in: line, range: range),
                      let numberRange = Range(match.range(at: 1), in: line),
                      let titleRange = Range(match.range(at: 2), in: line) else { continue }
                let number = String(line[numberRange]).uppercased()
                let title = clean(String(line[titleRange]))
                guard !seen.contains(number) else { break }
                seen.insert(number)
                found.append(CallSheetScene(scene: number, title: title))
                break
            }
        }
        return found
    }

    /// Scenes from a call sheet laid out as a table (Phil, 2026-11-09): the scene number sits in its own column,
    /// left of a cell that starts with the heading ("EXT - DOCK") over the synopsis, so the two come back from the
    /// reader as separate pieces. Each heading takes the numbers left of it, from its row down to the next heading.
    /// Pass the pieces of one page at a time.
    static func parseTable(_ pieces: [CallSheetText]) -> [CallSheetScene] {
        let headings = pieces.filter { piece in
            let range = NSRange(piece.text.startIndex..., in: piece.text)
            return headingCell.firstMatch(in: piece.text, range: range) != nil
        }.sorted { $0.minY < $1.minY }
        guard !headings.isEmpty else { return [] }
        let gaps = zip(headings, headings.dropFirst()).map { $1.minY - $0.minY }.filter { $0 > 0.005 }.sorted()
        let rowHeight = gaps.isEmpty ? 0.12 : gaps[gaps.count / 2]
        var found: [CallSheetScene] = []
        var seen = Set<String>()
        for (index, heading) in headings.enumerated() {
            let top = heading.minY - 0.006
            var bottom = index + 1 < headings.count ? headings[index + 1].minY - 0.003 : heading.minY + rowHeight * 1.5
            // The table ends at its footer ("TOTAL PAGE COUNT", the CAST list, "STRIPS CONTINUE OVER THE PAGE").
            if let end = pieces.filter({ $0.minY > heading.maxY && $0.minY < bottom && isTableEnd($0.text) }).map(\.minY).min() {
                bottom = end
            }
            let title = clean(heading.text)
            let numbers = pieces.filter { piece in
                let middle = (piece.minY + piece.maxY) / 2
                return piece.maxX <= heading.minX + 0.01 && middle >= top && middle < bottom
            }.sorted { $0.minY < $1.minY }
            for piece in numbers {
                for number in sceneNumbers(leading: piece.text) where !seen.contains(number.uppercased()) {
                    seen.insert(number.uppercased())
                    found.append(CallSheetScene(scene: number, title: title))
                }
            }
        }
        return found
    }

    private static func isTableEnd(_ text: String) -> Bool {
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        return upper.hasPrefix("TOTAL") || upper == "CAST" || upper.hasPrefix("STRIPS CONTINUE")
    }

    /// The scene numbers a scene-column cell starts with: "95A, 96pt" gives 95A and 96.
    static func sceneNumbers(leading text: String) -> [String] {
        var numbers: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == "&" || $0.isWhitespace }) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".;:)("))
            guard !token.isEmpty else { continue }
            let range = NSRange(token.startIndex..., in: token)
            guard let match = numberToken.firstMatch(in: token, range: range), let numberRange = Range(match.range(at: 1), in: token) else { break }
            numbers.append(String(token[numberRange]))
        }
        return numbers
    }

    /// Scenes from the pages of a call sheet, each page's pieces in reading order: lines like "12 INT. KITCHEN"
    /// first, then table rows, each number once.
    static func parse(pages: [[CallSheetText]]) -> [CallSheetScene] {
        var found = parse(pages.flatMap { $0.map(\.text) })
        var seen = Set(found.map { $0.scene.uppercased() })
        for page in pages {
            for item in parseTable(page) where !seen.contains(item.scene.uppercased()) {
                seen.insert(item.scene.uppercased())
                found.append(item)
            }
        }
        return found
    }

    /// One tidy line: spaces collapsed, stray dashes and dots trimmed from the ends.
    static func clean(_ text: String) -> String {
        let spaced = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return spaced.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:.,;|"))
    }
}

/// The scenes of the current shoot, kept on the phone and added to by scanning call sheets.
@MainActor
final class CallSheetStore: ObservableObject {
    static let shared = CallSheetStore()
    @Published private(set) var scenes: [CallSheetScene] = []
    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("callsheet.json")
        if let data = try? Data(contentsOf: self.file), let saved = try? JSONDecoder().decode([CallSheetScene].self, from: data) {
            scenes = saved
        }
    }

    /// What a scene is called, or nil if no call sheet named it.
    func title(for scene: String) -> String? {
        let title = scenes.first { $0.scene.caseInsensitiveCompare(scene) == .orderedSame }?.title
        return title?.isEmpty == false ? title : nil
    }

    /// Adds scenes, filling in a title that was missing and updating one that changed; order follows the call sheet numbers.
    func add(_ new: [CallSheetScene]) {
        for item in new {
            if let index = scenes.firstIndex(where: { $0.scene.caseInsensitiveCompare(item.scene) == .orderedSame }) {
                if !item.title.isEmpty { scenes[index].title = item.title }
            } else {
                scenes.append(item)
            }
        }
        scenes.sort { $0.scene.localizedStandardCompare($1.scene) == .orderedAscending }
        save()
    }

    func remove(_ scene: String) {
        scenes.removeAll { $0.scene.caseInsensitiveCompare(scene) == .orderedSame }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(scenes) { try? data.write(to: file, options: .atomic) }
    }
}
