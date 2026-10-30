import Foundation

/// Which department a board belongs to.
enum Department: String, Codable, CaseIterable, Identifiable {
    case hair, makeup, costume, props, set, other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .hair: "Hair"
        case .makeup: "Makeup"
        case .costume: "Costume"
        case .props: "Props"
        case .set: "Set"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .hair: "scissors"
        case .makeup: "paintbrush.pointed"
        case .costume: "tshirt"
        case .props: "cup.and.saucer"
        case .set: "sofa"
        case .other: "square.grid.2x2"
        }
    }

    /// The departments Match is made for. Props and Set stay readable on old boards and
    /// are only offered for a board that already uses them.
    static let main: [Department] = [.hair, .makeup, .costume, .other]

    static func picked(_ current: Department) -> [Department] {
        main.contains(current) ? main : main + [current]
    }
}

/// One continuity photo, taken in the app or imported (for example a QTake screenshot).
struct Shot: Codable, Identifiable, Equatable, Hashable {
    enum Source: String, Codable { case camera, imported }

    var id = UUID()
    var taken: Date
    var take: Int  // 0 is prep, before the first take
    var angle = ""
    var note = ""
    var isReference = false
    var source: Source = .camera

    init(taken: Date, take: Int, angle: String = "", source: Source = .camera) {
        self.taken = taken
        self.take = take
        self.angle = angle
        self.source = source
    }

    /// Missing fields fall back to defaults, so boards saved by an older build still open after an update.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        taken = (try? c.decode(Date.self, forKey: .taken)) ?? .now
        take = (try? c.decode(Int.self, forKey: .take)) ?? 0
        angle = (try? c.decode(String.self, forKey: .angle)) ?? ""
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        isReference = (try? c.decode(Bool.self, forKey: .isReference)) ?? false
        source = (try? c.decode(Source.self, forKey: .source)) ?? .camera
    }

    var file: String { "\(id.uuidString).jpg" }
    var thumbnailFile: String { "\(id.uuidString)-thumb.jpg" }
    /// The LiDAR depth when the photo was taken, on phones and iPads with LiDAR.
    var depthFile: String { "\(id.uuidString)-depth.bin" }

    var label: String {
        [Slate.takeName(take), angle.isEmpty ? nil : angle, taken.formatted(date: .omitted, time: .shortened)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Everything for one subject in one scene, for example Sarah's hair in scene 12, or the desk props.
struct Board: Codable, Identifiable, Equatable {
    var id = UUID()
    var scene: String
    var subject: String
    var department: Department
    /// The costume change or look, for example "Change 2" or "Look B".
    var look = ""
    var notes = ""
    var created: Date
    var shots: [Shot] = []

    init(scene: String, subject: String, department: Department, created: Date) {
        self.scene = scene
        self.subject = subject
        self.department = department
        self.created = created
    }

    /// Missing or unknown fields fall back to defaults, so an update never hides saved boards.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        scene = (try? c.decode(String.self, forKey: .scene)) ?? ""
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        department = (try? c.decode(Department.self, forKey: .department)) ?? .other
        look = (try? c.decode(String.self, forKey: .look)) ?? ""
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
        created = (try? c.decode(Date.self, forKey: .created)) ?? .now
        // A damaged photo entry is skipped rather than losing the whole board.
        shots = ((try? c.decode([Failable<Shot>].self, forKey: .shots)) ?? []).compactMap(\.value)
    }

    var title: String {
        [subject, look, department.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// Short enough for the camera's top bar, for example "Sarah Hair".
    var shortTitle: String { subject.isEmpty ? department.name : "\(subject) \(department.name)" }
    var references: [Shot] { shots.filter(\.isReference).sorted { $0.taken < $1.taken } }
    var takes: [Int] { Set(shots.map(\.take)).sorted(by: >) }
    var newest: Shot? { shots.max { $0.taken < $1.taken } }
    var cover: Shot? { references.first ?? newest }

    func shots(in take: Int) -> [Shot] {
        shots.filter { $0.take == take }.sorted { $0.taken < $1.taken }
    }

    /// What to compare a photo against: the reference from the same angle, else any reference,
    /// else the first photo on the board.
    func reference(for shot: Shot) -> Shot? {
        let others = shots.filter { $0.id != shot.id }
        let references = others.filter(\.isReference).sorted { $0.taken < $1.taken }
        return references.first { $0.angle == shot.angle } ?? references.first ?? others.min { $0.taken < $1.taken }
    }

    func matches(_ search: String) -> Bool {
        guard !search.isEmpty else { return true }
        let text = ([subject, look, notes, department.name, "scene \(scene)"] + shots.map(\.note)).joined(separator: " ")
        return text.localizedCaseInsensitiveContains(search)
    }
}

/// Decodes an element if it can, so one bad entry does not fail a whole list.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Scene and take numbering.
enum Slate {
    /// Angles round a person, in the order crew walk round them.
    static let angles = ["Front", "3/4 Left", "Left", "Back", "Right", "3/4 Right", "Close-up", "Full length"]

    /// The short label under the camera, for example "¾ L". Older angles show in capitals.
    static func angleLabel(_ angle: String) -> String {
        switch angle {
        case "": "ANY"
        case "3/4 Left": "¾ L"
        case "3/4 Right": "¾ R"
        case "Close-up": "CLOSE"
        case "Full length": "FULL"
        default: angle.uppercased()
        }
    }

    /// Text safe to use in a file name.
    static func fileSafe(_ text: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return text.components(separatedBy: bad).joined(separator: "-")
    }

    static func takeName(_ take: Int) -> String { take == 0 ? "Prep" : "Take \(take)" }
    static func shortTake(_ take: Int) -> String { take == 0 ? "Prep" : "Tk \(take)" }

    /// Orders scenes the way they read: 2 before 10, 12 before 12A.
    static func sortedScenes(_ scenes: some Sequence<String>) -> [String] {
        Set(scenes).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
