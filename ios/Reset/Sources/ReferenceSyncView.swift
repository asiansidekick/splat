import Security
import SwiftUI
import UIKit

/// The team's shared passcode, kept in this phone's keychain (never synced or backed up off it).
enum TeamPasscode {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "com.asiansidekick.reset.team",
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

/// Keeps references in step with teammates' phones close by, while this screen is open on each
/// of them. Wi-Fi and Bluetooth straight between phones: works with no signal, nothing uploaded.
struct ReferenceSyncView: View {
    /// Posted when a teammate's reference or edit has been saved here.
    static let changed = Notification.Name("ReferencesSynced")

    @Environment(\.dismiss) private var dismiss
    @AppStorage("teamName") private var name = ""
    @AppStorage("syncWithDepth") private var withDepth = true
    @State private var passcode = TeamPasscode.load() ?? ""
    @State private var sync: NearbySync?
    @State private var library: ReferenceSyncLibrary?

    var body: some View {
        NavigationStack {
            Form {
                if let sync {
                    ReferenceSyncStatus(sync: sync)
                } else {
                    Section {
                        SecureField("Team passcode (4 or more characters)", text: $passcode)
                            .textContentType(.oneTimeCode)
                        TextField("Your name, so teammates see who's syncing", text: $name)
                            .textContentType(.givenName)
                        Toggle("Include LiDAR depth and 3D models", isOn: $withDepth)
                    } footer: {
                        Text("Open Sync on each phone with the same team passcode. They find each other over Wi-Fi and Bluetooth, with no signal needed, and swap references, takes and notes both ways. Turn off LiDAR and 3D models for a much quicker sync of photos and room maps. Nothing is uploaded, and phones with another passcode can't join.")
                    }
                    Section {
                        Button("Start syncing") { start() }
                            .bold()
                            .disabled(passcode.count < 4)
                    }
                }
            }
            .navigationTitle("Sync with nearby phones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear {
            // The usual case: the passcode is set, so start straight away.
            if passcode.count >= 4 { start() }
        }
        .onDisappear {
            if let sync {
                Diagnostics.log("Sync stopped: received \(sync.progress.received), refused \(sync.progress.refused)")
            }
            sync?.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @MainActor
    private func start() {
        TeamPasscode.save(passcode)
        let library = ReferenceSyncLibrary(
            root: ReferenceStore.root, withDepth: withDepth,
            references: { ReferenceStore.all() },
            save: { reference in
                try? ReferenceStore.save(reference)
                NotificationCenter.default.post(name: ReferenceSyncView.changed, object: nil)
            })
        let sync = NearbySync(service: "reset-sync", name: name.trimmingCharacters(in: .whitespaces), passcode: passcode, library: library)
        self.library = library
        self.sync = sync
        sync.start()
        Diagnostics.log("Sync started (LiDAR and models \(withDepth ? "on" : "off"))")
        // Syncing stops if the screen locks, so keep it awake while this is open.
        UIApplication.shared.isIdleTimerDisabled = true
    }
}

private struct ReferenceSyncStatus: View {
    @ObservedObject var sync: NearbySync

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(sync.state == .upToDate ? Color.green : Color.accentColor)
                    .symbolEffect(.pulse, isActive: sync.state == .looking || sync.state == .syncing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Keep this screen open on every phone until it says Up to date. New references, takes and snapshots are added both ways; where two phones edited the same thing, the newest edit wins. Deleting a reference only deletes it on this phone.")
        }
        if !sync.progress.teammates.isEmpty {
            Section("Connected") {
                ForEach(sync.progress.teammates, id: \.self) { Label($0, systemImage: "iphone") }
            }
        }
        if sync.progress.received > 0 || sync.progress.refused > 0 {
            Section {
                Text("\(sync.progress.received) file\(sync.progress.received == 1 ? "" : "s") received"
                    + (sync.progress.refused > 0 ? ", \(sync.progress.refused) refused (not a file Reset can use)" : ""))
            }
        }
        if sync.strangerNearby {
            Section {
                Label("A phone nearby is using a different team passcode, so it can't sync with this one.", systemImage: "lock")
                    .font(.footnote)
            }
        }
    }

    private var symbol: String {
        switch sync.state {
        case .starting, .looking: return "antenna.radiowaves.left.and.right"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle.fill"
        }
    }

    private var headline: String {
        switch sync.state {
        case .starting: return "Starting…"
        case .looking: return "Looking for teammates…"
        case .syncing: return "Syncing…"
        case .upToDate: return "Up to date"
        }
    }

    private var detail: String {
        switch sync.state {
        case .starting, .looking: return "Open Sync on their phone too, with the same team passcode."
        case .syncing:
            return sync.progress.waiting > 0 ? "\(sync.progress.waiting) file\(sync.progress.waiting == 1 ? "" : "s") to come" : "Sending to teammates"
        case .upToDate: return "With " + sync.progress.teammates.joined(separator: ", ")
        }
    }
}
