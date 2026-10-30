import ARKit
import Combine
import PhotosUI
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
        WindowGroup { CameraHome() }
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

// MARK: - Camera home

/// The one screen, opened straight into the camera like the Camera app. With no reference picked
/// it records new ones; tap a reference's thumbnail and it shows that reference's ghost.
struct CameraHome: View {
    @State private var references: [Reference] = []
    @State private var selectedID: UUID?
    @State private var panel: Panel?
    @State private var deleting: Reference?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @StateObject private var thumbnails = Thumbnails()
    @AppStorage("seenCameraHelp") private var seenHelp = false
    @State private var loaded = false
    // The slate the next reference gets, carried on from the existing references.
    @State private var nextScene = "1"
    @State private var nextSetup = "A"
    @State private var nextName = ""
    /// The last shutter photo, offered for sending straight away.
    @State private var lastPhoto: UIImage?
    @State private var lastPhotoTask: Task<Void, Never>?
    @State private var sharingPhoto: UIImage?
    @State private var sketching: UIImage?
    @AppStorage("saveToPhotos") private var saveToPhotos = true

    enum Panel: Identifiable {
        case takeLog(UUID), compare(UUID), slate(UUID), pdf(UUID), nextSlate, help, gallery, sharePhoto, sync, sketch

        var id: String {
            switch self {
            case .takeLog(let id): return "log-\(id)"
            case .compare(let id): return "compare-\(id)"
            case .slate(let id): return "slate-\(id)"
            case .pdf(let id): return "pdf-\(id)"
            case .nextSlate: return "next"
            case .help: return "help"
            case .gallery: return "gallery"
            case .sharePhoto: return "share"
            case .sync: return "sync"
            case .sketch: return "sketch"
            }
        }
    }

    var body: some View {
        Group {
            if let id = selectedID, let reference = binding(for: id) {
                ResetStage(
                    reference: reference, thumbnails: thumbnails, open: { panel = $0 },
                    close: { selectedID = nil }, showToast: show, onPhoto: took)
                    .id(id)
            } else {
                CaptureStage(
                    scene: nextScene, setup: nextSetup, name: nextName, thumbnail: thumbnail,
                    open: { panel = $0 }, onSaved: saved, onPhoto: took, showToast: show)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .hiddenInScreenshots()
            }
        }
        .overlay(alignment: .topTrailing) {
            if lastPhoto != nil {
                HStack(spacing: 8) {
                    Button {
                        sketching = lastPhoto
                        panel = .sketch
                    } label: {
                        Label("Sketch", systemImage: "pencil.tip")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Button {
                        sharingPhoto = lastPhoto
                        panel = .sharePhoto
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.yellow, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 112)
                .transition(.scale.combined(with: .opacity))
                .hiddenInScreenshots()
            }
        }
        .sheet(item: $panel) { panel in sheet(for: panel) }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "reference")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete reference and its takes", role: .destructive) {
                if let reference = deleting { delete(reference) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReferenceSyncView.changed)) { _ in
            // A teammate's reference or edit arrived: show it.
            references = ReferenceStore.all()
            nextSetup = Slate.nextSetup(scene: nextScene, in: references)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            references = ReferenceStore.all()
            nextScene = Slate.currentScene(in: references)
            nextSetup = Slate.nextSetup(scene: nextScene, in: references)
            if !seenHelp { panel = .help }
        }
    }

    /// The newest reference, bottom left like the last photo in the Camera app; opens the gallery.
    private var thumbnail: AnyView {
        AnyView(Button {
            Haptics.tap()
            panel = .gallery
        } label: {
            // The title hangs under the thumbnail so it stays level with the shutter.
            ReferenceThumbnail(reference: references.first, thumbnails: thumbnails, size: 50)
                .overlay(alignment: .bottom) {
                    Text("Reference")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 2)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(y: 18)
                }
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("References"))
    }

    /// A binding to one reference that stays safe if the reference is deleted.
    private func binding(for id: UUID) -> Binding<Reference>? {
        guard let current = references.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { references.first { $0.id == id } ?? current },
            set: { updated in
                if let index = references.firstIndex(where: { $0.id == id }) { references[index] = updated }
            })
    }

    private func saved(_ reference: Reference) {
        references.insert(reference, at: 0)
        Haptics.success()
        show("Saved \(reference.slate.isEmpty ? "reference" : reference.slate)")
        nextSetup = Slate.nextSetup(scene: nextScene, in: references)
        nextName = ""
    }

    /// A shutter photo (with any 3D models in it): saved to Photos and offered for sending.
    private func took(_ image: UIImage) {
        if saveToPhotos {
            Task {
                let saved = await PhotoLibrary.save([image])
                if !saved { show("Allow Photos in Settings, Reset, Photos to save there") }
            }
        }
        lastPhotoTask?.cancel()
        withAnimation(.snappy) { lastPhoto = image }
        lastPhotoTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { lastPhoto = nil }
        }
    }

    /// Each photo picked from Photos becomes a photo reference with the next setup letter.
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        show("Importing \(items.count == 1 ? "photo" : "\(items.count) photos")…")
        Task {
            var imported: [Reference] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let setup = Slate.nextSetup(scene: nextScene, in: references + imported)
                if let reference = try? PhotoLibrary.makeReference(from: data, scene: nextScene, setup: setup) {
                    imported.append(reference)
                }
            }
            references = ReferenceStore.all()
            nextSetup = Slate.nextSetup(scene: nextScene, in: references)
            Diagnostics.log("Imported \(imported.count) of \(items.count) photos")
            if imported.isEmpty {
                show("Could not import those photos")
            } else {
                show(imported.count == 1 ? "Imported \(imported[0].slate)" : "Imported \(imported.count) photos")
                selectedID = imported.last?.id
            }
        }
    }

    private func exportPhotos(_ reference: Reference) {
        Task {
            let images = PhotoLibrary.images(of: reference)
            let saved = await PhotoLibrary.save(images)
            show(saved ? "Saved \(images.count) \(images.count == 1 ? "photo" : "photos") to Photos" : "Allow Photos in Settings, Reset, Photos")
        }
    }

    private func delete(_ reference: Reference) {
        if selectedID == reference.id { selectedID = nil }
        ReferenceStore.delete(reference)
        references.removeAll { $0.id == reference.id }
        nextSetup = Slate.nextSetup(scene: nextScene, in: references)
    }

    private func show(_ message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = message }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { toast = nil }
        }
    }

    @ViewBuilder
    private func sheet(for panel: Panel) -> some View {
        switch panel {
        case .takeLog(let id):
            if let reference = binding(for: id) { TakeLogView(reference: reference) }
        case .compare(let id):
            if let reference = references.first(where: { $0.id == id }) { CompareView(reference: reference) }
        case .slate(let id):
            if let reference = references.first(where: { $0.id == id }) {
                SlateEditor(reference: reference) { updated in
                    if let saved = binding(for: id) { saved.wrappedValue = updated }
                    try? ReferenceStore.save(updated)
                }
            }
        case .pdf(let id):
            if let reference = references.first(where: { $0.id == id }) {
                if let url = try? ReportPDF.make(for: reference) {
                    ShareSheet(items: [url])
                } else {
                    Text("Could not make the PDF.").padding()
                }
            }
        case .nextSlate:
            NextSlateSheet(scene: $nextScene, setup: $nextSetup, name: $nextName, references: references)
        case .help:
            HelpView().onDisappear { seenHelp = true }
        case .gallery:
            Gallery(
                references: references, selectedID: $selectedID, thumbnails: thumbnails, onImport: importPhotos,
                onSync: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.panel = .sync } }
            ) { action, reference in
                // Let the gallery close before the next sheet opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    switch action {
                    case .takeLog: self.panel = .takeLog(reference.id)
                    case .compare: self.panel = .compare(reference.id)
                    case .slate: self.panel = .slate(reference.id)
                    case .pdf: self.panel = .pdf(reference.id)
                    case .delete: deleting = reference
                    case .photos: exportPhotos(reference)
                    case .sketch:
                        if let photo = PhotoLibrary.images(of: reference).first {
                            sketching = photo
                            self.panel = .sketch
                        }
                    }
                }
            }
        case .sharePhoto:
            if let sharingPhoto { ShareSheet(items: [sharingPhoto]) }
        case .sync:
            ReferenceSyncView()
        case .sketch:
            if let sketching { SketchEditor(photo: sketching) }
        }
    }
}

/// The slate for the next reference: scene, setup letter and an optional description.
struct NextSlateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var scene: String
    @Binding var setup: String
    @Binding var name: String
    let references: [Reference]

    var body: some View {
        NavigationStack {
            Form {
                SlateFields(scene: $scene, setup: $setup, name: $name)
            }
            .onChange(of: scene) { _, newScene in
                setup = Slate.nextSetup(scene: newScene, in: references)
            }
            .navigationTitle("Next reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Layout

/// The Camera app's layout: the preview fills the whole screen, with the top bar and the shutter
/// controls floating over it, along the bottom when upright or down the side when the phone is
/// turned. The preview stays the same view whichever way the phone is held, so turning it does
/// not restart the camera. Things drawn over the preview keep clear of the controls with
/// `chromeInsets`.
struct CameraLayout<Top: View, Preview: View, Modes: View, Leading: View, Shutter: View, Trailing: View>: View {
    /// Dark bars behind the controls. Without them the controls float straight on the picture.
    var bars = true
    /// Left-handed: in landscape the control column runs down the left edge instead.
    @AppStorage("leftHanded") var leftHanded = false
    @ViewBuilder let top: () -> Top
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let modes: (_ vertical: Bool) -> Modes
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let shutter: () -> Shutter
    @ViewBuilder let trailing: () -> Trailing

    static var topHeight: CGFloat { 44 }
    static var bottomHeight: CGFloat { 108 }
    static var sideWidth: CGFloat { 100 }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let safe = geometry.safeAreaInsets
            let left = leftHanded
            let insets = landscape
                ? (left
                    ? EdgeInsets(top: safe.top + Self.topHeight, leading: max(safe.leading, Self.sideWidth), bottom: safe.bottom, trailing: safe.trailing)
                    : EdgeInsets(top: safe.top + Self.topHeight, leading: safe.leading, bottom: safe.bottom, trailing: max(safe.trailing, Self.sideWidth)))
                : EdgeInsets(top: safe.top + Self.topHeight, leading: safe.leading, bottom: safe.bottom + Self.bottomHeight, trailing: safe.trailing)
            ZStack {
                VStack(spacing: 0) {
                    top()
                        .frame(height: Self.topHeight)
                        .background(shade(.bottom, .top).ignoresSafeArea(edges: .top))
                    Spacer(minLength: 0)
                    if !landscape {
                        VStack(spacing: 4) {
                            modes(false)
                            ZStack {
                                shutter()
                                HStack {
                                    leading().frame(width: 84)
                                    Spacer(minLength: 0)
                                    trailing().frame(minWidth: 84, alignment: .trailing)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                        .frame(maxWidth: .infinity, minHeight: Self.bottomHeight)
                        .background(shade(.top, .bottom).ignoresSafeArea(edges: .bottom))
                    }
                }
                .padding(.trailing, landscape && !left ? max(0, Self.sideWidth - safe.trailing) : 0)
                .padding(.leading, landscape && left ? max(0, Self.sideWidth - safe.leading) : 0)
                .hiddenInScreenshots()
                if landscape {
                    HStack(spacing: 0) {
                        if !left { Spacer(minLength: 0) }
                        // Grouped round the shutter in the middle, like the Camera app, so nothing
                        // sits in the screen's top corner (taps there went unanswered).
                        VStack(spacing: 18) {
                            Spacer(minLength: 0)
                            trailing().environment(\.chromeVertical, true)
                            modes(true)
                            shutter()
                            leading()
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .frame(width: Self.sideWidth)
                        .frame(maxHeight: .infinity)
                        .background((left ? shade(.trailing, .leading) : shade(.leading, .trailing)).ignoresSafeArea(edges: [.top, .bottom]))
                        if left { Spacer(minLength: 0) }
                    }
                    // Right against the edge of the screen, like the Camera app, not inset by the
                    // safe area, which only leaves an empty strip.
                    .ignoresSafeArea(edges: left ? .leading : .trailing)
                    .hiddenInScreenshots()
                }
            }
            .background {
                preview()
                    .environment(\.chromeInsets, insets)
                    .clipped()
                    .ignoresSafeArea()
            }
        }
        .background(Color.black)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)  // big accessibility text would push the controls off screen
    }

    /// Shading behind the controls that fades into the picture instead of ending in a hard edge:
    /// clear on the picture side, darkest at the screen edge.
    private func shade(_ from: UnitPoint, _ to: UnitPoint) -> LinearGradient {
        LinearGradient(
            colors: bars ? [.black.opacity(0), .black.opacity(0.3), .black.opacity(0.55)] : [.clear],
            startPoint: from, endPoint: to)
    }
}

/// Keeps things drawn over the full-screen preview clear of the floating controls.
struct ClearOfControls: ViewModifier {
    @Environment(\.chromeInsets) private var insets

    func body(content: Content) -> some View {
        content.padding(insets)
    }
}

extension View {
    func clearOfControls() -> some View { modifier(ClearOfControls()) }
}

private struct ChromeInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

extension EnvironmentValues {
    /// How far the floating controls reach in from each edge of the full-screen preview.
    var chromeInsets: EdgeInsets {
        get { self[ChromeInsetsKey.self] }
        set { self[ChromeInsetsKey.self] = newValue }
    }
}

/// The mode names above the shutter: tap one, or swipe across them.
struct ModePicker<Mode: Hashable>: View {
    let modes: [Mode]
    let label: (Mode) -> String
    @Binding var selection: Mode
    var vertical = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 24))
        layout {
            ForEach(modes, id: \.self) { mode in
                Button {
                    choose(mode)
                } label: {
                    Text(label(mode))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selection == mode ? Color.yellow : Color.white)
                }
            }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 20).onEnded { drag in
            let distance = vertical ? drag.translation.height : drag.translation.width
            guard abs(distance) > 30, let index = modes.firstIndex(of: selection) else { return }
            let next = index + (distance < 0 ? 1 : -1)
            if modes.indices.contains(next) { choose(modes[next]) }
        })
    }

    private func choose(_ mode: Mode) {
        guard mode != selection else { return }
        Haptics.tap()
        withAnimation(.snappy) { selection = mode }
    }
}

struct ShutterButton: View {
    enum Style { case photo, record, stop }
    let style: Style
    var busy = false
    /// The outer ring: green when the ghost is lined up.
    var ring: Color = .white
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            ZStack {
                Circle().stroke(ring, lineWidth: 4).frame(width: 74, height: 74)
                switch style {
                case .photo: Circle().fill(Color.white).frame(width: 60, height: 60)
                case .record: Circle().fill(Color.red).frame(width: 60, height: 60)
                case .stop: RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 30, height: 30)
                }
                if busy { ProgressView().tint(style == .photo ? .black : .white) }
            }
        }
        .buttonStyle(PressScale())
    }
}

/// A round button beside the shutter, with a word under it.
struct SideButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 50, height: 50)
                    .background(Color.white.opacity(0.15), in: Circle())
                Text(title).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A small pill in the top bar.
struct TopPill: View {
    let text: String
    var systemImage: String?
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(text).lineLimit(1)
            }
            .font(.subheadline.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(highlighted ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
            .foregroundStyle(highlighted ? Color.black : Color.white)
        }
    }
}

enum Haptics {
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

/// A status line over the camera.
struct Banner: View {
    let text: String
    var tint: Color = .black

    var body: some View {
        Text(text)
            .font(.subheadline.bold())
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 480)
            .background(tint.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
    }
}

// MARK: - Thumbnails

/// One reference's first photo, square, with its slate on it.
struct ReferenceThumbnail: View {
    let reference: Reference?
    @ObservedObject var thumbnails: Thumbnails
    var size: CGFloat = 50
    var selected = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let reference, let image = thumbnails.images[reference.id] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.12)
                        .overlay(Image(systemName: "photo.on.rectangle").foregroundStyle(.white.opacity(0.6)))
                }
            }
            .frame(width: size, height: size)
            .clipped()
            if let reference, size >= 50 {
                HStack(spacing: 3) {
                    if !reference.slate.isEmpty { Text(reference.slate).bold() }
                    Spacer(minLength: 0)
                    Text(timestamp(reference.created))
                }
                .font(.system(size: size >= 100 ? 11 : 9).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .frame(width: size)
                .background(Color.black.opacity(0.65))
                .foregroundStyle(.white)
            } else if let slate = reference?.slate, !slate.isEmpty {
                Text(slate)
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .background(Color.black.opacity(0.65))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.yellow : Color.white.opacity(0.8), lineWidth: selected ? 3 : 1))
        .task(id: reference?.id) {
            if let reference { await thumbnails.load(reference) }
        }
    }

    /// When it was recorded: the time today, otherwise the date (and time on bigger tiles).
    private func timestamp(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        return size >= 100 ? "\(day) \(date.formatted(date: .omitted, time: .shortened))" : day
    }
}

/// Every reference, opened on the newest like the Camera app's photo viewer: swipe right for
/// older ones, tap Load (or double-tap the photo) to bring up its ghost. The grid button shows them
/// all by scene. Press and hold a photo for its take log, compare, report, slate or delete.
struct Gallery: View {
    enum Action { case takeLog, compare, slate, pdf, delete, photos, sketch }

    @Environment(\.dismiss) private var dismiss
    /// Oldest first, so the newest is the last page, as in Photos.
    private let ordered: [Reference]
    @Binding var selectedID: UUID?
    @ObservedObject var thumbnails: Thumbnails
    let onImport: ([PhotosPickerItem]) -> Void
    let onSync: () -> Void
    let action: (Action, Reference) -> Void
    @State private var current: UUID?
    @State private var showingGrid = false
    @State private var picked: [PhotosPickerItem] = []

    init(
        references: [Reference], selectedID: Binding<UUID?>, thumbnails: Thumbnails,
        onImport: @escaping ([PhotosPickerItem]) -> Void, onSync: @escaping () -> Void = {},
        action: @escaping (Action, Reference) -> Void
    ) {
        ordered = references.sorted { $0.created < $1.created }
        _selectedID = selectedID
        self.thumbnails = thumbnails
        self.onImport = onImport
        self.onSync = onSync
        self.action = action
        _current = State(initialValue: selectedID.wrappedValue ?? ordered.last?.id)
    }

    private var shown: Reference? { ordered.first { $0.id == current } }

    var body: some View {
        NavigationStack {
            Group {
                if ordered.isEmpty {
                    ContentUnavailableView(
                        "No references yet", systemImage: "camera.viewfinder",
                        description: Text("Close this and tap the shutter to save one, or import photos with the arrow at the top."))
                } else if showingGrid {
                    grid
                } else {
                    pager
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(showingGrid ? "References" : (shown?.title ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    PhotosPicker(selection: $picked, matching: .images) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import from Photos")
                    Button {
                        dismiss()
                        onSync()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("Sync with nearby phones")
                    Button {
                        withAnimation { showingGrid.toggle() }
                    } label: {
                        Image(systemName: showingGrid ? "photo" : "square.grid.2x2")
                    }
                    .accessibilityLabel(showingGrid ? "One at a time" : "All references")
                    if let shown, !showingGrid { menu(for: shown) }
                }
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                onImport(items)
                picked = []
                dismiss()
            }
        }
    }

    private var pager: some View {
        VStack(spacing: 12) {
            TabView(selection: $current) {
                ForEach(ordered) { reference in
                    GalleryPage(reference: reference)
                        .tag(Optional(reference.id))
                        .onTapGesture(count: 2) { load(reference) }
                        .contextMenu { menuItems(for: reference) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            filmstrip
            if let shown {
                Button {
                    load(shown)
                } label: {
                    Label("Load \(shown.slate.isEmpty ? "ghost" : shown.slate)", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: 360)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    /// Small thumbnails under the photo to jump along quickly, as in Photos.
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ordered) { reference in
                        Button {
                            withAnimation { current = reference.id }
                        } label: {
                            ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 40, selected: current == reference.id)
                        }
                        .id(reference.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 3)
            }
            .frame(height: 48)
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Slate.sortedScenes(ordered).reversed(), id: \.self) { scene in
                    Text(scene.isEmpty ? "No scene" : "Scene \(scene)").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(setups(in: scene)) { reference in
                            Button {
                                Haptics.tap()
                                current = reference.id
                                withAnimation { showingGrid = false }
                            } label: {
                                ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 100, selected: selectedID == reference.id)
                            }
                            .accessibilityLabel(reference.title)
                            .contextMenu { menuItems(for: reference) }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func setups(in scene: String) -> [Reference] {
        ordered
            .filter { $0.scene == scene }
            .sorted { $0.setup.localizedStandardCompare($1.setup) == .orderedAscending }
    }

    private func load(_ reference: Reference) {
        Haptics.tap()
        selectedID = reference.id
        dismiss()
    }

    private func menu(for reference: Reference) -> some View {
        Menu {
            menuItems(for: reference)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private func menuItems(for reference: Reference) -> some View {
        Button { dismiss(); action(.takeLog, reference) } label: { Label("Take log", systemImage: "list.number") }
        Button { dismiss(); action(.compare, reference) } label: { Label("Compare snapshots", systemImage: "rectangle.split.2x1") }
        Button { dismiss(); action(.pdf, reference) } label: { Label("Share PDF report", systemImage: "square.and.arrow.up") }
        Button { dismiss(); action(.photos, reference) } label: { Label("Save photos to Photos", systemImage: "photo.on.rectangle.angled") }
        Button { dismiss(); action(.sketch, reference) } label: { Label("Sketch on the photo", systemImage: "pencil.tip.crop.circle") }
        Button { dismiss(); action(.slate, reference) } label: { Label("Edit slate", systemImage: "pencil") }
        Button(role: .destructive) { dismiss(); action(.delete, reference) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// One reference, large: its first photo and what it is.
struct GalleryPage: View {
    let reference: Reference
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(details)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .contentShape(Rectangle())
        .task(id: reference.id) {
            guard image == nil, let first = reference.keyframes.first else { return }
            let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(first.imageFile)
            let orientation = first.uprightOrientation
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let cg = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
                return UIImage(cgImage: cg, scale: 1, orientation: orientation)
            }.value
        }
    }

    private var details: String {
        let takes = reference.takes.count == 1 ? "1 take" : "\(reference.takes.count) takes"
        let date = reference.created.formatted(date: .abbreviated, time: .shortened)
        var parts = [date, takes]
        if reference.hasDepth { parts.append("LiDAR") }
        if reference.photoOnly { parts.append("Imported photo") }
        if !reference.name.isEmpty { parts.insert(reference.name, at: 0) }
        return parts.joined(separator: " · ")
    }
}

/// Small upright copies of each reference's first photo, made off the main thread.
@MainActor
final class Thumbnails: ObservableObject {
    @Published private(set) var images: [UUID: UIImage] = [:]

    func load(_ reference: Reference) async {
        guard images[reference.id] == nil, let first = reference.keyframes.first else { return }
        let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(first.imageFile)
        let orientation = first.uprightOrientation
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let full = UIImage(contentsOfFile: url.path), full.size.width > 0 else { return nil }
            let size = CGSize(width: 200, height: 200 * full.size.height / full.size.width)
            guard let cg = full.preparingThumbnail(of: size)?.cgImage else { return nil }
            return UIImage(cgImage: cg, scale: 1, orientation: orientation)
        }.value
        if let image { images[reference.id] = image }
    }
}

// MARK: - Recording

enum CaptureMode: String, CaseIterable {
    case photo, snapshot, walk

    var label: String {
        switch self {
        case .photo: return "PHOTO"
        case .snapshot: return "QUICK SCAN"
        case .walk: return "WALK AROUND"
        }
    }
}

/// Holds the camera view, to take pictures of it with the 3D models in.
final class CameraViewHolder {
    weak var view: ARSCNView?
}

/// Recording new references. The camera maps the room in the background, but nothing is saved
/// until the shutter is tapped. Photo: a picture (with any 3D models) for Photos and sending.
/// Reference: each tap saves a reference. Walk around: tap to start, walk slowly round the props,
/// tap to stop and save.
struct CaptureStage: View {
    @StateObject private var recorder = Recorder()
    let scene: String
    let setup: String
    let name: String
    let thumbnail: AnyView
    let open: (CameraHome.Panel) -> Void
    let onSaved: (Reference) -> Void
    let onPhoto: (UIImage) -> Void
    let showToast: (String) -> Void
    @AppStorage("captureMode") private var mode: CaptureMode = .snapshot
    @AppStorage("useLiDAR") private var useLiDAR = true
    @State private var holder = CameraViewHolder()
    @State private var importingModels = false
    @State private var justSaved = false
    /// The "get its bearings" hint shows for a few seconds, then gives way to the usual line.
    @State private var bearingsHintDone = false
    @State private var bearingsTask: Task<Void, Never>?

    private var slate: String { scene + setup }

    var body: some View {
        CameraLayout {
            HStack(spacing: 8) {
                TopPill(text: "Next: \(slate.isEmpty ? "no slate" : slate)", systemImage: "pencil") {
                    open(.nextSlate)
                }
                .disabled(recorder.capturing)
                Spacer()
                if Recorder.lidarAvailable {
                    TopPill(text: "LiDAR", systemImage: "dot.circle.viewfinder", highlighted: useLiDAR) {
                        useLiDAR.toggle()
                    }
                    .disabled(recorder.capturing)
                    .accessibilityLabel(useLiDAR ? "LiDAR on" : "LiDAR off")
                }
                TorchButton()
                // Works while a scan or recording is going, too.
                MeasureToggle(measurer: recorder.measurer)
                Button { open(.help) } label: { Image(systemName: "questionmark.circle").font(.title3) }
                    .accessibilityLabel("Help")
            }
            .padding(.horizontal, 12)
            .foregroundStyle(.white)
        } preview: {
            ZStack {
                CameraView(session: recorder.session, content: recorder.modelsNode) { view in
                    recorder.placer.attachGestures(to: view)
                    recorder.measurer.attachGestures(to: view)
                    holder.view = view
                }
                // Dots on everything the scan has covered, building up as you walk round.
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { recorder.viewport = geometry.size }
                        .onChange(of: geometry.size) { _, size in recorder.viewport = size }
                }
                .allowsHitTesting(false)
                if let dots = recorder.scanDots {
                    Image(uiImage: dots)
                        .resizable()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                ModelSizeBadge(placer: recorder.placer).hiddenInScreenshots()
                MeasureReticle(measurer: recorder.measurer).hiddenInScreenshots()
                if mode == .snapshot && (recorder.pendingSave || recorder.saving || justSaved) {
                    ScanProgressOverlay(
                        progress: justSaved ? 1 : recorder.scanProgress, saved: justSaved,
                        mapping: recorder.mappingStatus, points: recorder.pointCount)
                        .clearOfControls()
                        .hiddenInScreenshots()
                        .transition(.opacity)
                }
                VStack {
                    Banner(text: status, tint: recorder.capturing ? .red : .black)
                        .onAppear { timeBearingsHint(recorder.trackingNormal) }
                        .onChange(of: recorder.trackingNormal) { _, normal in timeBearingsHint(normal) }
                    Spacer()
                    TorchDial()
                    MeasureBar(measurer: recorder.measurer)
                    ModelOverlay(placer: recorder.placer)
                    if let error = recorder.error {
                        Text(error).font(.callout).padding(10)
                            .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(8)
                .clearOfControls()
                .hiddenInScreenshots()
            }
        } modes: { vertical in
            ModePicker(modes: CaptureMode.allCases, label: \.label, selection: $mode, vertical: vertical)
                .disabled(recorder.capturing)
                .opacity(recorder.capturing ? 0.4 : 1)
        } leading: {
            thumbnail.disabled(recorder.capturing)
        } shutter: {
            ShutterButton(style: shutterStyle, busy: recorder.pendingSave || recorder.saving) {
                shutterTapped()
            }
            .disabled(recorder.saving)
            .accessibilityLabel(shutterLabel)
        } trailing: {
            WithScreenshot(camera: { holder.view }, toast: showToast) {
                if recorder.capturing {
                    Text("\(recorder.keyframeCount)\n\(recorder.keyframeCount == 1 ? "view" : "views")")
                        .font(.caption.bold().monospacedDigit())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                } else {
                    SideButton(title: "3D models", systemImage: "cube") { importingModels = true }
                }
            }
        }
        .overlay { MeasurePointer(measurer: recorder.measurer) }
        .overlay { MeasureEntry(measurer: recorder.measurer).hiddenInScreenshots() }
        .fileImporter(isPresented: $importingModels, allowedContentTypes: [.usdz], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { recorder.placer.add(from: urls) }
        }
        .onAppear {
            recorder.onSaved = { reference in
                onSaved(reference)
                withAnimation(.snappy) { justSaved = true }
                Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    withAnimation(.snappy) { justSaved = false }
                }
            }
            recorder.prepare(useLiDAR: useLiDAR)
        }
        .onDisappear { recorder.stop() }
        .onChange(of: showPoints) { _, show in
            holder.view?.debugOptions = show ? [.showFeaturePoints] : []
        }
        .onChange(of: useLiDAR) { _, on in
            recorder.stop()
            recorder.prepare(useLiDAR: on)
        }
    }

    /// The points ARKit is locking onto, shown while scanning a reference or walking around.
    private var showPoints: Bool {
        (mode == .snapshot && (recorder.pendingSave || recorder.saving)) || (mode == .walk && recorder.capturing)
    }

    private var shutterLabel: String {
        switch mode {
        case .photo: return "Take photo"
        case .snapshot: return "Save reference"
        case .walk: return recorder.capturing ? "Stop and save" : "Start recording"
        }
    }

    /// The camera view as it looks, with any 3D models in it.
    private func takePhoto() {
        guard let image = holder.view?.snapshot() else { return }
        onPhoto(image)
    }

    private var shutterStyle: ShutterButton.Style {
        switch mode {
        case .photo, .snapshot: return .photo
        case .walk: return recorder.capturing && !recorder.pendingSave ? .stop : .record
        }
    }

    private func shutterTapped() {
        switch mode {
        case .photo:
            takePhoto()
        case .snapshot:
            takePhoto()
            // Another tap while waiting for the map adds a second view to the same reference.
            if !recorder.capturing {
                recorder.autoCapture = false
                recorder.begin(scene: scene, setup: setup, name: name)
            }
            recorder.captureNow()
            recorder.saveWhenReady()
        case .walk:
            if recorder.capturing {
                recorder.saveWhenReady()
            } else {
                recorder.autoCapture = true
                recorder.begin(scene: scene, setup: setup, name: name)
            }
        }
    }

    /// Shows the bearings hint for four seconds each time tracking is lost.
    private func timeBearingsHint(_ normal: Bool) {
        bearingsTask?.cancel()
        bearingsHintDone = false
        guard !normal else { return }
        bearingsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { bearingsHintDone = true }
        }
    }

    private var status: String {
        let ready = recorder.canSaveMap
        if recorder.saving { return "Saving \(slate)…" }
        if recorder.pendingSave {
            return "Mapping the room. Move the phone gently side to side and it saves by itself. Tap again to save now."
        }
        if recorder.capturing {
            return "Recording \(slate). Walk slowly round the props, then tap stop."
        }
        if !recorder.trackingNormal && !bearingsHintDone {
            let start = mode == .walk ? "Press record" : "Tap the shutter"
            return "\(start). Move the phone slowly so the camera can get its bearings"
        }
        switch mode {
        case .photo:
            return recorder.placer.models.isEmpty
                ? "Tap for a photo. Add 3D models with the cube button to mock up the set."
                : "Tap for a photo with the models in it"
        case .snapshot:
            return ready ? "Point at the props and tap to save \(slate)" : "Move the phone gently to map the room, then tap to save \(slate)"
        case .walk:
            return "Tap record, then walk slowly round the props for \(slate)"
        }
    }
}

// MARK: - Reset

/// A time kept by reference, so closures captured from older copies of a view share it.
final class LastTime {
    var date = Date.distantPast
}

/// Putting a set back: the reference's ghost over the live camera, with edge guides to line it
/// up. The shutter saves a snapshot, Log logs the take, and Pause freezes the picture to fade or
/// wipe between the reference and now.
struct ResetStage: View {
    /// Whether the ruler is on: drags then draw lines, so the swipe for ghost strength steps aside.
    @State private var measuring = false
    @StateObject private var restorer: Restorer
    @Binding var reference: Reference
    @ObservedObject var thumbnails: Thumbnails
    let open: (CameraHome.Panel) -> Void
    let close: () -> Void
    let showToast: (String) -> Void
    let onPhoto: (UIImage) -> Void
    @AppStorage("ghostOpacity") private var ghostOpacity = 0.5
    /// Pause on the left and Log on the right, for the left hand.
    @AppStorage("leftHanded") private var leftHanded = false
    /// Compare by wiping across instead of fading.
    @AppStorage("compareStyleWipe") private var wipe = true
    @State private var ghostShown = true
    /// While swiping the ghost strength, the cursor shows.
    @State private var swipingStrength = false
    /// While swiping, how far towards now the view is, for the THEN and NOW tags; nil hides them.
    @State private var tagsValue: Double?
    @State private var tagsTask: Task<Void, Never>?
    /// While paused: 0 shows the reference, 1 the frozen live picture.
    @State private var toNow = 1.0
    @State private var importingModel = false
    @State private var notingTake: Take?
    @State private var holder = CameraViewHolder()
    @State private var tapCatcher = WindowTapCatcher()
    @State private var lastPauseToggle = LastTime()

    init(
        reference: Binding<Reference>, thumbnails: Thumbnails,
        open: @escaping (CameraHome.Panel) -> Void, close: @escaping () -> Void,
        showToast: @escaping (String) -> Void, onPhoto: @escaping (UIImage) -> Void
    ) {
        _reference = reference
        _restorer = StateObject(wrappedValue: Restorer(reference: reference.wrappedValue))
        self.thumbnails = thumbnails
        self.open = open
        self.close = close
        self.showToast = showToast
        self.onPhoto = onPhoto
    }

    var body: some View {
        CameraLayout(bars: false) {
            topBar
        } preview: {
            preview
        } modes: { vertical in
            if restorer.can3D && Restorer.offers3D && !restorer.paused {
                ModePicker(
                    modes: [false, true], label: { $0 ? (restorer.cloudReady || restorer.cloudFailed ? "3D GHOST" : "3D (BUILDING)") : "PHOTO GHOST" },
                    selection: $restorer.show3D, vertical: vertical)
            }
        } leading: {
            if leftHanded { pauseButton } else { logButton }
        } shutter: {
            ShutterButton(style: .photo, ring: restorer.matched ? .green : .white) { snapshot() }
                .modifier(WindowFrame { frame in tapCatcher.targets["Shutter"] = (frame, nil) })
                .disabled(restorer.status != .ready || restorer.paused)
                .opacity(restorer.paused ? 0 : restorer.status == .ready ? 1 : 0.5)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .accessibilityLabel("Snapshot")
        } trailing: {
            WithScreenshot(camera: { holder.view }, toast: showToast) {
                if leftHanded { logButton } else { pauseButton }
            }
        }
        .overlay { MeasurePointer(measurer: restorer.measurer) }
        .overlay { MeasureEntry(measurer: restorer.measurer).hiddenInScreenshots() }
        .modifier(CaptureButtonAction { togglePause() })
        .sheet(item: $notingTake) { take in
            TakeEditor(take: take, slate: reference.slate) { logged in
                reference.takes.append(logged)
                save()
            }
        }
        .fileImporter(isPresented: $importingModel, allowedContentTypes: [.usdz], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { restorer.placer.add(from: urls) }
        }
        .onReceive(restorer.placer.$models.dropFirst()) { models in
            reference.models = models
            save()
        }
        .onReceive(restorer.measurer.$active) { measuring = $0 }
        .onReceive(restorer.measurer.$revision.dropFirst()) { _ in
            reference.measurements = restorer.measurer.measurements
            reference.notes = restorer.measurer.notes
            reference.removedMarks = restorer.measurer.removed
            save()
        }
        .onChange(of: reference.measurements) { _, _ in followSyncedMarks() }
        .onChange(of: reference.notes) { _, _ in followSyncedMarks() }
        .onChange(of: restorer.paused) { _, paused in
            if paused { restorer.measurer.active = false }
        }
        .onChange(of: restorer.matched) { _, matched in
            if matched { Diagnostics.log("Edge guides all seated") }
        }
        .onAppear {
            tapCatcher.install()
            // Checked under the same light it was shot with.
            if let level = reference.torch, Torch.shared.available {
                Torch.shared.set(on: true, level: level)
                showToast("Torch on at \(Int((level * 100).rounded()))%, as when this was shot")
            }
        }
        .onDisappear {
            tapCatcher.remove()
            restorer.stop()
        }
    }

    private var logButton: some View {
        SideButton(title: "Log T\(reference.nextTakeNumber)", systemImage: "checkmark.circle", tint: .yellow) {
            logTake()
        }
        .modifier(WindowFrame { frame in tapCatcher.targets["Log"] = (frame, nil) })
        .shadow(color: .black.opacity(0.6), radius: 3)
        .contextMenu {
            Button { notingTake = newTake() } label: { Label("Log with a note", systemImage: "square.and.pencil") }
            Button { open(.takeLog(reference.id)) } label: { Label("Take log", systemImage: "list.number") }
        }
        .accessibilityLabel("Log take \(reference.nextTakeNumber)")
        .opacity(restorer.paused ? 0 : 1)
        .disabled(restorer.paused)
    }

    private var pauseButton: some View {
        PauseButton(paused: restorer.paused) { togglePause() }
            .modifier(WindowFrame { frame in tapCatcher.targets["Pause"] = (frame, { togglePause() }) })
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { close() } label: { Image(systemName: "xmark").font(.title3) }
                .accessibilityLabel("Back to recording")
            // This reference: tap to hide or show the ghost, press and hold for all references.
            ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 34, selected: ghostShown)
                .opacity(ghostShown ? 1 : 0.5)
                .onTapGesture {
                    Haptics.tap()
                    ghostShown.toggle()
                }
                .onLongPressGesture { open(.gallery) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(ghostShown ? "Hide the ghost" : "Show the ghost")
            TopPill(text: reference.slate.isEmpty ? "Take \(reference.nextTakeNumber)" : "\(reference.slate) · T\(reference.nextTakeNumber)") {
                open(.takeLog(reference.id))
            }
            Spacer(minLength: 0)
            if restorer.paused {
                // Small, in the top bar, so it covers none of the picture.
                Text("PAUSED")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color.orange)
                    .accessibilityLabel("Paused")
                TopPill(text: wipe ? "Wipe" : "Fade", systemImage: wipe ? "rectangle.split.2x1" : "square.on.square") {
                    Haptics.tap()
                    wipe.toggle()
                }
                .accessibilityLabel(wipe ? "Wiping. Switch to fade" : "Fading. Switch to wipe")
            } else {
                if restorer.usesDepth {
                    Button { restorer.showDifferences.toggle() } label: {
                        Image(systemName: "square.2.layers.3d").font(.title3)
                            .foregroundStyle(restorer.showDifferences ? Color.yellow : Color.white)
                    }
                    .accessibilityLabel(restorer.showDifferences ? "Hide LiDAR changes" : "Show LiDAR changes")
                }
                if !reference.photoOnly {
                    Button { restorer.toggleLock() } label: {
                        Image(systemName: restorer.lockedKeyframe == nil ? "lock.open" : "lock.fill")
                            .font(.title3)
                            .foregroundStyle(restorer.lockedKeyframe == nil ? Color.white : Color.yellow)
                    }
                    .accessibilityLabel(restorer.lockedKeyframe == nil ? "Hold this view" : "Follow the camera")
                }
            }
            if !restorer.paused {
                TorchButton()
                MeasureToggle(measurer: restorer.measurer)
                    .disabled(restorer.status != .ready)
            }
            Menu {
                Button { open(.gallery) } label: { Label("References", systemImage: "photo.on.rectangle") }
                Button { importingModel = true } label: { Label("Add 3D models (USDZ)", systemImage: "cube") }
                    .disabled(restorer.status != .ready)
                Button { open(.compare(reference.id)) } label: { Label("Compare snapshots", systemImage: "rectangle.split.2x1") }
                Button { open(.takeLog(reference.id)) } label: { Label("Take log", systemImage: "list.number") }
                Button { open(.pdf(reference.id)) } label: { Label("Share PDF report", systemImage: "square.and.arrow.up") }
                Button { open(.slate(reference.id)) } label: { Label("Edit slate", systemImage: "pencil") }
                Button { open(.sync) } label: { Label("Sync with nearby phones", systemImage: "arrow.triangle.2.circlepath") }
                Toggle(isOn: $leftHanded) { Label("Left-handed controls", systemImage: "hand.raised") }
                Button { open(.help) } label: { Label("Help", systemImage: "questionmark.circle") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                CameraView(session: restorer.session, content: restorer.sceneContent) { view in
                    restorer.placer.attachGestures(to: view)
                    restorer.measurer.attachGestures(to: view)
                    holder.view = view
                }
                if ghostShown {
                    if reference.photoOnly, let photo = restorer.startPhoto {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .opacity(ghostOpacity)
                            .allowsHitTesting(false)
                    } else if restorer.show3D {
                        // Drawn at the ghost strength already, dots in the photos' colours, gone parts blue.
                        if let ghost = restorer.ghost3D {
                            Image(uiImage: ghost)
                                .resizable()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .allowsHitTesting(false)
                        }
                    } else if let ghost = restorer.ghost {
                        Image(uiImage: ghost)
                            .resizable()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .opacity(ghostOpacity)
                            .allowsHitTesting(false)
                    }
                }
                if !restorer.paused, reference.models.isEmpty, !measuring {
                    // Swipe left or right anywhere for the ghost strength (not while measuring: drags draw lines).
                    Color.clear
                        .modifier(HorizontalSwipe(value: Binding(get: { 1 - ghostOpacity }, set: { ghostOpacity = 1 - $0 })) { active in
                            if active {
                                if !swipingStrength { withAnimation(.easeOut(duration: 0.15)) { swipingStrength = true } }
                            } else {
                                withAnimation(.easeOut(duration: 0.4).delay(0.8)) { swipingStrength = false }
                            }
                        })
                }
                if let differences = restorer.differences {
                    Image(uiImage: differences)
                        .resizable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                }
                if restorer.status == .ready, !restorer.show3D, !reference.photoOnly, !restorer.paused {
                    AimOverlay(state: restorer.aim).hiddenInScreenshots()
                    EdgeGuideOverlay(state: restorer.edges).hiddenInScreenshots()
                }
                if restorer.paused {
                    HeldCompare(
                        held: restorer.held, plainReference: reference.photoOnly ? restorer.startPhoto : restorer.heldPhoto,
                        toNow: $toNow, wipe: wipe)
                }
                VStack(spacing: 8) {
                    if restorer.status == .relocalizing, !reference.photoOnly, let photo = restorer.startPhoto, !restorer.paused {
                        findingHint(photo)
                    }
                    if let headline, !restorer.paused {
                        Banner(text: headline)
                    }
                    Spacer()
                    if restorer.paused {
                        ScrubCursor(value: toNow, start: "THEN", end: "NOW")
                    } else {
                        TorchDial()
                        MeasureBar(measurer: restorer.measurer)
                        ModelOverlay(placer: restorer.placer)
                        if swipingStrength {
                            ScrubCursor(value: 1 - ghostOpacity, start: "THEN", end: "NOW")
                                .transition(.opacity)
                        }
                    }
                }
                .padding(8)
                .clearOfControls()
                .hiddenInScreenshots()
                ModelSizeBadge(placer: restorer.placer).hiddenInScreenshots()
                if !restorer.paused {
                    MeasureReticle(measurer: restorer.measurer).hiddenInScreenshots()
                }
            }
            .overlay {
                if let tagsValue {
                    SwipeTags(value: tagsValue)
                        .clearOfControls()
                        .hiddenInScreenshots()
                        .transition(.opacity)
                }
            }
            .overlay {
                // Green once all four edge guides are in.
                if restorer.matched && !restorer.paused {
                    Rectangle().strokeBorder(Color.green, lineWidth: 4).ignoresSafeArea().allowsHitTesting(false).hiddenInScreenshots()
                }
            }
            .onAppear {
                restorer.viewport = geometry.size
                restorer.orientation = Screen.orientation
                restorer.setGhostOpacity(ghostOpacity)
                restorer.start()
            }
            .onChange(of: geometry.size) { _, size in
                restorer.viewport = size
                restorer.orientation = Screen.orientation
            }
            .onChange(of: ghostOpacity) { _, value in
                restorer.setGhostOpacity(value)
                if swipingStrength { showTags(1 - value) }
            }
            .onChange(of: toNow) { _, value in
                if restorer.paused { showTags(value) }
            }
        }
    }

    /// Shows the THEN and NOW tags, shaded by how far towards each the view is, until a second
    /// after the last change.
    private func showTags(_ value: Double) {
        if tagsValue == nil {
            withAnimation(.easeOut(duration: 0.15)) { tagsValue = value }
        } else {
            tagsValue = value
        }
        tagsTask?.cancel()
        tagsTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { tagsValue = nil }
        }
    }

    private func togglePause() {
        // The button and the window's tap watcher can both fire for one tap: act once.
        let now = Date()
        guard now.timeIntervalSince(lastPauseToggle.date) > 0.4 else { return }
        lastPauseToggle.date = now
        Diagnostics.log("Pause toggled: \(restorer.paused ? "resume" : "pause"), \(Screen.orientation.isLandscape ? "landscape" : "portrait"), status \(restorer.status)")
        if restorer.paused {
            restorer.resume()
        } else {
            toNow = 1
            restorer.pause()
        }
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

    /// Only while there is no ghost to line up: loading, finding the room, a problem, or the 3D
    /// ghost's state. Lining up itself is shown by the edge guides alone.
    private var headline: String? {
        switch restorer.status {
        case .loading: return "Loading…"
        case .relocalizing: return "Point at the set and move slowly to find \(reference.slate.isEmpty ? "the reference" : reference.slate)"
        case .failed(let message): return message
        case .ready:
            guard restorer.show3D else { return nil }
            if restorer.cloudFailed { return "No 3D points in this reference. Send the feedback log from ? please" }
            if !restorer.cloudReady { return "Building the 3D ghost…" }
            if !restorer.usesDepth { return "3D ghost: line the props up with the dots" }
            return restorer.missingPoints > 0
                ? "Blue dots: something has gone from there"
                : "3D ghost: dots on the props as they were"
        }
    }

    private func newTake() -> Take {
        Take(number: reference.nextTakeNumber, logged: Date(), resetChecked: restorer.matched)
    }

    /// One tap logs the take; press and hold the button to add a note.
    private func logTake() {
        let take = newTake()
        reference.takes.append(take)
        save()
        Haptics.success()
        showToast("Logged \(reference.slate) take \(take.number)")
    }

    /// Saves the set as it looks now, labelled for the take it comes before, to compare later.
    private func snapshot() {
        let label = "Before take \(reference.nextTakeNumber)"
        let count = reference.snapshots.filter { $0.label.hasPrefix(label) }.count
        guard let shot = restorer.takeSnapshot(label: count == 0 ? label : "\(label) (\(count + 1))") else { return }
        reference.snapshots.append(shot)
        save()
        if let image = holder.view?.snapshot() { onPhoto(image) }
        showToast("Snapshot saved. Compare it from the ••• menu.")
    }

    private func save() {
        try? ReferenceStore.save(reference)
    }

    /// A teammate's measurements or notes arrived by sync: show them.
    private func followSyncedMarks() {
        let measurer = restorer.measurer
        guard reference.measurements != measurer.measurements || reference.notes != measurer.notes else { return }
        measurer.load(measurements: reference.measurements, notes: reference.notes, removed: reference.removedMarks)
    }
}

/// After the shutter in Reference mode: a machine-vision style scanning display (red tint, scan
/// lines, a sweeping bar and readouts) while the room is mapped, then MAP SAVED.
struct ScanProgressOverlay: View {
    let progress: Double
    let saved: Bool
    let mapping: ARFrame.WorldMappingStatus
    let points: Int

    private var tint: Color { saved ? .green : .red }

    var body: some View {
        ZStack {
            tint.opacity(0.22)
            // Fine horizontal scan lines.
            Canvas { context, size in
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.25)))
                    y += 4
                }
            }
            // A bright bar sweeping down the screen.
            TimelineView(.animation) { timeline in
                GeometryReader { geometry in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    LinearGradient(colors: [tint.opacity(0), tint.opacity(0.6), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                        .offset(y: geometry.size.height * phase - 30)
                }
            }
            .opacity(saved ? 0 : 1)
            brackets
            VStack(alignment: .leading, spacing: 3) {
                Text(saved ? "MAP SAVED" : "SCANNING ROOM").font(.system(.title3, design: .monospaced).bold())
                Text("STATUS   \(statusText)")
                Text("POINTS   \(points)")
                Text("PROGRESS \(Int(progress * 100))%")
                ProgressView(value: progress)
                    .tint(saved ? .green : .white)
                    .frame(width: 180)
                    .animation(.easeOut(duration: 0.3), value: progress)
                if !saved {
                    Text("MOVE GENTLY SIDE TO SIDE").padding(.top, 4)
                }
            }
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(.white)
            .shadow(color: tint, radius: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 70)
            .padding(.leading, 28)
        }
        .allowsHitTesting(false)
    }

    private var statusText: String {
        if saved { return "LOCKED" }
        switch mapping {
        case .mapped: return "MAPPED"
        case .extending: return "EXTENDING"
        case .limited: return "ACQUIRING"
        default: return "INITIALISING"
        }
    }

    /// Corner brackets around a target box in the middle of the screen.
    private var brackets: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) * 0.55
            let rect = CGRect(x: (geometry.size.width - side) / 2, y: (geometry.size.height - side) / 2, width: side, height: side)
            Path { path in
                let arm: CGFloat = 26
                let corners: [(CGPoint, CGFloat, CGFloat)] = [
                    (CGPoint(x: rect.minX, y: rect.minY), 1, 1), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                    (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
                ]
                for (corner, dx, dy) in corners {
                    path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
                }
            }
            .stroke(Color.white.opacity(0.9), lineWidth: 2)
        }
    }
}

// MARK: - Guidance graphic

/// When the reference is off screen, a yellow arrow at the edge points the way to turn.
struct AimOverlay: View {
    @ObservedObject var state: AimState

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            if let point = state.point, let offset = state.offset, !offset.isMatched {
                let inset: CGFloat = 50
                let shown = CGPoint(
                    x: min(max(point.x, inset), size.width - inset),
                    y: min(max(point.y, inset), size.height - inset))
                if shown != point {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Color.yellow)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .rotationEffect(.radians(atan2(point.x - centre.x, centre.y - point.y)))
                        .position(shown)
                        .animation(.linear(duration: 0.1), value: shown)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
