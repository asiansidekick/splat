import CoreImage
import SwiftUI
import UIKit

/// Phil, 2026-11-09: more image editing for cut-outs, drawing masks. The automatic cut-out's edges are painted
/// right with a finger: Keep paints the photo back in, Erase takes it out. One finger paints; two fingers zoom
/// and move, so the brush stays the same size on screen and gets finer as you zoom in (no size slider).

/// The mask a cut-out is made with: white where the photo is kept, clear where it is not, as big as the photo.
enum CutoutMask {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A drawing surface holding `mask` (or nothing kept), with the top left as the origin.
    static func context(width: Int, height: Int, mask: CGImage?) -> CGContext? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let mask { context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        return context
    }

    /// Everything kept.
    static func full(width: Int, height: Int) -> CGImage? {
        guard let context = context(width: width, height: height, mask: nil) else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The kept part of the photo on a clear background, cropped to it, as PNG, with its width over height.
    nonisolated static func compose(_ photo: CGImage, mask: CGImage) -> (png: Data, aspect: Float, preview: UIImage)? {
        let width = photo.width, height = photo.height
        guard let context = context(width: width, height: height, mask: nil) else { return nil }
        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -CGFloat(height))
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Rows from the top in memory: find the box round everything kept.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = data + y * context.bytesPerRow
            for x in 0..<width where row[x * 4 + 3] > 12 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let picture = CIImage(cgImage: photo).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: CIImage(cgImage: mask),
        ])
        // Core Image counts rows from the bottom.
        let box = CGRect(x: minX, y: height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let out = CIContext().createCGImage(picture, from: box, format: .RGBA8, colorSpace: space),
              out.height > 0, let png = UIImage(cgImage: out).pngData() else { return nil }
        return (png, Float(out.width) / Float(out.height), UIImage(cgImage: out))
    }
}

/// The painting surface: the photo faint behind, the kept part bright over a chequer, and the finger's brush.
final class MaskCanvas: UIScrollView, UIScrollViewDelegate {
    var keeping = true
    var onChange: (() -> Void)?
    private(set) var undoStack: [CGImage] = []

    private let content = UIView()
    private let faint = UIImageView()
    private let kept = UIImageView()
    private let maskLayer = CALayer()
    private var context: CGContext?
    private var last: CGPoint?
    private let photo: UIImage
    private var fitted = false

    init(photo: UIImage, mask: CGImage) {
        self.photo = photo
        super.init(frame: .zero)
        let size = CGSize(width: photo.cgImage?.width ?? Int(photo.size.width), height: photo.cgImage?.height ?? Int(photo.size.height))
        context = CutoutMask.context(width: Int(size.width), height: Int(size.height), mask: mask)
        content.frame = CGRect(origin: .zero, size: size)
        content.backgroundColor = UIColor(patternImage: Self.chequer)
        faint.image = photo
        faint.alpha = 0.3
        faint.frame = content.bounds
        kept.image = photo
        kept.frame = content.bounds
        maskLayer.frame = content.bounds
        maskLayer.contents = context?.makeImage()
        kept.layer.mask = maskLayer
        content.addSubview(faint)
        content.addSubview(kept)
        addSubview(content)
        contentSize = size
        delegate = self
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        panGestureRecognizer.minimumNumberOfTouches = 2
        let paint = UIPanGestureRecognizer(target: self, action: #selector(painted(_:)))
        paint.maximumNumberOfTouches = 1
        content.addGestureRecognizer(paint)
        let dot = UITapGestureRecognizer(target: self, action: #selector(dotted(_:)))
        content.addGestureRecognizer(dot)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, content.bounds.width > 0 else { return }
        let fit = min(bounds.width / content.bounds.width, bounds.height / content.bounds.height)
        if !fitted || minimumZoomScale != fit {
            minimumZoomScale = fit
            maximumZoomScale = fit * 10
            if !fitted { zoomScale = fit }
            fitted = true
        }
        centre()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    private func centre() {
        let x = max(0, (bounds.width - content.frame.width) / 2)
        let y = max(0, (bounds.height - content.frame.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    /// About a fingertip wide on the screen, whatever the zoom.
    private var brushWidth: CGFloat { 30 / max(zoomScale, 0.01) }

    @objc private func painted(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: content)
        switch gesture.state {
        case .began:
            remember()
            last = point
            stroke(from: point, to: point)
        case .changed:
            stroke(from: last ?? point, to: point)
            last = point
        default:
            last = nil
            onChange?()
        }
    }

    @objc private func dotted(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: content)
        remember()
        stroke(from: point, to: point)
        onChange?()
    }

    private func remember() {
        guard let image = context?.makeImage() else { return }
        undoStack.append(image)
        if undoStack.count > 30 { undoStack.removeFirst() }
    }

    private func stroke(from a: CGPoint, to b: CGPoint) {
        guard let context else { return }
        context.setLineWidth(brushWidth)
        context.setBlendMode(keeping ? .normal : .clear)
        context.setStrokeColor(UIColor.white.cgColor)
        context.move(to: a)
        context.addLine(to: b)
        context.strokePath()
        show()
    }

    private func show() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.contents = context?.makeImage()
        CATransaction.commit()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        replace(with: previous)
    }

    func replace(with mask: CGImage) {
        guard let old = context else { return }
        context = CutoutMask.context(width: old.width, height: old.height, mask: mask)
        show()
        onChange?()
    }

    func startAgain(with mask: CGImage) {
        remember()
        replace(with: mask)
    }

    var paintedMask: CGImage? { context?.makeImage() }

    private static let chequer: UIImage = {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.22, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.32, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
            context.fill(CGRect(x: 12, y: 12, width: 12, height: 12))
        }
    }()
}

/// Holds the canvas so the buttons can reach it.
@MainActor
final class MaskCanvasHolder: ObservableObject {
    var canvas: MaskCanvas?
    @Published var canUndo = false
}

private struct MaskCanvasView: UIViewRepresentable {
    let photo: UIImage
    let mask: CGImage
    let keeping: Bool
    let holder: MaskCanvasHolder

    func makeUIView(context: Context) -> MaskCanvas {
        let canvas = MaskCanvas(photo: photo, mask: mask)
        canvas.onChange = { [weak canvas] in holder.canUndo = !(canvas?.undoStack.isEmpty ?? true) }
        holder.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: MaskCanvas, context: Context) { canvas.keeping = keeping }
}

/// Paint a mask by hand: Keep and Erase, Undo, Start again. `original` is what Start again goes back to.
struct MaskBrushSheet: View {
    let title: String
    let photo: UIImage
    let mask: CGImage
    let original: CGImage
    let onDone: (CGImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = MaskCanvasHolder()
    @State private var keeping = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(title).font(Theme.headline)
                Spacer()
                Button("Done") {
                    if let mask = holder.canvas?.paintedMask { onDone(mask) }
                    dismiss()
                }
                .fontWeight(.bold)
                .tint(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ZStack(alignment: .top) {
                MaskCanvasView(photo: photo, mask: mask, keeping: keeping, holder: holder)
                Text("Paint with one finger. Two fingers to zoom and move.")
                    .font(Theme.caption)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 10) {
                choice("Keep", symbol: "paintbrush.pointed.fill", on: keeping) { keeping = true }
                choice("Erase", symbol: "eraser.fill", on: !keeping) { keeping = false }
                Spacer(minLength: 4)
                Button { holder.canvas?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!holder.canUndo)
                Button("Start again") { holder.canvas?.startAgain(with: original) }
            }
            .buttonStyle(.bordered)
            .font(Theme.subheadline)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func choice(_ word: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(word, systemImage: symbol).fontWeight(on ? .bold : .regular) }
            .tint(on ? Theme.accent : .gray)
    }
}

/// The hand-painted mask over an imported photo, kept in the reference's folder on this phone.
enum GhostMask {
    private static func url(_ id: UUID) -> URL { ReferenceStore.folder(for: id).appendingPathComponent("ghost-mask.png") }

    static func load(_ id: UUID) -> UIImage? {
        guard let data = try? Data(contentsOf: url(id)), let image = UIImage(data: data) else { return nil }
        return image
    }

    static func save(_ mask: CGImage, reference id: UUID) -> UIImage? {
        let image = UIImage(cgImage: mask)
        do {
            try image.pngData()?.write(to: url(id), options: .atomic)
            Diagnostics.log("Imported photo masked by hand")
        } catch {
            Diagnostics.log("Could not save the photo mask: \(error)")
        }
        return image
    }

    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    /// The photo, upright and no more than 1600 points long, for painting on quickly.
    static func editable(_ photo: UIImage) -> UIImage? {
        let scale = min(1, 1600 / max(photo.size.width, photo.size.height, 1))
        let size = CGSize(width: (photo.size.width * scale).rounded(), height: (photo.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in photo.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// A saved mask stretched to the painting photo's size.
    static func fitted(_ mask: UIImage?, to photo: UIImage) -> CGImage? {
        guard let mask, let cg = mask.cgImage, let target = photo.cgImage else { return nil }
        guard let context = CutoutMask.context(width: target.width, height: target.height, mask: nil) else { return nil }
        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -CGFloat(target.height))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        context.restoreGState()
        return context.makeImage()
    }
}
