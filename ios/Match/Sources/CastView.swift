import SwiftUI

/// Edit the cast list: add, rename, note the actor, swipe to remove. Removing here never touches boards.
struct CastListView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CastList.key) private var json = "[]"
    /// Tapping a name picks it (when opened from a board); nil when just managing the list.
    var onPick: ((String) -> Void)?
    @State private var cast: [CastMember] = []
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a character", text: $newName)
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section(cast.isEmpty ? "No characters yet" : "Characters") {
                    ForEach($cast) { $member in
                        HStack {
                            if let onPick {
                                Button {
                                    onPick(member.character)
                                    dismiss()
                                } label: { Image(systemName: "arrow.up.circle").font(.title3) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Use \(member.character)")
                            }
                            TextField("Character", text: $member.character)
                            TextField("Actor", text: $member.actor)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { cast.remove(atOffsets: $0) }
                    .onMove { cast.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .navigationTitle("Cast list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) { EditButton() }
            }
            .onAppear { cast = CastList.decode(json) }
            .onChange(of: cast) { _, new in json = CastList.encode(new) }
        }
    }

    private func add() {
        cast = CastList.merged(cast, adding: [newName])
        newName = ""
    }
}
