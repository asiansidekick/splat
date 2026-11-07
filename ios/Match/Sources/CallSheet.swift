import Foundation

// Scenes read off a call sheet. Foundation only, so the sync tests can run it on a Mac.

/// One scene from a call sheet: its number as slated ("12", "14A") and what it is ("INT. KITCHEN - DAY").
struct CallSheetScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var scene: String
    var title: String
}

enum CallSheetParser {
    private static let place = "(?:INT|EXT|I\\/E|INT\\/EXT|EXT\\/INT)"
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

    /// One tidy line: spaces collapsed, stray dashes and dots trimmed from the ends.
    static func clean(_ text: String) -> String {
        let spaced = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return spaced.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:.,;|"))
    }
}

