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
                    Text("Match keeps continuity photos for hair, makeup and costume, and checks each look against them before every take. Everything stays on this device; no signal needed.")
                }
                Section("The camera screen") {
                    Text("Match opens straight into the camera, laid out like the Camera app (and like Reset). Nothing is saved until you press the shutter.")
                    Text("• Top: the grid opens all boards. The middle pill shows the scene, character and take; tap it to switch character or start a new one. Guide turns the edge guide on or off. Then switch camera, and ••• for Import from Photos, Compare, outlines and Help.")
                    Text("• Above the shutter: angles (Any, Front, ¾ L, Left, Back, Right, ¾ R, Close, Full). Tap or swipe. Picking an angle shows its reference see-through over the camera. The first photo of each angle becomes its reference.")
                    Text("• Bottom left: the reference thumbnail, with the time it was taken. Tap it for the gallery: swipe like Photos, Use as overlay, Compare, Import from Photos, Save to Photos.")
                    Text("• Bottom right: Next take. Touch and hold to go back or to Prep. Every board in the scene follows it.")
                    Text("• Pinch or drag the overlay to line up a QTake screenshot; double tap resets it.")
                }
                Section("The guide") {
                    Text("With a reference showing, the guide stays at the edges and corners of the screen, so the face and hair stay clear.")
                    Text("• Corners: white corners mark the screen. Yellow corners show where the reference's frame is now. Line the yellow corners up with the white ones.")
                    Text("• One instruction at a time, the biggest first: MOVE (slide the phone), PAN (aim left or right), TILT (aim up or down), ROTATE (twist it level), STEP IN or STEP BACK.")
                    Text("• Actor lock: when the reference has a person in it, the guide and the overlay follow the actor, not the room, wherever they stand. The Guide button reads Actor. For hair and makeup it follows the face; for costume boards, the body. It adds WALK ROUND LEFT or RIGHT, and RAISE or LOWER PHONE, to match the angle on the face. With several people in view, each gets a ring; tap one to follow them. It finds faces only, never who someone is, all on the phone.")
                    Text("• LiDAR (Pro iPhones and iPads): photos keep the distance to the actor, and STEP IN or STEP BACK says how far in centimetres. Turn it off in the ••• menu, LiDAR distance.")
                    Text("• Portrait and landscape both work. A portrait reference checked with the phone on its side (or the other way round) shows whole in the middle of the screen, and the guide lines up with that.")
                    Text("• Hold still once lined up: after half a second the corners turn green, LINED UP shows and the phone taps.")
                    Text("• The slider in the bottom left corner sets how strong the overlay is; the eye hides it.")
                    Text("The guide works from the pictures alone, so it works on any iPhone or iPad. It needs some detail in view. If it says POINT AT THE REFERENCE, it can't find a match yet.")
                }
                Section("Compare") {
                    Text("Side by side, Wipe, Blend, Flicker, or Changes, which lines the photos up and marks differences in red. Pinch to zoom; the expand button hides the controls.")
                }
                Section("Sending to the team") {
                    Text("AirDrop works with no signal: the photos go straight from one phone to another, with nothing uploaded.")
                    Text("• Boards screen, ••• menu, Send to team (AirDrop): pick the boards (the latest scene is ticked), References only or All photos, then AirDrop. In a board, ••• has the same for just that board.")
                    Text("• Your teammate taps Open in Match. New boards and photos are added; anything they already have, and their own notes, stay as they are. Send again later to pass on new photos.")
                    Text("• Team passcode: agree one passcode and enter it once on each phone. Packs are then locked with it, so a pack that lands on the wrong phone can't be opened. It stays on this phone only.")
                    Text("• Photos go without location, phone model or time-taken details. Messages, Mail and copying are taken out of the send sheet. Set AirDrop to Contacts Only (Settings, General, AirDrop) so strangers can't see your phone.")
                }
                Section("Sharing and safety") {
                    Text("In a board, the ••• menu has Share PDF sheet. On the Boards screen, the ••• menu has Back up all boards, which makes one zip of everything; AirDrop it to your computer now and then. Photos are also visible in the Files app under On My iPhone, Match.")
                    Text("When re-installing the app, install over the top. Deleting the app deletes its photos.")
                }
                Section("Testing") {
                    Text("Boards screen, ••• menu, Tester notes: jot down anything odd as it happens, then share the list. Version \(AppInfo.version).")
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
