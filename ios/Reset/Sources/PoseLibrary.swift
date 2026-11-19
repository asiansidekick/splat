import SwiftUI

/// Poses kept by name (Phil, 2026-11-19, after Magic Poser): save how a character stands, bring it back on any
/// other character or mannequin.
struct SavedPose: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var pose: MannequinPose
}

@MainActor
final class PoseLibrary: ObservableObject {
    static let shared = PoseLibrary()
    @Published private(set) var items: [SavedPose] = []

    private static var file: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SavedPoses.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let loaded = try? JSONDecoder().decode([SavedPose].self, from: data) { items = loaded }
    }

    /// A name left empty becomes "Pose 3" and so on.
    func save(_ pose: MannequinPose, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items.insert(SavedPose(name: clean.isEmpty ? "Pose \(items.count + 1)" : clean, pose: pose), at: 0)
        write()
    }

    func delete(_ item: SavedPose) {
        items.removeAll { $0.id == item.id }
        write()
    }

    private func write() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.file, options: .atomic) }
    }
}

/// The ready-made poses and the saved ones; tap one to use it.
struct PoseLibrarySheet: View {
    let onPick: (MannequinPose) -> Void
    @ObservedObject private var library = PoseLibrary.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !library.items.isEmpty {
                    Section("Saved") {
                        ForEach(library.items) { item in
                            Button(item.name) { onPick(item.pose); dismiss() }
                                .swipeActions { Button("Delete", role: .destructive) { library.delete(item) } }
                        }
                    }
                }
                Section("Ready-made") {
                    ForEach(MannequinPose.all, id: \.name) { item in
                        Button(item.name) { onPick(item.pose); dismiss() }
                    }
                }
            }
            .navigationTitle("Poses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}
