import Foundation

// Shared by Match and Reset (copy this file unchanged into the other app). It knows nothing
// about boards or references: each app describes its things as SyncItems and merges them itself.

/// One thing kept in step across phones: a Match board, a Reset reference. Its files are kept
/// in one folder each and never change once made (new photos get new names), so syncing is
/// fetching the files a phone hasn't got, then letting the app merge the record.
struct SyncItem: Codable, Equatable {
    /// The item's folder name (a UUID string).
    var id: String
    /// The app's own description (board.json, reference.json), merged by the app.
    var record: Data
    var files: [SyncFile]
}

struct SyncFile: Codable, Equatable, Hashable {
    var name: String
    var size: Int64
}

/// What an app gives the sync. Called on the main thread.
@MainActor
protocol SyncLibrary: AnyObject {
    /// Everything this phone offers the team right now.
    func syncItems() -> [SyncItem]
    func hasFile(itemID: String, name: String) -> Bool
    /// Whether to fetch this file from a teammate (Reset might skip LiDAR depth or models).
    func wants(itemID: String, file: SyncFile) -> Bool
    /// A file this phone has, to send.
    func fileURL(itemID: String, name: String) -> URL?
    /// A file arrived (already unlocked, in a temporary place). Check it and keep it in the
    /// item's folder; false refuses it (not a picture, a name the app doesn't use).
    func keep(_ url: URL, itemID: String, name: String) -> Bool
    /// A teammate's record, once the files it lists that this phone wanted are here (some may
    /// have failed: merge what's present). True if anything here changed.
    func merge(itemID: String, record: Data) -> Bool
}

/// The messages between phones, sealed with the team key before they go.
struct SyncMessage: Codable {
    enum Kind: String, Codable { case hello, inventory, want }
    var kind: Kind
    var version = 1
    var name: String?
    var items: [SyncItem]?
    var wants: [SyncWant]?
}

struct SyncWant: Codable, Equatable {
    var itemID: String
    var names: [String]
}

/// The sync between this phone and its nearby teammates, without the radio: the transport
/// (NearbySync, or a test) passes in what arrives and sends what this asks it to.
/// 1. On connecting, each phone sends hello and its inventory (every item and its files).
/// 2. Each asks for the files it hasn't got, from one teammate at a time.
/// 3. When an item's files are in, the app merges the teammate's record; if that changed
///    anything, the new inventory goes to everyone, so changes spread round the team.
/// Anything not sealed with the team key is refused, so only teammates can ask for files.
@MainActor
final class SyncEngine {
    struct Progress: Equatable {
        var teammates: [String] = []
        /// Files asked for and not yet in.
        var waiting = 0
        var received = 0
        var refused = 0
    }

    var sendMessage: (_ peer: String, _ data: Data) -> Void = { _, _ in }
    /// Send this file to the peer under this name ("<item>/<file>"). The transport seals it.
    var sendFile: (_ peer: String, _ url: URL, _ resource: String) -> Void = { _, _, _ in }
    var onProgress: (Progress) -> Void = { _ in }
    /// A phone nearby sent something not sealed with this team's key (another passcode).
    var onStranger: (_ peer: String) -> Void = { _ in }

    private let library: SyncLibrary
    private let key: SyncKey
    private let name: String

    private struct Peer {
        var name = ""
        var trusted = false
        var inventory: [String: SyncItem] = [:]
        /// Files asked of this peer and not yet in, by item.
        var pending: [String: Set<String>] = [:]
        var lastSent: Data?
    }

    private var peers: [String: Peer] = [:]
    /// Files this phone turned down ("<item>/<file>"), never asked for again this session.
    private var refusedFiles: Set<String> = []
    private(set) var progress = Progress() {
        didSet { if progress != oldValue { onProgress(progress) } }
    }

    init(library: SyncLibrary, key: SyncKey, name: String) {
        self.library = library
        self.key = key
        self.name = name
    }

    // MARK: From the transport

    func connected(_ peer: String) {
        peers[peer] = peers[peer] ?? Peer()
        send(SyncMessage(kind: .hello, name: name), to: peer)
        sendInventory(to: peer, force: true)
    }

    func disconnected(_ peer: String) {
        guard let gone = peers.removeValue(forKey: peer) else { return }
        // Merge what came in from them; the rest can come from someone else.
        var changed = false
        for itemID in gone.pending.keys {
            if let record = gone.inventory[itemID]?.record, library.merge(itemID: itemID, record: record) { changed = true }
        }
        updateProgress()
        if changed { localChanged() }
        for other in peers.keys { request(from: other) }
    }

    /// False if it wasn't from a teammate (the transport should drop that phone).
    @discardableResult
    func received(_ data: Data, from peer: String) -> Bool {
        guard let opened = key.open(data), let message = try? JSONDecoder().decode(SyncMessage.self, from: opened) else {
            onStranger(peer)
            return false
        }
        var state = peers[peer] ?? Peer()
        state.trusted = true
        peers[peer] = state
        switch message.kind {
        case .hello:
            peers[peer]?.name = String((message.name ?? "").prefix(40))
            updateProgress()
        case .inventory:
            var inventory: [String: SyncItem] = [:]
            for item in message.items ?? [] where Self.safe(item.id) {
                inventory[item.id] = SyncItem(id: item.id, record: item.record, files: item.files.filter { Self.safe($0.name) })
            }
            peers[peer]?.inventory = inventory
            request(from: peer)
        case .want:
            serve(message.wants ?? [], to: peer)
        }
        return true
    }

    /// A file came in (unlocked by the transport), or failed (`url` nil).
    func receivedFile(_ url: URL?, resource: String, from peer: String) {
        guard let (itemID, name) = Self.split(resource), peers[peer]?.pending[itemID]?.contains(name) == true else {
            // Not asked for: ignore it.
            return
        }
        peers[peer]?.pending[itemID]?.remove(name)
        if let url, library.keep(url, itemID: itemID, name: name) {
            progress.received += 1
        } else {
            progress.refused += 1
            refusedFiles.insert(resource)
        }
        if peers[peer]?.pending[itemID]?.isEmpty == true {
            peers[peer]?.pending.removeValue(forKey: itemID)
            if let record = peers[peer]?.inventory[itemID]?.record, library.merge(itemID: itemID, record: record) {
                localChanged()
            }
            // Other teammates' versions of this item were waiting on these files.
            for other in peers.keys where other != peer { request(from: other) }
        }
        updateProgress()
    }

    /// Something here changed (a merge, a new photo): tell every teammate.
    func localChanged() {
        for peer in peers.keys where peers[peer]?.trusted == true { sendInventory(to: peer, force: false) }
    }

    // MARK: Inside

    private func send(_ message: SyncMessage, to peer: String) {
        guard let json = try? JSONEncoder().encode(message), let sealed = try? key.seal(json) else { return }
        sendMessage(peer, sealed)
    }

    private func sendInventory(to peer: String, force: Bool) {
        let items = library.syncItems().sorted { $0.id < $1.id }
        guard let json = try? JSONEncoder().encode(items) else { return }
        if !force && peers[peer]?.lastSent == json { return }
        peers[peer]?.lastSent = json
        send(SyncMessage(kind: .inventory, items: items), to: peer)
    }

    /// Ask this peer for the files this phone hasn't got and isn't already fetching elsewhere.
    /// Items with nothing to fetch are merged straight away.
    private func request(from peer: String) {
        guard let state = peers[peer], state.trusted else { return }
        let fetching = Set(peers.values.flatMap { p in p.pending.flatMap { item, names in names.map { "\(item)/\($0)" } } })
        var wants: [SyncWant] = []
        var changed = false
        for item in state.inventory.values.sorted(by: { $0.id < $1.id }) {
            let missing = item.files.filter {
                !refusedFiles.contains("\(item.id)/\($0.name)") && !library.hasFile(itemID: item.id, name: $0.name)
                    && library.wants(itemID: item.id, file: $0)
            }
            let ask = missing.map(\.name).filter { !fetching.contains("\(item.id)/\($0)") }
            if !ask.isEmpty {
                peers[peer]?.pending[item.id, default: []].formUnion(ask)
                wants.append(SyncWant(itemID: item.id, names: ask))
            } else if missing.isEmpty, state.pending[item.id] == nil {
                if library.merge(itemID: item.id, record: item.record) { changed = true }
            }
        }
        if !wants.isEmpty { send(SyncMessage(kind: .want, wants: wants), to: peer) }
        updateProgress()
        if changed { localChanged() }
    }

    /// Send what a teammate asked for, if this phone offers it.
    private func serve(_ wants: [SyncWant], to peer: String) {
        let offered = Dictionary(library.syncItems().map { ($0.id, Set($0.files.map(\.name))) }, uniquingKeysWith: { a, _ in a })
        for want in wants where Self.safe(want.itemID) {
            for name in want.names where Self.safe(name) && offered[want.itemID]?.contains(name) == true {
                if let url = library.fileURL(itemID: want.itemID, name: name) {
                    sendFile(peer, url, "\(want.itemID)/\(name)")
                }
            }
        }
    }

    private func updateProgress() {
        progress.teammates = peers.values.filter(\.trusted).map { $0.name.isEmpty ? "Teammate" : $0.name }.sorted()
        progress.waiting = peers.values.reduce(0) { $0 + $1.pending.values.reduce(0) { $0 + $1.count } }
    }

    /// One plain name: no folders, no "..", nothing hidden, nothing odd.
    nonisolated static func safe(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains("..") && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    nonisolated static func split(_ resource: String) -> (String, String)? {
        let parts = resource.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, safe(parts[0]), safe(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }
}
