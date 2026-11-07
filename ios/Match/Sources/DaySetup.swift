import Foundation

// Sets up a shooting day from the text read off a call sheet. Foundation only, so CI can test it.
// Scene reading is Reset's (CallSheet.swift, kept the same in both apps); this adds the cast.

/// A scene of the day with the characters in it, ready to check and turn into boards.
struct DayScene: Identifiable, Equatable {
    var id = UUID()
    var scene: String
    var title: String
    /// Comma separated, so it is one text field to fix.
    var characters: String
    var include = true

    var characterList: [String] {
        characters.split(whereSeparator: { ",;&/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

enum DaySetup {
    /// "1. SARAH", "3 - Bob Jones", "2) DETECTIVE REYES": the cast list of a call sheet, by cast number.
    private static let castLine = try! NSRegularExpression(
        pattern: "^\\s*(\\d{1,2})\\s*[.):\\-–—]?\\s+([A-Za-z][A-Za-z'’.\\- ]{1,30})\\s*$")
    /// The cast numbers at the end of a scene row: "12 INT. KITCHEN - DAY  1, 3, 5".
    private static let trailingNumbers = try! NSRegularExpression(pattern: "((?:\\d{1,2}\\s*[,&]\\s*)+\\d{1,2}|\\s\\d{1,2})\\s*$")
    /// Words that mean a row is something else than a cast name.
    private static let notNames = ["int", "ext", "day", "night", "page", "pgs", "scene", "set", "cast", "call", "unit", "crew", "dawn", "dusk", "total", "pages"]

    /// Cast number to character, from the cast list rows.
    static func castTable(_ lines: [String]) -> [Int: String] {
        var table: [Int: String] = [:]
        for raw in lines {
            let line = clean(raw)
            let range = NSRange(line.startIndex..., in: line)
            guard CallSheetParser.parse([line]).isEmpty,
                let match = castLine.firstMatch(in: line, range: range),
                let numberRange = Range(match.range(at: 1), in: line), let nameRange = Range(match.range(at: 2), in: line),
                let number = Int(line[numberRange])
            else { continue }
            let name = CallSheetParser.clean(String(line[nameRange]))
            let words = name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            guard !name.isEmpty, !words.contains(where: { notNames.contains($0) }), table[number] == nil else { continue }
            table[number] = displayName(name)
        }
        return table
    }

    /// The scenes of the day with their characters where the sheet's cast numbers give them.
    static func parse(_ lines: [String]) -> [DayScene] {
        let table = castTable(lines)
        let scenes = CallSheetParser.parse(lines)
        return scenes.map { scene in
            var names: [String] = []
            // Find the row this scene came from and read the cast numbers off its end.
            if !table.isEmpty, let row = lines.map(clean).first(where: { CallSheetParser.parse([$0]).first?.scene == scene.scene }),
                let match = trailingNumbers.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)),
                let range = Range(match.range(at: 1), in: row)
            {
                let numbers = row[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                names = numbers.compactMap { table[$0] }
            }
            return DayScene(scene: scene.scene, title: scene.title, characters: names.joined(separator: ", "))
        }
    }

    /// Boards to make for the checked scenes: one per character per scene, skipping any that exist.
    static func boards(for scenes: [DayScene], department: Department, existing: [Board], now: Date = .now) -> [Board] {
        var made: [Board] = []
        for item in scenes where item.include {
            let scene = item.scene.trimmingCharacters(in: .whitespaces)
            guard !scene.isEmpty else { continue }
            for name in item.characterList {
                let taken = (existing + made).contains {
                    $0.scene.caseInsensitiveCompare(scene) == .orderedSame
                        && $0.subject.caseInsensitiveCompare(name) == .orderedSame && $0.department == department
                }
                guard !taken else { continue }
                var board = Board(scene: scene, subject: name, department: department, created: now)
                board.notes = item.title
                made.append(board)
            }
        }
        return made
    }

    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "SARAH JONES" reads as "Sarah Jones"; mixed case is left alone.
    private static func displayName(_ name: String) -> String {
        name == name.uppercased() ? name.capitalized : name
    }
}
