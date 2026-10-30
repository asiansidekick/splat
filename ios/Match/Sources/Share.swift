import Photos
import SwiftUI
import UIKit

/// A file to hand to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, for AirDrop (works with no signal), Files, Messages or Mail.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Before and after side by side with labels, as one picture to send.
enum PairImage {
    static func make(before: UIImage, after: UIImage, title: String, beforeLabel: String, afterLabel: String) -> UIImage {
        let height: CGFloat = 1200
        let gap: CGFloat = 16
        let header: CGFloat = 70
        let footer: CGFloat = 60
        let beforeWidth = height * before.size.width / max(before.size.height, 1)
        let afterWidth = height * after.size.width / max(after.size.height, 1)
        let size = CGSize(width: beforeWidth + afterWidth + gap * 3, height: header + height + footer + gap)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let titleStyle: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.white]
            let labelStyle: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.lightGray]
            (title as NSString).draw(at: CGPoint(x: gap, y: 14), withAttributes: titleStyle)
            before.draw(in: CGRect(x: gap, y: header, width: beforeWidth, height: height))
            after.draw(in: CGRect(x: gap * 2 + beforeWidth, y: header, width: afterWidth, height: height))
            ("Before: " + beforeLabel as NSString).draw(at: CGPoint(x: gap, y: header + height + 12), withAttributes: labelStyle)
            ("After: " + afterLabel as NSString).draw(at: CGPoint(x: gap * 2 + beforeWidth, y: header + height + 12), withAttributes: labelStyle)
        }
    }
}

/// A PDF continuity sheet for one board: the subject, notes, and every photo grouped by take
/// with its notes, so crew without the app can see it. Made on the device, offline.
enum BoardPDF {
    static func make(for board: Board) throws -> URL {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)  // A4 in points
        let margin: CGFloat = 36
        let width = page.width - 2 * margin
        let url = FileManager.default.temporaryDirectory.appending(path: Slate.fileSafe("Scene \(board.scene) \(board.title).pdf"))

        try UIGraphicsPDFRenderer(bounds: page).writePDF(to: url) { context in
            context.beginPage()
            var y = margin

            func newPageIfNeeded(_ height: CGFloat) {
                if y + height > page.height - margin {
                    context.beginPage()
                    y = margin
                }
            }

            func text(_ string: String, size: CGFloat, bold: Bool = false, color: UIColor = .black,
                      x: CGFloat = margin, width: CGFloat = width, after: CGFloat = 6, advance: Bool = true) -> CGFloat {
                let attributed = NSAttributedString(string: string, attributes: [
                    .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                    .foregroundColor: color,
                ])
                let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
                let height = ceil(attributed.boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude), options: options, context: nil).height)
                if advance { newPageIfNeeded(height) }
                attributed.draw(with: CGRect(x: x, y: y, width: width, height: height), options: options, context: nil)
                if advance { y += height + after }
                return height
            }

            _ = text("Scene \(board.scene) · \(board.title)", size: 22, bold: true)
            _ = text("Made \(Date.now.formatted(date: .abbreviated, time: .shortened)) · \(board.shots.count) photos",
                     size: 10, color: .darkGray, after: 10)
            if !board.notes.isEmpty { _ = text(board.notes, size: 12, after: 14) }

            let columns: CGFloat = 3
            let gap: CGFloat = 10
            let cell = (width - gap * (columns - 1)) / columns
            for take in board.takes.reversed() {
                y += 6
                _ = text(Slate.takeName(take), size: 15, bold: true)
                let shots = board.shots(in: take)
                for start in stride(from: 0, to: shots.count, by: Int(columns)) {
                    let row = Array(shots[start..<min(start + Int(columns), shots.count)])
                    let images = row.map { BoardStore.image($0, in: board.id, maxPixels: 900) }
                    let photoHeight = images.map { image in
                        image.map { cell * $0.size.height / max($0.size.width, 1) } ?? cell
                    }.max() ?? cell
                    let captionHeight: CGFloat = row.contains { !$0.note.isEmpty } ? 40 : 16
                    newPageIfNeeded(photoHeight + captionHeight)
                    for (column, shot) in row.enumerated() {
                        let x = margin + CGFloat(column) * (cell + gap)
                        if let image = images[column] {
                            let h = cell * image.size.height / max(image.size.width, 1)
                            image.draw(in: CGRect(x: x, y: y, width: cell, height: h))
                        }
                        let saved = y
                        y += photoHeight + 3
                        var caption = (shot.isReference ? "★ " : "") + [shot.angle, shot.taken.formatted(date: .omitted, time: .shortened)]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                        if !shot.note.isEmpty { caption += "\n" + shot.note }
                        _ = text(caption, size: 8, color: .darkGray, x: x, width: cell, advance: false)
                        y = saved
                    }
                    y += photoHeight + captionHeight + gap
                }
            }
        }
        return url
    }
}

/// Saves into the iPhone or iPad Photos library. Asks only for permission to add, not to read.
enum PhotoLibrary {
    static let deniedMessage = "Match can't add to Photos. Turn it on in Settings, Match, Photos."

    static func save(_ files: [URL]) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited, !files.isEmpty else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for file in files {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
                }
            }
            return true
        } catch {
            return false
        }
    }
}
