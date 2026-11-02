import RealityKit
import SwiftUI

/// Scan a prop with the phone and make a USDZ of it (Phil, 2026-11-02), using Apple's Object
/// Capture: guided photos around the object, then the model built on the phone, offline.
/// Needs a LiDAR iPhone on iOS 17+. The finished file is kept in Files > Reset > Scans and
/// is offered for placing in the camera view straight away.
@MainActor
final class ObjectScanner: ObservableObject {
    enum Phase: Equatable {
        case ready, detecting, capturing, building(Double), done(URL), failed(String)
    }

    @Published var phase: Phase = .ready
    @Published private(set) var session: ObjectCaptureSession?

    private var folder: URL?
    private var building: Task<Void, Never>?

    static var supported: Bool { ObjectCaptureSession.isSupported }

    func start() {
        guard session == nil else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = Self.scansFolder.appendingPathComponent("Scan-\(stamp)", isDirectory: true)
        let images = base.appendingPathComponent("Images", isDirectory: true)
        let checkpoints = base.appendingPathComponent("Checkpoint", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not make a folder for the scan.")
            return
        }
        folder = base
        let session = ObjectCaptureSession()
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpoints
        session.start(imagesDirectory: images, configuration: configuration)
        self.session = session
        Diagnostics.log("Object scan started")
        Task { [weak self] in
            for await state in session.stateUpdates {
                self?.handle(state)
            }
        }
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        switch state {
        case .ready: phase = .ready
        case .detecting: phase = .detecting
        case .capturing: phase = .capturing
        case .completed: build()
        case .failed(let error):
            Diagnostics.log("Object scan failed: \(error)")
            phase = .failed("The scan stopped: \(error.localizedDescription)")
        default: break
        }
    }

    func next() {
        guard let session else { return }
        switch phase {
        case .ready: _ = session.startDetecting()
        case .detecting: session.startCapturing()
        case .capturing: session.finish()
        default: break
        }
    }

    func cancel() {
        building?.cancel()
        session?.cancel()
        session = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Turns the pictures into a model on the phone.
    private func build() {
        guard let folder else { return }
        phase = .building(0)
        let images = folder.appendingPathComponent("Images", isDirectory: true)
        let output = Self.scansFolder.appendingPathComponent("\(folder.lastPathComponent).usdz")
        building = Task { [weak self] in
            do {
                var configuration = PhotogrammetrySession.Configuration()
                configuration.featureSensitivity = .normal
                let reconstruction = try PhotogrammetrySession(input: images, configuration: configuration)
                try reconstruction.process(requests: [.modelFile(url: output, detail: .reduced)])
                for try await event in reconstruction.outputs {
                    switch event {
                    case .requestProgress(_, let fraction):
                        self?.phase = .building(fraction)
                    case .requestComplete:
                        Diagnostics.log("Object scan built: \(output.lastPathComponent)")
                        try? FileManager.default.removeItem(at: images)
                        self?.phase = .done(output)
                    case .requestError(_, let error):
                        Diagnostics.log("Object scan build error: \(error)")
                        self?.phase = .failed("The model could not be built: \(error.localizedDescription)")
                    default: break
                    }
                }
            } catch {
                Diagnostics.log("Object scan build failed: \(error)")
                self?.phase = .failed("The model could not be built: \(error.localizedDescription)")
            }
        }
    }

    static var scansFolder: URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

struct ObjectScanView: View {
    /// Called with the finished USDZ when the person taps Place.
    let place: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = ObjectScanner()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = scanner.session, !isBuilding {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button("Cancel") {
                        scanner.cancel()
                        dismiss()
                    }
                    .padding(10)
                    Spacer()
                }
                Spacer()
                controls
                    .padding(.bottom, 30)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .onAppear { scanner.start() }
    }

    private var isBuilding: Bool {
        switch scanner.phase {
        case .building, .done, .failed: return true
        default: return false
        }
    }

    @ViewBuilder private var controls: some View {
        switch scanner.phase {
        case .ready:
            pill("Find the object") { scanner.next() }
        case .detecting:
            pill("Start scanning") { scanner.next() }
        case .capturing:
            pill("Finish") { scanner.next() }
        case .building(let fraction):
            VStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(width: 220)
                Text("Building the model…").font(.subheadline)
            }
        case .done(let url):
            VStack(spacing: 10) {
                Text("Saved in Files > Reset > Scans").font(.footnote)
                pill("Place in the camera") {
                    place(url)
                    dismiss()
                }
            }
        case .failed(let message):
            Text(message).font(.subheadline).multilineTextAlignment(.center).padding()
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.yellow, in: Capsule())
                .foregroundStyle(.black)
        }
    }
}
