import Foundation

/// The characters Match has seen, kept on the phone whatever happens to boards: delete a board, a
/// whole scene, or start a new project, and "Sarah" is still one tap away when making the next.
struct CastMember: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var character: String
    /// Who plays them, if worth noting.
    var actor = ""

    init(character: String, actor: String = "") {
        self.character = character
        self.actor = actor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        character = (try? c.decode(String.self, forKey: .character)) ?? ""
        actor = (try? c.decode(String.self, forKey: .actor)) ?? ""
    }
}

enum CastList {
    static let key = "castList"

    static func decode(_ json: String) -> [CastMember] {
        (try? JSONDecoder().decode([CastMember].self, from: Data(json.utf8)))?.filter { !$0.character.isEmpty } ?? []
    }

    static func encode(_ cast: [CastMember]) -> String {
        (try? JSONEncoder().encode(cast)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func load() -> [CastMember] { decode(UserDefaults.standard.string(forKey: key) ?? "[]") }

    static func save(_ cast: [CastMember]) { UserDefaults.standard.set(encode(cast), forKey: key) }

    /// Adds a character not yet listed (same name in any case counts as listed).
    static func merged(_ cast: [CastMember], adding names: [String]) -> [CastMember] {
        var out = cast
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !out.contains(where: { $0.character.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            out.append(CastMember(character: name))
        }
        return out
    }

    static func remember(_ name: String) {
        let before = load()
        let after = merged(before, adding: [name])
        if after != before { save(after) }
    }

    /// Characters from boards made before the list existed.
    static func seed(from boards: [Board]) {
        let before = load()
        let after = merged(before, adding: boards.sorted { $0.created < $1.created }.map(\.subject))
        if after != before { save(after) }
    }
}
