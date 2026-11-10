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
        Theme.installAppearance()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in Diagnostics.log("Memory warning") }
    }

    var body: some Scene {
        WindowGroup {
            CameraHome()
                .font(Theme.body)
                .tint(Theme.accent)
        }
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

/// A photo to sketch on. The sheet is opened with the photo inside it, so it can never open empty (grey).
struct SketchPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
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
    @Environment(\.verticalSizeClass) private var homeVerticalSize
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
    @State private var nextShot = ""
    /// Review opened from the gallery's Dimensions and notes button starts with the ruler on.
    @State private var reviewMeasuring = false
    @State private var nextSetup = "1"
    @State private var nextName = ""
    /// The last shutter photo, offered for sending straight away.
    @State private var lastPhoto: UIImage?
    @State private var lastPhotoTask: Task<Void, Never>?
    @State private var sharingPhoto: UIImage?
    @State private var sketching: SketchPhoto?
    /// The Edit window (PhotoEditor.swift), on a snapshot or a reference's photo.
    @State private var editing: EditTarget?
    @AppStorage("saveToPhotos") private var saveToPhotos = true
    /// The newest reference jiggles after it is recorded, to say "load me" (Phil, 2026-11-05).
    @State private var nudgeLoad = false
    /// Whether anything has been saved since the app opened, for the "not saved yet" reminder.
    @State private var anySaved = false
    @State private var nudgeTask: Task<Void, Never>?
    /// Phil, 2026-11-09: a snapshot becomes the overlay in one tap. "Use as overlay" shows for a few seconds after
    /// one saves; the Recent strip by the thumbnail offers the last few.
    @State private var justSaved: UUID?
    @State private var justSavedTask: Task<Void, Never>?
    @State private var showingRecent = false

    enum Panel: Identifiable {
        case takeLog(UUID), compare(UUID), review(UUID), explore(UUID), slate(UUID), pdf(UUID), cutoutScan(UUID), nextSlate, help, gallery, sharePhoto, sync, sketch

        var id: String {
            switch self {
            case .takeLog(let id): return "log-\(id)"
            case .compare(let id): return "compare-\(id)"
            case .review(let id): return "review-\(id)"
            case .explore(let id): return "explore-\(id)"
            case .cutoutScan(let id): return "cutscan-\(id)"
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
                    reference: reference, others: references.filter { $0.id != id }, added: added, thumbnails: thumbnails, open: { panel = $0 },
                    close: { selectedID = nil }, showToast: show, onPhoto: took)
                    .id(id)
            } else {
                CaptureStage(
                    scene: nextScene, shot: nextShot, setup: nextSetup, name: nextName, thumbnail: thumbnail,
                    open: { panel = $0 }, onSaved: saved, onPhoto: took, showToast: show)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(Theme.subheadline.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 12)
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .hiddenInScreenshots()
            }
        }
        .overlay(alignment: .topLeading) {
            if let id = justSaved, selectedID == nil, !showingRecent {
                Button { useAsOverlay(id, from: "the button after a snapshot") } label: {
                    Label("Use as overlay", systemImage: "square.on.square")
                        .font(Theme.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.black)
                        .fixedSize()
                }
                .padding(.leading, 16)
                .padding(.top, 166)
                .transition(.opacity)
                .hiddenInScreenshots()
            }
        }
        .overlay(alignment: .bottom) {
            if showingRecent, selectedID == nil {
                RecentStrip(references: Array(references.prefix(8)), thumbnails: thumbnails,
                            pick: { useAsOverlay($0, from: "the Recent strip") },
                            close: { withAnimation(.snappy) { showingRecent = false } })
                    .padding(.bottom, 150)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .hiddenInScreenshots()
            }
        }
        .overlay(alignment: .topTrailing) {
            if lastPhoto != nil {
                HStack(spacing: 8) {
                    Button {
                        if let lastPhoto { editing = EditTarget(photo: lastPhoto) }
                    } label: {
                        Label("Edit", systemImage: "wand.and.stars")
                            .font(Theme.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Button {
                        if let lastPhoto { sketching = SketchPhoto(image: lastPhoto) }
                    } label: {
                        Label("Sketch", systemImage: "pencil.tip")
                            .font(Theme.subheadline.bold())
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
                            .font(Theme.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 112)
                .transition(.scale.combined(with: .opacity))
                .hiddenInScreenshots()
            }
        }
        .sheet(item: $panel, onDismiss: { reviewMeasuring = false }) { panel in sheet(for: panel).themed() }
        .sheet(item: $sketching) { SketchEditor(photo: $0.image).themed() }
        .fullScreenCover(item: $editing) { target in
            PhotoEditorSheet(target: target, scene: nextScene, setup: nextSetup, onNewReference: { added($0) })
        }
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
            Task {
                // Nothing is saved until the shutter: say so if the camera has just sat there.
                try? await Task.sleep(for: .seconds(14))
                let shown = UserDefaults.standard.integer(forKey: "tip.unsaved")
                if panel == nil, !anySaved, shown < 3 {
                    UserDefaults.standard.set(shown + 1, forKey: "tip.unsaved")
                    show("Nothing is saved until you tap the shutter.", seconds: 5)
                }
            }
            if let warning = InstallExpiry.warning {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { show(warning, seconds: 8) }
            }
        }
    }

    /// The newest reference, bottom left like the last photo in the Camera app; opens the gallery.
    private var thumbnail: AnyView {
        AnyView(Button {
            Haptics.tap()
            // Just recorded: one tap loads it, the next step anyone wants. Hold for all references.
            if nudgeLoad, let newest = references.first {
                endNudge()
                selectedID = newest.id
            } else {
                panel = .gallery
            }
        } label: {
            // The title hangs under the thumbnail so it stays level with the shutter.
            ReferenceThumbnail(reference: references.first, thumbnails: thumbnails, size: 50)
                .modifier(LoadNudge(active: nudgeLoad))
                .overlay(alignment: .bottom) {
                    Text(nudgeLoad ? "Tap to load" : "Reference")
                        .font(Theme.font(size: 14, weight: .semibold))
                        .foregroundStyle(nudgeLoad ? Theme.accent : Color.white)
                        .shadow(color: .black.opacity(0.9), radius: 2)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(y: 18)
                }
        }
        .buttonStyle(PressScale())
        .overlay(alignment: .top) {
            if references.count > 1 {
                // Phil, 2026-11-10: plain words like MANUAL SCAN, no pill or shadow, and off the thumbnail.
                // Upright it sits in the mode line at the left edge; on its side, under "Reference".
                let sideways = homeVerticalSize == .compact
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { showingRecent.toggle() }
                } label: {
                    Text("RECENT")
                    .font(Theme.font(size: 13, weight: .semibold))
                    .foregroundStyle(showingRecent ? Theme.accent : Color.white)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .fixedSize()
                }
                .offset(x: sideways ? 0 : -10, y: sideways ? 80 : -40)
            }
        }
        .holdHint("captureThumb", "Hold: options", above: true, delay: 4)
        .contextMenu {
            // Hold the thumbnail for the newest reference's options, the same ones the gallery has.
            if let newest = references.first {
                Button { endNudge(); selectedID = newest.id } label: { Label("Load \(newest.slate.isEmpty ? "it" : newest.slate)", systemImage: "arrow.down.circle") }
                Button { endNudge(); perform(.hero, newest) } label: { Label(newest.hero ? "Remove hero star" : "Hero", systemImage: newest.hero ? "star.slash" : "star") }
                Button { endNudge(); perform(.review, newest) } label: { Label("Review frames", systemImage: "rectangle.stack") }
                Button { endNudge(); perform(.slate, newest) } label: { Label("Edit slate", systemImage: "pencil") }
                Button { endNudge(); perform(.takeLog, newest) } label: { Label("Take log", systemImage: "list.number") }
                Button { endNudge(); perform(.compare, newest) } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                Button { endNudge(); perform(.pdf, newest) } label: { Label("PDF report", systemImage: "doc.richtext") }
                Button(role: .destructive) { endNudge(); perform(.delete, newest) } label: { Label("Delete", systemImage: "trash") }
            }
            Button { endNudge(); panel = .gallery } label: { Label("All references", systemImage: "square.grid.2x2") }
        }
        .accessibilityLabel(nudgeLoad ? "Load the reference you just recorded" : "References"))
    }

    /// What the gallery's and the thumbnail's option menus do.
    private func perform(_ action: Gallery.Action, _ reference: Reference) {
        switch action {
        case .takeLog: panel = .takeLog(reference.id)
        case .compare: panel = .compare(reference.id)
        case .review:
            reviewMeasuring = false
            panel = .review(reference.id)
        case .measure:
            reviewMeasuring = true
            panel = .review(reference.id)
        case .explore: panel = .explore(reference.id)
        case .cutout: panel = .cutoutScan(reference.id)
        case .slate: panel = .slate(reference.id)
        case .pdf: panel = .pdf(reference.id)
        case .delete: deleting = reference
        case .photos: exportPhotos(reference)
        case .hero: toggleHero(reference)
        case .sketch:
            if let photo = PhotoLibrary.images(of: reference).first {
                sketching = SketchPhoto(image: photo)
            }
        case .edit:
            if let photo = PhotoLibrary.images(of: reference).first {
                editing = EditTarget(photo: photo, reference: reference)
            }
        }
    }

    /// A reference made elsewhere (the Edit window): shown first, without the "saved" fuss of a recording.
    private func added(_ reference: Reference) {
        guard !references.contains(where: { $0.id == reference.id }) else { return }
        references.insert(reference, at: 0)
    }

    /// Stars a reference as a hero, or takes the star off.
    private func toggleHero(_ reference: Reference) {
        guard let index = references.firstIndex(where: { $0.id == reference.id }) else { return }
        references[index].hero.toggle()
        references[index].slateEdited = Date()
        try? ReferenceStore.save(references[index])
        Haptics.success()
        show(references[index].hero ? "Starred as a hero" : "Star removed")
    }

    /// Starts the "load me" cue, which stops when tapped or after 20 seconds.
    private func startNudge() {
        nudgeTask?.cancel()
        withAnimation(.snappy) { nudgeLoad = true }
        nudgeTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { nudgeLoad = false }
        }
    }

    private func endNudge() {
        nudgeTask?.cancel()
        withAnimation(.snappy) { nudgeLoad = false }
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

    /// Puts references into a sub-group of their scene (or out of it, with an empty name).
    private func group(_ ids: [UUID], as name: String) {
        for id in ids {
            guard let index = references.firstIndex(where: { $0.id == id }) else { continue }
            references[index].group = name
            references[index].slateEdited = Date()
            try? ReferenceStore.save(references[index])
        }
        Haptics.success()
        show(name.isEmpty ? "Taken out of its group" : "Grouped in \(name)")
    }

    private func saved(_ reference: Reference) {
        references.insert(reference, at: 0)
        anySaved = true
        startNudge()
        Haptics.success()
        show("Saved \(reference.slate.isEmpty ? "reference" : reference.slate)")
        nextSetup = Slate.nextSetup(scene: nextScene, in: references)
        nextName = ""
        justSavedTask?.cancel()
        withAnimation(.snappy) { justSaved = reference.id }
        justSavedTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { justSaved = nil }
        }
    }

    /// Opens a reference over the camera, from the Use as overlay button or the Recent strip.
    private func useAsOverlay(_ id: UUID, from place: String) {
        Diagnostics.log("Reference used as the overlay from \(place)")
        endNudge()
        justSaved = nil
        showingRecent = false
        selectedID = id
    }

    /// A shutter photo (with any 3D models in it): saved to Photos and offered for sending.
    private func took(_ image: UIImage) {
        if saveToPhotos {
            Task {
                // On the reset screen the photo belongs to the reference open there; otherwise to the next slate.
                let stamp = selectedID.flatMap { id in references.first { $0.id == id } }.map { PhotoStamp($0) }
                    ?? PhotoStamp(scene: nextScene, shot: nextShot, take: nextSetup, name: nextName)
                let saved = await PhotoLibrary.save([image], stamp: stamp)
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
            let saved = await PhotoLibrary.save(images, stamp: PhotoStamp(reference))
            show(saved ? "Saved \(images.count) \(images.count == 1 ? "photo" : "photos") to Photos" : "Allow Photos in Settings, Reset, Photos")
        }
    }

    private func delete(_ reference: Reference) {
        if selectedID == reference.id { selectedID = nil }
        ReferenceStore.delete(reference)
        references.removeAll { $0.id == reference.id }
        nextSetup = Slate.nextSetup(scene: nextScene, in: references)
    }

    private func show(_ message: String) { show(message, seconds: 2) }

    private func show(_ message: String, seconds: Double) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = message }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
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
        case .review(let id):
            if let reference = references.first(where: { $0.id == id }) {
                FrameReview(reference: reference, startMeasuring: reviewMeasuring) { updated in
                    if let saved = binding(for: id) { saved.wrappedValue = updated }
                    try? ReferenceStore.save(updated)
                }
            }
        case .explore(let id):
            if let reference = references.first(where: { $0.id == id }) { ExploreView(reference: reference) }
        case .cutoutScan(let id):
            if let reference = references.first(where: { $0.id == id }) { CutoutFromScan(reference: reference) }
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
            NextSlateSheet(scene: $nextScene, shot: $nextShot, setup: $nextSetup, name: $nextName, references: references)
        case .help:
            HelpView().onDisappear { seenHelp = true }
        case .gallery:
            Gallery(
                references: references, selectedID: $selectedID, thumbnails: thumbnails, onImport: importPhotos,
                onSync: { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.panel = .sync } },
                onGroup: group
            ) { action, reference in
                // Let the gallery close before the next sheet opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { perform(action, reference) }
            }
        case .sharePhoto:
            if let sharingPhoto { ShareSheet(items: [sharingPhoto]) }
        case .sync:
            ReferenceSyncView()
        case .sketch:
            EmptyView()  // the sketch has its own sheet, which carries the photo with it
        }
    }
}

/// The slate for the next reference: scene, setup letter and an optional description.
struct NextSlateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var scene: String
    @Binding var shot: String
    @Binding var setup: String
    @Binding var name: String
    let references: [Reference]
    @ObservedObject private var callSheet = CallSheetStore.shared
    @State private var showingCallSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showingCallSheet = true } label: { Label("Scan a call sheet", systemImage: "doc.text.viewfinder") }
                    if !callSheet.scenes.isEmpty {
                        Picker("From call sheet", selection: $scene) {
                            ForEach(callSheet.scenes) { item in
                                Text(item.title.isEmpty ? item.scene : "\(item.scene) · \(item.title)").tag(item.scene)
                            }
                            if !callSheet.scenes.contains(where: { $0.scene == scene }) { Text("Pick a scene").tag(scene) }
                        }
                    }
                }
                SlateFields(scene: $scene, shot: $shot, setup: $setup, name: $name)
            }
            .sheet(isPresented: $showingCallSheet) { CallSheetSheet().themed() }
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
    /// Phone upright: reference, two buttons and the shutter in four equal cells (the capture screen).
    var evenRow = false
    /// Phone upright: reference-side control, shutter, then `trailing` as two equal cells (the Reset screen).
    var shutterSecond = false
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
                            Group {
                              if shutterSecond {
                                HStack(spacing: 0) {
                                    leading().frame(maxWidth: .infinity)
                                    shutter().frame(maxWidth: .infinity)
                                    trailing()
                                }
                              } else if evenRow {
                                // Four equal cells: reference, the two buttons in `trailing`, then the shutter.
                                HStack(spacing: 0) {
                                    leading().frame(maxWidth: .infinity)
                                    trailing()
                                    shutter().frame(maxWidth: .infinity)
                                }
                            } else {
                                ZStack {
                                    shutter()
                                    HStack {
                                        leading().frame(width: 84)
                                        Spacer(minLength: 0)
                                        trailing().frame(minWidth: 84, alignment: .trailing)
                                    }
                                }
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
            colors: bars ? [.black.opacity(0), .black.opacity(0.1), .black.opacity(0.25)] : [.clear],
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
                        .font(Theme.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selection == mode ? Theme.accent : Color.white)
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
                case .record:
                    Circle().fill(Color.red).frame(width: 60, height: 60)
                    Image(systemName: "video.fill").font(Theme.font(size: 26, weight: .semibold)).foregroundStyle(.white)
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
                    .font(Theme.title3)
                    .frame(width: 50, height: 50)
                    .background(Color.white.opacity(0.15), in: Circle())
                Text(title).font(Theme.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(PressScale())
    }
}

/// The 3D models button in the bottom row (phone upright); on its side it moves to the far edge instead.
struct ModelsBesideScreenshot: View {
    let action: () -> Void
    @Environment(\.chromeVertical) private var vertical

    var body: some View {
        if !vertical { SideButton(title: "3D models", systemImage: "cube", action: action) }
    }
}

/// The 3D models button at the screen's far edge when the phone is on its side, out of the way
/// while measuring (the measuring buttons stand there).
struct ModelsEdgeButton: View {
    @ObservedObject var measurer: Measurer
    /// Hidden while a model is picked: its tools run down that edge then.
    @ObservedObject var placer: ModelPlacer
    let action: () -> Void

    var body: some View {
        if !measurer.active, placer.selectedModel == nil {
            SideButton(title: "3D models", systemImage: "cube", action: action)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .hiddenInScreenshots()
        }
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
    /// A shorter wording used when the full one has no room (never cut short with "…").
    var short: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                // Never cut short (Phil, 2026-11-10): the shorter wording, or the row around it, gives way instead.
                if !text.isEmpty {
                    if let short {
                        ViewThatFits(in: .horizontal) {
                            Text(text).lineLimit(1).fixedSize()
                            Text(short).lineLimit(1).fixedSize()
                        }
                    } else {
                        Text(text).lineLimit(1).fixedSize()
                    }
                }
            }
            .font(Theme.footnote.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(highlighted ? Theme.accent : Color.white.opacity(0.15), in: Capsule())
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
    /// Hints fade away a few seconds after they change; what the person must act on stays.
    var fadesAfter: Double? = nil
    @State private var shown = true

    var body: some View {
        Text(text)
            .font(Theme.footnote.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: 440)
            .background(tint.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 2)
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: shown)
            .task(id: text) {
                shown = true
                guard let fadesAfter else { return }
                try? await Task.sleep(for: .seconds(fadesAfter))
                if !Task.isCancelled { shown = false }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Thumbnails

/// One reference's first photo, square, with its slate on it.
/// The last few references in a row over the camera: tap one and it is the overlay (Phil, 2026-11-09).
private struct RecentStrip: View {
    let references: [Reference]
    @ObservedObject var thumbnails: Thumbnails
    let pick: (UUID) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tap one to use as the overlay")
                    .font(Theme.subheadline.bold())
                Spacer()
                Button("Close", action: close).font(Theme.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(references) { reference in
                        Button { pick(reference.id) } label: {
                            VStack(spacing: 4) {
                                ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 64)
                                Text(reference.slate.isEmpty ? "Reference" : reference.slate)
                                    .font(Theme.font(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .buttonStyle(PressScale())
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }
}

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
            if let reference {
                // The take number, big enough to read at a glance (Phil, 2026-11-05), with what the photo
                // is called and any note under it, since the photo itself is already showing (Phil, 2026-11-07).
                VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(reference.number)
                        .font(Theme.font(size: max(14, size * (size >= 100 ? 0.2 : 0.32)), weight: .heavy).monospacedDigit())
                    if size >= 100 {
                        Spacer(minLength: 0)
                        Text(timestamp(reference.created)).font(Theme.font(size: 13).monospacedDigit())
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                ForEach(Array(reference.captionLines(count: size >= 80 ? 2 : 1).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Theme.font(size: size >= 100 ? 12 : size >= 80 ? 12 : 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Theme.accent)
                }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .frame(width: size)
                .foregroundStyle(.white)
                // Soft shadows round the letters instead of a hard block behind them (Phil, 2026-11-08).
                .shadow(color: .black.opacity(0.95), radius: 1.5, x: 0, y: 1)
                .shadow(color: .black.opacity(0.8), radius: 5, x: 0, y: 0)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topLeading) {
            if reference?.hero == true {
                Image(systemName: "star.fill")
                    .font(Theme.font(size: max(11, size * 0.2)))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .padding(3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : Color.white.opacity(0.8), lineWidth: selected ? 3 : 1))
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
    enum Action { case takeLog, compare, review, measure, explore, slate, pdf, delete, photos, sketch, hero, cutout, edit }

    @Environment(\.dismiss) private var dismiss
    /// Oldest first, so the newest is the last page, as in Photos.
    private let ordered: [Reference]
    @Binding var selectedID: UUID?
    @ObservedObject var thumbnails: Thumbnails
    let onImport: ([PhotosPickerItem]) -> Void
    let onSync: () -> Void
    /// Puts the references into a sub-group of their scene ("" takes them out of any group).
    let onGroup: ([UUID], String) -> Void
    let action: (Action, Reference) -> Void
    @State private var current: UUID?
    @State private var showingGrid = false
    @State private var selecting = false
    @State private var chosen: Set<UUID> = []
    @State private var naming = false
    @State private var showingCallSheet = false
    @ObservedObject private var callSheet = CallSheetStore.shared
    @State private var picked: [PhotosPickerItem] = []
    @State private var query = ""
    @ObservedObject private var search = ImageIndex.shared

    init(
        references: [Reference], selectedID: Binding<UUID?>, thumbnails: Thumbnails,
        onImport: @escaping ([PhotosPickerItem]) -> Void, onSync: @escaping () -> Void = {},
        onGroup: @escaping ([UUID], String) -> Void = { _, _ in },
        action: @escaping (Action, Reference) -> Void
    ) {
        ordered = references.sorted { $0.created < $1.created }
        _selectedID = selectedID
        self.thumbnails = thumbnails
        self.onImport = onImport
        self.onSync = onSync
        self.onGroup = onGroup
        self.action = { act, reference in Self.remember(reference.id); action(act, reference) }
        _current = State(initialValue: Self.lastViewed(in: ordered) ?? selectedID.wrappedValue ?? ordered.last?.id)
    }

    /// Phil, 2026-11-10: coming back to the references opens on the last one looked at, unless a
    /// newer reference has been taken since, which then comes first as before.
    private static let lastViewedKey = "gallery.lastViewed"
    private static let lastViewedAtKey = "gallery.lastViewedAt"

    private static func lastViewed(in ordered: [Reference]) -> UUID? {
        let defaults = UserDefaults.standard
        guard let text = defaults.string(forKey: lastViewedKey), let id = UUID(uuidString: text),
              ordered.contains(where: { $0.id == id }) else { return nil }
        let seen = Date(timeIntervalSince1970: defaults.double(forKey: lastViewedAtKey))
        if let newest = ordered.last, newest.created > seen { return nil }
        return id
    }

    private static func remember(_ id: UUID?) {
        guard let id else { return }
        UserDefaults.standard.set(id.uuidString, forKey: lastViewedKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastViewedAtKey)
    }

    private var shown: Reference? { ordered.first { $0.id == current } }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The references that match what is typed in the search box (all of them when it is empty).
    private var visible: [Reference] { searching ? ordered.filter { search.matches(query, $0) } : ordered }

    var body: some View {
        NavigationStack {
            Group {
                if ordered.isEmpty {
                    ContentUnavailableView(
                        "No references yet", systemImage: "camera.viewfinder",
                        description: Text("Close this and tap the shutter to save one, or import photos with the arrow at the top."))
                } else if showingGrid || searching {
                    grid
                } else {
                    pager
                }
            }
            .background(Color.black.ignoresSafeArea())
            // Phil, 2026-11-10: the one-at-a-time page shows as much photo as it can; search lives with all references.
            .modifier(SearchWhen(on: showingGrid || searching, text: $query))
            .task { search.refresh(ordered) }
            .navigationTitle(showingGrid || searching ? "References" : ((shown?.slate.isEmpty == false ? shown?.slate : shown?.title) ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    let paging = !(showingGrid || searching) && shown != nil
                    if !paging {
                        Button { showingCallSheet = true } label: { Image(systemName: "doc.text.viewfinder") }
                            .accessibilityLabel("Call sheet")
                    }
                    PhotosPicker(selection: $picked, matching: .images) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import from Photos")
                    if !paging {
                        Button {
                            dismiss()
                            onSync()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .accessibilityLabel("Sync with nearby phones")
                    }
                    Button {
                        withAnimation { showingGrid.toggle() }
                    } label: {
                        Image(systemName: showingGrid ? "photo" : "square.grid.2x2")
                    }
                    .accessibilityLabel(showingGrid ? "One at a time" : "All references and search")
                    if showingGrid {
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            chosen = []
                        }
                    }
                    if let shown, !showingGrid { menu(for: shown) }
                }
            }
            .sheet(isPresented: $showingCallSheet) { CallSheetSheet().themed() }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                onImport(items)
                picked = []
                dismiss()
            }
        }
    }

    /// Arrows at the sides so it is clear the pictures page sideways (swiping works too).
    private var pageArrows: some View {
        let position = ordered.firstIndex { $0.id == current } ?? 0
        return HStack {
            if position > 0 {
                Button { withAnimation { current = ordered[position - 1].id } } label: { arrow("chevron.left") }
            }
            Spacer()
            if position < ordered.count - 1 {
                Button { withAnimation { current = ordered[position + 1].id } } label: { arrow("chevron.right") }
            }
        }
        .padding(.horizontal, 6)
    }

    private func arrow(_ name: String) -> some View {
        Image(systemName: name)
            .font(Theme.font(size: 20, weight: .bold)).foregroundStyle(.white)
            .frame(width: 40, height: 64)
            .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    private var pager: some View {
        VStack(spacing: 8) {
            TabView(selection: $current) {
                ForEach(ordered) { reference in
                    GalleryPage(reference: reference)
                        .tag(Optional(reference.id))
                        .onTapGesture(count: 2) { load(reference) }
                        .contextMenu { menuItems(for: reference) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .topTrailing) {
                if let position = ordered.firstIndex(where: { $0.id == current }), ordered.count > 1 {
                    Text("\(position + 1) of \(ordered.count)")
                        .font(Theme.footnote.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .overlay { pageArrows }
            .overlay(alignment: .center) { Color.clear.frame(width: 1, height: 1).holdHint("galleryPhoto2", "Hold the photo for options", above: true, delay: 0.8) }
            filmstrip
            if let shown {
                // Phil, 2026-11-10: one height for every button, evenly spaced, and a Load label that is never cut short.
                HStack(spacing: 10) {
                    pagerIcon("ruler", "Dimensions") { dismiss(); action(.measure, shown) }
                    pagerIcon("pencil.tip.crop.circle", "Draw") { dismiss(); action(.sketch, shown) }
                    pagerIcon("wand.and.stars", "Edit photo") { dismiss(); action(.edit, shown) }
                    Button { load(shown) } label: {
                        Label("Load", systemImage: "camera.viewfinder")
                            .font(Theme.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(Theme.onAccent)
                    }
                    .buttonStyle(PressScale())
                }
                .frame(maxWidth: 400)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    private func pagerIcon(_ symbol: String, _ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(Theme.font(size: 20, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(Color.white.opacity(0.14), in: Circle())
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(name)
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
                            ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 62, selected: current == reference.id)
                        }
                        .id(reference.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 3)
            }
            .frame(height: 70)
            .onAppear { Self.remember(current); if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, id in
                Self.remember(id)
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if searching && visible.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                if search.remaining > 0 {
                    Label("Looking at your pictures so they can be searched… \(search.remaining) to go", systemImage: "sparkle.magnifyingglass")
                        .font(Theme.footnote).foregroundStyle(.secondary)
                }
                let heroes = visible.filter(\.hero)
                if !heroes.isEmpty {
                    Label("Heroes", systemImage: "star.fill").font(Theme.headline).foregroundStyle(Theme.accent)
                    section(title: nil, references: heroes)
                }
                ForEach(gridScenes, id: \.self) { scene in
                    Text(sceneHeading(scene)).font(Theme.headline)
                    let inScene = setups(in: scene)
                    if inScene.isEmpty {
                        Text("Nothing recorded yet").font(Theme.footnote).foregroundStyle(.secondary)
                    }
                    let groups = Array(Set(inScene.map(\.group).filter { !$0.isEmpty }))
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    section(title: groups.isEmpty ? nil : "Not grouped", references: inScene.filter { $0.group.isEmpty })
                    ForEach(groups, id: \.self) { name in
                        section(title: name, references: inScene.filter { $0.group == name })
                    }
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack(spacing: 12) {
                    Button { naming = true } label: {
                        Label("Group \(chosen.count)", systemImage: "rectangle.stack.badge.plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .font(Theme.headline)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
                    .disabled(chosen.isEmpty)
                    Button {
                        onGroup(Array(chosen), "")
                        chosen = []
                        selecting = false
                    } label: { Text("Ungroup").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .font(Theme.headline)
                        .disabled(chosen.isEmpty)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $naming) {
            GroupNameSheet(existing: Array(Set(ordered.map(\.group).filter { !$0.isEmpty })).sorted()) { name in
                onGroup(Array(chosen), name)
                chosen = []
                selecting = false
            }
            .themed()
            .presentationDetents([.medium])
        }
    }

    /// One heading and its tiles; in selection mode a tap ticks a tile instead of opening it.
    @ViewBuilder
    private func section(title: String?, references: [Reference]) -> some View {
        if !references.isEmpty {
            if let title { Text(title).font(Theme.subheadline.bold()).foregroundStyle(Theme.accent) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(references) { reference in
                    Button {
                        Haptics.tap()
                        if selecting {
                            if chosen.contains(reference.id) { chosen.remove(reference.id) } else { chosen.insert(reference.id) }
                        } else {
                            current = reference.id
                            query = ""
                            withAnimation { showingGrid = false }
                        }
                    } label: {
                        ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 100, selected: selecting ? chosen.contains(reference.id) : selectedID == reference.id)
                            .overlay(alignment: .topTrailing) {
                                if selecting {
                                    Image(systemName: chosen.contains(reference.id) ? "checkmark.circle.fill" : "circle")
                                        .font(Theme.title3)
                                        .foregroundStyle(chosen.contains(reference.id) ? Theme.accent : Color.white)
                                        .shadow(radius: 2)
                                        .padding(4)
                                }
                            }
                    }
                    .accessibilityLabel(reference.title)
                    .contextMenu {
                        Button {
                            selecting = true
                            chosen = [reference.id]
                        } label: { Label("Select", systemImage: "checkmark.circle") }
                        menuItems(for: reference)
                    }
                }
            }
        }
    }

    /// The scenes shown as folders, newest first: ones with references, and ones a call sheet listed that have none yet.
    private var gridScenes: [String] {
        var scenes = Set(visible.map(\.scene))
        if !searching { callSheet.scenes.forEach { scenes.insert($0.scene) } }
        return scenes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.reversed()
    }

    private func sceneHeading(_ scene: String) -> String {
        if scene.isEmpty { return "No scene" }
        if let title = callSheet.title(for: scene) { return "Scene \(scene) · \(title)" }
        return "Scene \(scene)"
    }

    private func setups(in scene: String) -> [Reference] {
        visible
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
            Section {
                Button { showingCallSheet = true } label: { Label("Call sheet", systemImage: "doc.text.viewfinder") }
                Button { dismiss(); onSync() } label: { Label("Sync with nearby phones", systemImage: "arrow.triangle.2.circlepath") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    /// Short, one-line rows so the whole menu fits on screen without scrolling (Phil, 2026-11-05).
    @ViewBuilder
    private func menuItems(for reference: Reference) -> some View {
        if reference.keyframes.count > 1, !reference.photoOnly {
            Button { dismiss(); action(.cutout, reference) } label: { Label("Cut-out from this scan", systemImage: "person.crop.rectangle.stack") }
        }
        Button { dismiss(); action(.hero, reference) } label: { Label(reference.hero ? "Remove hero star" : "Hero", systemImage: reference.hero ? "star.slash" : "star") }
        Button { dismiss(); action(.review, reference) } label: { Label("Review frames", systemImage: "rectangle.stack") }
        Button { dismiss(); action(.sketch, reference) } label: { Label("Sketch", systemImage: "pencil.tip.crop.circle") }
        Button { dismiss(); action(.edit, reference) } label: { Label("Edit photo (select, cut out)", systemImage: "wand.and.stars") }
        Button { dismiss(); action(.slate, reference) } label: { Label("Edit slate", systemImage: "pencil") }
        // The long menu scrolled badly and snapped back to the top (Phil, 2026-11-08), so the rarer ones are tucked away.
        Menu {
            Button { dismiss(); action(.takeLog, reference) } label: { Label("Take log", systemImage: "list.number") }
            Button { dismiss(); action(.compare, reference) } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
            if ExploreView.offered {
                Button { dismiss(); action(.explore, reference) } label: { Label("Explore in 3D", systemImage: "view.3d") }
            }
        } label: { Label("More", systemImage: "ellipsis.circle") }
        Menu {
            Button { dismiss(); action(.pdf, reference) } label: { Label("PDF report", systemImage: "doc.richtext") }
            Button { dismiss(); action(.photos, reference) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle.angled") }
        } label: { Label("Share", systemImage: "square.and.arrow.up") }
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
            // Phil, 2026-11-10: one short line, so the photo gets the room. "Hold for options" is a one-off hint now.
            Text(details)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        let date = reference.created.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        var parts = [date, takes]
        if reference.hasDepth { parts.append("LiDAR") }
        if reference.photoOnly { parts.append("Imported") }
        if !reference.name.isEmpty { parts.insert(reference.name, at: 0) }
        if !reference.slate.isEmpty { parts.insert(reference.slate, at: 0) }
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
    case snapshot, walk

    var label: String {
        switch self {
        case .snapshot: return "MANUAL SCAN"
        case .walk: return "AUTO SCAN"
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
    @StateObject private var freeScanner = FreeScanner()
    /// Landscape taps on the shutter sometimes never reached it (Phil, 2026-11-08), as on the reference screen:
    /// a tap inside its frame runs it from here too.
    @State private var tapCatcher = WindowTapCatcher()
    @State private var lastShutter = Date.distantPast
    @StateObject private var recorder = Recorder()
    let scene: String
    var shot = ""
    let setup: String
    let name: String
    let thumbnail: AnyView
    let open: (CameraHome.Panel) -> Void
    let onSaved: (Reference) -> Void
    let onPhoto: (UIImage) -> Void
    let showToast: (String) -> Void
    @AppStorage("captureMode") private var mode: CaptureMode = .snapshot
    /// Which lens a snapshot uses; anything but 1× is a plain photo (LensCamera.swift).
    @AppStorage("snapshotLens") private var lens = 1.0
    @State private var lensBusy = false
    @AppStorage("useLiDAR") private var useLiDAR = true
    @AppStorage("leftHanded") private var leftHanded = false
    @Environment(\.verticalSizeClass) private var verticalSize
    @State private var holder = CameraViewHolder()
    @State private var importingModels = false
    @State private var choosingModel = false
    @State private var makingCutout = false
    @State private var choosingExample = false
    @State private var justSaved = false
    /// The "get its bearings" hint shows for a few seconds, then gives way to the usual line.
    @State private var bearingsHintDone = false
    @State private var bearingsTask: Task<Void, Never>?

    private var slate: String { Reference.label(scene: scene, setup: setup, shot: shot) }

    private func topBar(lidarWord: Bool, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            TopPill(text: "Next: \(slate.isEmpty ? "no slate" : slate)", systemImage: "pencil") {
                open(.nextSlate)
            }
            .disabled(recorder.capturing)
            // A bump when the take number moves on, so the change is noticed.
            .scaleEffect(justSaved ? 1.15 : 1, anchor: .leading)
            .animation(.spring(duration: 0.35, bounce: 0.5), value: justSaved)
            Spacer()
            if Recorder.lidarAvailable {
                TopPill(text: lidarWord ? "LiDAR" : "", systemImage: "dot.circle.viewfinder", highlighted: useLiDAR) {
                    useLiDAR.toggle()
                }
                .disabled(recorder.capturing)
                .accessibilityLabel(useLiDAR ? "LiDAR on" : "LiDAR off")
            }
            TorchButton()
            // Works while a scan or recording is going, too.
            MeasureToggle(measurer: recorder.measurer)
            if FreeScanner.supported {
                Button { freeScanner.start(recorder) } label: { Image(systemName: "cube.transparent").font(Theme.title3) }
                    .disabled(recorder.capturing)
                    .accessibilityLabel("Scan")
            }
            Button {
                Diagnostics.log("Clean view started")
                ScreenshotMode.shared.viewing = true
            } label: { Image(systemName: "eye.slash").font(Theme.title3) }
                .accessibilityLabel("Hide controls")
            Button { open(.help) } label: { Image(systemName: "questionmark.circle").font(Theme.title3) }
                .accessibilityLabel("Help")
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
    }

    var body: some View {
        CameraLayout(evenRow: true) {
            // Phil, 2026-11-10: nothing clipped. The full row when it fits, then tighter, then LiDAR as its lit icon only.
            ViewThatFits(in: .horizontal) {
                topBar(lidarWord: true, spacing: 10)
                topBar(lidarWord: true, spacing: 6)
                topBar(lidarWord: false, spacing: 6)
            }
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
                    Banner(text: status, tint: recorder.capturing ? .red : .black,
                           fadesAfter: recorder.capturing || recorder.pendingSave || recorder.saving ? nil : 5)
                        .onAppear { timeBearingsHint(recorder.trackingNormal) }
                        .onChange(of: recorder.trackingNormal) { _, normal in timeBearingsHint(normal) }
                    Spacer()
                    TorchDial()
                    MeasureHint(measurer: recorder.measurer)
                    MeasureBar(measurer: recorder.measurer)
                    ModelOverlay(placer: recorder.placer)
                    if let error = recorder.error {
                        Text(error).font(Theme.callout).padding(10)
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
                shutterOnce()
            }
            .modifier(WindowFrame { frame in tapCatcher.targets["Capture shutter"] = (frame, { shutterOnce() }) })
            .overlay(alignment: verticalSize == .compact ? (leftHanded ? .trailing : .leading) : .top) {
                if mode == .snapshot, !recorder.capturing {
                    // On its side the lenses stand in a column beside the shutter, clear of the mode words.
                    if verticalSize == .compact {
                        LensChooser(zoom: $lens, vertical: true, register: { name, frame, action in tapCatcher.targets[name] = (frame, action) })
                            .offset(x: leftHanded ? 52 : -52).disabled(lensBusy)
                    } else {
                        LensChooser(zoom: $lens).offset(y: -44).disabled(lensBusy)
                    }
                }
            }
            .disabled(recorder.saving || lensBusy)
            .accessibilityLabel(shutterLabel)
        } trailing: {
            WithScreenshot(camera: { holder.view }, toast: showToast, size: 74, evenCells: true,
                           register: { frame, action in tapCatcher.targets["Screenshot"] = (frame, action) }) {
                if recorder.capturing {
                    ViewsCounter(count: recorder.keyframeCount)
                } else {
                    // On its side the cube moves to the opposite edge of the screen (see the overlay below).
                    ModelsBesideScreenshot { choosingModel = true }
                }
            }
        }
        .overlay(alignment: leftHanded ? .bottomTrailing : .bottomLeading) {
            if verticalSize == .compact, !recorder.capturing {
                ModelsEdgeButton(measurer: recorder.measurer, placer: recorder.placer) { choosingModel = true }
            }
        }
        .overlay { MeasurePointer(measurer: recorder.measurer) }
        .overlay { MeasureEntry(measurer: recorder.measurer).hiddenInScreenshots() }
        .overlay { CleanViewControls(snap: shutterOnce) }
        // Without the controls, a volume button takes a snapshot too.
        .modifier(CaptureButtonAction(action: volumeShutter))
        .confirmationDialog("Add to the room", isPresented: $choosingModel) {
            Button("3D model (USDZ, OBJ or STL)") { importingModels = true }
            Button("Cut-out from photos") { makingCutout = true }
            Button("Examples: people, set pieces") { choosingExample = true }
        }
        .sheet(isPresented: $makingCutout) { CutoutMaker(placer: recorder.placer).themed() }
        .sheet(isPresented: $choosingExample) { ExamplesSheet(placer: recorder.placer).themed() }
        .fileImporter(isPresented: $importingModels, allowedContentTypes: ModelImport.pickerTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { recorder.placer.add(from: urls) }
        }
        .overlay { FreeScanOverlay(scanner: freeScanner) { recorder.placer.add(from: [$0]) } }
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
        .onAppear { tapCatcher.install() }
        .onDisappear {
            ScreenshotMode.shared.viewing = false
            tapCatcher.remove()
            recorder.stop()
        }
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
        case .snapshot: return "Save reference"
        case .walk: return recorder.capturing ? "Stop and save" : "Start recording"
        }
    }

    /// The camera view as it looks, with any 3D models in it.
    private func takePhoto() {
        guard let image = Screenshot.capture(camera: holder.view) else { return }
        onPhoto(image)
    }

    private var shutterStyle: ShutterButton.Style {
        switch mode {
        case .snapshot: return .photo
        case .walk: return recorder.capturing && !recorder.pendingSave ? .stop : .record
        }
    }

    /// The button and the window's tap watcher can both fire for one tap: the second within 0.6 s is ignored.
    private func volumeShutter() {
        if ScreenshotMode.shared.viewing { shutterOnce() }
    }

    private func shutterOnce() {
        guard !recorder.saving, Date().timeIntervalSince(lastShutter) > 0.6 else { return }
        lastShutter = Date()
        Diagnostics.log("Capture shutter pressed (\(Screen.orientation.isLandscape ? "landscape" : "portrait"), \(mode))")
        shutterTapped()
    }

    /// A snapshot on the 0.5× or 3× lens: tracking pauses, the photo is taken, tracking carries on.
    private func lensSnapshot() {
        guard let chosen = LensCamera.lenses.first(where: { $0.zoom == lens }), !lensBusy else { return }
        lensBusy = true
        let configuration = recorder.session.configuration
        recorder.session.pause()
        Diagnostics.log("Lens snapshot on \(chosen.label)")
        Task {
            let data = await LensCamera.photo(chosen)
            if let configuration { recorder.session.run(configuration) }
            lensBusy = false
            guard let data else {
                showToast("Couldn't take the \(chosen.label) photo")
                return
            }
            do {
                var reference = try PhotoLibrary.makeReference(from: data, scene: scene, setup: setup)
                reference.shot = shot
                reference.name = name.isEmpty ? "\(chosen.label) photo" : name
                try ReferenceStore.save(reference)
                if let image = UIImage(data: data) { onPhoto(image) }
                onSaved(reference)
            } catch {
                Diagnostics.log("Lens snapshot could not be saved: \(error)")
                showToast("Couldn't save the \(chosen.label) photo")
            }
        }
    }

    private func shutterTapped() {
        switch mode {
        case .snapshot where lens != 1 && LensCamera.lenses.contains(where: { $0.zoom == lens }) && !recorder.capturing:
            lensSnapshot()
        case .snapshot:
            takePhoto()
            // Another tap while waiting for the map adds a second view to the same reference.
            if !recorder.capturing {
                recorder.autoCapture = false
                recorder.begin(scene: scene, setup: setup, name: name, shot: shot)
            }
            recorder.captureNow()
            recorder.saveWhenReady()
        case .walk:
            if recorder.capturing {
                recorder.saveWhenReady()
            } else {
                recorder.autoCapture = true
                recorder.begin(scene: scene, setup: setup, name: name, shot: shot)
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
    /// Where an imported photo sits over the camera (moved, scaled, turned, mirrored by hand).
    @State private var photoPose = PhotoPose()
    /// Phil, 2026-11-09: an imported photo can be masked by hand so only part of it (the props on the table)
    /// shows over the camera. White where it shows; saved beside the photo.
    @State private var ghostMask: UIImage?
    @State private var maskingGhost = false
    /// Other references laid over this one (Layers.swift).
    let others: [Reference]
    let added: (Reference) -> Void
    @State private var editingPhoto: EditTarget?
    @State private var layers: [OverlayLayer] = []
    @State private var layerPictures: [UUID: (photo: UIImage, mask: UIImage?)] = [:]
    @State private var addingLayer = false
    /// While swiping the ghost strength, the cursor shows.
    @State private var swipingStrength = false
    /// While swiping, how far towards now the view is, for the THEN and NOW tags; nil hides them.
    @State private var tagsValue: Double?
    /// The little swipe demonstration shown when a reference loads.
    @State private var showSwipeHint = true
    /// A one-time tip near the top (edge guides, pause, first measurement), gone after nine seconds.
    @State private var tip: String?
    @State private var tagsTask: Task<Void, Never>?
    /// While paused: 0 shows the reference, 1 the frozen live picture.
    @State private var toNow = 1.0
    @State private var importingModel = false
    @State private var makingCutout = false
    @State private var choosingExample = false
    @State private var notingTake: Take?
    @State private var holder = CameraViewHolder()
    @State private var tapCatcher = WindowTapCatcher()
    @State private var lastPauseToggle = LastTime()
    @State private var lastShutter = LastTime()
    @State private var lastLog = LastTime()

    init(
        reference: Binding<Reference>, others: [Reference] = [], added: @escaping (Reference) -> Void = { _ in }, thumbnails: Thumbnails,
        open: @escaping (CameraHome.Panel) -> Void, close: @escaping () -> Void,
        showToast: @escaping (String) -> Void, onPhoto: @escaping (UIImage) -> Void
    ) {
        _reference = reference
        self.others = others
        self.added = added
        _restorer = StateObject(wrappedValue: Restorer(reference: reference.wrappedValue))
        self.thumbnails = thumbnails
        self.open = open
        self.close = close
        self.showToast = showToast
        self.onPhoto = onPhoto
    }

    // The layer picker, the Edit window and the photo mask are added apart from the rest, so the compiler can check
    // the body in time.
    var body: some View { editingSheets(watching(stage)) }

    private var stage: some View {
        CameraLayout(bars: false, shutterSecond: true) {
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
            ShutterButton(style: .photo, ring: restorer.matched ? .green : .white) { snapshotOnce() }
                .modifier(WindowFrame { frame in tapCatcher.targets["Shutter"] = (frame, { snapshotOnce() }) })
                .disabled(restorer.status != .ready || restorer.paused)
                .opacity(restorer.paused ? 0 : restorer.status == .ready ? 1 : 0.5)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .accessibilityLabel("Snapshot")
        } trailing: {
            WithScreenshot(camera: { holder.view }, toast: showToast, size: 74, evenCells: true, screenshotFirst: true,
                           register: { frame, action in tapCatcher.targets["Screenshot"] = (frame, action) }) {
                if leftHanded { logButton } else { pauseButton }
            }
        }
        .overlay { MeasurePointer(measurer: restorer.measurer) }
        .overlay { MeasureEntry(measurer: restorer.measurer).hiddenInScreenshots() }
        .sheet(item: $notingTake) { take in
            TakeEditor(take: take, slate: reference.slate) { logged in
                reference.takes.append(logged)
                save()
            }
            .themed()
        }
        .sheet(isPresented: $makingCutout) { CutoutMaker(placer: restorer.placer).themed() }
        .sheet(isPresented: $choosingExample) { ExamplesSheet(placer: restorer.placer).themed() }
        .fileImporter(isPresented: $importingModel, allowedContentTypes: ModelImport.pickerTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { restorer.placer.add(from: urls) }
        }
        .onAppear {
            tapCatcher.install()
            layers = OverlayLayer.load(for: reference.id).filter { layer in others.contains { $0.id == layer.reference } }
            loadLayerPictures()
            if reference.photoOnly {
                photoPose = PhotoPose.load(reference.id)
                ghostMask = GhostMask.load(reference.id)
                showTip("Line the photo up: two fingers move it, pinch to size, twist to turn. Double tap puts it back. Flip is in the ••• menu.", key: "tip.photoPose")
            }
            // Checked under the same light it was shot with.
            if let level = reference.torch, Torch.shared.available {
                Torch.shared.set(on: true, level: level)
                showToast("Torch on at \(Int((level * 100).rounded()))%, as when this was shot")
            }
        }
        .onDisappear {
            ScreenshotMode.shared.viewing = false
            tapCatcher.remove()
            restorer.stop()
        }
    }

    /// Shows a tip once ever (per key), for nine seconds.
    /// Reads each layer's photo once, off the main thread.
    private func loadLayerPictures() {
        let wanted = layers.compactMap { layer in others.first { $0.id == layer.reference } }
            .filter { layerPictures[$0.id] == nil }
        guard !wanted.isEmpty else { return }
        Task {
            for reference in wanted {
                let picture = await Task.detached(priority: .userInitiated) { OverlayLayer.picture(of: reference) }.value
                if let picture { layerPictures[reference.id] = picture }
            }
        }
    }

    private func showTip(_ text: String, key: String) {
        guard !UserDefaults.standard.bool(forKey: key), tip == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        withAnimation(.snappy) { tip = text }
        Task {
            try? await Task.sleep(for: .seconds(9))
            withAnimation(.snappy) { if tip == text { tip = nil } }
        }
    }

    private var logButton: some View {
        SideButton(title: "Log T\(reference.nextTakeNumber)", systemImage: "checkmark.circle", tint: Theme.accent) {
            logTakeOnce()
        }
        .modifier(WindowFrame { frame in tapCatcher.targets["Log"] = (frame, { logTakeOnce() }) })
        .shadow(color: .black.opacity(0.6), radius: 3)
        .holdHint("logNote", "Hold: add a note", above: true, delay: 9)
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
            Button { close() } label: { Image(systemName: "xmark").font(Theme.title3) }
                .accessibilityLabel("Back to recording")
            // This reference: tap to hide or show the ghost, press and hold for all references.
            ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 34, selected: ghostShown)
                .opacity(ghostShown ? 1 : 0.5)
                .onTapGesture {
                    Haptics.tap()
                    ghostShown.toggle()
                }
                .onLongPressGesture { open(.gallery) }
                .holdHint("resetThumb", "Hold: all references", delay: 2.5)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(ghostShown ? "Hide the ghost" : "Show the ghost")
            TopPill(text: reference.slate.isEmpty ? "Take \(reference.nextTakeNumber)" : "\(reference.slate) · T\(reference.nextTakeNumber)",
                    short: "Take \(reference.nextTakeNumber)") {
                open(.takeLog(reference.id))
            }
            Spacer(minLength: 0)
            if restorer.paused {
                // Small, in the top bar, so it covers none of the picture.
                Text("PAUSED")
                    .font(Theme.caption.weight(.heavy))
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
                        Image(systemName: "square.2.layers.3d").font(Theme.title3)
                            .foregroundStyle(restorer.showDifferences ? Theme.accent : Color.white)
                    }
                    .accessibilityLabel(restorer.showDifferences ? "Hide LiDAR changes" : "Show LiDAR changes")
                }
                if !reference.photoOnly {
                    Button { restorer.toggleLock() } label: {
                        Image(systemName: restorer.lockedKeyframe == nil ? "lock.open" : "lock.fill")
                            .font(Theme.title3)
                            .foregroundStyle(restorer.lockedKeyframe == nil ? Color.white : Theme.accent)
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
                if reference.photoOnly {
                    Button {
                        photoPose.flipped.toggle()
                        photoPose.save(reference.id)
                    } label: { Label("Flip photo", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    if !photoPose.isStraight {
                        Button {
                            photoPose = PhotoPose()
                            photoPose.save(reference.id)
                        } label: { Label("Put photo back", systemImage: "arrow.uturn.backward") }
                    }
                    Button {
                        if let photo = restorer.startPhoto { editingPhoto = EditTarget(photo: photo, reference: reference) }
                    } label: { Label("Edit photo (select, show only part)", systemImage: "wand.and.stars") }
                    if ghostMask != nil {
                        Button {
                            GhostMask.remove(reference.id)
                            ghostMask = nil
                        } label: { Label("Show the whole photo", systemImage: "photo") }
                    }
                }
                Button { open(.gallery) } label: { Label("References", systemImage: "photo.on.rectangle") }
                if !others.isEmpty {
                    Button { addingLayer = true } label: { Label("Add a layer", systemImage: "square.3.layers.3d") }
                }
                Button { importingModel = true } label: { Label("Add 3D model", systemImage: "cube") }
                    .disabled(restorer.status != .ready)
                Button { makingCutout = true } label: { Label("Add cut-out from photos", systemImage: "figure.stand") }
                    .disabled(restorer.status != .ready)
                Button { choosingExample = true } label: { Label("Add an example (people, set pieces)", systemImage: "figure.stand.dress") }
                    .disabled(restorer.status != .ready)
                if ExploreView.offered {
                    Button { open(.explore(reference.id)) } label: { Label("Explore in 3D", systemImage: "view.3d") }
                }
                Button { open(.review(reference.id)) } label: { Label("Review frames", systemImage: "rectangle.stack") }
                Button { open(.compare(reference.id)) } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                Button { open(.takeLog(reference.id)) } label: { Label("Take log", systemImage: "list.number") }
                Button { open(.pdf(reference.id)) } label: { Label("Share PDF report", systemImage: "square.and.arrow.up") }
                Button { open(.slate(reference.id)) } label: { Label("Edit slate", systemImage: "pencil") }
                Button { open(.sync) } label: { Label("Sync phones", systemImage: "arrow.triangle.2.circlepath") }
                Toggle(isOn: $leftHanded) { Label("Left-handed", systemImage: "hand.raised") }
                Button {
                    HintStore.resetAll()
                    showToast("Tips will show again")
                } label: { Label("Show tips again", systemImage: "lightbulb") }
                Button {
                    Diagnostics.log("Clean view started")
                    ScreenshotMode.shared.viewing = true
                } label: { Label("Hide controls", systemImage: "eye.slash") }
                Button { open(.help) } label: { Label("Help", systemImage: "questionmark.circle") }
            } label: {
                Image(systemName: "ellipsis.circle").font(Theme.title3)
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
                            .mask { if let ghostMask { Image(uiImage: ghostMask).resizable() } else { Color.white } }
                            .aspectRatio(photo.size, contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .posed(photoPose)
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
                if ghostShown, !layers.isEmpty {
                    LayerPictures(layers: layers, pictures: layerPictures, size: geometry.size)
                }
                if !restorer.paused, reference.models.isEmpty, !measuring, reference.photoOnly {
                    // An imported photo: one finger sideways for strength, two fingers to move, pinch, twist; double tap resets.
                    PhotoAdjustLayer(
                        pose: $photoPose,
                        strength: Binding(get: { 1 - ghostOpacity }, set: { ghostOpacity = 1 - $0 }),
                        swiping: { active in
                            if active {
                                if !swipingStrength { withAnimation(.easeOut(duration: 0.15)) { swipingStrength = true } }
                            } else {
                                withAnimation(.easeOut(duration: 0.4).delay(0.8)) { swipingStrength = false }
                            }
                        },
                        changed: { photoPose.save(reference.id) })
                } else if !restorer.paused, reference.models.isEmpty, !measuring {
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
                if !layers.isEmpty, !restorer.paused {
                    HStack {
                        Spacer()
                        LayerChips(layers: $layers, references: others, thumbnails: thumbnails)
                            .padding(.trailing, 10)
                    }
                    .frame(maxHeight: .infinity)
                }
                VStack(spacing: 8) {
                    if restorer.status == .relocalizing, !reference.photoOnly, let photo = restorer.startPhoto, !restorer.paused {
                        findingHint(photo)
                    }
                    if let headline, !restorer.paused {
                        Banner(text: headline)
                    }
                    if let tip {
                        Banner(text: tip, fadesAfter: 8)
                            .transition(.opacity)
                    }
                    Spacer()
                    if showSwipeHint, !restorer.paused, reference.models.isEmpty, !measuring, ghostShown {
                        SwipeHint()
                            .transition(.opacity)
                    }
                    if !showSwipeHint, !swipingStrength, !restorer.paused, reference.models.isEmpty, !measuring, ghostShown {
                        StrengthIndicator(value: 1 - ghostOpacity)
                    }
                    if restorer.paused {
                        ScrubCursor(value: toNow, start: "THEN", end: "NOW")
                    } else {
                        TorchDial()
                        MeasureHint(measurer: restorer.measurer)
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
                // Every reference loads half ghost, half live.
                ghostOpacity = 0.5
                restorer.setGhostOpacity(ghostOpacity)
                restorer.start()
                showSwipeHint = true
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    withAnimation(.easeOut(duration: 0.5)) { showSwipeHint = false }
                }
            }
            .onChange(of: swipingStrength) { _, swiping in
                if swiping { withAnimation { showSwipeHint = false } }
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
                .font(Theme.caption)
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

    /// The button and the window's tap watcher can both fire for one tap (the button alone never gets it in
    /// landscape on some phones), so these act once per tap, and not while paused or still finding the room.
    /// What the Reset screen keeps an eye on: models, marks, pause, status.
    private func watching<V: View>(_ content: V) -> some View {
        content
            .onReceive(restorer.placer.$models.dropFirst()) { models in
                reference.models = models
                save()
            }
            .onReceive(restorer.measurer.$active) { measuring = $0 }
            .onReceive(restorer.measurer.$revision.dropFirst()) { _ in
                if !restorer.measurer.measurements.isEmpty {
                    showTip("Tap Exact in the ruler bar to make sizes exact. Hold a line's end, then drag, to move it.", key: "tip.measure")
                }
                reference.measurements = restorer.measurer.measurements
                reference.notes = restorer.measurer.notes
                reference.removedMarks = restorer.measurer.removed
                save()
            }
            .onChange(of: reference.measurements) { _, _ in followSyncedMarks() }
            .onChange(of: reference.notes) { _, _ in followSyncedMarks() }
            .onChange(of: restorer.paused) { _, paused in
                if paused {
                    restorer.measurer.active = false
                    showTip("Paused. Swipe left or right to compare THEN and NOW. Tap the same button to carry on.", key: "tip.pause")
                }
            }
            .onChange(of: restorer.status) { _, status in
                if status == .ready, !reference.photoOnly {
                    showTip("Move or turn the phone until all four edge marks go green.", key: "tip.guides")
                }
            }
            .onChange(of: restorer.matched) { _, matched in
                if matched { Diagnostics.log("Edge guides all seated") }
            }
    }

    private func editingSheets<V: View>(_ content: V) -> some View {
        content
            .modifier(CaptureButtonAction { volumePressed() })
            .overlay { CleanViewControls { snapshotOnce() } }
            .sheet(isPresented: $addingLayer) {
                LayerPicker(references: others.filter { other in !layers.contains { $0.reference == other.id } }, thumbnails: thumbnails) { id in
                    layers.append(OverlayLayer(reference: id))
                    Diagnostics.log("Layer added (\(layers.count) now)")
                }
                .themed()
            }
            .onChange(of: layers) { _, now in
                OverlayLayer.save(now, for: reference.id)
                loadLayerPictures()
            }
            .fullScreenCover(item: $editingPhoto) { target in
                PhotoEditorSheet(target: target, onNewReference: added, onMaskChanged: { ghostMask = GhostMask.load(reference.id) })
            }
            .fullScreenCover(isPresented: $maskingGhost) {
                if let photo = restorer.startPhoto.flatMap(GhostMask.editable), let whole = CutoutMask.full(width: photo.cgImage?.width ?? 1, height: photo.cgImage?.height ?? 1) {
                    MaskBrushSheet(title: "Show only part", photo: photo, mask: GhostMask.fitted(ghostMask, to: photo) ?? whole, original: whole) { mask in
                        ghostMask = GhostMask.save(mask, reference: reference.id)
                    }
                }
            }
    }

    /// Without the controls a volume button takes a snapshot; with them it pauses and plays.
    private func volumePressed() {
        if ScreenshotMode.shared.viewing { snapshotOnce() } else { togglePause() }
    }

    private func snapshotOnce() {
        let now = Date()
        guard !restorer.paused, restorer.status == .ready, now.timeIntervalSince(lastShutter.date) > 0.6 else { return }
        lastShutter.date = now
        Diagnostics.log("Snapshot pressed (\(Screen.orientation.isLandscape ? "landscape" : "portrait"))")
        snapshot()
    }

    private func logTakeOnce() {
        let now = Date()
        guard !restorer.paused, now.timeIntervalSince(lastLog.date) > 0.6 else { return }
        lastLog.date = now
        logTake()
    }

    /// Saves the set as it looks now, labelled for the take it comes before, to compare later.
    private func snapshot() {
        let label = "Before take \(reference.nextTakeNumber)"
        let count = reference.snapshots.filter { $0.label.hasPrefix(label) }.count
        guard let shot = restorer.takeSnapshot(label: count == 0 ? label : "\(label) (\(count + 1))") else { return }
        reference.snapshots.append(shot)
        save()
        if let image = Screenshot.capture(camera: holder.view) { onPhoto(image) }
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
                Text(saved ? "MAP SAVED" : "SCANNING ROOM").font(Theme.title3)
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
            .font(Theme.caption.weight(.bold))
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
                        .font(Theme.font(size: 54))
                        .foregroundStyle(Theme.accent)
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


/// Asks what to call a sub-group, or picks one that exists.
struct GroupNameSheet: View {
    let existing: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("New group") {
                    TextField("Hair, Kitchen angle, Props…", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(finish)
                }
                if !existing.isEmpty {
                    Section("Add to a group") {
                        ForEach(existing, id: \.self) { group in
                            Button(group) {
                                onPick(group)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Group", action: finish).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onPick(trimmed)
        dismiss()
    }
}


/// A gentle "tap me": the view grows a little and jiggles every second or so, with a yellow ring.
/// With Reduce Motion on it only grows and glows, without the jiggle.
struct LoadNudge: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active {
            content
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent, lineWidth: 3))
                .shadow(color: Theme.accent.opacity(0.8), radius: 8)
                .phaseAnimator(reduceMotion ? [0] : [0, -9, 9, -7, 7, 0, 0], content: { view, angle in
                    view.rotationEffect(.degrees(Double(angle))).scaleEffect(1.25)
                }, animation: { angle in
                    angle == 0 ? .easeOut(duration: 0.7) : .easeInOut(duration: 0.08)
                })
        } else {
            content
        }
    }
}


/// Search only where it is wanted: added or left off without changing the screen around it.
struct SearchWhen: ViewModifier {
    let on: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if on {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search: watch, sofa, a word…")
        } else {
            content
        }
    }
}
