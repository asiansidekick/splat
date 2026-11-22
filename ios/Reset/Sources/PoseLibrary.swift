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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PoseGroupList { _, pose in onPick(pose); dismiss() }
                .navigationTitle("Poses")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .preferredColorScheme(.dark)
    }
}

/// Phil, 2026-11-22: many more ready-made poses, so they come in groups (menus must not scroll): tap a group, then a
/// pose. Saved poses are a group of their own at the top. Push it inside a NavigationStack.
struct PoseGroupList: View {
    let onPick: (String, MannequinPose) -> Void
    @ObservedObject private var library = PoseLibrary.shared

    var body: some View {
        List {
            if !library.items.isEmpty {
                NavigationLink {
                    SavedPosesPage(onPick: onPick)
                } label: {
                    LabeledContent { Text("\(library.items.count)") } label: { Label("Saved", systemImage: "bookmark") }
                }
            }
            ForEach(MannequinPose.groups, id: \.name) { group in
                NavigationLink {
                    PoseGroupPage(group: group, onPick: onPick)
                } label: {
                    Label(group.name, systemImage: group.symbol)
                }
            }
        }
    }
}

/// One group's poses.
struct PoseGroupPage: View {
    let group: PoseGroup
    let onPick: (String, MannequinPose) -> Void

    var body: some View {
        List {
            ForEach(group.poses, id: \.name) { item in
                Button(item.name) { onPick(item.name, item.pose) }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The poses kept by name; swipe one to delete it.
private struct SavedPosesPage: View {
    let onPick: (String, MannequinPose) -> Void
    @ObservedObject private var library = PoseLibrary.shared

    var body: some View {
        List {
            ForEach(library.items) { item in
                Button(item.name) { onPick(item.name, item.pose) }
                    .swipeActions { Button("Delete", role: .destructive) { library.delete(item) } }
            }
        }
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Ready-made hands for a character with finger bones: pick one for each hand, or both together.
struct HandsSheet: View {
    let onPick: (Int?, HandPreset) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach([("Both hands", Int?.none), ("Left hand", 0), ("Right hand", 1)], id: \.0) { title, side in
                    Section(title) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(HandPreset.allCases, id: \.self) { preset in
                                    Button(preset.rawValue) { onPick(side, preset) }
                                        .buttonStyle(.bordered)
                                        .tint(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}
