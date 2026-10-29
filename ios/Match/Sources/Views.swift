import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct MatchApp: App {
    @StateObject private var store = BoardStore()

    var body: some Scene {
        WindowGroup {
            CaptureView().environmentObject(store)
        }
    }
}

// MARK: - Library

/// Every board, grouped by scene, opened from the capture screen. Opens on the board being shot.
struct HomeView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID]
    @State private var creating: Board?
    @State private var search = ""
    @State private var deletingBoards: [Board] = []
    @State private var showingHelp = false
    @State private var showingNotes = false
    @State private var sharing: SharedFile?
    @State private var backupError: String?

    init(openBoard: UUID? = nil) {
        _path = State(initialValue: openBoard.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.boards.isEmpty {
                    Text("Make a board for each character or prop you look after, for example \"Sarah · Hair\" in scene 12. Then take reference photos, or import QTake screenshots, and check against them before each take.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.scenes, id: \.self) { scene in
                    let boards = store.boards
                        .filter { $0.scene == scene && $0.matches(search) }
                        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                    if !boards.isEmpty {
                        Section {
                            ForEach(boards) { board in
                                NavigationLink(value: board.id) { BoardRow(board: board) }
                            }
                            .onDelete { offsets in deletingBoards = offsets.map { boards[$0] } }
                        } header: {
                            HStack {
                                Text(scene.isEmpty ? "No scene" : "Scene \(scene)")
                                Spacer()
                                Text(Slate.takeName(store.take(for: scene)))
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Shows which build is installed, so an old install is easy to spot.
                Text("Match build \(AppInfo.build)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            .searchable(text: $search, prompt: "Character, prop or note")
            .navigationTitle("Boards")
            .navigationDestination(for: UUID.self) { id in BoardView(boardID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Camera", systemImage: "camera.fill")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showingHelp = true } label: { Label("How to use Match", systemImage: "questionmark.circle") }
                        Button { showingNotes = true } label: { Label("Tester notes", systemImage: "note.text") }
                        Button(action: backUp) { Label("Back up all boards", systemImage: "externaldrive") }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = store.newBoard()
                    } label: {
                        Label("New board", systemImage: "plus")
                    }
                }
            }
            .confirmationDialog(
                deletingBoards.count == 1 ? "Delete \(deletingBoards[0].title) and all its photos?" : "Delete \(deletingBoards.count) boards and all their photos?",
                isPresented: Binding(get: { !deletingBoards.isEmpty }, set: { if !$0 { deletingBoards = [] } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deletingBoards.forEach { store.delete($0) }
                    deletingBoards = []
                }
            }
            .sheet(isPresented: $showingHelp) { HelpView() }
            .sheet(isPresented: $showingNotes) { TesterNotesView() }
            .sheet(item: $sharing) { file in ShareSheet(items: [file.url]) }
            .alert("Backup", isPresented: Binding(get: { backupError != nil }, set: { if !$0 { backupError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(backupError ?? "")
            }
            .sheet(item: $creating) { board in
                BoardEditor(board: board, isNew: true) { saved in
                    store.save(saved)
                    path.append(saved.id)
                }
            }
        }
    }
}

extension HomeView {
    private func backUp() {
        do {
            sharing = SharedFile(url: try Backup.make())
        } catch {
            backupError = "Could not make the backup: \(error.localizedDescription)"
        }
    }
}

struct BoardRow: View {
    @EnvironmentObject private var store: BoardStore
    let board: Board

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover = board.cover, let image = store.thumbnail(cover, in: board.id) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: board.department.symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(board.subject.isEmpty ? board.department.name : board.subject).font(.headline)
                Label(board.department.name, systemImage: board.department.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(board.shots.count == 1 ? "1 photo" : "\(board.shots.count) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Scene, subject, department and notes for a board.
struct BoardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var board: Board
    let isNew: Bool
    let onSave: (Board) -> Void

    init(board: Board, isNew: Bool, onSave: @escaping (Board) -> Void) {
        _board = State(initialValue: board)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Scene") {
                    TextField("12", text: $board.scene)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Character") {
                    TextField("Sarah", text: $board.subject)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Change or look") {
                    TextField("Change 2", text: $board.look)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Department", selection: $board.department) {
                    ForEach(Department.picked(board.department)) { department in
                        Label(department.name, systemImage: department.symbol).tag(department)
                    }
                }
                Section("Notes") {
                    TextField("For example: hair tucked behind left ear, top button undone", text: $board.notes, axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .navigationTitle(isNew ? "New board" : "Edit board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") {
                        board.scene = board.scene.trimmingCharacters(in: .whitespaces)
                        onSave(board)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Board

/// One board: the take counter, quick actions, reference photos, then every photo by take.
struct BoardView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.shoot) private var shoot
    let boardID: UUID
    @State private var comparing: ComparePair?
    @State private var viewing: Shot?
    @State private var editing = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var importing = 0
    @State private var sharing: SharedFile?
    @State private var message: String?
    @State private var deleting: Shot?

    private let grid = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    var body: some View {
        if let board = store.board(boardID) {
            content(board)
        } else {
            ContentUnavailableView("Board deleted", systemImage: "trash")
        }
    }

    private func content(_ board: Board) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !board.notes.isEmpty {
                    Text(board.notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { editing = true }
                }
                TakeBar(scene: board.scene)
                actions(board)
                if importing > 0 {
                    ProgressView("Importing \(importing) photo\(importing == 1 ? "" : "s")")
                }
                if board.shots.isEmpty {
                    Text("No photos yet. Tap Camera to take reference photos, or Import to bring in QTake screenshots or photos. The first photo from each angle becomes the reference.")
                        .foregroundStyle(.secondary)
                }
                if !board.references.isEmpty {
                    section("References", shots: board.references, board: board)
                }
                ForEach(board.takes, id: \.self) { take in
                    section(Slate.takeName(take), shots: board.shots(in: take), board: board)
                }
            }
            .padding()
        }
        .navigationTitle("Sc \(board.scene) · \(board.subject.isEmpty ? board.department.name : board.subject)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editing = true } label: { Label("Edit board", systemImage: "pencil") }
                    Button { sharePDF(board) } label: { Label("Share PDF sheet", systemImage: "doc.richtext") }
                    Button {
                        Task {
                            let saved = await PhotoLibrary.save(board.shots.sorted { $0.taken < $1.taken }.map { BoardStore.url(of: $0, in: board.id) })
                            message = saved ? "Saved \(board.shots.count) photos to Photos." : PhotoLibrary.deniedMessage
                        }
                    } label: { Label("Save all photos to Photos", systemImage: "square.and.arrow.down.on.square") }
                        .disabled(board.shots.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .dropDestination(for: Data.self) { items, _ in
            importData(items)
            return true
        }
        .onChange(of: pickerItems) { _, items in importPicked(items) }
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .fullScreenCover(item: $comparing) { pair in
            CompareView(boardID: boardID, before: pair.before, after: pair.after).environmentObject(store)
        }
        .sheet(item: $viewing) { shot in
            ShotView(boardID: boardID, shotID: shot.id).environmentObject(store).environment(\.shoot, shoot)
        }
        .sheet(isPresented: $editing) {
            BoardEditor(board: board, isNew: false) { store.save($0) }
        }
        .sheet(item: $sharing) { file in ShareSheet(items: [file.url]) }
        .confirmationDialog("Delete this photo?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete photo", role: .destructive) {
                if let deleting { store.delete(deleting, from: boardID) }
                deleting = nil
            }
        }
        .alert("Photos", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func actions(_ board: Board) -> some View {
        HStack(spacing: 10) {
            actionButton("Camera", systemImage: "camera.viewfinder") {
                shoot(board.id)
            }
            Menu {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .images) {
                    Label("Photos and screenshots", systemImage: "photo.on.rectangle")
                }
                Button { importingFiles = true } label: { Label("Files", systemImage: "folder") }
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            } label: {
                actionLabel("Import", systemImage: "square.and.arrow.down")
            }
            actionButton("Compare", systemImage: "rectangle.split.2x1") {
                let after = board.newest
                comparing = ComparePair(before: after.flatMap(board.reference(for:))?.id, after: after?.id)
            }
            .disabled(board.shots.count < 2)
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, systemImage: systemImage) }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.title2)
            Text(title).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func section(_ title: String, shots: [Shot], board: Board) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            LazyVGrid(columns: grid, spacing: 6) {
                ForEach(shots) { shot in
                    Button {
                        viewing = shot
                    } label: {
                        ShotThumbnail(shot: shot, boardID: board.id)
                    }
                    .contextMenu {
                        Button { shoot(board.id, ghost: shot) } label: { Label("Match with camera", systemImage: "camera.viewfinder") }
                        Button {
                            comparing = ComparePair(before: board.reference(for: shot)?.id, after: shot.id)
                        } label: { Label("Compare with reference", systemImage: "rectangle.split.2x1") }
                        Button {
                            var changed = shot
                            changed.isReference.toggle()
                            store.update(changed, in: board.id)
                        } label: {
                            Label(shot.isReference ? "Not a reference" : "Make reference", systemImage: shot.isReference ? "star.slash" : "star")
                        }
                        Button(role: .destructive) { deleting = shot } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
        }
    }

    // MARK: Import

    private func importPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickerItems = []
        importing += items.count
        Task {
            var failed = 0
            for item in items {
                // Fails for photos kept only in iCloud when there is no signal.
                let data = try? await item.loadTransferable(type: Data.self)
                if data == nil { failed += 1 }
                if let data, await store.addShot(data, to: boardID, angle: "", source: .imported) == nil { failed += 1 }
                importing -= 1
            }
            report(failed: failed, of: items.count)
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let files = urls.compactMap { url -> Data? in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }
        add(files, expected: urls.count)
    }

    private func importData(_ items: [Data]) {
        add(items, expected: items.count)
    }

    private func paste() {
        let images = UIPasteboard.general.images ?? []
        if images.isEmpty {
            message = "There is no picture on the clipboard. Copy a screenshot or photo first."
            return
        }
        add(images.compactMap { $0.jpegData(compressionQuality: 0.95) }, expected: images.count)
    }

    private func add(_ files: [Data], expected: Int) {
        guard expected > 0 else { return }
        importing += files.count
        Task {
            var failed = expected - files.count
            for data in files {
                if await store.addShot(data, to: boardID, angle: "", source: .imported) == nil { failed += 1 }
                importing -= 1
            }
            report(failed: failed, of: expected)
        }
    }

    private func report(failed: Int, of total: Int) {
        guard failed > 0 else { return }
        message = failed == total && total == 1
            ? "That photo could not be imported. If it is only in iCloud, it needs signal to download first."
            : "\(failed) of \(total) photos could not be imported. Photos kept only in iCloud need signal to download; also check the device has free storage."
    }

    private func sharePDF(_ board: Board) {
        do {
            sharing = SharedFile(url: try BoardPDF.make(for: board))
        } catch {
            message = "Could not make the PDF: \(error.localizedDescription)"
        }
    }
}

/// The scene's take counter, shared by every board in the scene. Prep is before the first take.
struct TakeBar: View {
    @EnvironmentObject private var store: BoardStore
    let scene: String

    var body: some View {
        let take = store.take(for: scene)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(scene.isEmpty ? "No scene" : "Scene \(scene)").font(.caption).foregroundStyle(.secondary)
                Text(Slate.takeName(take)).font(.title2.weight(.semibold).monospacedDigit())
            }
            Spacer()
            Button {
                store.setTake(take - 1, for: scene)
            } label: {
                Image(systemName: "minus").frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(take == 0)
            .accessibilityLabel("Previous take")
            Button {
                store.setTake(take + 1, for: scene)
            } label: {
                Label("Next take", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// When a photo was taken, small enough to sit on a thumbnail: the time today, else day and time.
struct TimeStamp: View {
    let date: Date
    var size: CGFloat = 10

    var body: some View {
        Text(Calendar.current.isDateInToday(date)
             ? date.formatted(date: .omitted, time: .shortened)
             : date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
            .font(.system(size: size, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.black.opacity(0.6), in: Capsule())
    }
}

struct ShotThumbnail: View {
    @EnvironmentObject private var store: BoardStore
    let shot: Shot
    let boardID: UUID

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = store.thumbnail(shot, in: boardID) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if shot.isReference {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(5)
                        .background(.black.opacity(0.5), in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                TimeStamp(date: shot.taken).padding(4)
            }
            .overlay(alignment: .topTrailing) {
                let parts = [shot.angle, shot.note.isEmpty ? "" : "✎"].filter { !$0.isEmpty }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " "))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(4)
                }
            }
    }
}

// MARK: - One photo

/// A photo full screen, with its take, angle and notes, and actions.
struct ShotView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    let boardID: UUID
    let shotID: UUID
    @State private var image: UIImage?
    @State private var zoom = ZoomState()
    @State private var editing = false
    @Environment(\.shoot) private var shoot
    @State private var comparing: ComparePair?
    @State private var confirmingDelete = false

    private var board: Board? { store.board(boardID) }
    private var shot: Shot? { board?.shots.first { $0.id == shotID } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                            .scaleEffect(zoom.scale)
                            .offset(zoom.offset)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .clipped()
                .modifier(ZoomGestures(zoom: $zoom))
                if let shot {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if shot.isReference { Label("Reference", systemImage: "star.fill").foregroundStyle(.yellow) }
                            Text(shot.label)
                            if shot.source == .imported { Text("· imported").foregroundStyle(.secondary) }
                        }
                        .font(.subheadline.weight(.medium))
                        if !shot.note.isEmpty { Text(shot.note).font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            .navigationTitle(board?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let shot, let board {
                        Button {
                            var changed = shot
                            changed.isReference.toggle()
                            store.update(changed, in: boardID)
                        } label: {
                            Label("Reference", systemImage: shot.isReference ? "star.fill" : "star")
                        }
                        Spacer()
                        Button { shoot(boardID, ghost: shot) } label: { Label("Match", systemImage: "camera.viewfinder") }
                        Spacer()
                        Button {
                            comparing = ComparePair(before: board.reference(for: shot)?.id, after: shot.id)
                        } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                            .disabled(board.shots.count < 2)
                        Spacer()
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        Spacer()
                        ShareLink(item: BoardStore.url(of: shot, in: boardID)) { Label("Share", systemImage: "square.and.arrow.up") }
                        Spacer()
                        Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .task {
                guard let shot else { return }
                let boardID = self.boardID
                image = await Task.detached(priority: .userInitiated) { BoardStore.image(shot, in: boardID, maxPixels: 3024) }.value
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete photo", role: .destructive) {
                    if let shot { store.delete(shot, from: boardID) }
                    dismiss()
                }
            }
            .sheet(isPresented: $editing) {
                if let shot {
                    ShotEditor(shot: shot) { store.update($0, in: boardID) }
                }
            }
            .fullScreenCover(item: $comparing) { pair in
                CompareView(boardID: boardID, before: pair.before, after: pair.after).environmentObject(store)
            }
        }
    }
}

/// Take, angle, notes and reference flag for one photo.
struct ShotEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var shot: Shot
    let onSave: (Shot) -> Void

    init(shot: Shot, onSave: @escaping (Shot) -> Void) {
        _shot = State(initialValue: shot)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper(Slate.takeName(shot.take), value: $shot.take, in: 0...999)
                Picker("Angle", selection: $shot.angle) {
                    Text("None").tag("")
                    ForEach(Slate.angles, id: \.self) { Text($0).tag($0) }
                    if !shot.angle.isEmpty && !Slate.angles.contains(shot.angle) {
                        Text(shot.angle).tag(shot.angle)
                    }
                }
                Toggle("Reference photo", isOn: $shot.isReference)
                Section("Notes") {
                    TextField("For example: collar flipped up on the right", text: $shot.note, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(shot)
                        dismiss()
                    }
                }
            }
        }
    }
}
