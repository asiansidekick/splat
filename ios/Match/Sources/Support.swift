import SwiftUI
import UIKit

/// Which build is installed, for bug reports.
enum AppInfo {
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (build \(build))"
    }

    /// For example "iPhone15,2, iOS 18.1".
    static var device: String {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }
}

/// Zips every board (photos, notes, take numbers) into one file to send or keep in Files.
enum Backup {
    static func make() throws -> URL {
        var made: Result<URL, Error> = .failure(CocoaError(.fileNoSuchFile))
        var coordinatorError: NSError?
        // Reading a folder "for uploading" makes the system zip it.
        NSFileCoordinator().coordinate(readingItemAt: BoardStore.root, options: .forUploading, error: &coordinatorError) { zip in
            let stamp = Date.now.formatted(.iso8601.year().month().day()) + " " +
                Date.now.formatted(date: .omitted, time: .shortened).replacingOccurrences(of: ":", with: ".")
            let destination = FileManager.default.temporaryDirectory.appending(path: Slate.fileSafe("Match backup \(stamp).zip"))
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zip, to: destination)
                made = .success(destination)
            } catch {
                made = .failure(error)
            }
        }
        if let coordinatorError { throw coordinatorError }
        return try made.get()
    }
}

// MARK: - Help

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Match keeps continuity photos for hair, makeup, costume, props and set, and checks the set against them before each take. Everything stays on this device; no signal needed.")
                }
                Section("1. Make a board") {
                    Text("Tap + for each character or prop you look after in a scene, for example \"Sarah\" with department Hair in scene 12. Swipe a board left to delete it.")
                }
                Section("2. Take reference photos") {
                    Text("Open the board and tap Camera. Pick an angle (Front, Left, Back…) before shooting. The first photo from each angle becomes its reference, marked ★.")
                    Text("Or tap Import to bring in QTake screenshots or photos from Photos, Files or the clipboard.")
                }
                Section("3. Keep the take number") {
                    Text("Tap Next take as takes go by. Every board in the scene follows it, and new photos are filed under the current take. Prep means before the first take.")
                }
                Section("4. Check before a take") {
                    Text("Tap Camera: the reference shows see-through over the live view. Use the slider for strength and the square for outlines only. Pinch or drag to line up a screenshot; double tap to reset. Take a photo, then tap its thumbnail to compare.")
                }
                Section("5. Compare") {
                    Text("Side by side, Wipe, Blend, Flicker, or Changes, which lines the photos up and marks differences in red. Pinch to zoom; the expand button hides the controls.")
                }
                Section("Sharing and safety") {
                    Text("Board menu (•••): Share PDF sheet. Home menu (•••): Back up all boards makes one zip of everything; AirDrop it to your computer now and then. Photos are also visible in the Files app under On My iPhone, Match.")
                    Text("When re-installing the app, install over the top. Deleting the app deletes its photos.")
                }
                Section("Testing") {
                    Text("Home menu (•••), Tester notes: jot down anything odd as it happens, then share the list. Version \(AppInfo.version).")
                }
            }
            .navigationTitle("How to use Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Tester notes

struct TesterNote: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var text: String
}

/// A running list of bugs and ideas noted while testing, shared as text with the build and device.
struct TesterNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [TesterNote] = TesterNotesView.load()
    @State private var draft = ""
    @FocusState private var typing: Bool

    private static var file: URL { URL.documentsDirectory.appending(path: "tester-notes.json") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("What happened? For example: compare froze after switching photos", text: $draft, axis: .vertical)
                        .lineLimit(2...6)
                        .focused($typing)
                    Button("Add note", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Take a screenshot (side button + volume up) of anything odd; it goes to Photos for sending later.")
                }
                Section("Notes") {
                    if notes.isEmpty {
                        Text("No notes yet.").foregroundStyle(.secondary)
                    }
                    ForEach(notes.reversed()) { note in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(note.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(note.text)
                        }
                    }
                    .onDelete { offsets in
                        let newestFirst = Array(notes.reversed())
                        let ids = Set(offsets.map { newestFirst[$0].id })
                        notes.removeAll { ids.contains($0.id) }
                        save()
                    }
                }
            }
            .navigationTitle("Tester notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ShareLink(item: report) { Label("Share", systemImage: "square.and.arrow.up") }
                        .disabled(notes.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var report: String {
        var lines = ["Match tester notes", "Version \(AppInfo.version) on \(AppInfo.device)", ""]
        for note in notes {
            lines.append("\(note.date.formatted(date: .abbreviated, time: .shortened)): \(note.text)")
        }
        return lines.joined(separator: "\n")
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.append(TesterNote(date: .now, text: text))
        draft = ""
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    private static func load() -> [TesterNote] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([TesterNote].self, from: data)) ?? []
    }
}
