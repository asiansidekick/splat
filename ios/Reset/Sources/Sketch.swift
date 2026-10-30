import PencilKit
import SwiftUI
import UIKit

/// Draw and write over a photo, then share it or save it to Photos (Phil, 2026-10-30). Shutter
/// photos already have any 3D models and measurements in them, so this is the quick way to mark
/// up a mock-up and send it. Draw with a finger or Pencil; Aa adds a label you can drag; press
/// and hold a label to delete it.
struct SketchEditor: View {
    let photo: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var labels: [SketchLabel] = []
    @State private var tool: Tool = .pen
    @State private var colour: SketchColour = .yellow
    @State private var writing = false
    @State private var draft = ""
    @State private var sharing: UIImage?
    @State private var shown: CGSize = .zero
    @State private var savedNote: String?

    enum Tool: String, CaseIterable { case pen, marker, eraser }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let size = SketchEditor.fitted(photo.size, in: geometry.size)
                    ZStack {
                        Image(uiImage: photo)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                        SketchCanvas(canvas: canvas, tool: inkingTool)
                            .frame(width: size.width, height: size.height)
                        ForEach($labels) { $label in
                            SketchLabelView(label: label)
                                .position(label.position)
                                .gesture(DragGesture(coordinateSpace: .named("sketch")).onChanged { label.position = $0.location })
                                .contextMenu {
                                    Button("Delete label", role: .destructive) { labels.removeAll { $0.id == label.id } }
                                }
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .coordinateSpace(name: "sketch")
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .onAppear { shown = size }
                    .onChange(of: geometry.size) { _, newSize in rescale(to: SketchEditor.fitted(photo.size, in: newSize)) }
                }
                tools
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Sketch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        let image = rendered()
                        Task {
                            let saved = await PhotoLibrary.save([image])
                            savedNote = saved ? "Saved to Photos" : "Allow Photos in Settings, Reset, Photos"
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Save to Photos")
                    Button { sharing = rendered() } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share")
                }
            }
            .alert("Label", isPresented: $writing) {
                TextField("For example: move 10 cm left", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Add") { addLabel() }
            }
            .alert(savedNote ?? "", isPresented: Binding(get: { savedNote != nil }, set: { if !$0 { savedNote = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
                if let sharing { ShareSheet(items: [sharing]) }
            }
        }
        .preferredColorScheme(.dark)
        // A downward stroke must draw, not close the sheet.
        .interactiveDismissDisabled()
    }

    private var tools: some View {
        HStack(spacing: 14) {
            ForEach(Tool.allCases, id: \.self) { item in
                Button {
                    tool = item
                } label: {
                    Image(systemName: item == .pen ? "pencil.tip" : item == .marker ? "highlighter" : "eraser")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .background(tool == item ? Color.white.opacity(0.25) : .clear, in: Circle())
                }
                .accessibilityLabel(item.rawValue.capitalized)
            }
            Divider().frame(height: 26)
            ForEach(SketchColour.allCases, id: \.self) { item in
                Circle()
                    .fill(Color(item.ui))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white, lineWidth: colour == item ? 3 : 0.5))
                    .onTapGesture {
                        colour = item
                        if tool == .eraser { tool = .pen }
                    }
                    .accessibilityLabel(item.rawValue)
                    .accessibilityAddTraits(.isButton)
            }
            Divider().frame(height: 26)
            Button {
                draft = ""
                writing = true
            } label: {
                Text("Aa").font(.title3.bold())
            }
            .accessibilityLabel("Add a label")
            Button { canvas.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.title3) }
                .accessibilityLabel("Undo")
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.black)
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
        labels.append(SketchLabel(text: text, colour: colour, position: CGPoint(x: shown.width / 2, y: shown.height / 2)))
    }

    /// The photo laid out to fit, keeping its shape.
    static func fitted(_ image: CGSize, in space: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, space.width > 0, space.height > 0 else { return .zero }
        let scale = min(space.width / image.width, space.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// Turning the phone resizes the photo: the drawing and labels go with it.
    private func rescale(to size: CGSize) {
        guard shown.width > 0, size.width > 0, size != shown else {
            shown = size
            return
        }
        let factor = size.width / shown.width
        canvas.drawing = canvas.drawing.transformed(using: CGAffineTransform(scaleX: factor, y: factor))
        for index in labels.indices {
            labels[index].position = CGPoint(x: labels[index].position.x * factor, y: labels[index].position.y * factor)
        }
        shown = size
    }

    /// The photo at full size with the drawing and labels on it.
    private func rendered() -> UIImage {
        let size = photo.size
        guard shown.width > 0 else { return photo }
        let scale = size.width / shown.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = photo.scale
        var drawing = UIImage()
        // Drawn in light mode, so the colours are the ones picked (dark mode swaps black and white).
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            drawing = canvas.drawing.image(from: CGRect(origin: .zero, size: shown), scale: scale * photo.scale)
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: size))
            drawing.draw(in: CGRect(origin: .zero, size: size))
            for label in labels {
                SketchLabelView.draw(label, scale: scale)
            }
        }
    }
}

enum SketchColour: String, CaseIterable {
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

struct SketchLabel: Identifiable {
    let id = UUID()
    var text: String
    var colour: SketchColour
    /// Its middle, in the shown photo's points.
    var position: CGPoint
}

/// A label on the sketch: bold text on a dark rounded tag, edged in its colour.
struct SketchLabelView: View {
    let label: SketchLabel
    static let fontSize: CGFloat = 20

    var body: some View {
        Text(label.text)
            .font(.system(size: SketchLabelView.fontSize, weight: .bold))
            .foregroundStyle(label.colour == .black ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(label.colour == .black ? Color.white.opacity(0.85) : Color.black.opacity(0.65))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(label.colour.ui), lineWidth: 2)))
            .fixedSize()
    }

    /// The same tag drawn into the full-size picture, `scale` times bigger than on screen.
    static func draw(_ label: SketchLabel, scale: CGFloat) {
        let font = UIFont.systemFont(ofSize: fontSize * scale, weight: .bold)
        let ink: UIColor = label.colour == .black ? .black : .white
        let text = label.text as NSString
        let size = text.size(withAttributes: [.font: font])
        let box = CGRect(
            x: label.position.x * scale - size.width / 2 - 10 * scale, y: label.position.y * scale - size.height / 2 - 5 * scale,
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

/// PencilKit's canvas, clear so the photo shows through, drawing with a finger or Pencil.
struct SketchCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    let tool: PKTool

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        // Colours as picked (dark mode would show black ink as white).
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = tool
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        view.tool = tool
    }
}
