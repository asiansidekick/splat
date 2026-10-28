import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct MatchApp: App {
    @StateObject private var store = BoardStore()

    var body: some Scene {
        WindowGroup {
            HomeView().environmentObject(store)
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var store: BoardStore
    @State private var path: [UUID] = []
    @State private var creating: Board?
    @State private var search = ""

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
                            .onDelete { offsets in offsets.map { boards[$0] }.forEach { store.delete($0) } }
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
            .searchable(text: $search, prompt: "Character, prop or note")
            .navigationTitle("Continuity")
            .navigationDestination(for: UUID.self) { id in BoardView(boardID: id) }
            .toolbar {
                Button {
                    creating = store.newBoard()
                } label: {
                    Label("New board", systemImage: "plus")
                }
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
                LabeledContent("Character or prop") {
                    TextField("Sarah", text: $board.subject)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Department", selection: $board.department) {
                    ForEach(Department.allCases) { department in
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
    let boardID: UUID
    @State private var matching: MatchRequest?
    @State private var comparing: ComparePair?
    @State private var viewing: Shot?
    @State private var editing = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var importing = 0
    @State private var sharing: SharedFile?
    @State private var message: String?

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
        .fullScreenCover(item: $matching) { request in
            MatchCameraView(boardID: boardID, ghost: request.ghost).environmentObject(store)
        }
        .fullScreenCover(item: $comparing) { pair in
            CompareView(boardID: boardID, before: pair.before, after: pair.after).environmentObject(store)
        }
        .sheet(item: $viewing) { shot in
            ShotView(boardID: boardID, shotID: shot.id).environmentObject(store)
        }
        .sheet(isPresented: $editing) {
            BoardEditor(board: board, isNew: false) { store.save($0) }
        }
        .sheet(item: $sharing) { file in ShareSheet(items: [file.url]) }
        .alert("Import", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func actions(_ board: Board) -> some View {
        HStack(spacing: 10) {
            actionButton("Camera", systemImage: "camera.viewfinder") {
                matching = MatchRequest(ghost: board.references.last ?? board.newest)
            }
            Menu {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 30, selectionBehavior: .ordered, matching: .images) {
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
                        Button { matching = MatchRequest(ghost: shot) } label: { Label("Match with camera", systemImage: "camera.viewfinder") }
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
                        Button(role: .destructive) { store.delete(shot, from: board.id) } label: { Label("Delete", systemImage: "trash") }
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
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await store.addShot(image, to: boardID, angle: "", source: .imported)
                }
                importing -= 1
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let images = urls.compactMap { url -> UIImage? in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
        }
        add(images)
    }

    private func importData(_ items: [Data]) {
        add(items.compactMap(UIImage.init(data:)))
    }

    private func paste() {
        let images = UIPasteboard.general.images ?? []
        if images.isEmpty {
            message = "There is no picture on the clipboard. Copy a screenshot or photo first."
        }
        add(images)
    }

    private func add(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        importing += images.count
        Task {
            for image in images {
                await store.addShot(image, to: boardID, angle: "", source: .imported)
                importing -= 1
            }
        }
    }

    private func sharePDF(_ board: Board) {
        do {
            sharing = SharedFile(url: try BoardPDF.make(for: board))
        } catch {
            message = "Could not make the PDF: \(error.localizedDescription)"
        }
    }
}

struct MatchRequest: Identifiable {
    let id = UUID()
    let ghost: Shot?
}

/// The scene's take counter, shared by every board in the scene. Prep is before the first take.
struct TakeBar: View {
    @EnvironmentObject private var store: BoardStore
    let scene: String

    var body: some View {
        let take = store.take(for: scene)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scene \(scene)").font(.caption).foregroundStyle(.secondary)
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
            .overlay(alignment: .bottomLeading) {
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
    @State private var matching: MatchRequest?
    @State private var comparing: ComparePair?

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
                        Button { matching = MatchRequest(ghost: shot) } label: { Label("Match", systemImage: "camera.viewfinder") }
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
                        Button(role: .destructive) {
                            store.delete(shot, from: boardID)
                            dismiss()
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .task {
                guard let shot else { return }
                let boardID = self.boardID
                image = await Task.detached(priority: .userInitiated) { BoardStore.image(shot, in: boardID, maxPixels: 3024) }.value
            }
            .sheet(isPresented: $editing) {
                if let shot {
                    ShotEditor(shot: shot) { store.update($0, in: boardID) }
                }
            }
            .fullScreenCover(item: $matching) { request in
                MatchCameraView(boardID: boardID, ghost: request.ghost).environmentObject(store)
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
