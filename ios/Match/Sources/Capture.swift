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

/// The main screen, like the iPhone Camera app: everything for checking continuity is one tap away.
/// Nothing is saved until the shutter is pressed. Board and take at the top; angles above the
/// shutter (picking an angle shows its reference); the reference thumbnail at bottom left opens a
/// gallery to pick the overlay or compare; the library at bottom right.
struct CaptureView: View {
    @EnvironmentObject private var store: BoardStore
    @StateObject private var camera = Camera()
    @AppStorage("currentBoard") private var currentBoard = ""
    @AppStorage("seenHelp") private var seenHelp = false
    @State private var ghostID: UUID?
    @State private var angle = ""
    @State private var ghost: UIImage?
    @State private var ghostEdges: UIImage?
    @State private var opacity = 0.4
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
    @State private var flash = false
    @State private var saveError: String?
    @State private var toast: String?

    /// The board being shot: the one chosen last, else the newest.
    private var board: Board? {
        UUID(uuidString: currentBoard).flatMap(store.board) ?? store.boards.max { $0.created < $1.created }
    }

    var body: some View {
        GeometryReader { geometry in
            // Controls sit beside the picture, never on it.
            let landscape = geometry.size.width > geometry.size.height
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if landscape { leftColumn } else { topBar }
                viewfinder
                if landscape { rightColumn(height: geometry.size.height) } else { bottomBar }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(.yellow)
        .statusBarHidden()
        .onAppear {
            camera.start()
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
        .sheet(isPresented: $showingHelp, onDismiss: { seenHelp = true }) { HelpView() }
        .sheet(isPresented: $showingGallery) {
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

    // MARK: Picture

    private var viewfinder: some View {
        ZStack(alignment: .top) {
            ZStack {
                CameraPreview(camera: camera)
                ghostLayer
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(ghostGesture)
            .onTapGesture(count: 2) {
                withAnimation {
                    ghostScale = 1
                    ghostOffset = .zero
                }
            }
            if flash { Color.white.opacity(0.6).allowsHitTesting(false) }
            VStack(spacing: 6) {
                if camera.paused { banner("Camera paused. On iPad it stops while another app uses it.") }
                if let error = camera.error { banner(error) }
                if let saveError { banner(saveError) }
                if let toast {
                    Text(toast)
                        .font(.title2.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .transition(.opacity)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var ghostLayer: some View {
        if let image = outlines ? ghostEdges : ghost {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .colorMultiply(outlines ? .cyan : .white)
                .blendMode(outlines ? .screen : .normal)
                .opacity(outlines ? max(opacity, 0.6) : opacity)
                .scaleEffect(x: camera.isFront ? -ghostScale : ghostScale, y: ghostScale)
                .offset(ghostOffset)
                .allowsHitTesting(false)
        }
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

    // MARK: Portrait

    private var topBar: some View {
        HStack(spacing: 14) {
            boardMenu(compact: false)
            Spacer(minLength: 4)
            takeMenu
            flipButton
        }
        .padding(.horizontal)
        .frame(height: 44)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if ghost != nil { opacityRow.padding(.horizontal) }
            angleStrip
            HStack {
                referenceButton
                Spacer()
                shutter
                Spacer()
                libraryButton
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 8)
    }

    // MARK: Landscape

    private var leftColumn: some View {
        VStack(spacing: 14) {
            libraryButton
            boardMenu(compact: true)
            takeMenu
            Spacer(minLength: 4)
            if ghost != nil {
                Slider(value: $opacity, in: 0...1)
                    .frame(width: 110)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 36, height: 110)
                outlinesButton
                hideButton
            }
            Spacer(minLength: 4)
            flipButton
        }
        .padding(.vertical, 12)
        .frame(width: 84)
    }

    private func rightColumn(height: CGFloat) -> some View {
        VStack(spacing: 10) {
            angleMenu
            Spacer(minLength: 4)
            shutter
            Spacer(minLength: 4)
            referenceButton
        }
        .padding(.vertical, 12)
        .frame(width: 104)
    }

    // MARK: Controls

    private var opacityRow: some View {
        HStack(spacing: 10) {
            hideButton
            Slider(value: $opacity, in: 0...1)
            outlinesButton
        }
    }

    private var outlinesButton: some View {
        Button {
            outlines.toggle()
        } label: {
            Image(systemName: outlines ? "square.dashed" : "photo").frame(width: 32, height: 32)
        }
        .accessibilityLabel(outlines ? "Show whole photo" : "Show outlines only")
    }

    private var hideButton: some View {
        Button {
            ghostID = nil
        } label: {
            Image(systemName: "eye.slash").frame(width: 32, height: 32)
        }
        .accessibilityLabel("Hide overlay")
    }

    private var flipButton: some View {
        Button {
            camera.flip()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3).frame(width: 36, height: 36)
        }
        .accessibilityLabel("Switch camera")
    }

    private var shutter: some View {
        Button(action: shoot) {
            ZStack {
                Circle().fill(.white).frame(width: 60, height: 60)
                Circle().stroke(.white, lineWidth: 3).frame(width: 72, height: 72)
            }
        }
        .accessibilityLabel("Take photo")
    }

    private var libraryButton: some View {
        Button {
            showingLibrary = true
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
        .accessibilityLabel("Boards and photos")
    }

    /// Switch boards in one tap; boards grouped by scene, newest scene first.
    private func boardMenu(compact: Bool) -> some View {
        Menu {
            Button {
                creating = store.newBoard()
            } label: {
                Label("New board", systemImage: "plus")
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
            if compact {
                VStack(spacing: 2) {
                    Image(systemName: "rectangle.stack.badge.person.crop").font(.title3)
                    Text(board.map { "Sc \($0.scene)" } ?? "Board").font(.caption2).lineLimit(1)
                }
                .frame(width: 70)
            } else {
                HStack(spacing: 4) {
                    Text(board.map { "Sc \($0.scene) · \($0.subject.isEmpty ? $0.department.name : $0.subject)" } ?? "New board")
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
            }
        }
        .accessibilityLabel("Choose board")
    }

    /// Tap for the next take; touch and hold to go back or to Prep.
    private var takeMenu: some View {
        let scene = board?.scene ?? ""
        let take = store.take(for: scene)
        return Menu {
            if take > 0 {
                Button("Back to \(Slate.takeName(take - 1))") { setTake(take - 1, scene: scene) }
                Button("Prep") { setTake(0, scene: scene) }
            }
            Button("Next take (\(take + 1))") { setTake(take + 1, scene: scene) }
        } label: {
            VStack(spacing: 0) {
                Text(take == 0 ? "PREP" : "TAKE").font(.system(size: 9, weight: .bold))
                Text(take == 0 ? "–" : "\(take)").font(.title3.weight(.bold).monospacedDigit())
            }
            .frame(minWidth: 44, minHeight: 36)
            .padding(.horizontal, 4)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        } primaryAction: {
            setTake(take + 1, scene: scene)
        }
        .accessibilityLabel("Take \(take). Tap for next take, hold for more.")
    }

    /// Angles in a row like the Camera app's modes. Picking one also picks its reference.
    private var angleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach([""] + Slate.angles, id: \.self) { item in
                    Button {
                        selectAngle(item)
                    } label: {
                        Text(item.isEmpty ? "ANY" : item.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item == angle ? Color.yellow : .white)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 24)
    }

    private var angleMenu: some View {
        Menu {
            Picker("Angle", selection: Binding(get: { angle }, set: { selectAngle($0) })) {
                Text("Any angle").tag("")
                ForEach(Slate.angles, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            Text(angle.isEmpty ? "ANY" : angle.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)
                .frame(width: 84, height: 30)
                .background(.white.opacity(0.15), in: Capsule())
        }
    }

    /// One thumbnail, like the Camera app's: the overlay being shown, else the latest reference.
    /// Tap it for the gallery.
    @ViewBuilder
    private var referenceButton: some View {
        let shown = ghostID.flatMap { id in board?.shots.first { $0.id == id } }
        let shot = shown ?? board?.references.last
        Button {
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
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(shown != nil ? Color.yellow : .white, lineWidth: 2))
        }
        .disabled(board?.shots.isEmpty ?? true)
        .accessibilityLabel("Reference photos")
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .padding(10)
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Actions

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

    private func setTake(_ take: Int, scene: String) {
        store.setTake(take, for: scene)
        show(Slate.takeName(max(0, take)))
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { if toast == message { toast = nil } }
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
        camera.capture { data in
            guard let data else {
                saveError = "The photo did not take. Try again."
                return
            }
            Task {
                if let shot = await store.addShot(data, to: target.id, angle: angle, source: .camera) {
                    lastShot = shot
                    // A new reference is shown straight away, so the next photo can be checked against it.
                    if shot.isReference, ghostID == nil { ghostID = shot.id }
                    saveError = nil
                    show(shot.isReference ? "Reference \(shot.angle.isEmpty ? "" : shot.angle)" : Slate.takeName(shot.take))
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
            return
        }
        let boardID = board.id
        let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, UIImage?) in
            let image = BoardStore.image(shot, in: boardID, maxPixels: 1600)
            return (image, image.flatMap(Ghost.edges(of:)))
        }.value
        guard !Task.isCancelled else { return }
        ghost = loaded.0
        ghostEdges = loaded.1
    }
}

// MARK: - Gallery

/// The board's photos, references first. Tap one to show it over the camera; compare the latest
/// photo from the top.
struct GalleryView: View {
    enum Choice {
        case overlay(Shot?)
        case compare(before: UUID?, after: UUID)
    }

    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    let board: Board
    let overlay: UUID?
    let last: Shot?
    let onChoose: (Choice) -> Void

    private let grid = [GridItem(.adaptive(minimum: 96), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let last, board.shots.count > 1 {
                        Button {
                            let shown = overlay.flatMap { id in board.shots.first { $0.id == id } }
                            let before = shown?.id == last.id ? board.reference(for: last) : (shown ?? board.reference(for: last))
                            onChoose(.compare(before: before?.id, after: last.id))
                        } label: {
                            Label("Compare latest photo with its reference", systemImage: "rectangle.split.2x1")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    section("References", board.references.reversed())
                    ForEach(board.takes, id: \.self) { take in
                        section(Slate.takeName(take), board.shots(in: take).filter { !$0.isReference }.reversed())
                    }
                }
                .padding()
            }
            .navigationTitle(board.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("No overlay") { onChoose(.overlay(nil)) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ shots: [Shot]) -> some View {
        if !shots.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                LazyVGrid(columns: grid, spacing: 6) {
                    ForEach(shots) { shot in
                        Button {
                            onChoose(.overlay(shot))
                        } label: {
                            ShotThumbnail(shot: shot, boardID: board.id)
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.yellow, lineWidth: shot.id == overlay ? 3 : 0))
                        }
                        .contextMenu {
                            Button {
                                onChoose(.compare(before: board.reference(for: shot)?.id, after: shot.id))
                            } label: {
                                Label("Compare with reference", systemImage: "rectangle.split.2x1")
                            }
                        }
                    }
                }
            }
        }
    }
}
