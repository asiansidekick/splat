import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

/// Reads the text on a picture of a call sheet, on the phone, with no internet.
enum CallSheetScanner {
    /// The pieces of text on the page, top to bottom then left to right, with where each sits.
    static func lines(in image: UIImage) async -> [CallSheetText] {
        guard let cg = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: read(cg, orientation: orientation))
            }
        }
    }

    /// A tall screenshot of a whole call sheet is shrunk by the reader until its small print is lost, so it is
    /// read in overlapping strips about as tall as the page is wide (as Match does), and text cut by a strip's
    /// edge is left to the strip that holds it whole.
    private static func read(_ cg: CGImage, orientation: CGImagePropertyOrientation) -> [CallSheetText] {
        let width = Double(cg.width), height = Double(cg.height)
        let tall = orientation == .up && height > width * 1.4
        var strips: [(bottom: Double, top: Double)] = [(0, 1)]
        if tall {
            let size = min(1, width / height)
            let step = size * 0.75
            strips = []
            var top = 1.0
            while true {
                let bottom = max(0, top - size)
                strips.append((bottom, top))
                if bottom <= 0 { break }
                top -= step
            }
        }
        var found: [CallSheetText] = []
        for strip in strips {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            // The reader skips text under a thirty-second of the picture's height unless told not to.
            request.minimumTextHeight = 0
            request.regionOfInterest = CGRect(x: 0, y: strip.bottom, width: 1, height: strip.top - strip.bottom)
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
            try? handler.perform([request])
            let span = strip.top - strip.bottom
            for observation in request.results ?? [] {
                guard let text = observation.topCandidates(1).first?.string else { continue }
                let box = observation.boundingBox
                // Cut by the strip's edge (and not the page's): the next strip has it whole.
                if box.minY < 0.01, strip.bottom > 0 { continue }
                if box.maxY > 0.99, strip.top < 1 { continue }
                let low = strip.bottom + Double(box.minY) * span
                let high = strip.bottom + Double(box.maxY) * span
                let piece = CallSheetText(text: text, minX: box.minX, minY: 1 - high, maxX: box.maxX, maxY: 1 - low)
                let twice = found.contains { other in
                    other.text == piece.text && abs(other.minY - piece.minY) < 0.004 && abs(other.minX - piece.minX) < 0.01
                }
                if !twice { found.append(piece) }
            }
        }
        // Top to bottom, then left to right, so a table reads like the page.
        return found.sorted { a, b in
            let am = (a.minY + a.maxY) / 2, bm = (b.minY + b.maxY) / 2
            return abs(am - bm) > 0.01 * (tall ? width / height : 1) ? am < bm : a.minX < b.minX
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// The document camera, which finds the page, flattens it and sharpens it.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.onCancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.onCancel() }
    }
}

/// Scan or pick a call sheet, check what was read, and keep the scenes. They then name the scene
/// folders in the gallery and can be picked when slating.
struct CallSheetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CallSheetStore.shared
    @State private var picked: [PhotosPickerItem] = []
    @State private var scanning = false
    @State private var reading = false
    @State private var found: [CallSheetScene] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if VNDocumentCameraViewController.isSupported {
                        Button { scanning = true } label: { Label("Scan a call sheet", systemImage: "doc.viewfinder") }
                    }
                    PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) {
                        Label("Pick photos of one (several if it runs on)", systemImage: "photo.on.rectangle")
                    }
                    if reading { HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
                    if let message { Text(message).font(Theme.footnote).foregroundStyle(.orange) }
                }
                if !found.isEmpty {
                    Section("Found on the sheet. Fix anything wrong, then add.") {
                        ForEach($found) { $item in
                            HStack(spacing: 8) {
                                TextField("12", text: $item.scene)
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                                    .frame(width: 56)
                                    .fontWeight(.bold)
                                TextField("Name", text: $item.title)
                            }
                        }
                        .onDelete { found.remove(atOffsets: $0) }
                        Button {
                            store.add(found.filter { !$0.scene.trimmingCharacters(in: .whitespaces).isEmpty })
                            Haptics.success()
                            found = []
                            message = nil
                        } label: { Label("Add \(found.count) scene\(found.count == 1 ? "" : "s")", systemImage: "plus.circle.fill") }
                            .tint(Theme.accent)
                    }
                }
                if !store.scenes.isEmpty {
                    Section("Scenes on this shoot") {
                        ForEach(store.scenes) { item in
                            HStack {
                                Text(item.scene).fontWeight(.bold).frame(width: 56, alignment: .leading)
                                Text(item.title.isEmpty ? "No name" : item.title).foregroundStyle(item.title.isEmpty ? .secondary : .primary)
                            }
                        }
                        .onDelete { offsets in offsets.map { store.scenes[$0].scene }.forEach { store.remove($0) } }
                    }
                }
            }
            .navigationTitle("Call sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $scanning) {
                DocumentScanner(onScan: { images in scanning = false; read(images) }, onCancel: { scanning = false })
                    .ignoresSafeArea()
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                let chosen = items
                picked = []
                Task {
                    var images: [UIImage] = []
                    for item in chosen {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { images.append(image) }
                    }
                    read(images)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func read(_ images: [UIImage]) {
        reading = true
        message = nil
        Task {
            var pages: [[CallSheetText]] = []
            for image in images { pages.append(await CallSheetScanner.lines(in: image)) }
            let lines = pages.flatMap { $0 }
            let scenes = CallSheetParser.parse(pages: pages)
            Diagnostics.log("Call sheet: \(images.count) picture(s), \(lines.count) lines read, \(scenes.count) scenes found")
            reading = false
            // Picking or scanning again adds the next part of a long sheet to what is already found.
            let known = Set(found.map { $0.scene.uppercased() })
            found += scenes.filter { !known.contains($0.scene.uppercased()) }
            if scenes.isEmpty, found.isEmpty {
                message = lines.isEmpty
                    ? "Nothing readable in that picture. Try again in better light, with the whole page in view."
                    : "No scenes found. Scene lines look like \"12 INT. KITCHEN - DAY\", \"Sc 12 Kitchen\", or a table with a SCENE column next to \"EXT - DOCK\"."
            }
        }
    }
}
