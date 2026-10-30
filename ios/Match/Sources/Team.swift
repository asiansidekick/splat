import Security
import SwiftUI
import UIKit

// MARK: - Team passcode

/// The team's shared passcode, kept in this phone's keychain (never synced or backed up off it).
/// Set once; every pack sent is then locked with it, and packs from the team open without asking.
enum TeamPasscode {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.asiansidekick.match.team",
        kSecAttrAccount: "passcode",
    ]

    static func load() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ passcode: String) {
        SecItemDelete(query as CFDictionary)
        guard !passcode.isEmpty else { return }
        var add = query
        add[kSecValueData] = Data(passcode.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Sending

/// The share sheet for team packs, with the online destinations (Messages, Mail, copy, print)
/// taken out, so cast photos go by AirDrop or to Files. The pack is deleted from the phone when
/// the sheet closes.
struct AirDropSheet: UIViewControllerRepresentable {
    let url: URL
    var onDone: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.excludedActivityTypes = [
            .message, .mail, .print, .copyToPasteboard, .assignToContact, .saveToCameraRoll, .addToReadingList,
            .postToFacebook, .postToTwitter, .postToWeibo, .postToTencentWeibo, .postToFlickr, .postToVimeo,
            .openInIBooks, .markupAsPDF, .sharePlay, .collaborationInviteWithLink, .collaborationCopyLink,
        ]
        controller.completionWithItemsHandler = { _, completed, _, _ in
            try? FileManager.default.removeItem(at: url)
            onDone(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Which boards to start the send screen with.
struct TeamPick: Identifiable {
    let id = UUID()
    let boards: Set<UUID>
}

/// Pick boards and send them to the team by AirDrop. No internet: the pack goes straight from
/// this phone to theirs.
struct SendToTeamView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID>
    @AppStorage("teamContent") private var contentRaw = TeamPack.Content.references.rawValue
    @AppStorage("teamName") private var name = ""
    @AppStorage("teamLock") private var lock = true
    @State private var passcode = TeamPasscode.load() ?? ""
    @State private var making = false
    @State private var sending: SharedFile?
    @State private var problem: String?

    init(chosen: Set<UUID>) {
        _chosen = State(initialValue: chosen)
    }

    private var content: TeamPack.Content { TeamPack.Content(rawValue: contentRaw) ?? .references }
    private var picked: [Board] { store.boards.filter { chosen.contains($0.id) } }
    private var photoCount: Int {
        picked.reduce(0) { $0 + (content == .references ? $1.references.count : $1.shots.count) }
    }
    private var passcodeOK: Bool { !lock || passcode.count >= 4 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Send", selection: $contentRaw) {
                        ForEach(TeamPack.Content.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Your name, so they know who sent it", text: $name)
                        .textContentType(.givenName)
                } footer: {
                    Text("\(picked.count) board\(picked.count == 1 ? "" : "s"), \(photoCount) photo\(photoCount == 1 ? "" : "s"). Works with no signal; nothing is uploaded.")
                }
                Section {
                    Toggle("Lock with team passcode", isOn: $lock)
                    if lock {
                        SecureField("Team passcode (4 or more characters)", text: $passcode)
                            .textContentType(.oneTimeCode)
                    }
                } footer: {
                    Text(lock
                        ? "Agree one passcode with your team and enter it once on each phone. Locked packs can't be opened by anyone else, even if they land on the wrong phone. Photos go without location or camera details."
                        : "Anyone who receives this pack can open it. Photos go without location or camera details.")
                }
                ForEach(store.scenes, id: \.self) { scene in
                    let boards = store.boards.filter { $0.scene == scene }
                        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    Section {
                        ForEach(boards) { board in
                            Button {
                                if chosen.contains(board.id) { chosen.remove(board.id) } else { chosen.insert(board.id) }
                            } label: {
                                HStack {
                                    Image(systemName: chosen.contains(board.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(board.id) ? Color.accentColor : .secondary)
                                    Text(board.title.isEmpty ? "Untitled" : board.title).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(content == .references ? board.references.count : board.shots.count)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(scene.isEmpty ? "No scene" : "Scene \(scene)")
                            Spacer()
                            let ids = Set(boards.map(\.id))
                            Button(ids.isSubset(of: chosen) ? "None" : "All") {
                                if ids.isSubset(of: chosen) { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                            }
                            .font(.caption.bold())
                        }
                    }
                }
                Section {
                    Text("On the AirDrop sheet, pick your teammate's phone. They tap Open in Match. Setting AirDrop to Contacts Only (Settings, General, AirDrop) stops strangers seeing your phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Send to team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if making {
                        ProgressView()
                    } else {
                        Button("AirDrop") { make() }
                            .bold()
                            .disabled(picked.isEmpty || !passcodeOK)
                    }
                }
            }
            .sheet(item: $sending) { file in
                AirDropSheet(url: file.url) { sent in
                    sending = nil
                    if sent { dismiss() }
                }
            }
            .alert("Send to team", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

    private func make() {
        let boards = picked
        let content = content
        let from = name.trimmingCharacters(in: .whitespaces)
        let code = lock ? passcode : nil
        if lock { TeamPasscode.save(passcode) }
        let scenes = Slate.sortedScenes(boards.map(\.scene))
        // The name shows on the receiving phone before it's opened, so it names the scene only.
        let title = scenes.count == 1 ? "Match scene \(scenes[0])" : "Match team pack"
        let url = FileManager.default.temporaryDirectory.appending(path: Slate.fileSafe(title) + "." + TeamPack.fileExtension)
        making = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    let data = try TeamPack.make(boards: boards, content: content, from: from, passcode: code, root: BoardStore.root)
                    try? FileManager.default.removeItem(at: url)
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    return url
                }
            }.value
            making = false
            switch result {
            case .success(let url): sending = SharedFile(url: url)
            case .failure(let error): problem = "Could not make the pack: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Receiving

/// Opens a pack AirDropped (or opened from Files) into Match: asks for the team passcode if it
/// doesn't already know it, adds what's new, says what was added, and deletes the received file.
enum TeamReceiver {
    @MainActor
    static func receive(_ url: URL, store: BoardStore) {
        guard url.pathExtension.lowercased() == TeamPack.fileExtension else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let data else {
            show("Couldn't read the pack", "Try sending it again.")
            return
        }
        attempt(data, passcode: TeamPasscode.load(), typed: false, url: url, store: store)
    }

    @MainActor
    private static func attempt(_ data: Data, passcode: String?, typed: Bool, url: URL, store: BoardStore) {
        let locked = TeamPack.isLocked(data)
        if locked && (passcode ?? "").isEmpty {
            ask(nil, data: data, url: url, store: store)
            return
        }
        let existing = store.boards
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(TeamPack.Opened, [Board], TeamPack.Report), Error> in
                Result {
                    let opened = try TeamPack.open(data, passcode: locked ? passcode : nil)
                    let (boards, report) = try TeamPack.install(opened, into: BoardStore.root, existing: existing)
                    return (opened, boards, report)
                }
            }.value
            switch result {
            case .success(let (opened, boards, report)):
                boards.forEach { store.save($0) }
                if typed, let passcode { TeamPasscode.save(passcode) }
                removeIfReceived(url)
                let from = opened.manifest.from.isEmpty ? "a teammate" : opened.manifest.from
                let names = boards.map { "Sc \($0.scene) \($0.title)" }.joined(separator: "\n")
                show("From \(from)", report.summary + (names.isEmpty ? "" : "\n\n" + names))
            case .failure(let error as TeamPack.PackError) where error == .wrongPasscode || error == .needsPasscode:
                ask(typed ? "That passcode didn't open it." : nil, data: data, url: url, store: store)
            case .failure(let error):
                removeIfReceived(url)
                show("Couldn't open the pack", error.localizedDescription)
            }
        }
    }

    @MainActor
    private static func ask(_ problem: String?, data: Data, url: URL, store: BoardStore) {
        let alert = UIAlertController(
            title: "Locked team pack",
            message: (problem.map { $0 + " " } ?? "") + "Enter the team passcode. Match remembers it for next time.",
            preferredStyle: .alert)
        alert.addTextField {
            $0.isSecureTextEntry = true
            $0.placeholder = "Team passcode"
            $0.textContentType = .oneTimeCode
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in removeIfReceived(url) })
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak alert] _ in
            let typed = alert?.textFields?.first?.text ?? ""
            Task { @MainActor in attempt(data, passcode: typed, typed: true, url: url, store: store) }
        })
        present(alert)
    }

    @MainActor
    private static func show(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    /// AirDrop leaves its copy in Documents/Inbox, visible in Files; it isn't needed once read.
    private static func removeIfReceived(_ url: URL) {
        let inbox = URL.documentsDirectory.appending(path: "Inbox").standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(inbox) || url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// On top of whatever is showing (camera, boards, a photo), so it's never lost behind a sheet.
    @MainActor
    private static func present(_ controller: UIViewController) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(controller, animated: true)
    }
}
