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
/// board and take, guide, switch camera, more. Above the shutter: the board's reference photos (tap one to
/// line up with it). Bottom left: the reference thumbnail, which opens the gallery. Bottom
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
    @AppStorage("leftHanded") private var leftHanded = false
    @State private var ghostID: UUID?
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
    @State private var showingMore = false
    @State private var moreAtEnd = false
    @State private var showingImport = false
    @State private var previewSize: CGSize = .zero
    @AppStorage("showChanges") private var showChanges = false
    @AppStorage("lightLevel") private var lightLevel = 0.6
    @State private var lightOn = false
    /// Paused: the live picture frozen, with the reference over it to fade THEN to NOW at leisure.
    @State private var frozen: UIImage?
    @State private var pausing = false
    @State private var lensOpen = false
    @State private var scrubStart: Double?
    @State private var opacityBefore: Double?
    /// Paused compare as a wipe, like Reset: the reference left of a line you drag. Off is a fade.
    @AppStorage("pauseWipe") private var wipeStyle = true
    /// How much of the screen, from the left, shows the reference in a wipe.
    @State private var wipePos = 0.5
    private var wiping: Bool { paused && wipeStyle && ghost != nil }
    private var paused: Bool { frozen != nil }
    @State private var wheelShown = false
    @State private var wheelHide: Task<Void, Never>?
    @State private var lightDragStart: Double?
    @State private var savedBrightness: CGFloat?
    @Environment(\.scenePhase) private var scenePhase

    /// The board being shot: the one chosen last, else the newest.
    private var board: Board? {
        UUID(uuidString: currentBoard).flatMap(store.board) ?? store.boards.max { $0.created < $1.created }
    }

    private var take: Int { store.take(for: board?.scene ?? "") }

    /// The photo shown over the camera.
    private var ghostShot: Shot? { ghostID.flatMap { id in board?.shots.first { $0.id == id } } }
    /// An imported photo's size and place on the live view, once worked out.
    private var ghostFit: OverlayFit? { ghostShot?.fit }
    /// An imported photo (another camera, a QTake screenshot) not yet sized to the live view.
    private var needsFit: Bool { ghostShot?.source == .imported && ghostShot?.fit == nil }

    var body: some View {
        CameraLayout {
            topBar
        } preview: {
            preview
        } modes: { vertical in
            referenceStrip(vertical: vertical)
        } leading: {
            if previewSize.width > previewSize.height {
                referenceButton(size: 60)
            } else {
                Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
            }
        } shutter: {
            if previewSize.width > previewSize.height {
                // On its side there is no room across, so pause goes under the shutter.
                VStack(spacing: 14) {
                    ShutterButton(style: .photo) { shoot() }
                        .accessibilityLabel("Take photo")
                    pauseButton(size: 74)
                }
            } else {
                // Upright: the reference thumbnail, the shutter dead centre and pause, the same size,
                // with equal room each side (swapped when left-handed).
                HStack(spacing: 0) {
                    (leftHanded ? AnyView(pauseButton(size: 74)) : AnyView(referenceButton(size: 74)))
                        .frame(maxWidth: .infinity)
                    ShutterButton(style: .photo) { shoot() }
                        .accessibilityLabel("Take photo")
                    (leftHanded ? AnyView(referenceButton(size: 74)) : AnyView(pauseButton(size: 74)))
                        .frame(maxWidth: .infinity)
                }
            }
        } trailing: {
            Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
        }
        .modifier(CaptureButtonAction { if paused { resume() } else { pause() } })
        .preferredColorScheme(.dark)
        .fontDesign(.rounded)
        .tint(Theme.accent)
        .statusBarHidden()
        .onAppear {
            camera.start()
            Motion.shared.start()
            guide.showChanges = showChanges
            connectGuide()
            if !seenHelp { showingHelp = true }
        }
        .onChange(of: showingLibrary) { _, open in
            // The camera rests while the library is open, and picks up again after.
            if open { camera.stop() } else { camera.start() }
            updateLight()
        }
        .onChange(of: board?.id) { _, _ in
            lastShot = nil
            pickReference()
        }
        .onChange(of: guideOn) { _, _ in connectGuide() }
        .onChange(of: ghostFit) { _, _ in connectGuide() }
        .onChange(of: guide.fitted) { _, fit in keepFit(fit) }
        .onChange(of: useLiDAR) { _, _ in camera.reconfigure() }
        .onChange(of: showChanges) { _, on in guide.showChanges = on }
        .onChange(of: visibleAspect) { _, _ in connectGuide() }
        .onChange(of: picked) { _, items in importPicked(items) }
        .photosPicker(isPresented: $showingImport, selection: $picked, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .images)
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
                        ghostID = shot.id
                    } else {
                        pickReference(in: store.board(boardID))
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
        let sideways = previewSize.width > previewSize.height
        return VStack(spacing: 6) {
            // One line: the scene pill (all boards are one tap away on the thumbnail), then the controls.
            HStack(spacing: 10) {
                boardMenu
                if sideways { nextTakeButton }
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
                if hasLight { lightButton }
                Button { camera.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3) }
                    .accessibilityLabel("Switch camera")
                moreMenu
            }
            .frame(height: 44)
            // No band behind the row, so the picture runs to the top; a faint shadow keeps icons legible.
            .shadow(color: .black.opacity(0.35), radius: 2)
            if !sideways {
                HStack(spacing: 8) {
                    Spacer(minLength: 4)
                    nextTakeButton
                }
                .frame(height: 38)
            }
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
        // Here rather than on body, which is already as much as the compiler will check in one go.
        .onChange(of: lightOn) { _, _ in updateLight() }
        .onChange(of: lightLevel) { _, _ in updateLight() }
        .onChange(of: camera.isFront) { _, _ in updateLight() }
        .onChange(of: camera.hasTorch) { _, _ in updateLight() }
        .onChange(of: scenePhase) { _, phase in
            updateLight()
            if phase != .active { resume() }
        }
        .onDisappear {
            restoreBrightness()
            Motion.shared.stop()
        }
    }

    // MARK: Next take

    /// A plain "Next take" button, top right, under the row of icons. Touch and hold to go back or to Prep.
    private var nextTakeButton: some View {
        Button {
            Haptics.tap()
            setTake(take + 1)
        } label: {
            Text("Next take")
                .font(.subheadline.bold())
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(PressScale())
        .contextMenu {
            if take > 0 {
                Button("Back to \(Slate.takeName(take - 1))") { setTake(take - 1) }
                Button("Prep") { setTake(0) }
            }
        }
        .accessibilityLabel("Next take, \(take + 1). Touch and hold to go back.")
    }

    // MARK: Pause

    /// Freezes the picture so the reference can be faded over it: swipe anywhere, or tap to jump
    /// between THEN and NOW. Press again (or take a photo) to go live.
    private func pauseButton(size: CGFloat) -> some View {
        Button {
            Haptics.tap()
            if paused { resume() } else { pause() }
        } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(paused ? Theme.onAccent : Theme.text)
                .frame(width: size, height: size)
                .background(paused ? Theme.accent : Theme.chip, in: Circle())
                .overlay(Circle().stroke(paused ? Theme.accent : Theme.text, lineWidth: size > 60 ? 4 : 3))
                .contentShape(Circle())
        }
        .accessibilityLabel(paused ? "Back to live" : "Pause and compare")
    }

    private func pause() {
        guard !pausing else { return }
        pausing = true
        camera.grabFrame { image in
            pausing = false
            if let image {
                frozen = image
                // Compare from THEN, the reference as it was; the swipe moves toward NOW.
                if ghost != nil {
                    opacityBefore = opacity
                    opacity = 1
                    wipePos = 0.5
                }
            } else {
                show("Could not pause. Try again.")
            }
        }
    }

    private func resume() {
        guard frozen != nil else { return }
        frozen = nil
        scrubStart = nil
        // The strength you had before pausing comes back.
        if let before = opacityBefore { opacity = before }
        opacityBefore = nil
    }

    /// The frozen picture, laid out exactly as the live camera and the reference are.
    private func frozenLayer(_ image: UIImage) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let turn = camera.photoToPreview
            let sideways = abs(abs(turn) - 90) < 1
            let box = sideways ? CGSize(width: size.height, height: size.width) : size
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: box.width, height: box.height)
                .clipped()
                .rotationEffect(.degrees(turn))
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: camera.isFront ? -1 : 1, y: 1)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// The wipe's line and handle. The reference is left of it, the live picture right.
    private func wipeLine(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.white).frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.8), radius: 2)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Color.white, in: Circle())
                .shadow(color: .black.opacity(0.5), radius: 3)
        }
        .position(x: width * wipePos, y: height / 2)
        .allowsHitTesting(false)
    }

    /// While paused the whole screen is the scrubber, like Reset: swipe left for THEN, right for
    /// NOW, tap to jump to the other end.
    private var scrubLayer: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    guard ghost != nil else { return }
                    Haptics.tap()
                    withAnimation(.snappy(duration: 0.2)) {
                        if wipeStyle { wipePos = wipePos > 0.5 ? 0 : 1 } else { opacity = opacity > 0.5 ? 0 : 1 }
                    }
                }
                .gesture(DragGesture(minimumDistance: 8)
                    .onChanged { drag in
                        guard ghost != nil else { return }
                        let share = Double(drag.translation.width / max(geometry.size.width, 1))
                        if wipeStyle {
                            // The line follows the finger.
                            let start = scrubStart ?? wipePos
                            scrubStart = start
                            wipePos = min(1, max(0, start + share))
                        } else {
                            let start = scrubStart ?? (1 - opacity)
                            scrubStart = start
                            opacity = 1 - min(1, max(0, start + share))
                        }
                    }
                    .onEnded { _ in scrubStart = nil })
        }
    }

    // MARK: Light

    /// The back camera's torch, or on the front the screen glowing round the edges.
    private var hasLight: Bool { camera.hasTorch || camera.isFront }

    /// Tap: light on or off. Drag sideways on it, or on the wheel that shows, to set the brightness.
    /// Touch and hold: show the wheel again.
    private var lightButton: some View {
        Image(systemName: lightOn ? "flashlight.on.fill" : "flashlight.off.fill")
            .font(.title3)
            .foregroundStyle(lightOn ? Theme.onAccent : Theme.text)
            .frame(width: 34, height: 34)
            .background(lightOn ? Theme.accent : Color.clear, in: Circle())
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.tap()
                lightOn.toggle()
                if lightOn { showWheel() } else { hideWheel() }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                Haptics.tap()
                lightOn = true
                showWheel()
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { drag in
                let start = lightDragStart ?? lightLevel
                if lightDragStart == nil {
                    lightDragStart = start
                    lightOn = true
                }
                LightScrub.set(&lightLevel, from: start, by: drag.translation.width)
                showWheel()
            }.onEnded { _ in lightDragStart = nil })
            .accessibilityElement()
            .accessibilityLabel(lightOn ? "Turn the light off" : "Turn the light on")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { lightOn.toggle() }
    }

    private func showWheel() {
        withAnimation(.easeOut(duration: 0.2)) { wheelShown = true }
        wheelHide?.cancel()
        wheelHide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { wheelShown = false }
        }
    }

    private func hideWheel() {
        wheelHide?.cancel()
        withAnimation(.easeIn(duration: 0.2)) { wheelShown = false }
    }

    /// Puts the torch and the screen to what the button and wheel say, and the camera is showing.
    private func updateLight() {
        let showing = lightOn && !showingLibrary && scenePhase == .active
        camera.setTorch(showing && !camera.isFront ? Float(lightLevel) : 0)
        if showing && camera.isFront {
            if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
            UIScreen.main.brightness = 1
        } else {
            restoreBrightness()
        }
    }

    private func restoreBrightness() {
        guard let saved = savedBrightness else { return }
        UIScreen.main.brightness = saved
        savedBrightness = nil
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
        .background(highlighted ? Theme.accent : Theme.chip, in: Capsule())
        .foregroundStyle(highlighted ? Theme.onAccent : Theme.text)
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
            scenePill
        }
        .accessibilityLabel("Choose character")
    }

    /// Scene and shot on the first line, character and take on the second, in full.
    private var scenePill: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let board {
                Text(Slate.sceneName(board.scene, shot: board.shotLetter))
                Text("\(board.shortTitle) · \(Slate.takeName(take))")
            } else {
                Text("New board")
            }
        }
        .font(.caption.bold())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(Theme.text)
    }

    private func moreRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            showingMore = false
            action()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func moreToggle(_ title: String, _ icon: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Label(title, systemImage: icon) }
            .tint(Theme.accent)
    }

    private func moreHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private var morePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                moreHeader("Overlay")
                if ghostID != nil {
                    moreRow("Hide overlay", "eye.slash") { ghostID = nil }
                } else if let last = board?.references.last {
                    moreRow("Show overlay", "eye") { ghostID = last.id }
                }
                moreToggle("Show as outlines", "square.dashed", $outlines)
                if camera.hasLiDAR {
                    moreToggle("Show what changed", "square.2.layers.3d", $showChanges)
                }
                Divider()
                moreHeader("Photos")
                moreRow("Import from Photos", "photo.badge.plus") { showingImport = true }
                if let board, board.shots.count > 1, let latest = lastShot ?? board.newest {
                    moreRow("Compare latest photo", "rectangle.split.2x1") {
                        comparing = ComparePair(before: board.reference(for: latest)?.id, after: latest.id)
                    }
                }
                moreRow("Boards, notes and backup", "square.grid.2x2") { showingLibrary = true }
                Divider()
                moreHeader("Settings")
                if camera.hasLiDAR {
                    moreToggle(camera.isFront ? "Face ID distance" : "LiDAR distance", "dot.radiowaves.forward", $useLiDAR)
                }
                moreToggle("Left-handed", "hand.raised", $leftHanded)
                moreToggle("Also save to Photos", "square.and.arrow.down", $saveToPhotos)
                moreRow("Help", "questionmark.circle") { showingHelp = true }
                Color.clear.frame(height: 1)
                    .onAppear { moreAtEnd = true }
                    .onDisappear { moreAtEnd = false }
            }
            .font(.body)
            .foregroundStyle(Theme.text)
            .padding(16)
        }
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(onAppear: true)
        .overlay(alignment: .bottom) {
            // A fade and an arrow while there is more below.
            if !moreAtEnd {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [.clear, Color(red: 0.07, green: 0.09, blue: 0.09)], startPoint: .top, endPoint: .bottom)
                    Label("Scroll for more", systemImage: "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.accent)
                        .padding(.bottom, 6)
                }
                .frame(height: 56)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: moreAtEnd)
        .frame(width: 300)
        .frame(minHeight: 200, maxHeight: 520)
        .presentationCompactAdaptation(.popover)
        .presentationBackground(Color(red: 0.07, green: 0.09, blue: 0.09))
        .preferredColorScheme(.dark)
    }

    private var moreMenu: some View {
        Button { showingMore = true } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .accessibilityLabel("More")
        .popover(isPresented: $showingMore) { morePanel }
    }

    // MARK: Picture

    private var preview: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreview(camera: camera)
                if let frozen { frozenLayer(frozen) }
                ghostLayer
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: wiping ? geometry.size.width * wipePos : geometry.size.width)
                    }
                    .contentShape(Rectangle())
                    .gesture(ghostGesture)
                    .onTapGesture(count: 2) {
                        withAnimation {
                            ghostScale = 1
                            ghostOffset = .zero
                        }
                        // An imported photo: fit it to the live view again.
                        if let board, var shot = ghostShot, shot.source == .imported, shot.fit != nil {
                            shot.fit = nil
                            store.update(shot, in: board.id)
                            show("Fitting again…")
                        }
                    }
                    .onTapGesture { location in
                        // Several people in view: follow the one tapped.
                        guide.follow(at: ScreenMap(size: geometry.size, quarterTurns: quarterTurns, mirrored: camera.isFront, inner: ghostBox)
                            .toPhoto(location))
                    }
                if let changes = guide.changes, showChanges { changeLayer(changes, size: geometry.size) }
                if paused { scrubLayer }
                if wiping { wipeLine(width: geometry.size.width, height: geometry.size.height) }
                if guideOn, ghost != nil, !guide.fitting, !paused {
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
                } else if let last = board?.references.last, !paused {
                    Button {
                        Haptics.tap()
                        ghostID = last.id
                    } label: {
                        Label("Show overlay", systemImage: "eye")
                            .font(.caption.bold())
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(Theme.chip, in: Capsule())
                            .foregroundStyle(Theme.text)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .clearOfControls()
                }
                if camera.zoomStops.count > 1, !camera.isFront {
                    lensControl
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 8)
                        .padding(.top, 8)
                        .clearOfControls()
                }
                if lightOn, camera.isFront, !showingLibrary { RingLight(level: lightLevel) }
                if flash { Color.white.opacity(0.6).allowsHitTesting(false) }
                VStack(spacing: 8) {
                    if wheelShown, lightOn, hasLight {
                        LightWheel(level: $lightLevel, title: camera.isFront ? "SCREEN LIGHT" : "LIGHT") { showWheel() }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if camera.paused { Banner(text: "Camera paused. On iPad it stops while another app uses it.", tint: .red) }
                    if let error = camera.error { Banner(text: error, tint: .red) }
                    if let notice = camera.notice { Banner(text: notice, tint: .orange) }
                    if let saveError { Banner(text: saveError, tint: .red) }
                    if guide.fitting, ghost != nil {
                        // A picture, not words: point at the same view as the photo until it's sized.
                        Image(systemName: "viewfinder")
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.chip, in: Capsule())
                            .accessibilityLabel("Sizing the imported photo to the camera. Point at the same view.")
                    }
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

    /// Overlay strength as THEN to NOW, like Reset: all the way left is the reference at full strength, all the
    /// way right is the live camera alone. Tucked into the bottom left corner so the guide's arrows stay clear.
    private func strengthControl(wide: Bool) -> some View {
        let hide = Button {
            Haptics.tap()
            ghostID = nil
        } label: {
            Label(wide ? "Hide" : "Hide overlay", systemImage: "eye.slash")
                .font(.caption.bold()).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 30)
                .background(.white.opacity(0.18), in: Capsule())
        }
        .accessibilityLabel("Hide overlay")
        let mode = Button {
            // Paused: switch between a wipe and a fade, as Reset's Fade does.
            Haptics.tap()
            wipeStyle.toggle()
            if wipeStyle { wipePos = opacity; opacity = 1 } else { opacity = wipePos }
        } label: {
            Label(wipeStyle ? "Fade" : "Wipe", systemImage: wipeStyle ? "circle.lefthalf.filled" : "square.split.2x1")
                .font(.caption.bold()).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 30)
                .background(.white.opacity(0.18), in: Capsule())
        }
        .accessibilityLabel(wipeStyle ? "Switch to fade" : "Switch to wipe")
        let slider = Slider(value: Binding(get: { wiping ? 1 - wipePos : 1 - opacity },
                                           set: { if wiping { wipePos = 1 - $0 } else { opacity = 1 - $0 } }), in: 0...1)
            .frame(width: wide ? 150 : nil)
            .accessibilityLabel("Then to now")
            .accessibilityValue("\(Int(((1 - opacity) * 100).rounded())) percent now")
        return HStack(spacing: 6) {
            if paused { mode } else { hide }
            Text("THEN").font(.caption2.bold())
            slider
            Text("NOW").font(.caption2.bold())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.chip, in: Capsule())
        .foregroundStyle(.white)
        // Portrait: the whole width of the screen. Landscape: a compact one in the corner.
        .frame(maxWidth: wide ? nil : .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.horizontal, 8)
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
                // An imported photo sized and placed to sit on the live view.
                let fit = ghostFit ?? .none
                let ratio = ghostWhole
                    ? min(box.width / max(image.size.width, 1), box.height / max(image.size.height, 1))
                    : max(box.width / max(image.size.width, 1), box.height / max(image.size.height, 1))
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: ghostWhole ? .fit : .fill)
                    .frame(width: box.width, height: box.height)
                    .scaleEffect(CGFloat(fit.scale))
                    .offset(x: CGFloat(fit.x) * image.size.width * ratio, y: CGFloat(fit.y) * image.size.height * ratio)
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

    private static func zoomText(_ stop: Double) -> String {
        stop == stop.rounded() ? String(Int(stop)) : ".5"
    }

    private static func zoomName(_ stop: Double) -> String {
        stop < 1 ? "Ultra wide lens" : "Zoom \(zoomText(stop)) times"
    }

    /// The lens choice: a small aperture icon with the zoom in use, at the top right. Tap it to open
    /// the Camera app's stops (0.5, 1, 3...), tap one to switch. The chosen one is yellow.
    private var lensControl: some View {
        HStack(spacing: 4) {
            if lensOpen {
                ForEach(camera.zoomStops, id: \.self) { stop in
                    Button {
                        Haptics.tap()
                        camera.setZoom(stop)
                        withAnimation(.snappy(duration: 0.2)) { lensOpen = false }
                    } label: {
                        Text(Self.zoomText(stop))
                            .font(.footnote.bold())
                            .foregroundStyle(camera.zoom == stop ? Theme.onAccent : Theme.text)
                            .frame(width: 34, height: 34)
                            .background(camera.zoom == stop ? Theme.accent : Theme.chip, in: Circle())
                    }
                    .accessibilityLabel(Self.zoomName(stop))
                }
            }
            Button {
                Haptics.tap()
                withAnimation(.snappy(duration: 0.2)) { lensOpen.toggle() }
            } label: {
                HStack(spacing: 3) {
                    FieldOfView(zoom: camera.zoom).frame(width: 22, height: 16)
                    Text("\(Self.zoomText(camera.zoom))×").monospacedDigit()
                }
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 34)
                .background(Theme.chip, in: Capsule())
            }
            .accessibilityLabel("Lens, \(Self.zoomText(camera.zoom)) times")
        }
    }

    /// The LiDAR change colours, laid out like the camera picture (turned for the phone, mirrored on the front).
    private func changeLayer(_ image: CGImage, size: CGSize) -> some View {
        let turn = camera.photoToPreview
        let sideways = abs(abs(turn) - 90) < 1
        let box = sideways ? CGSize(width: size.height, height: size.width) : size
        return Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: box.width, height: box.height)
            .clipped()
            .rotationEffect(.degrees(turn))
            .frame(width: size.width, height: size.height)
            .scaleEffect(x: camera.isFront ? -1 : 1, y: 1)
            .allowsHitTesting(false)
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

    /// The board's reference photos as small thumbnails above the shutter, once there are two or more.
    /// Tap one to line up with it; no names, so nothing to read or fill in.
    @ViewBuilder
    private func referenceStrip(vertical: Bool) -> some View {
        if let board, board.references.count > 1 {
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                let items = ForEach(board.references) { shot in
                    Button {
                        Haptics.tap()
                        ghostID = shot.id
                    } label: {
                        Group {
                            if let image = store.thumbnail(shot, in: board.id) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Color.white.opacity(0.2)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(shot.id == ghostID ? Theme.accent : .white.opacity(0.5), lineWidth: 2))
                    }
                    .accessibilityLabel("Reference photo, \(shot.taken.formatted(date: .omitted, time: .shortened))")
                }
                if vertical {
                    VStack(spacing: 8) { items }.padding(.vertical, 8)
                } else {
                    HStack(spacing: 8) { items }.padding(.horizontal, 16)
                }
            }
            .frame(maxHeight: vertical ? 150 : 34)
        }
    }

    /// One thumbnail, like the Camera app's: the overlay being shown, else the latest reference.
    /// Tap it for the gallery.
    @ViewBuilder
    private func referenceButton(size: CGFloat) -> some View {
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
            .frame(width: size, height: size)
            .background(Theme.chip)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if let shot { TimeStamp(date: shot.taken, size: 8).offset(y: 9) }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(shown != nil ? Theme.accent : Theme.text, lineWidth: 2))
        }
        .accessibilityLabel("Reference photos")
        // All boards and photos, as a small grid badge on the thumbnail instead of its own button.
        .overlay(alignment: .topLeading) {
            Button {
                Haptics.tap()
                showingLibrary = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: size > 60 ? 12 : 10, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: size > 60 ? 26 : 22, height: size > 60 ? 26 : 22)
                    .background(Theme.chip, in: Circle())
            }
            .padding(4)
            .accessibilityLabel("All boards and photos")
        }
    }

    // MARK: Actions

    /// Live frames go to the guide only while it is on and there is a reference to line up with.
    private func connectGuide() {
        let guide = self.guide
        // Frames also flow with the guide off while an imported photo is being sized.
        let wanted = (guideOn || needsFit) && ghost != nil
        if wanted {
            camera.onFrame = { @Sendable [weak guide] frame, depth in guide?.consider(frame, depth: depth) }
        } else {
            camera.onFrame = nil
        }
        guide.liveAttitude = { [camera] in Motion.shared.attitude(uprightAngle: camera.uprightAngle, front: camera.isFront) }
        guide.setReference(wanted ? ghost : nil, depth: ghostDepth, aspect: visibleAspect, whole: ghostWhole,
                           prefersBody: board?.department == .costume, fit: ghostFit, needsFit: needsFit,
                           attitude: ghostShot?.attitude)
    }

    /// Keeps the size and place found for an imported photo with it, so it fits next time too.
    private func keepFit(_ fit: OverlayFit?) {
        guard let fit, let board, var shot = ghostShot, shot.source == .imported else { return }
        shot.fit = fit
        store.update(shot, in: board.id)
        show("Imported photo sized to the camera. Double tap to redo.")
    }

    /// Shows a reference when none is showing: the latest one on the board.
    private func pickReference(in chosen: Board? = nil) {
        guard let target = chosen ?? board else {
            ghostID = nil
            return
        }
        if !target.shots.contains(where: { $0.id == ghostID }) {
            ghostID = target.references.last?.id
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
                    await store.addShot(data, to: target.id, source: .imported) != nil
                {
                    continue
                }
                failed += 1
            }
            show(failed == 0 ? "Imported \(items.count)" : "\(failed) of \(items.count) could not be imported")
        }
    }

    private func shoot() {
        // A photo is always of the live view, so pausing ends.
        resume()
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
        let against = ghostShot?.id
        let alsoToPhotos = saveToPhotos
        let crop = visibleAspect
        // LiDAR depth at the moment of the shot, cropped like the photo, so it can be a reference.
        let depth = camera.currentDepth()?.cropped(aspect: crop)
        // How the phone is held at the shutter, so a later check can match its pitch and roll.
        let attitude = Motion.shared.attitude(uprightAngle: camera.uprightAngle, front: camera.isFront)
        camera.capture { data in
            guard let data else {
                saveError = "The photo did not take. Try again."
                return
            }
            Task {
                if let shot = await store.addShot(data, to: target.id, against: against, source: .camera, crop: crop, depth: depth,
                                                  zoom: camera.isFront ? nil : camera.zoom, attitude: attitude) {
                    lastShot = shot
                    // A new reference is shown straight away, so the next photo can be checked against it.
                    if shot.isReference, ghostID == nil { ghostID = shot.id }
                    saveError = nil
                    show(shot.isReference ? "Reference" : Slate.takeName(shot.take))
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
        // Back on the lens the reference was shot with, so the picture lines up.
        if let zoom = shot.zoom, !camera.isFront, camera.zoomStops.contains(zoom) { camera.setZoom(zoom) }
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
    @State private var marking: Shot?
    /// Bumped when marks are saved, so the pages reload them.
    @State private var marksVersion = 0
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
                        GalleryPage(shot: shot, boardID: board.id, marksVersion: marksVersion)
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
                            marking = current
                        } label: {
                            Label("Draw & write", systemImage: "pencil.tip")
                        }
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
        .fullScreenCover(item: $marking) { shot in
            MarkupEditor(shot: shot, boardID: boardID) { marksVersion += 1 }
        }
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
                    let shot = await store.addShot(data, to: boardID, source: .imported)
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
            let boardID = boardID
            // With drawing or notes on it, the picture saved is the marked one.
            let file = await Task.detached { BoardStore.hasMarks(shot, in: boardID) ? BoardStore.flattened(shot, in: boardID) : nil }.value
            let saved = await PhotoLibrary.save([file ?? BoardStore.url(of: shot, in: boardID)])
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
                                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.accent).padding(2)
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
    var marksVersion = 0
    @State private var image: UIImage?
    @State private var marks: UIImage?
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
                    .overlay { if let marks { Image(uiImage: marks).resizable().scaledToFit() } }
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
        .task(id: marksVersion) {
            let shot = shot
            let boardID = boardID
            marks = await Task.detached { BoardStore.marksImage(of: shot, in: boardID) }.value
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

/// A field-of-view wedge: a camera point with two lines opening out, wider on the ultra wide lens
/// and narrower the more it zooms.
struct FieldOfView: View {
    var zoom: Double

    var body: some View {
        Canvas { context, size in
            // Half the angle of view: about 42 degrees at .5, 24 at 1, 8.5 at 3.
            let half = atan(0.45 / max(zoom, 0.3))
            let height = size.height - 3
            let spread = min(size.width / 2 - 1, CGFloat(tan(half)) * height)
            let apex = CGPoint(x: size.width / 2, y: size.height - 2)
            var wedge = Path()
            wedge.move(to: apex)
            wedge.addLine(to: CGPoint(x: apex.x - spread, y: apex.y - height))
            wedge.move(to: apex)
            wedge.addLine(to: CGPoint(x: apex.x + spread, y: apex.y - height))
            wedge.move(to: CGPoint(x: apex.x - spread, y: apex.y - height))
            wedge.addLine(to: CGPoint(x: apex.x + spread, y: apex.y - height))
            context.stroke(wedge, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: apex.x - 2, y: apex.y - 2, width: 4, height: 4)), with: .foreground)
        }
        .accessibilityHidden(true)
    }
}
