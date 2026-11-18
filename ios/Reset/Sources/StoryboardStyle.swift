import CoreImage
import SwiftUI
import UIKit

/// How a storyboard panel is drawn (Phil, 2026-11-18). Each element is a small list of steps named in words,
/// changed by dragging up or down on the picture; a style is just a saved set of them.
struct DrawStyle: Codable, Equatable {
    var lines = 2
    var detail = 1
    var shadows = 1
    var greys = 3
    var colour = 0
    var paper = 0
    var dots = 0
    var splatter = 0

    enum Element: String, CaseIterable, Identifiable {
        case lines, detail, shadows, greys, colour, dots, paper
        var id: String { rawValue }

        var title: String {
            switch self {
            case .lines: return "Lines"
            case .detail: return "Detail"
            case .shadows: return "Shadows"
            case .greys: return "Tones"
            case .colour: return "Colour"
            case .dots: return "Texture"
            case .paper: return "Paper"
            }
        }

        var steps: [String] {
            switch self {
            case .lines: return ["Off", "Thin", "Normal", "Bold", "Heavy"]
            case .detail: return ["Simple", "Normal", "Detailed"]
            case .shadows: return ["Off", "Some", "Strong", "Black"]
            case .greys: return ["Smooth", "2", "3", "4", "5", "6"]
            case .colour: return ["None", "Sepia", "Muted", "Full", "Bold"]
            case .dots: return ["Off", "Dots", "Tone", "Hatch", "Cross"]
            case .paper: return ["Smooth", "Light", "Rough", "Heavy"]
            }
        }

        /// What dragging up or down does, in the one line of hint text.
        var hint: String {
            switch self {
            case .lines: return "thinner or bolder ink lines"
            case .detail: return "simpler or more detailed drawing"
            case .shadows: return "fewer or more solid black shadows"
            case .greys: return "fewer or more tone bands"
            case .colour: return "less or more colour"
            case .dots: return "dots, screen tone or hatching"
            case .paper: return "smoother or rougher paper"
            }
        }
    }

    subscript(element: Element) -> Int {
        get {
            switch element {
            case .lines: return lines
            case .detail: return detail
            case .shadows: return shadows
            case .greys: return greys
            case .colour: return colour
            case .dots: return dots
            case .paper: return paper
            }
        }
        set {
            let value = min(max(newValue, 0), element.steps.count - 1)
            switch element {
            case .lines: lines = value
            case .detail: detail = value
            case .shadows: shadows = value
            case .greys: greys = value
            case .colour: colour = value
            case .dots: dots = value
            case .paper: paper = value
            }
        }
    }

    func word(_ element: Element) -> String { element.steps[self[element]] }
}

/// The ready-made styles. Several are drawn from looks Phil named (2026-11-18) as inspiration, not copies:
/// heavy black weekly-comic ink, dense fine-line detail, painted realism, scratchy ink, wobbly
/// coloured pencil and clean tech manga.
struct StylePreset: Identifiable, Equatable {
    let name: String
    let style: DrawStyle
    var id: String { name }

    static let all: [StylePreset] = [
        StylePreset(name: "Marker", style: DrawStyle(lines: 3, detail: 1, shadows: 1, greys: 4, colour: 0, paper: 0, dots: 0, splatter: 0)),
        StylePreset(name: "Pencil", style: DrawStyle(lines: 1, detail: 2, shadows: 0, greys: 0, colour: 0, paper: 2, dots: 4, splatter: 0)),
        StylePreset(name: "Ink & wash", style: DrawStyle(lines: 2, detail: 1, shadows: 0, greys: 5, colour: 1, paper: 2, dots: 0, splatter: 0)),
        StylePreset(name: "Graphic novel", style: DrawStyle(lines: 3, detail: 1, shadows: 2, greys: 3, colour: 3, paper: 0, dots: 1, splatter: 0)),
        StylePreset(name: "Bold comic", style: DrawStyle(lines: 4, detail: 1, shadows: 3, greys: 2, colour: 4, paper: 0, dots: 1, splatter: 0)),
        StylePreset(name: "Fine line", style: DrawStyle(lines: 1, detail: 2, shadows: 1, greys: 4, colour: 2, paper: 1, dots: 0, splatter: 0)),
        StylePreset(name: "Painted", style: DrawStyle(lines: 0, detail: 2, shadows: 0, greys: 0, colour: 3, paper: 1, dots: 0, splatter: 0)),
        // Phil, 2026-11-19: no splatter in the preset; the blots stayed put on the screen while the picture moved.
        StylePreset(name: "Scratchy ink", style: DrawStyle(lines: 4, detail: 0, shadows: 2, greys: 2, colour: 1, paper: 2, dots: 0, splatter: 0)),
        StylePreset(name: "Coloured pencil", style: DrawStyle(lines: 1, detail: 1, shadows: 0, greys: 4, colour: 2, paper: 3, dots: 3, splatter: 0)),
        StylePreset(name: "Tech manga", style: DrawStyle(lines: 1, detail: 2, shadows: 1, greys: 3, colour: 0, paper: 0, dots: 2, splatter: 0)),
        StylePreset(name: "Photo", style: DrawStyle(lines: 0, detail: 2, shadows: 0, greys: 0, colour: 3, paper: 0, dots: 0, splatter: 0)),
    ]

    static func named(_ name: String) -> StylePreset? { all.first { $0.name == name } }

    /// The preset these settings match, or nil when they have been changed by hand.
    static func matching(_ style: DrawStyle) -> StylePreset? { all.first { $0.style == style } }
}

/// Draws a photo in a `DrawStyle` with Core Image: everything on the GPU, offline, the same on every panel.
final class StoryboardRenderer: @unchecked Sendable {
    static let shared = StoryboardRenderer()

    private let context: CIContext
    private let linesKernel: CIColorKernel?
    private let composeKernel: CIColorKernel?

    private init() {
        // Worked in gamma-encoded sRGB, so the tone thresholds match how the picture looks.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        context = CIContext(options: [.workingColorSpace: sRGB, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        var lines: CIColorKernel?
        var compose: CIColorKernel?
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let data = try? Data(contentsOf: url) {
            do {
                lines = try CIColorKernel(functionName: "storyLines", fromMetalLibraryData: data)
                compose = try CIColorKernel(functionName: "storyCompose", fromMetalLibraryData: data)
            } catch {
                Diagnostics.log("Storyboard: kernels failed to load: \(error)")
            }
        } else {
            Diagnostics.log("Storyboard: no default.metallib in the app")
        }
        linesKernel = lines
        composeKernel = compose
    }

    var ready: Bool { linesKernel != nil && composeKernel != nil }

    /// The photo drawn in `style`, the same size as the photo.
    func image(_ input: CIImage, style: DrawStyle) -> CIImage {
        let extent = input.extent
        guard extent.width > 2, extent.height > 2, let linesKernel, let composeKernel else { return input }
        let photo = input.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let frame = CGRect(origin: .zero, size: extent.size)
        let unit = Float(max(extent.width, extent.height) / 1000)
        let clamped = photo.clampedToExtent()

        // Simplified colour: shrunk, then grown back along the photo's own edges, which keeps outlines
        // crisp while flattening the areas between them (an edge-preserving smoothing).
        let shrink: CGFloat = [0.16, 0.26, 0.4][style.detail]
        let small = photo.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
        var smooth = photo
        if let upsample = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            upsample.setValue(photo, forKey: kCIInputImageKey)
            upsample.setValue(small, forKey: "inputSmallImage")
            upsample.setValue(4.0, forKey: "inputSpatialSigma")
            upsample.setValue(0.15, forKey: "inputLumaSigma")
            smooth = upsample.outputImage?.cropped(to: frame) ?? photo
        }

        // Lines.
        var lines = CIImage(color: .white).cropped(to: frame)
        if style.lines > 0 {
            let sigma = CGFloat(unit) * [2.0, 1.4, 0.9][style.detail]
            let near = clamped.applyingGaussianBlur(sigma: Double(sigma)).cropped(to: frame)
            let far = clamped.applyingGaussianBlur(sigma: Double(sigma * 1.6)).cropped(to: frame)
            let eps: Float = [0.5, 0.55, 0.62][style.detail]
            if let drawn = linesKernel.apply(extent: frame, arguments: [near, far, Float(22), eps, Float(12)]) {
                lines = drawn
                // Bolder lines: the dark grows.
                let grow = [0, 0, 0.6, 1.4, 2.4][style.lines] * Double(unit)
                if grow >= 0.5, let minimum = CIFilter(name: "CIMorphologyMinimum") {
                    minimum.setValue(lines.clampedToExtent(), forKey: kCIInputImageKey)
                    minimum.setValue(grow, forKey: kCIInputRadiusKey)
                    lines = minimum.outputImage?.cropped(to: frame) ?? lines
                }
            }
        }

        let levels: Float = style.greys == 0 ? 0 : Float(style.greys + 1)
        let shadow: Float = [0, 0.12, 0.2, 0.3][style.shadows]
        let colourMode: Float = style.colour == 0 ? 0 : style.colour == 1 ? 1 : 2
        let saturation: Float = [0, 0, 0.45, 1.0, 1.45][style.colour]
        let lineDark: Float = [0, 0.7, 1, 1, 1][style.lines]
        let paper: Float = [0, 0.06, 0.12, 0.2][style.paper]
        // Phil, 2026-11-19: splatter removed (the blots stayed fixed on screen); old saved styles draw none.
        let splatter: Float = 0
        let arguments: [Any] = [smooth, lines, levels, shadow, colourMode, saturation, Float(style.dots),
                                lineDark, paper, splatter, unit]
        return composeKernel.apply(extent: frame, arguments: arguments) ?? photo
    }

    /// A finished picture, longest side at most `maxSide` pixels.
    func render(_ photo: UIImage, style: DrawStyle, maxSide: CGFloat) -> UIImage? {
        guard let input = Self.upright(photo) else { return nil }
        return render(input, style: style, maxSide: maxSide)
    }

    func render(_ input: CIImage, style: DrawStyle, maxSide: CGFloat) -> UIImage? {
        let scale = min(1, maxSide / max(input.extent.width, input.extent.height))
        let sized = scale < 1 ? input.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : input
        let drawn = image(sized, style: style)
        guard let cg = context.createCGImage(drawn, from: drawn.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A CIImage as a plain picture, no drawing style.
    func plain(_ image: CIImage) -> UIImage? {
        context.createCGImage(image, from: image.extent).map { UIImage(cgImage: $0) }
    }

    /// The photo as a CIImage the right way up.
    static func upright(_ photo: UIImage) -> CIImage? {
        guard let cg = photo.cgImage else { return photo.ciImage }
        let orientation = CGImagePropertyOrientation(photo.imageOrientation)
        return CIImage(cgImage: cg).oriented(orientation)
    }
}
