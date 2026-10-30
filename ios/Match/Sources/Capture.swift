import PhotosUI
import SwiftUI
import UIKit

/// Opens the capture screen on a board, optionally with a photo as the overlay. Boards and
/// photos in the library use it for "shoot this".
struct ShootAction {
    var run: (UUID, Shot?) -> Void = { _, _ in }
    func callAsFunction(_ boardID: UUID, ghost: Shot? = nil) { run(boardID, ghost) }
}

private struct ShootKey: EnvironmentKey {
    static let defaultValue = ShootAction()
}

extension EnvironmentValues {
    var shoot: ShootAction {
        get { self[ShootKey.self] }
        set { self[ShootKey.self] = newValue }
    }
}

/// The main screen, laid out like Reset's (and the Camera app's): the camera fills the screen with
/// the controls floating over it. Nothing is saved until the shutter is pressed. Top: library,
/// board and take, guide, switch camera, more. Above the shutter: angles (swipe, or tap; picking
/// one shows its reference). Bottom left: the reference thumbnail, which opens the gallery. Bottom
/// right: next take. The guide sits on the edges of the screen, so the face, hair and costume stay
/// clear.
struct CaptureView: View {
    @EnvironmentObject private var store: BoardStore
    @StateObject private var camera = Camera()
    @StateObject private var guide = Guide()
    @AppStorage("currentBoard") private var currentBoard = ""
    @AppStorage("seenHelp") private var seenHelp = false
    @AppStorage("ghostOpacity") private var opacity = 0.5
    @AppStorage("guideOn") private var guideOn = true
    @AppStorage("saveToPhotos") private var saveToPhotos = false
    @State private var ghostID: UUID?
    @State private var angle = ""
    @State private var ghost: UIImage?
    @State private var ghostEdges: UIImage?
    @State private var ghostDepth: DepthGrid?
    @AppStorage("useLiDAR") private var useLiDAR = true
    @State private var outlines = false
    @State private var ghostScale: CGFloat = 1
    @State private var ghostOffset: CGSize = .zero
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGSize?
    @State private var lastShot: Shot?
    @State private var comparing: ComparePair?
    @State private var showingLibrary = false
    @State private var showingHelp = false
    @State private var showingGallery = false
    @State private var creating: Board?
    @State private var editing: Board?
    @State private var flash = false
    @State private var saveError: String?
    @State private var toast: String?
    @State private var picked: [PhotosPickerItem] = []
    @State private var previewSize: CGSize = .zero

    /// The board being shot: the one chosen last, else the newest.
    private var board: Board? {
        UUID(uuidString: currentBoard).flatMap(store.board) ?? store.boards.max { $0.created < $1.created }
    }

    private var take: Int { store.take(for: board?.scene ?? "") }

    var body: some View {
        CameraLayout {
            topBar
        } preview: {
            preview
        } modes: { vertical in
            anglePicker(vertical: vertical)
        } leading: {
            referenceButton
        } shutter: {
            ShutterButton(style: .photo) { shoot() }
                .accessibilityLabel("Take photo")
        } trailing: {
            SideButton(title: "Next T\(take + 1)", systemImage: "forward.end.fill", tint: .yellow) {
                setTake(take + 1)
            }
            .contextMenu {
                if take > 0 {
                    Button("Back to \(Slate.takeName(take - 1))") { setTake(take - 1) }
                    Button("Prep") { setTake(0) }
                }
            }
            .accessibilityLabel("Next take, \(take + 1). Touch and hold to go back.")
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            camera.start()
            connectGuide()
            if !seenHelp { showingHelp = true }
        }
        .onChange(of: showingLibrary) { _, open in
            // The camera rests while the library is open, and picks up again after.
            if open { camera.stop() } else { camera.start() }
        }
        .onChange(of: board?.id) { _, _ in
            lastShot = nil
            pickReference(for: angle)
        }
        .onChange(of: guideOn) { _, _ in connectGuide() }
        .onChange(of: useLiDAR) { _, _ in camera.reconfigure() }
        .onChange(of: visibleAspect) { _, _ in connectGuide() }
        .onChange(of: picked) { _, items in importPicked(items) }
        .task(id: ghostID) { await loadGhost() }
        .fullScreenCover(item: $comparing) { pair in
            if let board {
                CompareView(boardID: board.id, before: pair.before, after: pair.after).environmentObject(store)
            }
        }
        .fullScreenCover(isPresented: $showingLibrary) {
            HomeView(openBoard: board?.id)
                .environmentObject(store)
                .environment(\.shoot, ShootAction { boardID, shot in
                    currentBoard = boardID.uuidString
                    if let shot {
                        angle = shot.angle
                        ghostID = shot.id
                    } else {
                        pickReference(for: angle, in: store.board(boardID))
                    }
                    showingLibrary = false
                })
        }
        .sheet(item: $creating) { board in
            BoardEditor(board: board, isNew: true) { saved in
                store.save(saved)
                currentBoard = saved.id.uuidString
                ghostID = nil
            }
        }
        .sheet(item: $editing) { board in
            BoardEditor(board: board, isNew: false) { store.save($0) }
        }
        .sheet(isPresented: $showingHelp, onDismiss: { seenHelp = true }) { HelpView() }
        .fullScreenCover(isPresented: $showingGallery) {
            if let board {
                GalleryView(board: board, overlay: ghostID, last: lastShot ?? board.newest) { choice in
                    showingGallery = false
                    switch choice {
                    case .overlay(let shot):
                        ghostID = shot?.id
                        if let shot { angle = shot.angle }
                    case .compare(let before, let after):
                        comparing = ComparePair(before: before, after: after)
                    }
                }
                .environmentObject(store)
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showingLibrary = true } label: { Image(systemName: "square.grid.2x2").font(.title3) }
                .accessibilityLabel("Boards and photos")
            boardMenu
            Spacer(minLength: 4)
            Button {
                Haptics.tap()
                guideOn.toggle()
            } label: {
                pill(guideOn ? (guide.lockedToActor ? "Actor" : "Guide") : "Guide off",
                     systemImage: guide.lockedToActor && guideOn ? "person.crop.rectangle" : "arrow.up.and.down.and.arrow.left.and.right",
                     highlighted: guideOn && ghost != nil)
            }
            .accessibilityLabel(guideOn ? "Turn the guide off" : "Turn the guide on")
            Button { camera.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3) }
                .accessibilityLabel("Switch camera")
            moreMenu
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
    }

    /// Looks like Reset's top pills; used as a menu label as well as a button.
    private func pill(_ text: String, systemImage: String? = nil, highlighted: Bool = false) -> some View {
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

    /// Switch character in one tap; boards grouped by scene, newest scene first.
    private var boardMenu: some View {
        Menu {
            Button { creating = store.newBoard() } label: { Label("New character or look", systemImage: "plus") }
            if let board {
                Button { editing = board } label: { Label("Edit \(board.subject.isEmpty ? "this board" : board.subject)", systemImage: "pencil") }
            }
            ForEach(store.scenes.reversed(), id: \.self) { scene in
                Section(scene.isEmpty ? "No scene" : "Scene \(scene)") {
                    ForEach(store.boards.filter { $0.scene == scene }.sorted { $0.title < $1.title }) { item in
                        Button {
                            currentBoard = item.id.uuidString
                        } label: {
                            if item.id == board?.id {
                                Label(item.title, systemImage: "checkmark")
                            } else {
                                Text(item.title)
                            }
                        }
                    }
                }
            }
        } label: {
            pill(board.map { "Sc \($0.scene) · \($0.shortTitle) · \(Slate.shortTake(take))" } ?? "New board")
        }
        .accessibilityLabel("Choose character")
    }

    private var moreMenu: some View {
        Menu {
            PhotosPicker(selection: $picked, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .images) {
                Label("Import from Photos", systemImage: "photo.badge.plus")
            }
            if let board, board.shots.count > 1, let latest = lastShot ?? board.newest {
                Button {
                    comparing = ComparePair(before: board.reference(for: latest)?.id, after: latest.id)
                } label: { Label("Compare latest photo", systemImage: "rectangle.split.2x1") }
            }
            Toggle(isOn: $outlines) { Label("Overlay as outlines", systemImage: "square.dashed") }
            if camera.hasLiDAR {
                Toggle(isOn: $useLiDAR) { Label("LiDAR distance", systemImage: "dot.radiowaves.forward") }
            }
            Toggle(isOn: $saveToPhotos) { Label("Also save photos to Photos", systemImage: "square.and.arrow.down") }
            Button { showingLibrary = true } label: { Label("Boards, notes and backup", systemImage: "square.grid.2x2") }
            Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .accessibilityLabel("More")
    }

    // MARK: Picture

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreview(camera: camera)
                ghostLayer
                    .contentShape(Rectangle())
                    .gesture(ghostGesture)
                    .onTapGesture(count: 2) {
                        withAnimation {
                            ghostScale = 1
                            ghostOffset = .zero
                        }
                    }
                    .onTapGesture { location in
                        // Several people in view: follow the one tapped.
                        guide.follow(at: ScreenMap(size: geometry.size, quarterTurns: quarterTurns, mirrored: camera.isFront, inner: ghostBox)
                            .toPhoto(location))
                    }
                if guideOn, ghost != nil {
                    if guide.people.count > 1 {
                        PeopleRings(people: guide.people, followed: guide.followed,
                                    quarterTurns: quarterTurns, mirrored: camera.isFront, inner: ghostBox)
                    }
                    EdgeGuide(reading: guide.reading, cue: guide.cue, matched: guide.matched, searching: guide.searching,
                              people: guide.people.count, quarterTurns: quarterTurns, mirrored: camera.isFront, inner: ghostBox)
                        .clearOfControls()
                }
                if ghost != nil {
                    strengthControl(wide: geometry.size.width > geometry.size.height)
                        .clearOfControls()
                }
                if flash { Color.white.opacity(0.6).allowsHitTesting(false) }
                VStack(spacing: 8) {
                    if camera.paused { Banner(text: "Camera paused. On iPad it stops while another app uses it.", tint: .red) }
                    if let error = camera.error { Banner(text: error, tint: .red) }
                    if let saveError { Banner(text: saveError, tint: .red) }
                    if let toast {
                        Text(toast)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                }
                .padding(.horizontal, 64)  // keep clear of the edge arrows
                .padding(.vertical, 8)
                .clearOfControls()
            }
            .onAppear { previewSize = geometry.size }
            .onChange(of: geometry.size) { _, size in previewSize = size }
        }
    }

    /// Overlay strength, tucked into the bottom left corner so the guide's arrows stay clear: upright
    /// along the left edge when the phone is upright, along the bottom when it is on its side.
    private func strengthControl(wide: Bool) -> some View {
        let length: CGFloat = 130
        let hide = Button { ghostID = nil } label: {
            Image(systemName: "eye.slash").font(.footnote).frame(width: 30, height: 30)
        }
        .accessibilityLabel("Hide overlay")
        let slider = Slider(value: $opacity, in: 0...1)
            .frame(width: length)
            .accessibilityLabel("Overlay strength")
        let layout = wide ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
        return layout {
            if wide {
                hide
                slider
            } else {
                slider.rotationEffect(.degrees(-90)).frame(width: 30, height: length)
                hide
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.35), in: Capsule())
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 8)
        .padding(.bottom, 12)
    }

    /// The part of the camera picture the screen shows, as width over height the way photos are
    /// saved, so photos keep just what was on screen.
    private var visibleAspect: CGFloat? {
        guard previewSize.width > 0, previewSize.height > 0 else { return nil }
        let sideways = abs(quarterTurns) % 2 == 1
        return sideways ? previewSize.height / previewSize.width : previewSize.width / previewSize.height
    }

    private var quarterTurns: Int { Int((camera.photoToPreview / 90).rounded()) }

    @ViewBuilder
    private var ghostLayer: some View {
        GeometryReader { geometry in
            if let image = outlines ? ghostEdges : ghost {
                let size = geometry.size
                let turn = camera.photoToPreview
                let sideways = abs(abs(turn) - 90) < 1
                // Filled like the camera (and Reset's ghost), and fitted as it will look once turned.
                let box = sideways ? CGSize(width: size.height, height: size.width) : size
                // A portrait reference on a landscape screen (or the other way round) is shown whole.
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: ghostWhole ? .fit : .fill)
                    .frame(width: box.width, height: box.height)
                    .clipped()
                    .rotationEffect(.degrees(turn))
                    .frame(width: size.width, height: size.height)
                    .colorMultiply(outlines ? .cyan : .white)
                    .blendMode(outlines ? .screen : .normal)
                    .opacity(outlines ? max(opacity, 0.6) : opacity)
                    .scaleEffect(x: camera.isFront ? -ghostScale : ghostScale, y: ghostScale)
                    .offset(ghostOffset)
                    // Actor lock: the reference's eyes (or shoulders) sit on the actor's, wherever they stand.
                    .modifier(ActorPin(transform: guideOn ? guide.anchor.map {
                        ScreenMap(size: size, quarterTurns: quarterTurns, mirrored: camera.isFront, inner: ghostBox)
                            .ghostTransform(from: $0.from, to: $0.to)
                    } : nil))
                    .animation(.easeOut(duration: 0.2), value: guide.anchor)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A portrait reference checked with the phone on its side (or the other way round): shown
    /// whole in the middle of the screen, and the guide lines up with that box.
    private var ghostWhole: Bool {
        guard let ghost, let visibleAspect else { return false }
        return Fit.showsWhole(reference: ghost.size.width / max(ghost.size.height, 1), screen: visibleAspect)
    }

    /// Where the reference sits on screen, in the photo's directions: all of it, or the middle box.
    private var ghostBox: CGRect {
        guard ghostWhole, let ghost, let visibleAspect else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return Fit.centredBox(outer: visibleAspect, inner: ghost.size.width / max(ghost.size.height, 1))
    }

    /// Pinch and drag the overlay to line up a photo framed differently, such as a QTake screenshot.
    private var ghostGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = ghostScale }
                ghostScale = min(max((pinchStart ?? 1) * value.magnification, 0.3), 5)
            }
            .onEnded { _ in pinchStart = nil }
            .simultaneously(with: DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if dragStart == nil { dragStart = ghostOffset }
                    let start = dragStart ?? .zero
                    ghostOffset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in dragStart = nil })
    }

    // MARK: Controls

    /// Angles above the shutter like Reset's modes: tap one or swipe. Picking one shows its reference.
    private func anglePicker(vertical: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                ModePicker(modes: [""] + Slate.angles, label: Slate.angleLabel,
                           selection: Binding(get: { angle }, set: { selectAngle($0) }), vertical: vertical)
                    .padding(vertical ? .vertical : .horizontal, 16)
            }
            .frame(maxHeight: vertical ? 150 : 24)
            .onChange(of: angle) { _, value in
                withAnimation { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    /// One thumbnail, like the Camera app's: the overlay being shown, else the latest reference.
    /// Tap it for the gallery.
    @ViewBuilder
    private var referenceButton: some View {
        let shown = ghostID.flatMap { id in board?.shots.first { $0.id == id } }
        let shot = shown ?? board?.references.last
        Button {
            Haptics.tap()
            if board == nil {
                // Start a board, so photos can be imported before any are taken.
                let fresh = store.newBoard()
                store.save(fresh)
                currentBoard = fresh.id.uuidString
            }
            showingGallery = true
        } label: {
            ZStack {
                if let board, let shot, let thumbnail = store.thumbnail(shot, in: board.id) {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle").font(.title3)
                }
            }
            .frame(width: 52, height: 52)
            .background(.white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if let shot { TimeStamp(date: shot.taken, size: 8).offset(y: 9) }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(shown != nil ? Color.yellow : .white, lineWidth: 2))
        }
        .accessibilityLabel("Reference photos")
    }

    // MARK: Actions

    /// Live frames go to the guide only while it is on and there is a reference to line up with.
    private func connectGuide() {
        let guide = self.guide
        if guideOn, ghost != nil {
            camera.onFrame = { @Sendable [weak guide] frame, depth in guide?.consider(frame, depth: depth) }
        } else {
            camera.onFrame = nil
        }
        guide.setReference(guideOn ? ghost : nil, depth: ghostDepth, aspect: visibleAspect, whole: ghostWhole, prefersBody: board?.department == .costume)
    }

    private func selectAngle(_ newAngle: String) {
        angle = newAngle
        pickReference(for: newAngle)
    }

    /// Shows the reference for the angle, if there is one.
    private func pickReference(for angle: String, in chosen: Board? = nil) {
        let target = chosen ?? board
        guard let target else {
            ghostID = nil
            return
        }
        let references = target.references
        if let match = references.last(where: { $0.angle == angle }) {
            ghostID = match.id
        } else if !references.contains(where: { $0.id == ghostID }) {
            ghostID = angle.isEmpty ? references.last?.id : nil
        }
    }

    private func setTake(_ newTake: Int) {
        Haptics.tap()
        store.setTake(newTake, for: board?.scene ?? "")
        show(Slate.takeName(max(0, newTake)))
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { if toast == message { toast = nil } }
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picked = []
        let target: Board
        if let board {
            target = board
        } else {
            target = store.newBoard()
            store.save(target)
            currentBoard = target.id.uuidString
        }
        show("Importing \(items.count)…")
        Task {
            var failed = 0
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                    await store.addShot(data, to: target.id, angle: "", source: .imported) != nil
                {
                    continue
                }
                failed += 1
            }
            show(failed == 0 ? "Imported \(items.count)" : "\(failed) of \(items.count) could not be imported")
        }
    }

    private func shoot() {
        withAnimation(.easeOut(duration: 0.15)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { flash = false } }
        // No board yet: start one, so the first photo is never lost. It can be renamed later.
        let target: Board
        if let board {
            target = board
        } else {
            target = store.newBoard()
            store.save(target)
            currentBoard = target.id.uuidString
        }
        let angle = self.angle
        let alsoToPhotos = saveToPhotos
        let crop = visibleAspect
        // LiDAR depth at the moment of the shot, cropped like the photo, so it can be a reference.
        let depth = camera.currentDepth()?.cropped(aspect: crop)
        camera.capture { data in
            guard let data else {
                saveError = "The photo did not take. Try again."
                return
            }
            Task {
                if let shot = await store.addShot(data, to: target.id, angle: angle, source: .camera, crop: crop, depth: depth) {
                    lastShot = shot
                    // A new reference is shown straight away, so the next photo can be checked against it.
                    if shot.isReference, ghostID == nil { ghostID = shot.id }
                    saveError = nil
                    show(shot.isReference ? "Reference \(Slate.angleLabel(shot.angle))" : Slate.takeName(shot.take))
                    if alsoToPhotos, !(await PhotoLibrary.save([BoardStore.url(of: shot, in: target.id)])) {
                        show(PhotoLibrary.deniedMessage)
                    }
                } else {
                    saveError = "Could not save the photo. The iPhone or iPad may be out of storage."
                }
            }
        }
    }

    private func loadGhost() async {
        ghostScale = 1
        ghostOffset = .zero
        guard let ghostID, let board, let shot = board.shots.first(where: { $0.id == ghostID }) else {
            ghost = nil
            ghostEdges = nil
            ghostDepth = nil
            connectGuide()
            return
        }
        let boardID = board.id
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, UIImage?, DepthGrid?) in
            let image = BoardStore.image(shot, in: boardID, maxPixels: 1600)
            return (image, image.flatMap(Ghost.edges(of:)), BoardStore.depth(shot, in: boardID))
        }.value
        guard !Task.isCancelled else { return }
        ghost = loaded.0
        ghostEdges = loaded.1
        ghostDepth = loaded.2
        connectGuide()
    }
}

/// Scales, turns and moves the ghost about the screen's middle; nothing when there is no actor.
private struct ActorPin: ViewModifier {
    let transform: (scale: CGFloat, angle: CGFloat, offset: CGSize)?

    func body(content: Content) -> some View {
        content
            .scaleEffect(transform?.scale ?? 1)
            .rotationEffect(.radians(Double(transform?.angle ?? 0)))
            .offset(transform?.offset ?? .zero)
    }
}

// MARK: - Gallery

/// The board's photos full screen, swiped through like the Photos app: references first, then the
/// rest newest first, opening on the overlay (else the latest reference). A filmstrip at the bottom
/// jumps along; Use shows the photo over the camera; Compare puts it against its reference.
struct GalleryView: View {
    enum Choice {
        case overlay(Shot?)
        case compare(before: UUID?, after: UUID)
    }

    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    private let boardID: UUID
    private let fallback: Board
    let onChoose: (Choice) -> Void
    @State private var selection: UUID?
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = 0
    @State private var notice: String?
    /// iPhone on its side: the caption sits over the photo, leaving it as much height as possible.
    @Environment(\.verticalSizeClass) private var verticalSize

    init(board: Board, overlay: UUID?, last: Shot?, onChoose: @escaping (Choice) -> Void) {
        boardID = board.id
        fallback = board
        self.onChoose = onChoose
        _selection = State(initialValue: overlay ?? board.references.last?.id ?? board.newest?.id)
    }

    /// Live, so photos imported here show up straight away.
    private var board: Board { store.board(boardID) ?? fallback }
    private var shots: [Shot] {
        Array(board.references.reversed()) + board.shots.filter { !$0.isReference }.sorted { $0.taken > $1.taken }
    }
    private var current: Shot? { shots.first { $0.id == selection } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if shots.isEmpty {
                    ContentUnavailableView {
                        Label("No photos yet", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("Take one with the shutter, or bring in photos and QTake screenshots from your Photos library.")
                    } actions: {
                        importButton(prominent: true)
                    }
                    .frame(maxHeight: .infinity)
                }
                TabView(selection: $selection) {
                    ForEach(shots) { shot in
                        GalleryPage(shot: shot, boardID: board.id)
                            .tag(Optional(shot.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background(Color.black)
                .overlay(alignment: .bottom) {
                    if let current, verticalSize == .compact {
                        caption(current).background(Color.black.opacity(0.55)).allowsHitTesting(false)
                    }
                }
                if let current, verticalSize != .compact {
                    caption(current).background(Color.black)
                }
                filmstrip
            }
            .overlay(alignment: .top) {
                if importing > 0 || notice != nil {
                    Text(importing > 0 ? "Importing \(importing)…" : notice ?? "")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .onChange(of: picked) { _, items in importPicked(items) }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(board.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    importButton(prominent: false)
                    Button("No overlay") { onChoose(.overlay(nil)) }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let current {
                        Button {
                            onChoose(.compare(before: board.reference(for: current)?.id, after: current.id))
                        } label: {
                            Label("Compare", systemImage: "rectangle.split.2x1")
                        }
                        .disabled(board.shots.count < 2)
                        Spacer()
                        Button {
                            save(current)
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        Spacer()
                        Button {
                            onChoose(.overlay(current))
                        } label: {
                            Text("Use as overlay").bold()
                        }
                    }
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Several photos at once from the Photos library, in the order picked.
    private func importButton(prominent: Bool) -> some View {
        PhotosPicker(selection: $picked, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .images) {
            if prominent {
                Text("Import from Photos").bold()
            } else {
                Label("Import from Photos", systemImage: "photo.badge.plus")
            }
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picked = []
        importing = items.count
        Task {
            var first: Shot?
            var failed = 0
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                    let shot = await store.addShot(data, to: boardID, angle: "", source: .imported)
                {
                    first = first ?? shot
                } else {
                    failed += 1
                }
                importing -= 1
            }
            if let first { selection = first.id }
            flash(failed == 0
                  ? "Imported \(items.count) photo\(items.count == 1 ? "" : "s")"
                  : "\(failed) of \(items.count) could not be imported (iCloud only, or storage full?)")
        }
    }

    private func save(_ shot: Shot) {
        Task {
            let saved = await PhotoLibrary.save([BoardStore.url(of: shot, in: boardID)])
            flash(saved ? "Saved to Photos" : PhotoLibrary.deniedMessage)
        }
    }

    private func flash(_ text: String) {
        withAnimation { notice = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { if notice == text { notice = nil } }
        }
    }

    private func caption(_ shot: Shot) -> some View {
        VStack(spacing: 2) {
            Text((shot.isReference ? "★ Reference · " : "") + shot.label)
                .font(.subheadline.weight(.semibold))
            if !shot.note.isEmpty {
                Text(shot.note).font(.caption).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 3) {
                    ForEach(shots) { shot in
                        Button {
                            withAnimation { selection = shot.id }
                        } label: {
                            Group {
                                if let image = store.thumbnail(shot, in: board.id) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Color.gray
                                }
                            }
                            .frame(width: shot.id == selection ? 46 : 34, height: 46)
                            .clipped()
                            .overlay(alignment: .bottom) {
                                Text(shot.taken.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 7, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .frame(maxWidth: .infinity)
                                    .background(.black.opacity(0.6))
                            }
                            .overlay(alignment: .topLeading) {
                                if shot.isReference {
                                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow).padding(2)
                                }
                            }
                        }
                        .id(shot.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 52)
            .background(Color.black)
            .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
            .onChange(of: selection) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

/// One photo in the gallery. Pinch to zoom; drag pans only once zoomed, so swiping still turns pages.
private struct GalleryPage: View {
    let shot: Shot
    let boardID: UUID
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGSize?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
            } else {
                ProgressView().tint(.white)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    if pinchStart == nil { pinchStart = scale }
                    scale = min(max((pinchStart ?? 1) * value.magnification, 1), 8)
                }
                .onEnded { _ in
                    pinchStart = nil
                    if scale < 1.05 { withAnimation { scale = 1; offset = .zero } }
                }
        )
        .gesture(scale > 1 ? pan : nil)
        .onTapGesture(count: 2) {
            withAnimation {
                if scale > 1 {
                    scale = 1
                    offset = .zero
                } else {
                    scale = 2.5
                }
            }
        }
        .task {
            let shot = shot
            let boardID = boardID
            image = await Task.detached(priority: .userInitiated) { BoardStore.image(shot, in: boardID, maxPixels: 2048) }.value
        }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = offset }
                let start = dragStart ?? .zero
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }
}
