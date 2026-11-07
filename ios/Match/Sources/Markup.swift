import PencilKit
import SwiftUI
import UIKit

/// Drawing and notes on a reference photo (Phil, 2026-11-07, like Reset's Sketch). The photo is never
/// changed: the marks are kept beside it as a transparent picture (shown over the photo in the gallery)
/// plus the editable drawing, so they can be reopened, changed or removed.
struct Markup: Codable {
    /// The width the drawing and label positions are measured in.
    static let referenceWidth: CGFloat = 1000
    var drawing: Data
    var labels: [MarkupLabel]
}

struct MarkupLabel: Codable, Identifiable {
    var id = UUID()
    var text: String
    var colour: MarkupColour
    /// Its middle, in `Markup.referenceWidth` units.
    var x: CGFloat
    var y: CGFloat
}

enum MarkupColour: String, CaseIterable, Codable {
    case yellow, red, cyan, white, black

    var ui: UIColor {
        switch self {
        case .yellow: return UIColor(red: 1, green: 0.84, blue: 0.1, alpha: 1)
        case .red: return UIColor(red: 1, green: 0.25, blue: 0.2, alpha: 1)
        case .cyan: return UIColor(red: 0.2, green: 0.8, blue: 1, alpha: 1)
        case .white: return .white
        case .black: return .black
        }
    }
}

extension BoardStore {
    nonisolated static func markupURL(of shot: Shot, in boardID: UUID) -> URL { folder(for: boardID).appending(path: shot.markupFile) }
    nonisolated static func marksImageURL(of shot: Shot, in boardID: UUID) -> URL { folder(for: boardID).appending(path: shot.marksFile) }

    nonisolated static func markup(of shot: Shot, in boardID: UUID) -> Markup? {
        (try? Data(contentsOf: markupURL(of: shot, in: boardID))).flatMap { try? JSONDecoder().decode(Markup.self, from: $0) }
    }

    nonisolated static func marksImage(of shot: Shot, in boardID: UUID) -> UIImage? {
        UIImage(contentsOfFile: marksImageURL(of: shot, in: boardID).path)
    }

    nonisolated static func hasMarks(_ shot: Shot, in boardID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: marksImageURL(of: shot, in: boardID).path)
    }

    /// Keeps the marks, or removes them when there are none.
    nonisolated static func saveMarkup(_ markup: Markup?, image: UIImage?, for shot: Shot, in boardID: UUID) {
        let json = markupURL(of: shot, in: boardID)
        let png = marksImageURL(of: shot, in: boardID)
        guard let markup, let image, let data = try? JSONEncoder().encode(markup), let pngData = image.pngData() else {
            try? FileManager.default.removeItem(at: json)
            try? FileManager.default.removeItem(at: png)
            return
        }
        try? data.write(to: json, options: .atomic)
        try? pngData.write(to: png, options: .atomic)
    }

    /// The photo with its marks on it, as a JPEG file ready for Photos or sharing.
    nonisolated static func flattened(_ shot: Shot, in boardID: UUID) -> URL? {
        guard let marks = marksImage(of: shot, in: boardID),
            let photo = ImageFile.load(url(of: shot, in: boardID), maxPixels: ImageFile.maxPixels)
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: photo.size, format: format).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: photo.size))
            marks.draw(in: CGRect(origin: .zero, size: photo.size))
        }
        let out = FileManager.default.temporaryDirectory.appending(path: "\(shot.id.uuidString)-marked.jpg")
        guard let data = image.jpegData(compressionQuality: 0.9), (try? data.write(to: out, options: .atomic)) != nil else { return nil }
        return out
    }
}

struct MarkupEditor: View {
    let shot: Shot
    let boardID: UUID
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photo: UIImage?
    @State private var canvas = PKCanvasView()
    @State private var labels: [MarkupLabel] = []
    @State private var tool: Tool = .pen
    @State private var colour: MarkupColour = .yellow
    @State private var writing = false
    @State private var draft = ""
    @State private var shown: CGSize = .zero
    @State private var loadedFromDisk = false

    enum Tool: CaseIterable { case pen, marker, eraser }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    if let photo {
                        let size = Self.fitted(photo.size, in: geometry.size)
                        ZStack {
                            Image(uiImage: photo).resizable().frame(width: size.width, height: size.height)
                            MarkupCanvas(canvas: canvas, tool: inkingTool)
                                .frame(width: size.width, height: size.height)
                            ForEach($labels) { $label in
                                MarkupLabelView(label: label, factor: shown.width / Markup.referenceWidth)
                                    .position(x: label.x * shown.width / Markup.referenceWidth,
                                              y: label.y * shown.width / Markup.referenceWidth)
                                    .gesture(DragGesture(coordinateSpace: .named("markup")).onChanged {
                                        label.x = $0.location.x * Markup.referenceWidth / max(shown.width, 1)
                                        label.y = $0.location.y * Markup.referenceWidth / max(shown.width, 1)
                                    })
                                    .contextMenu {
                                        Button("Delete note", role: .destructive) { labels.removeAll { $0.id == label.id } }
                                    }
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .coordinateSpace(name: "markup")
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .onAppear { place(size) }
                        .onChange(of: geometry.size) { _, new in place(Self.fitted(photo.size, in: new)) }
                    } else {
                        ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                tools
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Draw and write")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Clear all", role: .destructive) {
                        canvas.drawing = PKDrawing()
                        labels = []
                    }
                    Button("Save") { save() }.bold()
                }
            }
            .alert("Add a note", isPresented: $writing) {
                TextField("For example: lift the fringe", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Add") { addLabel() }
            }
        }
        .preferredColorScheme(.dark)
        // A downward stroke must draw, not close the sheet.
        .interactiveDismissDisabled()
        .task {
            let shot = shot
            let boardID = boardID
            photo = await Task.detached(priority: .userInitiated) { BoardStore.image(shot, in: boardID, maxPixels: 2048) }.value
        }
    }

    private var tools: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Tool.allCases, id: \.self) { item in
                    toolButton(
                        item == .pen ? "Draw" : item == .marker ? "Highlight" : "Erase",
                        item == .pen ? "pencil.tip" : item == .marker ? "highlighter" : "eraser",
                        on: tool == item
                    ) { tool = item }
                }
                toolButton("Write", "textformat", on: false) {
                    draft = ""
                    writing = true
                }
                toolButton("Undo", "arrow.uturn.backward", on: false) { canvas.undoManager?.undo() }
            }
            HStack(spacing: 22) {
                ForEach(MarkupColour.allCases, id: \.self) { item in
                    Circle()
                        .fill(Color(item.ui))
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(Color.white, lineWidth: colour == item ? 3.5 : 0.5))
                        .contentShape(Circle().inset(by: -6))
                        .onTapGesture {
                            colour = item
                            if tool == .eraser { tool = .pen }
                        }
                        .accessibilityLabel(item.rawValue)
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    private func toolButton(_ title: String, _ image: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: image)
                    .font(Theme.georgia(.title3))
                    .frame(width: 44, height: 36)
                    .background(on ? Color.white.opacity(0.25) : .clear, in: Capsule())
                Text(title).font(Theme.georgia(.caption).weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(title)
    }

    private var inkingTool: PKTool {
        switch tool {
        case .pen: return PKInkingTool(.pen, color: colour.ui, width: 6)
        case .marker: return PKInkingTool(.marker, color: colour.ui, width: 24)
        case .eraser: return PKEraserTool(.vector)
        }
    }

    private func addLabel() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        labels.append(MarkupLabel(text: text, colour: colour, x: Markup.referenceWidth / 2,
                                  y: Markup.referenceWidth / 2 * (shown.height / max(shown.width, 1))))
    }

    static func fitted(_ image: CGSize, in space: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, space.width > 0, space.height > 0 else { return .zero }
        let scale = min(space.width / image.width, space.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// The photo is laid out at `size`: load any saved marks the first time, and keep the drawing
    /// in step when the phone turns.
    private func place(_ size: CGSize) {
        guard size.width > 0 else { return }
        if !loadedFromDisk {
            loadedFromDisk = true
            shown = size
            if let saved = BoardStore.markup(of: shot, in: boardID), let drawing = try? PKDrawing(data: saved.drawing) {
                let factor = size.width / Markup.referenceWidth
                canvas.drawing = drawing.transformed(using: CGAffineTransform(scaleX: factor, y: factor))
                labels = saved.labels
            }
            return
        }
        guard shown.width > 0, size != shown else { return }
        let factor = size.width / shown.width
        canvas.drawing = canvas.drawing.transformed(using: CGAffineTransform(scaleX: factor, y: factor))
        shown = size
    }

    private func save() {
        guard shown.width > 0 else { dismiss(); return }
        let empty = canvas.drawing.strokes.isEmpty && labels.isEmpty
        if empty {
            BoardStore.saveMarkup(nil, image: nil, for: shot, in: boardID)
        } else {
            let toReference = Markup.referenceWidth / shown.width
            let drawing = canvas.drawing.transformed(using: CGAffineTransform(scaleX: toReference, y: toReference))
            let markup = Markup(drawing: drawing.dataRepresentation(), labels: labels)
            BoardStore.saveMarkup(markup, image: Self.render(markup, aspect: shown.height / shown.width), for: shot, in: boardID)
        }
        onDone()
        dismiss()
    }

    /// The marks alone on a clear picture, 1600 pixels wide and the photo's shape.
    static func render(_ markup: Markup, aspect: CGFloat) -> UIImage? {
        guard let drawing = try? PKDrawing(data: markup.drawing) else { return nil }
        let width: CGFloat = 1600
        let size = CGSize(width: width, height: (width * aspect).rounded())
        let factor = width / Markup.referenceWidth
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var ink = UIImage()
        // Drawn in light mode so the colours are the ones picked.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: CGRect(x: 0, y: 0, width: Markup.referenceWidth, height: size.height / factor), scale: factor)
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            ink.draw(in: CGRect(origin: .zero, size: size))
            for label in markup.labels { MarkupLabelView.draw(label, factor: factor) }
        }
    }
}

/// A note on the photo: bold text on a dark rounded tag, edged in its colour.
struct MarkupLabelView: View {
    let label: MarkupLabel
    /// Screen points per reference unit.
    let factor: CGFloat
    static let fontSize: CGFloat = 20

    var body: some View {
        let scale = factor * Markup.referenceWidth / 390
        Text(label.text)
            .font(.custom("Georgia-Bold", fixedSize: Self.fontSize * scale))
            .foregroundStyle(label.colour == .black ? Color.black : Color.white)
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 5 * scale)
            .background(
                RoundedRectangle(cornerRadius: 8 * scale)
                    .fill(label.colour == .black ? Color.white.opacity(0.85) : Color.black.opacity(0.65))
                    .overlay(RoundedRectangle(cornerRadius: 8 * scale).stroke(Color(label.colour.ui), lineWidth: 2 * scale)))
            .fixedSize()
    }

    /// The same tag drawn into the marks picture; `factor` is output pixels per reference unit.
    /// The tag is 20 point text on a 390 point wide photo, scaled with the picture.
    static func draw(_ label: MarkupLabel, factor: CGFloat) {
        let scale = factor * Markup.referenceWidth / 390
        let font = UIFont(name: "Georgia-Bold", size: fontSize * scale) ?? UIFont.systemFont(ofSize: fontSize * scale, weight: .bold)
        let ink: UIColor = label.colour == .black ? .black : .white
        let text = label.text as NSString
        let size = text.size(withAttributes: [.font: font])
        let centre = CGPoint(x: label.x * factor, y: label.y * factor)
        let box = CGRect(x: centre.x - size.width / 2 - 10 * scale, y: centre.y - size.height / 2 - 5 * scale,
                         width: size.width + 20 * scale, height: size.height + 10 * scale)
        let shape = UIBezierPath(roundedRect: box, cornerRadius: 8 * scale)
        (label.colour == .black ? UIColor.white.withAlphaComponent(0.85) : UIColor.black.withAlphaComponent(0.65)).setFill()
        shape.fill()
        label.colour.ui.setStroke()
        shape.lineWidth = 2 * scale
        shape.stroke()
        text.draw(at: CGPoint(x: box.minX + 10 * scale, y: box.minY + 5 * scale), withAttributes: [.font: font, .foregroundColor: ink])
    }
}

struct MarkupCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    let tool: PKTool

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = tool
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        view.tool = tool
    }
}
