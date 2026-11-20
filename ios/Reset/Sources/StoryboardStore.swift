import SwiftUI
import UIKit

/// One storyboard panel (Phil, 2026-11-18): the photo it was drawn from, how it is drawn, what is drawn over
/// it and its notes. The photo is kept as taken, so the style and frame shape can change later.
struct StoryPanel: Codable, Identifiable, Equatable {
    var id = UUID()
    var scene: String
    var shot: String
    var number: Int
    var created = Date()
    var photoFile: String
    var style: DrawStyle
    var styleName: String
    var aspect: String
    var marks: [StoryMark] = []
    var action = ""
    var camera = ""
    var sound = ""

    var slate: String {
        var parts = ["Sc \(scene.isEmpty ? "–" : scene)"]
        if !shot.isEmpty { parts.append("Shot \(shot)") }
        parts.append("Panel \(number)")
        return parts.joined(separator: " · ")
    }

    /// The camera moves drawn on the panel, for the top line of the page.
    var moves: String { marks.compactMap { $0.move?.title }.joined(separator: ", ") }
}

/// Frame shapes for panels.
enum PanelAspect {
    static let all = ["16:9", "1.85", "2.39", "4:3"]

    static func ratio(_ name: String) -> CGFloat {
        switch name {
        case "1.85": return 1.85
        case "2.39": return 2.39
        case "4:3": return 4.0 / 3.0
        default: return 16.0 / 9.0
        }
    }

    /// The middle of `image` cut to the frame shape (the long side across: landscape panels, as on a storyboard).
    static func crop(_ image: CIImage, _ name: String) -> CIImage {
        let e = image.extent
        let r = ratio(name)
        var target = e
        if e.width / e.height > r {
            target.size.width = e.height * r
            target.origin.x = e.midX - target.width / 2
        } else {
            target.size.height = e.width / r
            target.origin.y = e.midY - target.height / 2
        }
        return image.cropped(to: target.integral)
    }
}

@MainActor
final class StoryboardStore: ObservableObject {
    static let shared = StoryboardStore()
    @Published private(set) var panels: [StoryPanel] = []

    static let folder: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Storyboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var listURL: URL { Self.folder.appendingPathComponent("panels.json") }
    private var cache: [UUID: (key: String, image: UIImage)] = [:]

    private init() {
        if let data = try? Data(contentsOf: listURL), let saved = try? JSONDecoder().decode([StoryPanel].self, from: data) {
            // Splatter is gone (Phil, 2026-11-19); clear it so these panels still match their style's name.
            panels = saved.map { panel in
                var panel = panel
                panel.style.splatter = 0
                return panel
            }
        }
    }

    /// Panels in story order: scene, shot, then panel number.
    var ordered: [StoryPanel] {
        panels.sorted {
            let a = ($0.scene.localizedStandardCompare($1.scene), $0.shot.localizedStandardCompare($1.shot))
            if a.0 != .orderedSame { return a.0 == .orderedAscending }
            if a.1 != .orderedSame { return a.1 == .orderedAscending }
            return $0.number < $1.number
        }
    }

    func nextNumber(scene: String, shot: String) -> Int {
        (panels.filter { $0.scene == scene && $0.shot == shot }.map(\.number).max() ?? 0) + 1
    }

    /// Saves a new photo and its panel.
    func add(photo: UIImage, scene: String, shot: String, style: DrawStyle, styleName: String, aspect: String) -> StoryPanel? {
        let file = "panel_\(UUID().uuidString.prefix(8)).jpg"
        guard let data = photo.jpegData(compressionQuality: 0.9) else { return nil }
        do {
            try data.write(to: Self.folder.appendingPathComponent(file))
        } catch {
            Diagnostics.log("Storyboard: photo not saved: \(error)")
            return nil
        }
        let panel = StoryPanel(scene: scene, shot: shot, number: nextNumber(scene: scene, shot: shot), photoFile: file,
                               style: style, styleName: styleName, aspect: aspect)
        panels.append(panel)
        save()
        Diagnostics.log("Storyboard: panel \(panel.slate) added, \(styleName)")
        return panel
    }

    func update(_ panel: StoryPanel) {
        guard let i = panels.firstIndex(where: { $0.id == panel.id }) else { return }
        panels[i] = panel
        save()
    }

    func delete(_ panel: StoryPanel) {
        panels.removeAll { $0.id == panel.id }
        cache[panel.id] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(panel.photoFile))
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(panels)
            try data.write(to: listURL, options: .atomic)
        } catch {
            Diagnostics.log("Storyboard: list not saved: \(error)")
        }
    }

    func photo(_ panel: StoryPanel) -> UIImage? {
        UIImage(contentsOfFile: Self.folder.appendingPathComponent(panel.photoFile).path)
    }

    /// The panel's picture in its style and frame shape, without marks.
    func drawn(_ panel: StoryPanel, maxSide: CGFloat) -> UIImage? {
        let key = "\(maxSide)-\(panel.aspect)-\(String(describing: panel.style))"
        if let hit = cache[panel.id], hit.key == key { return hit.image }
        guard let photo = photo(panel), let upright = StoryboardRenderer.upright(photo) else { return nil }
        let cropped = PanelAspect.crop(upright, panel.aspect)
        guard let image = StoryboardRenderer.shared.render(cropped, style: panel.style, maxSide: maxSide) else { return nil }
        cache[panel.id] = (key, image)
        return image
    }

    /// The finished panel: drawing plus bubbles, captions and camera moves.
    func finished(_ panel: StoryPanel, maxSide: CGFloat) -> UIImage? {
        guard let drawn = drawn(panel, maxSide: maxSide) else { return nil }
        guard !panel.marks.isEmpty else { return drawn }
        let size = drawn.size
        let renderer = ImageRenderer(content:
            ZStack {
                Image(uiImage: drawn).resizable()
                MarksCanvas(marks: panel.marks)
            }
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        return renderer.uiImage
    }
}

/// Storyboard pages as a PDF: three panels with notes, or six in a grid. A4 landscape.
enum StoryboardPDF {
    enum Layout: String, CaseIterable, Identifiable {
        case threeWithNotes = "3 panels with notes"
        case sixGrid = "6 in a grid"
        var id: String { rawValue }
        var perPage: Int { self == .threeWithNotes ? 3 : 6 }
    }

    @MainActor static func make(_ panels: [StoryPanel], layout: Layout, store: StoryboardStore) -> URL? {
        guard !panels.isEmpty else { return nil }
        let page = CGRect(x: 0, y: 0, width: 842, height: 595)
        let margin: CGFloat = 28
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "Storyboard", kCGPDFContextCreator as String: "Reset"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        let ink = UIColor(white: 0.1, alpha: 1)
        let titleFont = Theme.uiFont(size: 15, weight: .bold)
        let slateFont = Theme.uiFont(size: 11, weight: .bold)
        let noteFont = Theme.uiFont(size: 9.5)
        let pages = stride(from: 0, to: panels.count, by: layout.perPage).map { Array(panels[$0..<min($0 + layout.perPage, panels.count)]) }
        let scenes = Array(Set(panels.map(\.scene))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let title = "Storyboard · " + (scenes.count == 1 ? "Sc \(scenes[0])" : "Sc " + scenes.joined(separator: ", "))
        let data = renderer.pdfData { context in
            for (index, group) in pages.enumerated() {
                context.beginPage()
                (title as NSString).draw(at: CGPoint(x: margin, y: margin - 8), withAttributes: [.font: titleFont, .foregroundColor: ink])
                let pageNumber = "Page \(index + 1) of \(pages.count)" as NSString
                let numberSize = pageNumber.size(withAttributes: [.font: noteFont])
                pageNumber.draw(at: CGPoint(x: page.width - margin - numberSize.width, y: margin - 4), withAttributes: [.font: noteFont, .foregroundColor: ink])
                let top = margin + 22
                let columns: CGFloat = 3
                let rows: CGFloat = layout == .threeWithNotes ? 1 : 2
                let gap: CGFloat = 16
                let cellWidth = (page.width - 2 * margin - (columns - 1) * gap) / columns
                let cellHeight = (page.height - top - margin - (rows - 1) * gap) / rows
                for (i, panel) in group.enumerated() {
                    let col = CGFloat(i % 3), row = CGFloat(i / 3)
                    let cell = CGRect(x: margin + col * (cellWidth + gap), y: top + row * (cellHeight + gap), width: cellWidth, height: cellHeight)
                    var y = cell.minY
                    let moves = panel.moves.uppercased() as NSString
                    (panel.slate as NSString).draw(at: CGPoint(x: cell.minX, y: y), withAttributes: [.font: slateFont, .foregroundColor: ink])
                    let movesSize = moves.size(withAttributes: [.font: slateFont])
                    moves.draw(at: CGPoint(x: cell.maxX - movesSize.width, y: y), withAttributes: [.font: slateFont, .foregroundColor: ink])
                    y += 16
                    let ratio = PanelAspect.ratio(panel.aspect)
                    let imageRect = CGRect(x: cell.minX, y: y, width: cellWidth, height: cellWidth / ratio)
                    if let image = store.finished(panel, maxSide: 1400) {
                        image.draw(in: imageRect)
                    }
                    let frame = UIBezierPath(rect: imageRect)
                    frame.lineWidth = 1.5
                    ink.setStroke()
                    frame.stroke()
                    y = imageRect.maxY + 8
                    var notes: [String] = []
                    if !panel.action.isEmpty { notes.append("Action: " + panel.action) }
                    if !panel.camera.isEmpty { notes.append("Camera: " + panel.camera) }
                    if !panel.sound.isEmpty { notes.append("Sound: " + panel.sound) }
                    if layout == .threeWithNotes {
                        // Ruled lines to write on by hand, under any typed notes.
                        let text = notes.joined(separator: "\n") as NSString
                        let textRect = CGRect(x: cell.minX, y: y, width: cellWidth, height: cell.maxY - y)
                        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: noteFont, .foregroundColor: ink], context: nil)
                        let used = text.boundingRect(with: textRect.size, options: [.usesLineFragmentOrigin], attributes: [.font: noteFont], context: nil).height
                        var lineY = y + used + 18
                        UIColor(white: 0.75, alpha: 1).setStroke()
                        while lineY < cell.maxY - 4 {
                            let rule = UIBezierPath()
                            rule.move(to: CGPoint(x: cell.minX, y: lineY))
                            rule.addLine(to: CGPoint(x: cell.maxX, y: lineY))
                            rule.lineWidth = 0.5
                            rule.stroke()
                            lineY += 18
                        }
                    } else if !notes.isEmpty {
                        let text = notes.joined(separator: "  ") as NSString
                        text.draw(with: CGRect(x: cell.minX, y: y, width: cellWidth, height: cell.maxY - y),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: noteFont, .foregroundColor: ink], context: nil)
                    }
                }
            }
        }
        let name = "Storyboard " + (scenes.count == 1 ? "Sc \(scenes[0])" : "") + ".pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name.replacingOccurrences(of: "  ", with: " ").replacingOccurrences(of: " .pdf", with: ".pdf"))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Diagnostics.log("Storyboard: PDF not written: \(error)")
            return nil
        }
    }
}
