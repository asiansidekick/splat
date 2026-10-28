import SwiftUI
import UIKit
import simd

/// A PDF continuity report for one setup: the slate, the take log and a spread of reference
/// photos, so crew without the app can see how the set should look. Made on the device, offline.
enum ReportPDF {
    static let photoCount = 6

    static func make(for reference: Reference) throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)  // A4 in points
        let margin: CGFloat = 40
        let width = page.width - 2 * margin
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(for: reference))
        let folder = ReferenceStore.folder(for: reference.id)

        try UIGraphicsPDFRenderer(bounds: page).writePDF(to: url) { context in
            context.beginPage()
            var y = margin

            func newPageIfNeeded(_ height: CGFloat) {
                if y + height > page.height - margin {
                    context.beginPage()
                    y = margin
                }
            }

            func text(_ string: String, size: CGFloat, bold: Bool = false, color: UIColor = .black, after: CGFloat = 6) {
                let attributed = NSAttributedString(string: string, attributes: [
                    .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                    .foregroundColor: color,
                ])
                let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
                let height = ceil(attributed.boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options, context: nil).height)
                newPageIfNeeded(height)
                attributed.draw(with: CGRect(x: margin, y: y, width: width, height: height), options: options, context: nil)
                y += height + after
            }

            text(reference.title.isEmpty ? "Reference" : reference.title, size: 24, bold: true)
            let lidar = reference.hasDepth ? " · LiDAR" : ""
            text("Recorded \(reference.created.formatted(date: .abbreviated, time: .shortened)) · \(reference.keyframes.count) views\(lidar)",
                 size: 11, color: .darkGray, after: 18)

            text("Takes", size: 16, bold: true)
            if reference.takes.isEmpty {
                text("No takes logged.", size: 12, color: .darkGray)
            }
            for take in reference.takes.sorted(by: { $0.number < $1.number }) {
                var line = "Take \(take.number)\(take.circled ? " (circled)" : "")  ·  \(take.logged.formatted(date: .omitted, time: .shortened))"
                if take.resetChecked { line += "  ·  set matched the reference" }
                text(line, size: 12, bold: take.circled, after: take.note.isEmpty ? 6 : 2)
                if !take.note.isEmpty {
                    text("     \(take.note)", size: 11, color: .darkGray)
                }
            }
            y += 12

            let photos = spread(reference.keyframes, count: photoCount).compactMap { keyframe -> UIImage? in
                guard let image = UIImage(contentsOfFile: folder.appendingPathComponent(keyframe.imageFile).path),
                      let cg = image.cgImage else { return nil }
                return UIImage(cgImage: cg, scale: 1, orientation: keyframe.uprightOrientation)
            }
            guard !photos.isEmpty else { return }
            text("Reference photos", size: 16, bold: true)
            let gap: CGFloat = 12
            let cell = (width - gap) / 2
            for pair in stride(from: 0, to: photos.count, by: 2) {
                let row = photos[pair..<min(pair + 2, photos.count)]
                let height = row.map { cell * $0.size.height / $0.size.width }.max() ?? cell
                newPageIfNeeded(height)
                for (column, image) in row.enumerated() {
                    let h = cell * image.size.height / image.size.width
                    image.draw(in: CGRect(x: margin + CGFloat(column) * (cell + gap), y: y, width: cell, height: h))
                }
                y += height + gap
            }
        }
        return url
    }

    /// Up to `count` items spread evenly through the list, so the photos cover the whole walk.
    static func spread<T>(_ items: [T], count: Int) -> [T] {
        guard items.count > count, count > 1 else { return items }
        return (0..<count).map { items[$0 * (items.count - 1) / (count - 1)] }
    }

    static func fileName(for reference: Reference) -> String {
        let title = reference.title.isEmpty ? "Reference" : reference.title
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe) continuity.pdf"
    }
}

extension Keyframe {
    /// How to turn this keyframe's photo (stored in the sensor's landscape layout) so it shows
    /// upright, worked out from which way was up when it was taken. Same for its depth map.
    var uprightOrientation: UIImage.Orientation {
        let up = SIMD3<Float>(0, 1, 0)
        let alongX = simd_dot(cameraToWorld.columns.0.xyz, up)
        let alongY = simd_dot(cameraToWorld.columns.1.xyz, up)
        if abs(alongY) >= abs(alongX) {
            return alongY >= 0 ? .up : .down
        }
        return alongX < 0 ? .right : .left
    }
}

/// A file to hand to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, for AirDrop, Files, Messages or Mail.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
