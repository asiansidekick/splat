import ARKit
import SwiftUI

@main
struct ResetApp: App {
    var body: some Scene {
        WindowGroup { HomeView() }
    }
}

/// Shows the live camera for an ARSession.
struct CameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}

// MARK: - Home

struct HomeView: View {
    @State private var references: [Reference] = []
    @State private var recording = false

    var body: some View {
        NavigationStack {
            List {
                if references.isEmpty {
                    Text("No references yet. Record one for each setup before the first take, then use it to reset the set.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Slate.sortedScenes(references), id: \.self) { scene in
                    let setups = references
                        .filter { $0.scene == scene }
                        .sorted { $0.setup.localizedStandardCompare($1.setup) == .orderedAscending }
                    Section(scene.isEmpty ? "No scene" : "Scene \(scene)") {
                        ForEach(setups) { reference in
                            NavigationLink(value: reference.id) {
                                VStack(alignment: .leading) {
                                    Text(reference.title).font(.headline)
                                    Text(summary(reference))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { setups[$0] }.forEach(ReferenceStore.delete)
                            references = ReferenceStore.all()
                        }
                    }
                }
            }
            .navigationTitle("References")
            .navigationDestination(for: UUID.self) { id in
                if let reference = references.first(where: { $0.id == id }) {
                    RestoreView(reference: reference)
                }
            }
            .toolbar {
                Button { recording = true } label: { Label("New reference", systemImage: "plus") }
            }
            .fullScreenCover(isPresented: $recording, onDismiss: { references = ReferenceStore.all() }) {
                RecordView(existing: references)
            }
            .onAppear { references = ReferenceStore.all() }
        }
    }

    private func summary(_ reference: Reference) -> String {
        let takes = reference.takes.count == 1 ? "1 take" : "\(reference.takes.count) takes"
        let date = reference.created.formatted(date: .abbreviated, time: .shortened)
        return "\(takes) · \(date) · \(reference.keyframes.count) views\(reference.hasDepth ? " · LiDAR" : "")"
    }
}

// MARK: - Record

struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = Recorder()
    let existing: [Reference]
    @State private var scene: String
    @State private var setupLetter: String
    @State private var name = ""
    @State private var useLiDAR = Recorder.lidarAvailable
    @State private var started = false
    @State private var snapshotMode = false

    /// Carries on in the latest scene with the next free setup letter.
    init(existing: [Reference]) {
        self.existing = existing
        let scene = Slate.currentScene(in: existing)
        _scene = State(initialValue: scene)
        _setupLetter = State(initialValue: Slate.nextSetup(scene: scene, in: existing))
    }

    var body: some View {
        ZStack {
            CameraView(session: recorder.session).ignoresSafeArea()
            VStack {
                if started {
                    Text(statusText)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    setupCard
                }
                Spacer()
                if let error = recorder.error {
                    Text(error).font(.callout).padding(10)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                }
                HStack {
                    Button("Cancel", role: .cancel) {
                        recorder.cancel()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if started && snapshotMode {
                        Button {
                            recorder.captureNow()
                        } label: {
                            Image(systemName: "camera.circle.fill")
                                .font(.system(size: 64))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, .white)
                        }
                        .accessibilityLabel("Take snapshot")
                        Spacer()
                    }
                    if started {
                        Button(recorder.saving ? "Saving…" : "Save reference") {
                            Task {
                                if await recorder.finish() != nil { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.saving || recorder.keyframeCount < (snapshotMode ? 1 : 5))
                    }
                }
            }
            .padding()
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Scene", text: $scene)
                    .keyboardType(.numbersAndPunctuation)
                    .frame(maxWidth: 90)
                TextField("Setup", text: $setupLetter)
                    .textInputAutocapitalization(.characters)
                    .frame(maxWidth: 70)
                TextField("Description (optional)", text: $name)
            }
            .textFieldStyle(.roundedBorder)
            .onChange(of: scene) { _, newScene in
                setupLetter = Slate.nextSetup(scene: newScene, in: existing)
            }
            Picker("Capture", selection: $snapshotMode) {
                Text("Walk around").tag(false)
                Text("Quick snapshot").tag(true)
            }
            .pickerStyle(.segmented)
            if Recorder.lidarAvailable {
                Toggle("Use LiDAR (adds depth, highlights what moved)", isOn: $useLiDAR)
            }
            Text(snapshotMode
                ? "Stand where you can see the props. Sway the phone gently side to side for a couple of seconds so it can map the spot, then tap the shutter. Take more from other angles if you like."
                : "Walk slowly around the area, pointing at the props. Cover each spot from a couple of angles.")
                .font(.callout)
            Button("Start") {
                recorder.autoCapture = !snapshotMode
                recorder.start(scene: scene, setup: setupLetter, name: name, useLiDAR: useLiDAR)
                started = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusText: String {
        let mapping: String
        switch recorder.mappingStatus {
        case .mapped: mapping = "Mapped"
        case .extending: mapping = "Mapping, keep going"
        case .limited: mapping = "Mapping, move slowly"
        default: mapping = "Starting"
        }
        let slate = scene + setupLetter
        let count = recorder.keyframeCount
        let shots = snapshotMode ? (count == 1 ? "1 photo" : "\(count) photos") : "\(count) views"
        return "\(slate.isEmpty ? "" : "\(slate) · ")\(shots) · \(mapping)"
    }
}

// MARK: - Restore

struct RestoreView: View {
    @StateObject private var restorer: Restorer
    @State private var reference: Reference
    @State private var ghostOpacity = 0.5
    @State private var loggingTake: Take?
    @State private var showingLog = false
    @State private var showingCompare = false
    @State private var snapshotNote: String?

    init(reference: Reference) {
        _restorer = StateObject(wrappedValue: Restorer(reference: reference))
        _reference = State(initialValue: reference)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraView(session: restorer.session)
                if let ghost = restorer.ghost {
                    Image(uiImage: ghost)
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(ghostOpacity)
                        .allowsHitTesting(false)
                }
                if let differences = restorer.differences {
                    Image(uiImage: differences)
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                }
                VStack {
                    Text(headline)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(
                            (restorer.matched ? Color.green : Color.black).opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    Spacer()
                    controls
                }
                .padding()
            }
            .onAppear {
                restorer.viewport = geometry.size
                restorer.start()
            }
            .onChange(of: geometry.size) { _, size in restorer.viewport = size }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(reference.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup {
                Button("Compare") { showingCompare = true }
                Button("Take log") { showingLog = true }
            }
        }
        .sheet(isPresented: $showingCompare) {
            CompareView(reference: reference)
        }
        .sheet(item: $loggingTake) { take in
            TakeEditor(take: take, slate: reference.slate) { logged in
                reference.takes.append(logged)
                try? ReferenceStore.save(reference)
            }
        }
        .sheet(isPresented: $showingLog) {
            TakeLogView(reference: $reference)
        }
        .onDisappear { restorer.stop() }
    }

    private var headline: String {
        switch restorer.status {
        case .loading: return "Loading…"
        case .relocalizing: return "Point at the set and move slowly so it can find where the reference was recorded"
        case .failed(let message): return message
        case .ready: return restorer.guidance.isEmpty ? "Ready" : restorer.guidance
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.slate.isEmpty ? "Next take" : "Scene \(reference.slate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Take \(reference.nextTakeNumber)").font(.title3.bold().monospacedDigit())
                }
                Spacer()
                Button {
                    snapshot()
                } label: {
                    Label("Snapshot", systemImage: "camera")
                }
                .buttonStyle(.bordered)
                .disabled(restorer.status != .ready)
                Button("Log take \(reference.nextTakeNumber)") {
                    loggingTake = Take(number: reference.nextTakeNumber, logged: Date(), resetChecked: restorer.matched)
                }
                .buttonStyle(.borderedProminent)
            }
            if let snapshotNote {
                Text(snapshotNote).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: $ghostOpacity, in: 0...1)
            }
            HStack {
                Button(restorer.lockedKeyframe == nil ? "Hold this view" : "Follow camera") {
                    restorer.toggleLock()
                }
                .buttonStyle(.bordered)
                Spacer()
                if restorer.usesDepth {
                    Toggle("Highlight changes", isOn: $restorer.showDifferences)
                        .fixedSize()
                }
            }
            if restorer.usesDepth && restorer.showDifferences {
                Text("Red: something is in front of where it was. Blue: something is missing.")
                    .font(.caption)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Saves the set as it looks now, labelled for the take it comes before, to compare later.
    private func snapshot() {
        let label = "Before take \(reference.nextTakeNumber)"
        let count = reference.snapshots.filter { $0.label.hasPrefix(label) }.count
        guard let shot = restorer.takeSnapshot(label: count == 0 ? label : "\(label) (\(count + 1))") else { return }
        reference.snapshots.append(shot)
        try? ReferenceStore.save(reference)
        snapshotNote = "Saved \(shot.label). Tap Compare to check it against the reference."
    }
}
