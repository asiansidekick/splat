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
                    Text("• Top: the pill at the left says the scene and shot, then the character and take, in full; tap it to switch character or start a new one. Guide turns the edge guide on or off. Under the row, Next take (mint) moves on to the next take; touch and hold it to go back or to Prep. The small grid on the reference thumbnail (bottom left) opens all boards. Then the light, switch camera, and ••• for Import from Photos, Compare, outlines and Help.")
                    Text("• Take photos from whatever angles matter at the moment; there is no list. Prep photos (take 0), or the first photo on a board, become references, and you can star any photo as one. With two or more references, a row of small thumbnails sits above the shutter: tap one to line up with it. Each photo remembers the reference it was checked against, and Compare uses it.")
                    Text("• Bottom left: the reference thumbnail, with the time it was taken. Tap it for the gallery: swipe like Photos, Use as overlay, Compare, Draw & write (draw on the photo with a finger or Pencil, and add notes you can drag; the photo itself is never changed), Import from Photos, Save to Photos (with the drawing on it).")
                    Text("• Scene, Shot and Take, as QTAKE and Reset name them: a board has a Scene, an optional Shot letter (the A in Sc 12 · Shot A · Tk 3, set when you edit the board and carried on to new boards like the scene) and the Take counter. Each photo is a Reference, or a later photo you compare with it.")
                    Text("• Left-handed (••• menu): with the phone on its side the controls go down the left edge, and upright the thumbnail and pause swap sides.")
                    Text("• Every board in the scene follows Next take.")
                    Text("• Pinch or drag the overlay to line up a QTake screenshot; double tap resets it.")
                    Text("• Pause (the button beside the shutter) freezes the picture with the reference over it, so you can compare at leisure. It opens as a wipe, like Reset: the reference is left of a line, so drag anywhere to move the line, or tap to jump it to the other end. The button beside the slider switches to a fade (swipe left for THEN, right for NOW). A volume button (or Camera Control) pauses and plays too. Press play, or take a photo, to go live again. The strength you had before comes back.")
                    Text("• Then / Now slider (bottom left, with a reference showing): all the way left is the reference at full strength, all the way right is the live camera alone.")
                    Text("• Lenses (the field-of-view icon with the zoom, top right; tap it to open the choices): .5 ultra wide, 1 main, and the telephoto or a 2 crop where the phone has them. Picking a reference shot on another lens switches to that lens. LiDAR measures through the main lens only, so distance and the change colours pause on any other lens.")
                    Text("• Light: tap the torch to turn the light on or off. A dial shows under the top bar: scroll it sideways to set the brightness (left brighter, right dimmer), or drag sideways on the torch itself. Touch and hold the torch to show the dial again. On the front camera the screen glows round the edges like a ring light and goes to full brightness, then back when the light is off.")
                }
                Section("Characters and changes") {
                    Text("• Cast list: the pick-a-character button beside Character in a board lists everyone you have used before, and Edit cast list adds, renames, reorders and notes the actor. It stays on this phone even if boards are deleted.")
                    Text("• Show changes (••• menu, LiDAR phones): once the guide says lined up, red marks where something is now nearer than in the reference photo and blue where it has gone or moved away. Needs a reference taken with LiDAR; small shifts are ignored.")
                }
                Section("The guide") {
                    Text("• Pitch and roll: each photo remembers how the phone was held, from its motion sensors, so it works anywhere with no room map. Two level lines sit at the screen's sides: white is how the reference was held, yellow is the phone now. Twist the phone to level the yellow line, aim it up or down to slide it onto the white; it turns green when they meet. Photos taken before this update, and imported ones, use the picture's own guess instead.")
                    Text("• The guide uses pictures, not words, so your eyes stay on the image: everything sits at the edges and corners of the screen. A phone sliding along a straight arrow means move the phone (sideways, up or down) without turning it; a phone tipping on a curved arrow means stay where you are and aim it (pan or tilt); arrows closing in or opening out in the top left mean step in or back, a twisting arrow in the top right means level the phone, and a tick means lined up.")
                    Text("With a reference showing, the guide stays at the edges and corners of the screen, so the face and hair stay clear.")
                    Text("• Corners: white corners mark the screen. Yellow corners show where the reference's frame is now. Line the yellow corners up with the white ones.")
                    Text("• One instruction at a time, the biggest first: MOVE (slide the phone), PAN (aim left or right), TILT (aim up or down), ROTATE (twist it level), STEP IN or STEP BACK.")
                    Text("• Actor lock: when the reference has a person in it, the guide and the overlay follow the actor, not the room, wherever they stand. The Guide button reads Actor. For hair and makeup it follows the face; for costume boards, the body. It adds WALK ROUND LEFT or RIGHT, and RAISE or LOWER PHONE, to match the angle on the face. With several people in view, each gets a ring; tap one to follow them. It finds faces only, never who someone is, all on the phone.")
                    Text("• Front camera: works like the back one. The guide, actor lock and overlay all work, and on phones with Face ID the front camera measures distance too, so BRING PHONE CLOSER or HOLD PHONE FURTHER (the front camera's words for STEP IN and STEP BACK) gives centimetres. The screen shows a mirror, as the Camera app does; photos are saved the right way round.")
                    Text("• Imported photos (QTake screenshots, another camera): black bars are trimmed, and the first time one is shown Match sizes and places it on the live view by itself. It uses the actor's eyes or shoulders, or else the whole picture. Point at the same view until it says it's done. Double tap the overlay to do it again.")
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
                    Text("• Photos go without location, phone model or time-taken details. The AirDrop sheet leaves out Messages and Mail. Set AirDrop to Contacts Only (Settings, General, AirDrop) so strangers can't see your phone.")
                    Text("• Sync with nearby phones (Boards screen, •••): open it on each phone with the same team passcode. Phones find each other over Wi-Fi and Bluetooth, with no signal needed, and swap new boards and photos both ways, passing them on round the team. Keep the screen open until it says Up to date. Phones with another passcode can't join, and nothing is deleted or overwritten.")
                    Text("• No AirDrop? Send to team also has Send by Messages or Mail (the pack stays locked on the way and photos are made smaller) and PDF for someone without Match. Both go over the internet, and a PDF can't be locked, so Match checks first.")
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
