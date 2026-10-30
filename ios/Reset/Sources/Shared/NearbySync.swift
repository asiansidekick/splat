import Combine
import Foundation
import MultipeerConnectivity

// Shared by Match and Reset (copy this file unchanged into the other app).

/// Syncs with teammates' phones close by, over Wi-Fi and Bluetooth directly between phones: no
/// internet, no router, no cloud. Phones only find teammates with the same team passcode, and
/// everything between them is sealed with the team key on top of the radio's own encryption.
/// Runs while the sync screen is open (iOS stops it in the background).
///
/// The app needs in its Info.plist: NSLocalNetworkUsageDescription, and NSBonjourServices with
/// "_<service>._tcp" and "_<service>._udp".
@MainActor
final class NearbySync: NSObject, ObservableObject {
    enum State: Equatable {
        case starting, looking, syncing, upToDate
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var progress = SyncEngine.Progress()
    /// Set when a phone nearby has a different passcode, to explain why it isn't syncing.
    @Published private(set) var strangerNearby = false

    private let service: String
    private let name: String
    private let passcode: String
    private weak var library: SyncLibrary?

    private var engine: SyncEngine?
    private var key: SyncKey? {
        get { keyBox.key }
        set { keyBox.key = newValue }
    }
    /// Read off the main thread when a file arrives.
    private nonisolated let keyBox = KeyBox()
    private let me: MCPeerID
    private let myID = UUID().uuidString
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var ids: [MCPeerID: String] = [:]
    private var byID: [String: MCPeerID] = [:]
    private var outgoing = 0

    /// `service`: 1 to 15 lowercase letters, numbers or hyphens, e.g. "match-sync".
    init(service: String, name: String, passcode: String, library: SyncLibrary) {
        self.service = service
        self.name = name
        self.passcode = passcode
        self.library = library
        me = MCPeerID(displayName: String((name.isEmpty ? "Teammate" : name).prefix(40)))
    }

    func start() {
        guard session == nil else { return }
        state = .starting
        let passcode = passcode, service = service
        Task {
            let key = await Task.detached(priority: .userInitiated) { SyncKey(passcode: passcode, service: service) }.value
            begin(with: key)
        }
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        engine = nil
        key = nil
        ids = [:]
        byID = [:]
    }

    /// Something changed in the app (a new photo): pass it on.
    func localChanged() { engine?.localChanged() }

    private func begin(with key: SyncKey) {
        guard let library, session == nil else { return }
        self.key = key
        let session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let engine = SyncEngine(library: library, key: key, name: name)
        engine.sendMessage = { [weak self] peer, data in
            guard let self, let id = self.byID[peer] else { return }
            try? self.session?.send(data, toPeers: [id], with: .reliable)
        }
        engine.sendFile = { [weak self] peer, url, resource in self?.send(url, resource: resource, to: peer) }
        engine.onProgress = { [weak self] progress in
            self?.progress = progress
            self?.updateState()
        }
        engine.onStranger = { [weak self] peer in
            guard let self else { return }
            self.strangerNearby = true
            if let id = self.byID[peer] { self.session?.cancelConnectPeer(id) }
        }
        self.engine = engine

        let info = ["team": key.tag, "id": myID]
        advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: info, serviceType: service)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        browser = MCNearbyServiceBrowser(peer: me, serviceType: service)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        state = .looking
    }

    private func id(for peer: MCPeerID) -> String {
        if let id = ids[peer] { return id }
        let id = UUID().uuidString
        ids[peer] = id
        byID[id] = peer
        return id
    }

    private func send(_ url: URL, resource: String, to peer: String) {
        guard let key, let id = byID[peer] else { return }
        outgoing += 1
        updateState()
        let sealed = FileManager.default.temporaryDirectory.appending(path: "sync-out-\(UUID().uuidString)")
        Task {
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                (try? key.sealFile(at: url, to: sealed, name: resource)) != nil
            }.value
            guard ok, let session = self.session else {
                try? FileManager.default.removeItem(at: sealed)
                self.outgoing -= 1
                self.updateState()
                return
            }
            session.sendResource(at: sealed, withName: resource, toPeer: id) { _ in
                try? FileManager.default.removeItem(at: sealed)
                Task { @MainActor in
                    self.outgoing -= 1
                    self.updateState()
                }
            }
        }
    }

    private func updateState() {
        guard session != nil, state != .starting else { return }
        if progress.teammates.isEmpty {
            state = .looking
        } else {
            state = progress.waiting > 0 || outgoing > 0 ? .syncing : .upToDate
        }
    }
}

/// The team key, safe to read from the radio's own threads.
final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SyncKey?
    var key: SyncKey? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension NearbySync: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard session === self.session else { return }
            let peer = self.id(for: peerID)
            switch state {
            case .connected: self.engine?.connected(peer)
            case .notConnected: self.engine?.disconnected(peer)
            default: break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard session === self.session else { return }
            self.engine?.received(data, from: self.id(for: peerID))
        }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // The received file is deleted when this returns, so unlock it into our own place now.
        var plain: URL?
        if error == nil, let localURL, let key = keyBox.key {
            let destination = FileManager.default.temporaryDirectory.appending(path: "sync-in-\(UUID().uuidString)")
            if key.openFile(at: localURL, to: destination, name: resourceName) { plain = destination }
        }
        let unlocked = plain
        Task { @MainActor in
            defer { if let unlocked { try? FileManager.default.removeItem(at: unlocked) } }
            guard session === self.session else { return }
            self.engine?.receivedFile(unlocked, resource: resourceName, from: self.id(for: peerID))
        }
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                             fromPeer peerID: MCPeerID) {}
}

extension NearbySync: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            // Anyone may connect, but nothing is shared until they prove the team key.
            invitationHandler(self.session != nil, self.session)
        }
    }
}

extension NearbySync: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard let session = self.session, let key = self.key else { return }
            guard info?["team"] == key.tag else {
                self.strangerNearby = true
                return
            }
            // Only one of the two phones invites, so they don't cross.
            guard let theirs = info?["id"], theirs > self.myID, !session.connectedPeers.contains(peerID) else { return }
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
