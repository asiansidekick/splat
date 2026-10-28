import ARKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ResetApp: App {
    init() {
        Diagnostics.logLaunch()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in Diagnostics.log("Memory warning") }
    }

    var body: some Scene {
        WindowGroup { HomeView() }
    }
}

/// Shows the live camera for an ARSession.
struct CameraView: UIViewRepresentable {
    let session: ARSession
    /// 3D content placed in ARKit's world coordinates, such as the 3D ghost.
    var content: SCNNode?
    /// Called once with the view, for example to add gestures.
    var onMake: ((ARSCNView) -> Void)?

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.autoenablesDefaultLighting = true  // lights imported models
        if let content { view.scene.rootNode.addChildNode(content) }
        onMake?(view)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}
}

enum Screen {
    /// The current interface orientation of the app's window.
    @MainActor static var orientation: UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
        let value = scene?.interfaceOrientation ?? .portrait
        return value == .unknown ? .portrait : value
    }
}

// MARK: - Home

struct HomeView: View {
    @State private var references: [Reference] = []
    @State private var recording = false
    @State private var showingHelp = false
    @AppStorage("seenHelp") private var seenHelp = false

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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { recording = true } label: { Label("New reference", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showingHelp, onDismiss: { seenHelp = true }) {
                HelpView()
            }
            .onAppear {
                if !seenHelp { showingHelp = true }
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
                        .disabled(recorder.saving || recorder.keyframeCount < (snapshotMode ? 1 : 5) || !recorder.canSaveMap)
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
        .frame(maxWidth: 560)  // keeps panels narrow when the device is held landscape
    }

    private var statusText: String {
        let mapping: String
        switch recorder.mappingStatus {
        case .mapped: mapping = "Mapped"
        case .extending: mapping = "Ready to save (more helps)"
        case .limited: mapping = "Keep moving slowly, not ready yet"
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
    @State private var showingMore = false
    @State private var importingModel = false

    init(reference: Reference) {
        _restorer = StateObject(wrappedValue: Restorer(reference: reference))
        _reference = State(initialValue: reference)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraView(session: restorer.session, content: restorer.sceneContent) { view in
                    restorer.attachGestures(to: view)
                }
                if !restorer.show3D, let ghost = restorer.ghost {
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
                    if restorer.status == .relocalizing, let photo = restorer.startPhoto {
                        findingHint(photo)
                    }
                    Text(headline)
                        .font(.subheadline.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 480)
                        .background(
                            (restorer.matched ? Color.green : Color.black).opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    Spacer()
                    controls
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 20)
            }
            .onAppear {
                restorer.viewport = geometry.size
                restorer.orientation = Screen.orientation
                restorer.start()
            }
            .onChange(of: geometry.size) { _, size in
                restorer.viewport = size
                restorer.orientation = Screen.orientation
            }
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
        .fileImporter(isPresented: $importingModel, allowedContentTypes: [.usdz]) { result in
            if case .success(let url) = result { restorer.addModel(from: url) }
        }
        .onChange(of: restorer.models) { _, models in
            reference.models = models
            try? ReferenceStore.save(reference)
        }
        .alert("3D model", isPresented: Binding(get: { restorer.modelError != nil }, set: { if !$0 { restorer.modelError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restorer.modelError ?? "")
        }
        .onDisappear { restorer.stop() }
    }

    /// While the room is being found: the first reference photo, so the person starts there.
    private func findingHint(_ photo: UIImage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(uiImage: photo)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 110, maxHeight: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(restorer.slowToFind
                ? "Still looking. Stand where this photo was taken and point at the same spot. Turn the lights back to how they were, and move slowly side to side."
                : "Start where this photo was taken and point at the same spot.")
                .font(.caption)
                .foregroundStyle(.white)
        }
        .padding(8)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 480)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private var headline: String {
        switch restorer.status {
        case .loading: return "Loading…"
        case .relocalizing: return "Point at the set and move slowly so it can find where the reference was recorded"
        case .failed(let message): return message
        case .ready:
            if restorer.show3D { return "3D ghost: check the props from anywhere" }
            return restorer.guidance.isEmpty ? "Ready" : restorer.guidance
        }
    }

    /// A slim bar over the camera; the rest opens on demand so the set stays visible.
    private var controls: some View {
        VStack(spacing: 8) {
            if showingMore {
                VStack(spacing: 8) {
                    if restorer.can3D {
                        Picker("Ghost", selection: $restorer.show3D) {
                            Text("Photo ghost").tag(false)
                            Text(restorer.cloudReady ? "3D ghost" : "3D (building…)").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    Button {
                        importingModel = true
                    } label: {
                        Label("Add 3D model (USDZ)", systemImage: "cube")
                    }
                    .buttonStyle(.bordered)
                    .disabled(restorer.status != .ready)
                    HStack {
                        Button(restorer.lockedKeyframe == nil ? "Hold view" : "Follow camera") {
                            restorer.toggleLock()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if restorer.usesDepth {
                            Toggle("Changes", isOn: $restorer.showDifferences)
                                .fixedSize()
                        }
                    }
                    if restorer.usesDepth && restorer.showDifferences {
                        HStack(spacing: 12) {
                            Label("In front of where it was", systemImage: "square.fill").foregroundStyle(.red)
                            Label("Missing", systemImage: "square.fill").foregroundStyle(.blue)
                        }
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                    }
                }
            }
            if let name = restorer.selectedModelName {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name): drag to move, pinch to scale, twist to turn").font(.caption2)
                    HStack {
                        Button("True size") { restorer.resetSelectedModelSize() }
                        Button("Delete", role: .destructive) { restorer.deleteSelectedModel() }
                        Spacer()
                        Button("Done") { restorer.selectedModel = nil }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let snapshotNote {
                Text(snapshotNote).font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text(reference.slate.isEmpty ? "T\(reference.nextTakeNumber)" : "\(reference.slate) T\(reference.nextTakeNumber)")
                    .font(.subheadline.bold().monospacedDigit())
                Image(systemName: "circle.lefthalf.filled").font(.caption)
                Slider(value: $ghostOpacity, in: 0...1)
                    .onChange(of: ghostOpacity) { _, value in restorer.setGhostOpacity(value) }
                    .accessibilityLabel("Ghost strength")
                Button {
                    snapshot()
                } label: {
                    Image(systemName: "camera")
                }
                .accessibilityLabel("Snapshot")
                .buttonStyle(.bordered)
                .disabled(restorer.status != .ready)
                Button("Log") {
                    loggingTake = Take(number: reference.nextTakeNumber, logged: Date(), resetChecked: restorer.matched)
                }
                .accessibilityLabel("Log take \(reference.nextTakeNumber)")
                .buttonStyle(.borderedProminent)
                Button {
                    withAnimation(.snappy) { showingMore.toggle() }
                } label: {
                    Image(systemName: showingMore ? "chevron.down" : "chevron.up")
                }
                .accessibilityLabel(showingMore ? "Fewer controls" : "More controls")
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .font(.subheadline)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 480)  // keeps the bar narrow when the device is held landscape
        .dynamicTypeSize(...DynamicTypeSize.large)  // large accessibility text would cover the set
    }

    /// Saves the set as it looks now, labelled for the take it comes before, to compare later.
    private func snapshot() {
        let label = "Before take \(reference.nextTakeNumber)"
        let count = reference.snapshots.filter { $0.label.hasPrefix(label) }.count
        guard let shot = restorer.takeSnapshot(label: count == 0 ? label : "\(label) (\(count + 1))") else { return }
        reference.snapshots.append(shot)
        try? ReferenceStore.save(reference)
        snapshotNote = "Saved \(shot.label). Tap Compare to check it."
        Task {
            try? await Task.sleep(for: .seconds(3))
            snapshotNote = nil
        }
    }
}
