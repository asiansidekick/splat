import Foundation

// Reads call sheets laid out as a table (Phil, 2026-11-09): the scene number sits in its own cell,
// often half way down it, the set ("EXT - VILLAGE NEAR DOCK") heads the next cell, and the cast
// column lists "9. ROSALIE". Plain lines lose that layout, so this works from where each piece of
// text sits on the page. Foundation only, so CI can test it.

/// A piece of text read off a page and where it is: 0...1 of the page across and down, from the
/// top left.
struct TextBox: Equatable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    func sameRow(as other: TextBox) -> Bool {
        abs(midY - other.midY) < max(height, other.height) * 0.6
    }
}

enum CallSheetTable {
    /// "EXT - DOCK", "INT. KITCHEN", "I/E - DOCK STRUCTURE", "INT/EXT CAR".
    private static let heading = try! NSRegularExpression(
        pattern: "^\\s*(?:INT\\.?\\s*/\\s*EXT|EXT\\.?\\s*/\\s*INT|I\\s*/\\s*E|INT|EXT)\\.?(?:\\s|[\\-–—:.]|$)",
        options: [.caseInsensitive])
    /// One scene number as written: "94A", "95aA", "96Apt" (pt is part of a scene), "104aApt".
    private static let sceneToken = try! NSRegularExpression(pattern: "^(\\d{1,3}[A-Za-z]{0,3}?)(?:pt|PT|Pt)?\\.?$")
    /// "9. ROSALIE", "10) FRANKIE", and several in one piece: "6. TYGO 9. ROSALIE".
    private static let castEntry = try! NSRegularExpression(
        pattern: "(\\d{1,3})\\s*[.):]\\s*([A-Za-z][A-Za-z'’\\-]*(?:\\s+[A-Za-z][A-Za-z'’\\-]*){0,3})")
    private static let notNames: Set<String> = ["int", "ext", "day", "night", "page", "pgs", "scene", "set", "cast", "call",
                                                "unit", "crew", "dawn", "dusk", "total", "pages", "x", "dbl", "double",
                                                "stunt", "coord", "stand", "in", "sb"]

    /// Scenes on one page laid out as a table, with the characters its cast cells name. `cast` is
    /// the cast list by number (from anywhere in the sheet), for cast cells that give numbers only.
    static func scenes(on page: [TextBox], cast: [Int: String] = [:]) -> [DayScene] {
        let headings = page.filter { isHeading($0.text) }.sorted { $0.y < $1.y }
        guard !headings.isEmpty else { return [] }
        let columns = headerColumns(page)
        let sceneColumn = columns.first { $0.name == "scene" }
        let castColumn = columns.first { $0.name == "cast" }
        let stops = page.filter { isStop($0.text) }

        // How tall a scene's cell usually is, to bound the last one on the page.
        var gaps: [Double] = []
        for i in 0..<max(0, headings.count - 1) {
            let gap = headings[i + 1].y - headings[i].y
            gaps.append(gap)
        }
        gaps.sort()
        let typical: Double = gaps.isEmpty ? headings[0].height * 14 : gaps[gaps.count / 2] * 1.5

        var found: [DayScene] = []
        for (i, head) in headings.enumerated() {
            let top = head.y - head.height
            var bottom = head.y + typical
            if i + 1 < headings.count { bottom = min(bottom, headings[i + 1].y - head.height * 0.3) }
            for stop in stops where stop.y > head.maxY && stop.y < bottom { bottom = stop.y }
            // Another table's heading on the left ("ID" over a cast list) ends it too.
            for word in page where word.y > head.maxY && word.y < bottom && word.maxX <= head.x + 0.01 && isColumnWord(word.text) {
                bottom = word.y
            }
            let block = page.filter { $0.midY >= top && $0.midY <= bottom && $0 != head }

            // The scene numbers: left of the set, or under the SCENE header when there is one.
            let numberCells = block.filter { box in
                if let sceneColumn, let column = nearestColumn(box, columns) { return column == sceneColumn.name }
                return box.maxX <= head.x + 0.01
            }.sorted { $0.y < $1.y }
            var numbers: [String] = []
            for cell in numberCells {
                guard let tokens = sceneNumbers(cell.text) else { continue }
                for token in tokens where !numbers.contains(token) { numbers.append(token) }
            }
            guard !numbers.isEmpty else { continue }

            // The characters: "9. ROSALIE" cells, or bare cast numbers under the CAST header.
            var names: [String] = []
            for box in block.sorted(by: { $0.y < $1.y }) where box.x > head.x || castColumn != nil {
                let inCast: Bool
                if let castColumn, let column = nearestColumn(box, columns) { inCast = column == castColumn.name } else { inCast = true }
                guard inCast else { continue }
                for (number, name) in castEntries(box.text) where castColumn != nil || number < 100 {
                    // The cell's own name: a cast list read from loose lines can be wrong.
                    if !names.contains(name) { names.append(name) }
                }
                if castColumn != nil, let bare = numberList(box.text) {
                    for number in bare {
                        if let name = cast[number], !names.contains(name) { names.append(name) }
                    }
                }
            }

            let title = CallSheetParser.clean(head.text)
            for number in numbers {
                found.append(DayScene(scene: number, title: title, characters: names.joined(separator: ", ")))
            }
        }
        return found
    }

    /// Any table with a scene-number column, with or without INT/EXT headings (Reset's reader,
    /// Phil 2026-11-09: "call sheets can differ"). The column is found by its heading ("SC",
    /// "SCENE"); each cell below holding only scene numbers is a scene, named from its row: an
    /// INT/EXT cell if there is one, else the nearest wordy cell to the right (the set).
    static func columnScenes(on page: [TextBox], cast: [Int: String] = [:]) -> [DayScene] {
        let columns = headerColumns(page)
        let castColumn = columns.first { $0.name == "cast" }
        var found: [DayScene] = []
        for header in page where isSceneHeader(header.text) {
            let reach = max(0.02, header.width)
            let left = header.x - reach, right = header.maxX + reach
            var end = 2.0
            for box in page where box.y > header.maxY && isStop(box.text) { end = min(end, box.y) }
            let cells = page.filter { $0.y > header.maxY - 0.002 && $0.y < end && $0.midX > left && $0.midX < right }
                .sorted { $0.y < $1.y }
            for cell in cells {
                // Another table's heading under this column ("ID", "CAST") ends it.
                if isColumnWord(cell.text), cell.y > header.maxY + 0.002 { break }
                guard let numbers = sceneNumbers(cell.text), !numbers.isEmpty else { continue }
                let band = max(cell.height, 0.004) * 1.6
                let row = page.filter { abs($0.midY - cell.midY) < band && $0 != cell }
                let beside = row.filter { box in
                    guard box.x > cell.maxX - 0.002 else { return false }
                    return isHeading(box.text) || isName(box.text)
                }.sorted { $0.x < $1.x }
                let set = beside.first { isHeading($0.text) } ?? beside.first { castEntries($0.text).isEmpty }
                var names: [String] = []
                for box in row {
                    let inCast: Bool
                    if let castColumn, let column = nearestColumn(box, columns) { inCast = column == castColumn.name } else { inCast = false }
                    guard inCast else { continue }
                    for (_, name) in castEntries(box.text) where !names.contains(name) { names.append(name) }
                    for number in numberList(box.text) ?? [] {
                        if let name = cast[number], !names.contains(name) { names.append(name) }
                    }
                }
                let title = CallSheetParser.clean(set?.text ?? "")
                for number in numbers {
                    found.append(DayScene(scene: number, title: title, characters: names.joined(separator: ", ")))
                }
            }
        }
        return found
    }

    /// The cast list laid out as a table: numbers in the first column, characters under a
    /// CHARACTER (or ROLE) header.
    static func castList(on page: [TextBox]) -> [Int: String] {
        var table: [Int: String] = [:]
        let headers = page.filter {
            let word = $0.text.trimmingCharacters(in: .whitespaces).uppercased()
            return word == "CHARACTER" || word == "CHARACTERS" || word == "ROLE" || word == "CHARACTER NAME"
        }
        for header in headers {
            let names = page.filter { $0.y > header.maxY && $0.x >= header.x - 0.03 && $0.x <= header.maxX + 0.01 }
            for box in names {
                let ids = page.filter { $0.sameRow(as: box) && $0.maxX < box.x && Int($0.text.trimmingCharacters(in: .whitespaces)) != nil }
                guard let id = ids.min(by: { $0.x < $1.x }), let number = Int(id.text.trimmingCharacters(in: .whitespaces)),
                    let name = characterName(box.text), table[number] == nil
                else { continue }
                table[number] = name
            }
        }
        return table
    }

    static func isHeading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 6 else { return false }
        return heading.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    /// "95A, 96pt" as ["95A", "96"]; nil when the text is anything else than scene numbers.
    static func sceneNumbers(_ text: String) -> [String]? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "&" || $0 == "/" || $0 == " " || $0 == ";" })
        guard !parts.isEmpty else { return nil }
        var out: [String] = []
        for part in parts {
            let token = String(part)
            let range = NSRange(token.startIndex..., in: token)
            guard let match = sceneToken.firstMatch(in: token, range: range), let core = Range(match.range(at: 1), in: token) else { return nil }
            out.append(String(token[core]))
        }
        return out
    }

    /// "6. TYGO 9. ROSALIE" as [(6, "Tygo"), (9, "Rosalie")].
    static func castEntries(_ text: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in castEntry.matches(in: text, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: text), let nameRange = Range(match.range(at: 2), in: text),
                let number = Int(text[numberRange]), let name = characterName(String(text[nameRange]))
            else { continue }
            out.append((number, name))
        }
        return out
    }

    // MARK: - Pieces

    private struct Column {
        var name: String
        var midX: Double
    }

    /// The header row over the scene strips (SCENE ... CAST ... STUNTS ...), when on this page.
    private static func headerColumns(_ page: [TextBox]) -> [Column] {
        guard let scene = page.first(where: { isSceneHeader($0.text) }) else { return [] }
        var columns = [Column(name: "scene", midX: scene.midX)]
        for box in page where box != scene && box.sameRow(as: scene) {
            let word = box.text.trimmingCharacters(in: .whitespaces).uppercased()
            let name = word.hasPrefix("CAST") ? "cast" : word.lowercased()
            columns.append(Column(name: name, midX: box.midX))
        }
        return columns.count >= 2 ? columns : []
    }

    private static func nearestColumn(_ box: TextBox, _ columns: [Column]) -> String? {
        columns.min { abs($0.midX - box.midX) < abs($1.midX - box.midX) }?.name
    }

    /// A scene column's heading: "SC", "SCENE", "SC #", "SCN", "SCENE NO".
    static func isSceneHeader(_ text: String) -> Bool {
        let upper = text.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: " .:#"))
        let words: Set<String> = ["SC", "SCN", "SCS", "SCENE", "SCENES", "SC NO", "SCENE NO", "SC NUMBER", "SCENE NUMBER", "SC.NO"]
        return words.contains(upper)
    }

    /// A short all-capitals word like a table's column heading: "ID", "CAST", "NO".
    static func isColumnWord(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: CharacterSet(charactersIn: " .:#"))
        return word.count >= 2 && word.count <= 12 && word.allSatisfy { $0.isUppercase || $0 == " " }
    }

    /// Text that names a set: at least three letters, and not a time of day, a page count or "D5".
    private static func isName(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count
        guard letters >= 3 else { return false }
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        let notSets: Set<String> = ["DAY", "NIGHT", "DUSK", "DAWN", "MORNING", "EVENING", "INT", "EXT", "INT.", "EXT."]
        return !notSets.contains(upper)
    }

    /// Where a scene's cell certainly ends.
    private static func isStop(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespaces).uppercased()
        return word == "CAST" || word.hasPrefix("TOTAL") || word.hasPrefix("STRIPS CONTINUE") || word.hasPrefix("END OF DAY")
            || word.hasPrefix("ADVANCE") || word == "CHARACTER"
    }

    private static func numberList(_ text: String) -> [Int]? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "&" })
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            out.append(n)
        }
        return out
    }

    /// A tidy character name, or nil when it is clearly something else.
    private static func characterName(_ raw: String) -> String? {
        var name = raw
        if let open = name.firstIndex(of: "(") { name = String(name[..<open]) }
        name = CallSheetParser.clean(name)
        guard name.count >= 2, name.first?.isLetter == true else { return nil }
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty, !words.contains(where: { notNames.contains($0) }) else { return nil }
        guard name.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "’" || $0 == "-" || $0 == "." }) else { return nil }
        return name == name.uppercased() ? name.capitalized : name
    }
}
