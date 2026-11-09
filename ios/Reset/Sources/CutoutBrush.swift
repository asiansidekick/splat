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
/// What one finger does on the canvas.
enum MaskTool { case keep, erase, loop, pick, magic }

final class MaskCanvas: UIScrollView, UIScrollViewDelegate {
    var tool: MaskTool = .erase
    private var keeping: Bool { tool == .keep }
    /// Each subject the phone found on its own (people, things), for Tap subject; their coverage, one byte a pixel.
    private var parts: [CGImage] = []
    private var partCover: [[UInt8]] = []
    private var loopPoints: [CGPoint] = []
    private let loopLayer = CAShapeLayer()
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

    init(photo: UIImage, mask: CGImage, parts: [CGImage] = []) {
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
        loopLayer.fillColor = UIColor(red: 0.4, green: 0.95, blue: 0.8, alpha: 0.18).cgColor
        loopLayer.strokeColor = UIColor(red: 0.4, green: 0.95, blue: 0.8, alpha: 1).cgColor
        loopLayer.lineDashPattern = [8, 5]
        content.layer.addSublayer(loopLayer)
        self.parts = parts
        partCover = parts.map { Self.cover(of: $0, width: Int(size.width), height: Int(size.height)) }
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
        if tool == .pick || tool == .magic { return }
        if tool == .loop {
            looped(gesture.state, at: point)
            return
        }
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
        if tool == .pick {
            pick(at: point)
            return
        }
        if tool == .magic {
            magic(at: point)
            return
        }
        if tool == .loop { return }
        remember()
        stroke(from: point, to: point)
        onChange?()
    }

    /// Draw round something: when the finger lifts, only the inside is kept.
    private func looped(_ state: UIGestureRecognizer.State, at point: CGPoint) {
        switch state {
        case .began:
            loopPoints = [point]
        case .changed:
            loopPoints.append(point)
        default:
            if loopPoints.count > 4, let context {
                remember()
                let path = CGMutablePath()
                path.addLines(between: loopPoints)
                path.closeSubpath()
                context.setBlendMode(.clear)
                context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
                context.setBlendMode(.normal)
                context.setFillColor(UIColor.white.cgColor)
                context.addPath(path)
                context.fillPath()
                show()
                Diagnostics.log("Mask drawn round by hand")
            }
            loopPoints = []
            onChange?()
        }
        let path = CGMutablePath()
        if loopPoints.count > 1 { path.addLines(between: loopPoints) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loopLayer.lineWidth = 3 / max(zoomScale, 0.01)
        loopLayer.path = path
        CATransaction.commit()
    }

    /// Tap a subject the phone found: in if it is out, out if it is in.
    private func pick(at point: CGPoint) {
        guard let context, let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < context.width, y < context.height else { return }
        guard let index = partCover.firstIndex(where: { $0[y * context.width + x] > 100 }) else { return }
        let shown = data[y * context.bytesPerRow + x * 4 + 3] > 128
        remember()
        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -CGFloat(context.height))
        context.setBlendMode(shown ? .destinationOut : .normal)
        context.draw(parts[index], in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.restoreGState()
        show()
        onChange?()
    }

    /// How much of each pixel a subject covers, rows from the top.
    private static func cover(of part: CGImage, width: Int, height: Int) -> [UInt8] {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CutoutMask.space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var cover = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = data + y * context.bytesPerRow
            for x in 0..<width { cover[y * width + x] = row[x * 4 + 3] }
        }
        return cover
    }

    var hasParts: Bool { !parts.isEmpty }
    var partCount: Int { parts.count }

    /// The subjects arrive after the canvas opens (finding them takes a moment).
    func setParts(_ found: [CGImage]) {
        guard let context else { return }
        parts = found
        partCover = found.map { Self.cover(of: $0, width: context.width, height: context.height) }
    }

    /// The photo's colours, one RGBA pixel each, rows from the top; read once for Magic select.
    private lazy var pixels: [UInt8] = {
        guard let cg = photo.cgImage, let context else { return [] }
        let width = context.width, height = context.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let drawing = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CutoutMask.space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            drawing.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }()

    /// Like the magic wand: everything joined to the tapped spot in about the same colour joins the selection.
    private func magic(at point: CGPoint) {
        guard let context, let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = context.width, height = context.height, row = context.bytesPerRow
        let x0 = Int(point.x), y0 = Int(point.y)
        guard x0 >= 0, y0 >= 0, x0 < width, y0 < height, pixels.count == width * height * 4 else { return }
        remember()
        let seed = (y0 * width + x0) * 4
        let r = Int(pixels[seed]), g = Int(pixels[seed + 1]), b = Int(pixels[seed + 2])
        let tolerance = 34 * 34 * 3
        var seen = [Bool](repeating: false, count: width * height)
        var stack = [y0 * width + x0]
        seen[y0 * width + x0] = true
        var filled = 0
        while let index = stack.popLast() {
            let x = index % width, y = index / width
            let p = index * 4
            let dr = Int(pixels[p]) - r, dg = Int(pixels[p + 1]) - g, db = Int(pixels[p + 2]) - b
            guard dr * dr + dg * dg + db * db <= tolerance else { continue }
            let m = y * row + x * 4
            data[m] = 255; data[m + 1] = 255; data[m + 2] = 255; data[m + 3] = 255
            filled += 1
            if x > 0, !seen[index - 1] { seen[index - 1] = true; stack.append(index - 1) }
            if x < width - 1, !seen[index + 1] { seen[index + 1] = true; stack.append(index + 1) }
            if y > 0, !seen[index - width] { seen[index - width] = true; stack.append(index - width) }
            if y < height - 1, !seen[index + width] { seen[index + width] = true; stack.append(index + width) }
        }
        Diagnostics.log("Magic select took \(filled) pixels")
        show()
        onChange?()
    }

    /// Selected becomes unselected and the other way round.
    func invert() {
        guard let context, let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        remember()
        for y in 0..<context.height {
            let row = data + y * context.bytesPerRow
            for x in 0..<context.width {
                let a = 255 - row[x * 4 + 3]
                row[x * 4] = a; row[x * 4 + 1] = a; row[x * 4 + 2] = a; row[x * 4 + 3] = a
            }
        }
        show()
        onChange?()
    }

    /// Feathers the selection's edge a few pixels.
    func soften() {
        guard let current = context?.makeImage() else { return }
        let image = CIImage(cgImage: current)
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: image.extent)
        guard let out = CIContext().createCGImage(blurred, from: image.extent, format: .RGBA8, colorSpace: CutoutMask.space) else { return }
        remember()
        replace(with: out)
    }

    /// Nothing selected yet, to start a selection from scratch.
    static func empty(width: Int, height: Int) -> CGImage? {
        CutoutMask.context(width: width, height: height, mask: nil)?.makeImage()
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

struct MaskCanvasView: UIViewRepresentable {
    let photo: UIImage
    let mask: CGImage
    let parts: [CGImage]
    let tool: MaskTool
    let holder: MaskCanvasHolder

    func makeUIView(context: Context) -> MaskCanvas {
        let canvas = MaskCanvas(photo: photo, mask: mask, parts: parts)
        canvas.onChange = { [weak canvas] in holder.canUndo = !(canvas?.undoStack.isEmpty ?? true) }
        holder.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: MaskCanvas, context: Context) {
        canvas.tool = tool
        if canvas.partCount != parts.count { canvas.setParts(parts) }
    }
}

/// Paint a mask by hand: Keep and Erase, a loop round what you want, tap a subject the phone found; Undo,
/// Start again. `original` is what Start again goes back to; `parts` are the subjects found one by one.
struct MaskBrushSheet: View {
    let title: String
    let photo: UIImage
    let mask: CGImage
    let original: CGImage
    var parts: [CGImage] = []
    let onDone: (CGImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = MaskCanvasHolder()
    @State private var tool: MaskTool = .erase

    private var help: String {
        switch tool {
        case .keep: return "Paint over what to keep. Two fingers zoom and move."
        case .erase: return "Paint over what to remove. Two fingers zoom and move."
        case .loop: return "Draw round what you want. Only the inside is kept."
        case .pick: return "Tap a person or thing to add it. Tap again to take it out."
        case .magic: return "Tap a colour: everything joined to it in that colour is kept."
        }
    }

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
                MaskCanvasView(photo: photo, mask: mask, parts: parts, tool: tool, holder: holder)
                Text(help)
                    .font(Theme.caption)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    choice("Keep", symbol: "paintbrush.pointed.fill", on: tool == .keep) { tool = .keep }
                    choice("Erase", symbol: "eraser.fill", on: tool == .erase) { tool = .erase }
                    choice("Loop", symbol: "lasso", on: tool == .loop) { tool = .loop }
                    if !parts.isEmpty {
                        choice("Tap subject", symbol: "hand.tap", on: tool == .pick) { tool = .pick }
                    }
                }
                HStack(spacing: 10) {
                    Button { holder.canvas?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!holder.canUndo)
                    Button("Start again") { holder.canvas?.startAgain(with: original) }
                }
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
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(word).fixedSize()
            }
            .fontWeight(on ? .bold : .regular)
            .frame(minWidth: 56)
        }
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
