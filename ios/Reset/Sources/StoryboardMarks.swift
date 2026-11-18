import SwiftUI
import UIKit

/// Something drawn over a storyboard panel: a bubble, caption, sound effect, arrow or camera move (Phil,
/// 2026-11-18). Positions are fractions of the panel, so a mark sits in the same place at any size.
struct StoryMark: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case speech, thought, shout, whisper, caption, sound, arrow, move
        var id: String { rawValue }

        var title: String {
            switch self {
            case .speech: return "Speech"
            case .thought: return "Thought"
            case .shout: return "Shout"
            case .whisper: return "Whisper"
            case .caption: return "Caption"
            case .sound: return "Sound effect"
            case .arrow: return "Arrow"
            case .move: return "Camera move"
            }
        }

        var startText: String {
            switch self {
            case .speech: return "Line of dialogue"
            case .thought: return "A thought"
            case .shout: return "Shout!"
            case .whisper: return "a whisper"
            case .caption: return "Meanwhile…"
            case .sound: return "BOOM"
            case .arrow, .move: return ""
            }
        }

        var hasTail: Bool { self == .speech || self == .thought || self == .shout || self == .whisper || self == .arrow }
        var hasWords: Bool { self != .arrow && self != .move }
    }

    var id = UUID()
    var kind: Kind
    var text: String
    var center: CGPoint
    var scale: CGFloat = 1
    var angle: Double = 0
    /// Bubbles: where the tail points. Arrows: where the arrow ends.
    var tail: CGPoint
    var move: CameraMove?

    static func new(_ kind: Kind, move: CameraMove? = nil) -> StoryMark {
        switch kind {
        case .arrow:
            return StoryMark(kind: kind, text: "", center: CGPoint(x: 0.35, y: 0.6), tail: CGPoint(x: 0.65, y: 0.5))
        case .move:
            let fills = move?.drawsEndFrame ?? false
            return StoryMark(kind: kind, text: "", center: CGPoint(x: 0.5, y: 0.5), scale: fills ? 0.5 : 1,
                             tail: CGPoint(x: 0.5, y: 0.5), move: move)
        case .caption:
            return StoryMark(kind: kind, text: kind.startText, center: CGPoint(x: 0.22, y: 0.1), tail: .zero)
        case .sound:
            return StoryMark(kind: kind, text: kind.startText, center: CGPoint(x: 0.7, y: 0.25), angle: -0.2, tail: .zero)
        default:
            return StoryMark(kind: kind, text: kind.startText, center: CGPoint(x: 0.3, y: 0.2), tail: CGPoint(x: 0.42, y: 0.45))
        }
    }
}

/// The camera moves a storyboard artist draws, with their usual symbols.
enum CameraMove: String, Codable, CaseIterable, Identifiable {
    case panLeft, panRight, tiltUp, tiltDown, pushIn, pullOut, dollyLeft, dollyRight
    case craneUp, craneDown, zoomIn, zoomOut, orbit, handheld, whipPan, rackFocus
    var id: String { rawValue }

    var title: String {
        switch self {
        case .panLeft: return "Pan left"
        case .panRight: return "Pan right"
        case .tiltUp: return "Tilt up"
        case .tiltDown: return "Tilt down"
        case .pushIn: return "Push in"
        case .pullOut: return "Pull out"
        case .dollyLeft: return "Dolly left"
        case .dollyRight: return "Dolly right"
        case .craneUp: return "Crane up"
        case .craneDown: return "Crane down"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .orbit: return "Orbit"
        case .handheld: return "Handheld"
        case .whipPan: return "Whip pan"
        case .rackFocus: return "Rack focus"
        }
    }

    /// Push, pull and zoom show the frame the shot ends on.
    var drawsEndFrame: Bool { self == .pushIn || self == .pullOut || self == .zoomIn || self == .zoomOut }
}

/// Sizes and places marks; shared by drawing and by finding which mark a finger is on.
enum MarkLayout {
    /// Pixels per "point" of mark size: marks are sized against a 1000-wide panel.
    static func unit(_ size: CGSize) -> CGFloat { max(size.width, size.height) / 1000 }

    static func font(_ kind: StoryMark.Kind, unit: CGFloat, scale: CGFloat) -> UIFont {
        let size: CGFloat
        switch kind {
        case .sound: size = 64
        case .shout: size = 30
        case .caption: size = 24
        case .whisper: size = 24
        default: size = 27
        }
        let base = UIFont.systemFont(ofSize: size * unit * scale, weight: kind == .sound ? .black : .bold)
        if kind == .sound, let italic = base.fontDescriptor.withSymbolicTraits([.traitItalic, .traitBold]) {
            return UIFont(descriptor: italic, size: base.pointSize)
        }
        return base
    }

    /// The words' box, centred on the mark.
    static func textRect(_ mark: StoryMark, in size: CGSize) -> CGRect {
        let u = unit(size)
        let font = font(mark.kind, unit: u, scale: mark.scale)
        let width = (mark.kind == .sound ? 700 : 300) * u * mark.scale
        let text = (mark.text.isEmpty ? " " : mark.text) as NSString
        let bounds = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil)
        let c = point(mark.center, size)
        return CGRect(x: c.x - ceil(bounds.width) / 2, y: c.y - ceil(bounds.height) / 2,
                      width: ceil(bounds.width) + 1, height: ceil(bounds.height) + 1)
    }

    /// The bubble or box round the words.
    static func bodyRect(_ mark: StoryMark, in size: CGSize) -> CGRect {
        let u = unit(size) * mark.scale
        let text = textRect(mark, in: size)
        switch mark.kind {
        case .caption: return text.insetBy(dx: -16 * u, dy: -12 * u)
        case .sound: return text.insetBy(dx: -8 * u, dy: -8 * u)
        case .thought: return text.insetBy(dx: -50 * u, dy: -38 * u)
        case .shout: return text.insetBy(dx: -52 * u, dy: -44 * u)
        default: return text.insetBy(dx: -40 * u, dy: -28 * u)
        }
    }

    /// The end frame of a push, pull or zoom: the panel's own shape, `scale` of its size.
    static func endFrame(_ mark: StoryMark, in size: CGSize) -> CGRect {
        let s = min(max(mark.scale, 0.15), 0.95)
        let c = point(mark.center, size)
        return CGRect(x: c.x - size.width * s / 2, y: c.y - size.height * s / 2, width: size.width * s, height: size.height * s)
    }

    /// Where a finger can take hold of the mark.
    static func hitRect(_ mark: StoryMark, in size: CGSize) -> CGRect {
        let u = unit(size)
        switch mark.kind {
        case .arrow:
            let a = point(mark.center, size), b = point(mark.tail, size)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -30 * u, dy: -30 * u)
        case .move:
            if mark.move?.drawsEndFrame == true { return endFrame(mark, in: size).insetBy(dx: -20 * u, dy: -20 * u) }
            let c = point(mark.center, size)
            let r = 120 * u * mark.scale
            return CGRect(x: c.x - r, y: c.y - r * 0.8, width: 2 * r, height: 1.8 * r)
        default:
            return bodyRect(mark, in: size)
        }
    }

    static func point(_ p: CGPoint, _ size: CGSize) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
}

/// Draws all of a panel's marks. Used on screen and for the saved picture and PDF.
struct MarksCanvas: View {
    let marks: [StoryMark]
    var selected: UUID?

    var body: some View {
        Canvas { context, size in
            for mark in marks { MarkPainter.draw(mark, in: &context, size: size, selected: mark.id == selected) }
        }
        .allowsHitTesting(false)
    }
}

enum MarkPainter {
    static let ink = Color.black
    static let moveColour = Color(red: 1.0, green: 0.84, blue: 0.04)

    static func draw(_ mark: StoryMark, in context: inout GraphicsContext, size: CGSize, selected: Bool) {
        let u = MarkLayout.unit(size)
        let line = 4 * u
        switch mark.kind {
        case .speech, .whisper, .shout, .thought:
            let body = MarkLayout.bodyRect(mark, in: size)
            let tip = MarkLayout.point(mark.tail, size)
            var path = Path()
            if mark.kind == .shout {
                path.addPath(burst(body, spikes: 14, depth: 0.16))
            } else if mark.kind == .thought {
                path.addPath(cloud(body))
            } else {
                path.addEllipse(in: body)
            }
            if mark.kind == .thought {
                // Trailing circles towards the thinker instead of a tail.
                let c = CGPoint(x: body.midX, y: body.midY)
                for (t, r) in [(0.62, 13.0), (0.82, 8.0)] as [(CGFloat, CGFloat)] {
                    let p = edgePoint(body, towards: tip, from: c)
                    let q = CGPoint(x: p.x + (tip.x - p.x) * t, y: p.y + (tip.y - p.y) * t)
                    path.addEllipse(in: CGRect(x: q.x - r * u * mark.scale, y: q.y - r * u * mark.scale,
                                               width: 2 * r * u * mark.scale, height: 2 * r * u * mark.scale))
                }
            } else {
                path.addPath(tail(body, tip: tip, width: 0.28))
            }
            let style = mark.kind == .whisper ? StrokeStyle(lineWidth: line * 2, dash: [10 * u, 8 * u]) : StrokeStyle(lineWidth: line * 2, lineJoin: .round)
            context.stroke(path, with: .color(ink), style: style)
            context.fill(path, with: .color(.white))
            if mark.kind == .whisper {
                // The dashed outline shows through the white only where dashed, so draw it again, thin, outside.
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: line, dash: [10 * u, 8 * u]))
            }
            drawWords(mark, in: &context, size: size, colour: ink)
        case .caption:
            let body = MarkLayout.bodyRect(mark, in: size)
            let box = Path(body)
            context.fill(box, with: .color(Color(red: 1, green: 0.96, blue: 0.75)))
            context.stroke(box, with: .color(ink), lineWidth: line)
            drawWords(mark, in: &context, size: size, colour: ink)
        case .sound:
            var turned = context
            let c = MarkLayout.point(mark.center, size)
            turned.translateBy(x: c.x, y: c.y)
            turned.rotate(by: .radians(mark.angle))
            turned.translateBy(x: -c.x, y: -c.y)
            // A black outline: the words drawn round the edge, then white over them.
            let o = 5 * u * mark.scale
            for dx in [-o, 0, o] {
                for dy in [-o, 0, o] where dx != 0 || dy != 0 {
                    var shifted = turned
                    shifted.translateBy(x: dx, y: dy)
                    drawWords(mark, in: &shifted, size: size, colour: ink)
                }
            }
            drawWords(mark, in: &turned, size: size, colour: moveColour)
        case .arrow:
            let a = MarkLayout.point(mark.center, size), b = MarkLayout.point(mark.tail, size)
            let arrow = arrowPath(from: a, to: b, width: 16 * u * mark.scale)
            context.stroke(arrow, with: .color(ink), style: StrokeStyle(lineWidth: line * 1.6, lineJoin: .round))
            context.fill(arrow, with: .color(.white))
        case .move:
            guard let move = mark.move else { break }
            if move.drawsEndFrame {
                drawEndFrame(mark, move: move, in: &context, size: size)
            } else {
                var turned = context
                let c = MarkLayout.point(mark.center, size)
                turned.translateBy(x: c.x, y: c.y)
                turned.rotate(by: .radians(mark.angle))
                turned.translateBy(x: -c.x, y: -c.y)
                let r = 110 * u * mark.scale
                let rect = CGRect(x: c.x - r, y: c.y - r * 0.65, width: 2 * r, height: 1.3 * r)
                MoveIcon.draw(move, in: rect, context: &turned, colour: moveColour, outline: ink, frameColour: .white)
                label(move.title.uppercased(), at: CGPoint(x: c.x, y: rect.maxY + 26 * u * mark.scale), in: &turned, unit: u * mark.scale)
            }
        }
        if selected {
            let rect = MarkLayout.hitRect(mark, in: size)
            context.stroke(Path(roundedRect: rect, cornerRadius: 8 * u), with: .color(Theme.accent),
                           style: StrokeStyle(lineWidth: 3 * u, dash: [12 * u, 8 * u]))
            if mark.kind.hasTail {
                let tip = MarkLayout.point(mark.tail, size)
                let r = 16 * u
                let handle = Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r))
                context.fill(handle, with: .color(Theme.accent))
                context.stroke(handle, with: .color(.black), lineWidth: 2 * u)
            }
        }
    }

    private static func drawWords(_ mark: StoryMark, in context: inout GraphicsContext, size: CGSize, colour: Color) {
        let rect = MarkLayout.textRect(mark, in: size)
        let font = MarkLayout.font(mark.kind, unit: MarkLayout.unit(size), scale: mark.scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let words = NSAttributedString(string: mark.text, attributes: [
            .font: font, .foregroundColor: UIColor(colour), .paragraphStyle: paragraph,
        ])
        // UIKit text: wraps and centres like the measured box (MarkLayout.textRect).
        context.withCGContext { cg in
            UIGraphicsPushContext(cg)
            words.draw(with: rect, options: [.usesLineFragmentOrigin], context: nil)
            UIGraphicsPopContext()
        }
    }

    private static func label(_ words: String, at point: CGPoint, in context: inout GraphicsContext, unit: CGFloat) {
        let font = Font.system(size: 24 * unit, weight: .heavy)
        let o = 3 * unit
        for dx in [-o, o] {
            for dy in [-o, o] {
                context.draw(Text(words).font(font).foregroundColor(.black), at: CGPoint(x: point.x + dx, y: point.y + dy))
            }
        }
        context.draw(Text(words).font(font).foregroundColor(.white), at: point)
    }

    private static func drawEndFrame(_ mark: StoryMark, move: CameraMove, in context: inout GraphicsContext, size: CGSize) {
        let u = MarkLayout.unit(size)
        let end = MarkLayout.endFrame(mark, in: size)
        let frame = Path(end)
        context.stroke(frame, with: .color(.white), style: StrokeStyle(lineWidth: 8 * u, dash: [22 * u, 14 * u]))
        context.stroke(frame, with: .color(.black), style: StrokeStyle(lineWidth: 4 * u, dash: [22 * u, 14 * u]))
        let inward = move == .pushIn || move == .zoomIn
        let corners = [(CGPoint(x: 0, y: 0), CGPoint(x: end.minX, y: end.minY)),
                       (CGPoint(x: size.width, y: 0), CGPoint(x: end.maxX, y: end.minY)),
                       (CGPoint(x: 0, y: size.height), CGPoint(x: end.minX, y: end.maxY)),
                       (CGPoint(x: size.width, y: size.height), CGPoint(x: end.maxX, y: end.maxY))]
        for (outer, inner) in corners {
            // Arrows stop short of both ends so they never cover the frame line.
            let a = mix(outer, inner, 0.18), b = mix(outer, inner, 0.82)
            let arrow = inward ? arrowPath(from: a, to: b, width: 12 * u) : arrowPath(from: b, to: a, width: 12 * u)
            context.stroke(arrow, with: .color(.black), style: StrokeStyle(lineWidth: 5 * u, lineJoin: .round))
            context.fill(arrow, with: .color(moveColour))
        }
        label(move.title.uppercased() + (move == .zoomIn || move == .zoomOut ? "" : " · END FRAME"),
              at: CGPoint(x: end.midX, y: end.minY + 26 * u), in: &context, unit: u)
    }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

    /// Where the line from `c` towards `tip` leaves the ellipse in `rect`.
    static func edgePoint(_ rect: CGRect, towards tip: CGPoint, from c: CGPoint) -> CGPoint {
        let angle = atan2((tip.y - c.y) / max(rect.height, 1), (tip.x - c.x) / max(rect.width, 1))
        return CGPoint(x: c.x + cos(angle) * rect.width / 2, y: c.y + sin(angle) * rect.height / 2)
    }

    /// A speech tail: a wedge from inside the bubble out to the tip.
    static func tail(_ rect: CGRect, tip: CGPoint, width: CGFloat) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let angle = atan2((tip.y - c.y) / max(rect.height, 1), (tip.x - c.x) / max(rect.width, 1))
        let spread = width
        let p1 = CGPoint(x: c.x + cos(angle - spread) * rect.width * 0.4, y: c.y + sin(angle - spread) * rect.height * 0.4)
        let p2 = CGPoint(x: c.x + cos(angle + spread) * rect.width * 0.4, y: c.y + sin(angle + spread) * rect.height * 0.4)
        var path = Path()
        path.move(to: p1)
        path.addQuadCurve(to: tip, control: mix(p1, tip, 0.5))
        path.addLine(to: p2)
        path.closeSubpath()
        return path
    }

    static func burst(_ rect: CGRect, spikes: Int, depth: CGFloat) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let n = spikes * 2
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            let k: CGFloat = i % 2 == 0 ? 0.5 + depth : 0.5 - depth * 0.6
            let p = CGPoint(x: c.x + cos(a) * rect.width * k, y: c.y + sin(a) * rect.height * k)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    static func cloud(_ rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.1))
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let puffs = 10
        for i in 0..<puffs {
            let a = CGFloat(i) / CGFloat(puffs) * 2 * .pi
            let p = CGPoint(x: c.x + cos(a) * rect.width * 0.4, y: c.y + sin(a) * rect.height * 0.38)
            let r = min(rect.width, rect.height) * 0.22
            path.addEllipse(in: CGRect(x: p.x - r * 1.2, y: p.y - r, width: r * 2.4, height: r * 2))
        }
        return path
    }

    /// A block arrow from `a` to `b`, `width` thick, as one outline.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width: CGFloat) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 1)
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let head = min(width * 2.6, length * 0.6)
        let half = width / 2
        let base = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
        var path = Path()
        path.move(to: CGPoint(x: a.x + nx * half, y: a.y + ny * half))
        path.addLine(to: CGPoint(x: base.x + nx * half, y: base.y + ny * half))
        path.addLine(to: CGPoint(x: base.x + nx * width * 1.4, y: base.y + ny * width * 1.4))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: base.x - nx * width * 1.4, y: base.y - ny * width * 1.4))
        path.addLine(to: CGPoint(x: base.x - nx * half, y: base.y - ny * half))
        path.addLine(to: CGPoint(x: a.x - nx * half, y: a.y - ny * half))
        path.closeSubpath()
        return path
    }
}

/// The camera move symbols, drawn into any rectangle: on the panel and in the picker.
enum MoveIcon {
    static func draw(_ move: CameraMove, in r: CGRect, context: inout GraphicsContext, colour: Color, outline: Color?, frameColour: Color) {
        let w = r.width, h = r.height
        let c = CGPoint(x: r.midX, y: r.midY)
        let t = max(w / 18, 2)
        func arrow(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat? = nil) {
            let path = MarkPainter.arrowPath(from: a, to: b, width: width ?? t)
            if let outline { context.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: t * 0.5, lineJoin: .round)) }
            context.fill(path, with: .color(colour))
        }
        func frame(_ rect: CGRect, _ col: Color) {
            if let outline { context.stroke(Path(rect), with: .color(outline), lineWidth: t * 0.7) }
            context.stroke(Path(rect), with: .color(col), lineWidth: t * 0.4)
        }
        func camera(_ p: CGPoint, _ s: CGFloat) {
            var body = Path()
            body.addRect(CGRect(x: p.x - 0.18 * s, y: p.y - 0.1 * s, width: 0.26 * s, height: 0.2 * s))
            body.move(to: CGPoint(x: p.x + 0.08 * s, y: p.y))
            body.addLine(to: CGPoint(x: p.x + 0.2 * s, y: p.y - 0.09 * s))
            body.addLine(to: CGPoint(x: p.x + 0.2 * s, y: p.y + 0.09 * s))
            body.closeSubpath()
            if let outline { context.stroke(body, with: .color(outline), lineWidth: t * 0.5) }
            context.fill(body, with: .color(frameColour))
        }
        let box = CGRect(x: c.x - w * 0.32, y: c.y - h * 0.3, width: w * 0.64, height: h * 0.6)
        switch move {
        case .panLeft, .panRight:
            frame(box, frameColour)
            let l = CGPoint(x: r.minX + w * 0.05, y: c.y), rr = CGPoint(x: r.maxX - w * 0.05, y: c.y)
            move == .panLeft ? arrow(rr, l) : arrow(l, rr)
        case .tiltUp, .tiltDown:
            frame(box, frameColour)
            let top = CGPoint(x: c.x, y: r.minY), bottom = CGPoint(x: c.x, y: r.maxY)
            move == .tiltUp ? arrow(bottom, top) : arrow(top, bottom)
        case .pushIn, .zoomIn, .pullOut, .zoomOut:
            let outer = r.insetBy(dx: w * 0.05, dy: h * 0.05)
            let inner = CGRect(x: c.x - w * 0.18, y: c.y - h * 0.18, width: w * 0.36, height: h * 0.36)
            let inward = move == .pushIn || move == .zoomIn
            frame(outer, inward ? frameColour : colour)
            frame(inner, inward ? colour : frameColour)
            let pairs = [(CGPoint(x: outer.minX, y: outer.minY), CGPoint(x: inner.minX, y: inner.minY)),
                         (CGPoint(x: outer.maxX, y: outer.minY), CGPoint(x: inner.maxX, y: inner.minY)),
                         (CGPoint(x: outer.minX, y: outer.maxY), CGPoint(x: inner.minX, y: inner.maxY)),
                         (CGPoint(x: outer.maxX, y: outer.maxY), CGPoint(x: inner.maxX, y: inner.maxY))]
            for (o, i) in pairs {
                let a = MarkPainter.mix(o, i, 0.12), b = MarkPainter.mix(o, i, 0.88)
                inward ? arrow(a, b, t * 0.6) : arrow(b, a, t * 0.6)
            }
            if move == .zoomIn || move == .zoomOut {
                context.draw(Text("Z").font(.system(size: h * 0.22, weight: .heavy)).foregroundColor(colour), at: c)
            }
        case .dollyLeft, .dollyRight:
            camera(CGPoint(x: c.x, y: c.y - h * 0.18), w * 0.8)
            var rails = Path()
            rails.move(to: CGPoint(x: r.minX + w * 0.1, y: c.y + h * 0.05))
            rails.addLine(to: CGPoint(x: r.maxX - w * 0.1, y: c.y + h * 0.05))
            rails.move(to: CGPoint(x: r.minX + w * 0.1, y: c.y + h * 0.13))
            rails.addLine(to: CGPoint(x: r.maxX - w * 0.1, y: c.y + h * 0.13))
            context.stroke(rails, with: .color(frameColour), lineWidth: t * 0.35)
            let l = CGPoint(x: r.minX + w * 0.1, y: c.y + h * 0.36), rr = CGPoint(x: r.maxX - w * 0.1, y: c.y + h * 0.36)
            move == .dollyLeft ? arrow(rr, l) : arrow(l, rr)
        case .craneUp, .craneDown:
            camera(CGPoint(x: c.x + w * 0.12, y: c.y), w * 0.8)
            var arm = Path()
            arm.move(to: CGPoint(x: c.x - w * 0.25, y: r.maxY - h * 0.05))
            arm.addLine(to: CGPoint(x: c.x + w * 0.02, y: c.y + h * 0.05))
            context.stroke(arm, with: .color(frameColour), lineWidth: t * 0.6)
            let top = CGPoint(x: r.minX + w * 0.15, y: r.minY + h * 0.05), bottom = CGPoint(x: r.minX + w * 0.15, y: r.maxY - h * 0.1)
            move == .craneUp ? arrow(bottom, top) : arrow(top, bottom)
        case .orbit:
            context.fill(Path(ellipseIn: CGRect(x: c.x - w * 0.07, y: c.y - w * 0.07, width: w * 0.14, height: w * 0.14)), with: .color(frameColour))
            var ring = Path()
            ring.addArc(center: c, radius: w * 0.38, startAngle: .degrees(200), endAngle: .degrees(500), clockwise: false,
                        transform: CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: 1, y: 0.6).translatedBy(x: -c.x, y: -c.y))
            if let outline { context.stroke(ring, with: .color(outline), lineWidth: t * 1.2) }
            context.stroke(ring, with: .color(colour), lineWidth: t * 0.7)
            arrow(CGPoint(x: c.x + w * 0.1, y: c.y - h * 0.38), CGPoint(x: c.x + w * 0.34, y: c.y - h * 0.24), t * 0.7)
        case .handheld:
            frame(box, frameColour)
            var zig = Path()
            for i in 0...12 {
                let p = CGPoint(x: box.minX + box.width * CGFloat(i) / 12, y: r.maxY - h * 0.05 + (i % 2 == 0 ? -h * 0.05 : h * 0.03))
                if i == 0 { zig.move(to: p) } else { zig.addLine(to: p) }
            }
            if let outline { context.stroke(zig, with: .color(outline), lineWidth: t * 0.9) }
            context.stroke(zig, with: .color(colour), lineWidth: t * 0.5)
        case .whipPan:
            var streaks = Path()
            for i in 0..<5 {
                let y = c.y - h * 0.3 + h * 0.15 * CGFloat(i)
                streaks.move(to: CGPoint(x: r.minX, y: y))
                streaks.addLine(to: CGPoint(x: c.x + w * 0.1, y: y))
            }
            context.stroke(streaks, with: .color(frameColour), lineWidth: t * 0.25)
            arrow(CGPoint(x: r.minX + w * 0.05, y: c.y), CGPoint(x: r.maxX, y: c.y), t * 1.2)
        case .rackFocus:
            let near = CGRect(x: r.minX + w * 0.05, y: c.y - h * 0.15, width: h * 0.3, height: h * 0.3)
            context.stroke(Path(ellipseIn: near), with: .color(frameColour), lineWidth: t * 0.5)
            for k in [0.3, 0.2, 0.1] as [CGFloat] {
                let far = CGRect(x: r.maxX - w * 0.05 - h * 0.3 + h * (0.3 - k * 2) / 2, y: c.y - h * k, width: h * k * 2, height: h * k * 2)
                context.stroke(Path(ellipseIn: far), with: .color(colour), lineWidth: t * 0.35)
            }
            arrow(CGPoint(x: near.maxX + w * 0.04, y: c.y), CGPoint(x: r.maxX - w * 0.05 - h * 0.34, y: c.y), t * 0.6)
        }
    }
}
