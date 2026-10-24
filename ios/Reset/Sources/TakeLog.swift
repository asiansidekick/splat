import SwiftUI

/// One take shot on a setup, with the script supervisor style notes that go with it.
struct Take: Codable, Identifiable, Equatable {
    var id = UUID()
    var number: Int
    var logged: Date
    var note = ""
    var circled = false  // a good take, circled on the report
    var resetChecked = false  // the set matched the reference before this take
}

/// Automatic scene, setup and take numbering.
enum Slate {
    /// Setup letters as slated: A, B, C… skipping I and O, which read as 1 and 0.
    static let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ".map(String.init)

    /// The scene of the most recent reference, so a new setup carries on in the same scene.
    static func currentScene(in references: [Reference]) -> String {
        references.max { $0.created < $1.created }?.scene ?? "1"
    }

    /// The first setup letter not yet used in this scene.
    static func nextSetup(scene: String, in references: [Reference]) -> String {
        let used = Set(references.filter { $0.scene == scene }.map(\.setup))
        return letters.first { !used.contains($0) } ?? ""
    }

    /// Orders scenes the way they read: 2 before 10, 12 before 12A.
    static func sortedScenes(_ references: [Reference]) -> [String] {
        Set(references.map(\.scene)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension Reference {
    /// A plain text take report, to share by AirDrop, Messages or Mail once there is signal.
    var takeReport: String {
        var lines = [title, created.formatted(date: .complete, time: .omitted), ""]
        for take in takes.sorted(by: { $0.number < $1.number }) {
            var line = "Take \(take.number)\(take.circled ? " (circled)" : "") · \(take.logged.formatted(date: .omitted, time: .shortened))"
            if take.resetChecked { line += " · reset checked" }
            lines.append(line)
            if !take.note.isEmpty { lines.append("    \(take.note)") }
        }
        if takes.isEmpty { lines.append("No takes logged.") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Views

/// A take number, drawn in a circle when the take is circled.
struct TakeNumber: View {
    let take: Take

    var body: some View {
        Text("\(take.number)")
            .font(.headline.monospacedDigit())
            .frame(minWidth: 32, minHeight: 32)
            .overlay {
                if take.circled { Circle().stroke(lineWidth: 2) }
            }
            .accessibilityLabel("Take \(take.number)\(take.circled ? ", circled" : "")")
    }
}

struct TakeRow: View {
    let take: Take

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TakeNumber(take: take)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(take.logged.formatted(date: .omitted, time: .shortened))
                    if take.resetChecked {
                        Label("Reset checked", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
                .font(.subheadline)
                if !take.note.isEmpty {
                    Text(take.note).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Logs a new take or edits one already logged.
struct TakeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var take: Take
    let slate: String
    let onSave: (Take) -> Void

    init(take: Take, slate: String, onSave: @escaping (Take) -> Void) {
        _take = State(initialValue: take)
        self.slate = slate
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper("Take \(take.number)", value: $take.number, in: 1...999)
                Toggle("Circled (good take)", isOn: $take.circled)
                Toggle("Set matched the reference", isOn: $take.resetChecked)
                Section("Notes") {
                    TextField("For example: cup handle turned left, chair 10 cm closer", text: $take.note, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(slate.isEmpty ? "Take" : "Scene \(slate)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(take)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Edits a reference's scene, setup letter and description.
struct SlateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reference: Reference
    let onSave: (Reference) -> Void

    init(reference: Reference, onSave: @escaping (Reference) -> Void) {
        _reference = State(initialValue: reference)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                SlateFields(scene: $reference.scene, setup: $reference.setup, name: $reference.name)
            }
            .navigationTitle("Edit slate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(reference)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Scene, setup and description fields, shared by recording and editing.
struct SlateFields: View {
    @Binding var scene: String
    @Binding var setup: String
    @Binding var name: String

    var body: some View {
        LabeledContent("Scene") {
            TextField("12", text: $scene)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Setup") {
            TextField("A", text: $setup)
                .textInputAutocapitalization(.characters)
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Description") {
            TextField("Optional, for example desk", text: $name)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Every take logged against one setup, newest first. Tap a take to edit it, swipe to delete.
struct TakeLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var reference: Reference
    @State private var editing: Take?
    @State private var editingSlate = false
    @State private var sharing: SharedFile?
    @State private var shareError: String?

    private var sortedTakes: [Take] {
        reference.takes.sorted { $0.number > $1.number }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        editingSlate = true
                    } label: {
                        LabeledContent(reference.title.isEmpty ? "No slate" : reference.title, value: "Edit")
                    }
                }
                Section("Takes") {
                    if reference.takes.isEmpty {
                        Text("No takes yet. Tap Log take on the reset screen after each take.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sortedTakes) { take in
                        Button {
                            editing = take
                        } label: {
                            TakeRow(take: take)
                        }
                        .tint(.primary)
                    }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { sortedTakes[$0].id })
                        reference.takes.removeAll { ids.contains($0.id) }
                        save()
                    }
                }
            }
            .navigationTitle("Take log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Button("PDF with reference photos") { sharePDF() }
                        ShareLink("Text only", item: reference.takeReport)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { take in
                TakeEditor(take: take, slate: reference.slate) { updated in
                    if let index = reference.takes.firstIndex(where: { $0.id == updated.id }) {
                        reference.takes[index] = updated
                        save()
                    }
                }
            }
            .sheet(item: $sharing) { file in
                ShareSheet(items: [file.url])
            }
            .alert("Could not make the PDF", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(shareError ?? "")
            }
            .sheet(isPresented: $editingSlate) {
                SlateEditor(reference: reference) { updated in
                    reference = updated
                    save()
                }
            }
        }
    }

    private func save() {
        try? ReferenceStore.save(reference)
    }

    private func sharePDF() {
        do {
            sharing = SharedFile(url: try ReportPDF.make(for: reference))
        } catch {
            shareError = error.localizedDescription
        }
    }
}
