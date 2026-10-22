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
                    Text("No references yet. Record one before the first take, then use it to reset the set.")
                        .foregroundStyle(.secondary)
                }
                ForEach(references) { reference in
                    NavigationLink(value: reference.id) {
                        VStack(alignment: .leading) {
                            Text(reference.name).font(.headline)
                            Text("\(reference.created.formatted(date: .abbreviated, time: .shortened)) · \(reference.keyframes.count) views\(reference.hasDepth ? " · LiDAR" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { references[$0] }.forEach(ReferenceStore.delete)
                    references = ReferenceStore.all()
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
                RecordView()
            }
            .onAppear { references = ReferenceStore.all() }
        }
    }
}

// MARK: - Record

struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = Recorder()
    @State private var name = "Scene 1, setup A"
    @State private var useLiDAR = Recorder.lidarAvailable
    @State private var started = false

    var body: some View {
        ZStack {
            CameraView(session: recorder.session).ignoresSafeArea()
            VStack {
                if started {
                    Text(statusText)
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else {
                    setup
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
                    if started {
                        Button(recorder.saving ? "Saving…" : "Save reference") {
                            Task {
                                if await recorder.finish() != nil { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.saving || recorder.keyframeCount < 5)
                    }
                }
            }
            .padding()
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name, for example 12B setup 1", text: $name)
                .textFieldStyle(.roundedBorder)
            if Recorder.lidarAvailable {
                Toggle("Use LiDAR (adds depth, highlights what moved)", isOn: $useLiDAR)
            }
            Text("Walk slowly around the area, pointing at the props. Cover each spot from a couple of angles.")
                .font(.callout)
            Button("Start") {
                recorder.start(name: name, useLiDAR: useLiDAR)
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
        return "\(recorder.keyframeCount) views · \(mapping)"
    }
}

// MARK: - Restore

struct RestoreView: View {
    @StateObject private var restorer: Restorer
    @State private var ghostOpacity = 0.5

    init(reference: Reference) {
        _restorer = StateObject(wrappedValue: Restorer(reference: reference))
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
        .navigationTitle(restorer.reference.name)
        .navigationBarTitleDisplayMode(.inline)
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
}
