import SwiftUI
import UIKit

/// Which two photos to compare.
struct ComparePair: Identifiable {
    let id = UUID()
    let before: UUID?
    let after: UUID?
}

/// Puts two photos from a board against each other, offline: side by side, a wipe, a blend,
/// flicker, or the changes highlighted in red. Pinch to zoom; both photos zoom together.
struct CompareView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case side = "Side", wipe = "Wipe", blend = "Blend", flicker = "Flicker", changes = "Changes"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    let boardID: UUID
    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var mode: Mode = .side
    @State private var before: UIImage?
    @State private var after: UIImage?
    @State private var aligned: Aligned?
    @State private var aligning = false
    @State private var lineUp = true
    @State private var wipe = 0.5
    @State private var blend = 0.5
    @State private var sensitivity = 0.3
    @State private var changes: UIImage?
    @State private var zoom = ZoomState()
    @State private var sharing: SharedFile?
    @State private var expanded = false

    init(boardID: UUID, before: UUID?, after: UUID?) {
        self.boardID = boardID
        _beforeID = State(initialValue: before)
        _afterID = State(initialValue: after)
    }

    private var board: Board? { store.board(boardID) }
    private var beforeShot: Shot? { board?.shots.first { $0.id == beforeID } }
    private var afterShot: Shot? { board?.shots.first { $0.id == afterID } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // The photos get most of the screen: controls go in a side column in landscape,
                // and the expand button hides them altogether.
                let landscape = geometry.size.width > geometry.size.height
                if landscape {
                    HStack(spacing: 12) {
                        framedPicture
                        if !expanded {
                            ScrollView {
                                VStack(spacing: 12) { controls }
                            }
                            .frame(width: min(320, geometry.size.width * 0.38))
                        }
                    }
                    .padding(8)
                } else {
                    VStack(spacing: 8) {
                        framedPicture
                        if !expanded { controls }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle(board?.title ?? "Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button(action: share) { Label("Share", systemImage: "square.and.arrow.up") }
                        .disabled(before == nil || after == nil)
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        Label(expanded ? "Show controls" : "Hide controls",
                              systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: "\(beforeID?.uuidString ?? "")|\(afterID?.uuidString ?? "")") { await load() }
            .task(id: "\(sensitivity)|\(aligned == nil)") { await updateChanges() }
            .sheet(item: $sharing) { file in ShareSheet(items: [file.url]) }
        }
    }

    // MARK: Pieces

    private var framedPicture: some View {
        picture
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .modifier(ZoomGestures(zoom: $zoom))
    }

    @ViewBuilder
    private var controls: some View {
        pickers
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        modeControls
    }

    private var pickers: some View {
        HStack {
            shotMenu("Before", selection: $beforeID)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            shotMenu("After", selection: $afterID)
        }
    }

    private func shotMenu(_ title: String, selection: Binding<UUID?>) -> some View {
        Menu {
            if let board {
                Picker(title, selection: selection) {
                    ForEach(board.shots.sorted { $0.taken > $1.taken }) { shot in
                        Text((shot.isReference ? "★ " : "") + shot.label).tag(Optional(shot.id))
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(board?.shots.first { $0.id == selection.wrappedValue }?.label ?? "Choose")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let before, let after {
            switch mode {
            case .side:
                SideBySide(before: before, after: after, beforeLabel: beforeShot?.label ?? "Before",
                           afterLabel: afterShot?.label ?? "After", zoom: zoom)
            case .wipe, .blend, .flicker:
                let top = lineUp ? (aligned?.after ?? after) : after
                Stacked(before: before, after: top, mode: mode, wipe: wipe, blend: blend)
                    .scaleEffect(zoom.scale)
                    .offset(zoom.offset)
            case .changes:
                if let aligned {
                    ZStack {
                        Image(uiImage: aligned.after).resizable()
                        if let changes { Image(uiImage: changes).resizable() }
                    }
                    .aspectRatio(aligned.after.size, contentMode: .fit)
                    .scaleEffect(zoom.scale)
                    .offset(zoom.offset)
                } else {
                    ProgressView("Lining up the photos")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
        } else if beforeID == nil || afterID == nil {
            ContentUnavailableView("Choose two photos", systemImage: "photo.on.rectangle",
                                   description: Text("Pick a before and an after photo above."))
        } else {
            ProgressView().tint(.white)
        }
    }

    @ViewBuilder
    private var modeControls: some View {
        switch mode {
        case .side:
            hint("Pinch to zoom both photos together. Double tap to reset.")
        case .wipe:
            Slider(value: $wipe, in: 0...1) { Text("Wipe") } minimumValueLabel: { Text("After").font(.caption) } maximumValueLabel: { Text("Before").font(.caption) }
            lineUpToggle
        case .blend:
            Slider(value: $blend, in: 0...1) { Text("Blend") } minimumValueLabel: { Text("After").font(.caption) } maximumValueLabel: { Text("Before").font(.caption) }
            lineUpToggle
        case .flicker:
            hint("Switches between the two photos; anything that changed jumps.")
            lineUpToggle
        case .changes:
            Slider(value: $sensitivity, in: 0...1) { Text("Sensitivity") } minimumValueLabel: { Text("Less").font(.caption) } maximumValueLabel: { Text("More").font(.caption) }
            hint(aligned.map { $0.lined
                ? "Red marks what looks different. Photos were lined up automatically; this works best from about the same spot."
                : "Could not line up these photos (framing too different), so red may include things that only look shifted."
            } ?? "")
        }
    }

    private var lineUpToggle: some View {
        Toggle("Line up automatically", isOn: $lineUp)
            .font(.subheadline)
            .disabled(aligned == nil)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Work

    private func load() async {
        before = nil
        after = nil
        aligned = nil
        changes = nil
        zoom = ZoomState()
        guard let beforeShot, let afterShot else { return }
        let boardID = self.boardID
        let images = await Task.detached(priority: .userInitiated) {
            (BoardStore.image(beforeShot, in: boardID), BoardStore.image(afterShot, in: boardID))
        }.value
        guard !Task.isCancelled, let first = images.0, let second = images.1 else { return }
        before = first
        after = second
        let result = await Task.detached(priority: .userInitiated) { Differ.align(before: first, after: second) }.value
        guard !Task.isCancelled else { return }
        aligned = result
    }

    private func updateChanges() async {
        guard let difference = aligned?.difference else {
            changes = nil
            return
        }
        // Sensitivity 0...1 maps to a difference threshold of 0.4 down to 0.08. The default (0.3)
        // ignores small shifts from lighting and imperfect lining up, so only real changes show.
        let threshold = Float(0.4 - 0.32 * sensitivity)
        let image = await Task.detached(priority: .userInitiated) { Differ.changes(difference, threshold: threshold) }.value
        guard !Task.isCancelled else { return }
        changes = image
    }

    private func share() {
        guard let before, let after, let board else { return }
        let image = PairImage.make(
            before: before, after: after, title: "Scene \(board.scene) · \(board.title)",
            beforeLabel: beforeShot?.label ?? "Before", afterLabel: afterShot?.label ?? "After")
        let url = FileManager.default.temporaryDirectory.appending(path: "Scene \(board.scene) compare.jpg")
        guard let data = image.jpegData(compressionQuality: 0.9), (try? data.write(to: url, options: .atomic)) != nil else { return }
        sharing = SharedFile(url: url)
    }
}

/// Two photos next to each other, across or stacked, whichever shows them bigger.
private struct SideBySide: View {
    let before: UIImage
    let after: UIImage
    let beforeLabel: String
    let afterLabel: String
    let zoom: ZoomState

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let aspect = (before.size.width / max(before.size.height, 1) + after.size.width / max(after.size.height, 1)) / 2
            let across = fitted(aspect, in: CGSize(width: size.width / 2, height: size.height))
            let stacked = fitted(aspect, in: CGSize(width: size.width, height: size.height / 2))
            let layout = across >= stacked ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
            layout {
                panel(before, label: beforeLabel)
                panel(after, label: afterLabel)
            }
        }
    }

    private func fitted(_ aspect: CGFloat, in box: CGSize) -> CGFloat {
        let width = min(box.width, box.height * aspect)
        return width * width / aspect
    }

    private func panel(_ image: UIImage, label: String) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom.scale)
            .offset(zoom.offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
    }
}

/// One photo on top of the other: a wipe, a blend, or flicker between them.
private struct Stacked: View {
    let before: UIImage
    let after: UIImage
    let mode: CompareView.Mode
    let wipe: Double
    let blend: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Image(uiImage: after).resizable()
                switch mode {
                case .wipe:
                    Image(uiImage: before).resizable()
                        .mask(alignment: .leading) { Rectangle().frame(width: width * wipe) }
                    Rectangle().fill(.white).frame(width: 2).offset(x: width * wipe - 1).shadow(radius: 2)
                case .blend:
                    Image(uiImage: before).resizable().opacity(blend)
                default:
                    TimelineView(.periodic(from: .now, by: 0.6)) { context in
                        let showBefore = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                        Image(uiImage: before).resizable().opacity(showBefore ? 1 : 0)
                            .overlay(alignment: .topLeading) {
                                Text(showBefore ? "Before" : "After")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.6), in: Capsule())
                                    .padding(6)
                                    .opacity(1)
                            }
                    }
                }
            }
        }
        .aspectRatio(before.size, contentMode: .fit)
    }
}

// MARK: - Zoom

struct ZoomState: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

/// Pinch to zoom, drag to pan once zoomed, double tap to zoom in or reset.
struct ZoomGestures: ViewModifier {
    @Binding var zoom: ZoomState
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGSize?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStart == nil { pinchStart = zoom.scale }
                        zoom.scale = min(max((pinchStart ?? 1) * value.magnification, 1), 8)
                    }
                    .onEnded { _ in
                        pinchStart = nil
                        if zoom.scale < 1.05 { withAnimation { zoom = ZoomState() } }
                    }
                    .simultaneously(with: DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard zoom.scale > 1 else { return }
                            if dragStart == nil { dragStart = zoom.offset }
                            let start = dragStart ?? .zero
                            zoom.offset = CGSize(width: start.width + value.translation.width,
                                                 height: start.height + value.translation.height)
                        }
                        .onEnded { _ in dragStart = nil })
            )
            .onTapGesture(count: 2) {
                withAnimation { zoom = zoom.scale > 1 ? ZoomState() : ZoomState(scale: 2.5) }
            }
    }
}
