import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

/// Reads the text on a picture of a call sheet, on the phone, with no internet.
enum CallSheetScanner {
    /// Every piece of text on the picture and where it is (0...1 from the top left). A tall
    /// screenshot is read in overlapping strips, because the reader shrinks a whole tall picture
    /// until the small print of a call sheet is lost.
    static func boxes(in image: UIImage) async -> [TextBox] {
        guard let cg = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let sideways: [CGImagePropertyOrientation] = [.left, .right, .leftMirrored, .rightMirrored]
        let turned = sideways.contains(orientation)
        let width = Double(turned ? cg.height : cg.width), height = Double(turned ? cg.width : cg.height)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Strips about as tall as the picture is wide, overlapping by a fifth.
                let strip = min(1, width / max(height, 1))
                var starts: [Double] = [0]
                while let last = starts.last, last + strip < 0.999 {
                    let next = min(1 - strip, last + strip * 0.8)
                    guard next > last + 0.001 else { break }
                    starts.append(next)
                }
                var found: [TextBox] = []
                for start in starts {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.minimumTextHeight = 0
                    // Vision measures from the bottom.
                    let roi = CGRect(x: 0, y: 1 - start - strip, width: 1, height: strip)
                    request.regionOfInterest = roi
                    let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
                    try? handler.perform([request])
                    for observation in request.results ?? [] {
                        guard let text = observation.topCandidates(1).first?.string else { continue }
                        let box = observation.boundingBox
                        // Text cut by the edge of a strip is read whole in the next one.
                        let nearTop = box.maxY > 0.995 && start > 0
                        let nearBottom = box.minY < 0.005 && start + strip < 0.999
                        if nearTop || nearBottom { continue }
                        let top = start + Double(1 - box.maxY) * strip
                        let piece = TextBox(text: text, x: Double(box.minX), y: top, width: Double(box.width),
                                            height: Double(box.height) * strip)
                        // Read twice where the strips overlap: keep one.
                        let twice = found.contains {
                            $0.text == piece.text && abs($0.midX - piece.midX) < 0.01 && abs($0.midY - piece.midY) < max(piece.height, 0.002)
                        }
                        if !twice { found.append(piece) }
                    }
                }
                continuation.resume(returning: found)
            }
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

/// Scan or pick a call sheet, check the scenes and characters it names, and make the day's boards.
struct DaySetupSheet: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Board) -> Void
    @State private var picked: [PhotosPickerItem] = []
    @State private var scanning = false
    @State private var reading = false
    @State private var found: [DayScene] = []
    /// What each picture read so far said, so more pictures add to it.
    @State private var pages: [[TextBox]] = []
    @State private var department: Department = .hair
    @State private var message: String?

    private var toMake: [Board] { DaySetup.boards(for: found, department: department, existing: store.boards) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if VNDocumentCameraViewController.isSupported {
                        Button { scanning = true } label: { Label("Scan a call sheet", systemImage: "doc.viewfinder") }
                    }
                    PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) {
                        Label(pages.isEmpty ? "Pick photos or screenshots" : "Add more of the sheet", systemImage: "photo.on.rectangle")
                    }
                    if pages.isEmpty {
                        Text("Pick several if the sheet runs over more than one screenshot.")
                            .font(Theme.font(.footnote)).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("\(pages.count) picture\(pages.count == 1 ? "" : "s") read").foregroundStyle(.secondary)
                            Spacer()
                            Button("Start again") { pages = []; found = []; message = nil }
                                .buttonStyle(.borderless)
                        }
                        .font(Theme.font(.footnote))
                    }
                    if reading { HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
                    if let message { Text(message).font(Theme.font(.footnote)).foregroundStyle(.orange) }
                }
                if !found.isEmpty {
                    Section {
                        Picker("Your department", selection: $department) {
                            ForEach(Department.main) { Text($0.name).tag($0) }
                        }
                    }
                    Section("Found on the sheet. Untick or fix anything wrong.") {
                        ForEach($found) { $item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Toggle("", isOn: $item.include).labelsHidden().tint(Theme.accent)
                                    TextField("12", text: $item.scene)
                                        .textInputAutocapitalization(.characters)
                                        .autocorrectionDisabled()
                                        .frame(width: 56)
                                        .fontWeight(.bold)
                                    TextField("Name", text: $item.title)
                                }
                                TextField("Characters, separated by commas", text: $item.characters)
                                    .font(Theme.font(.subheadline))
                                    .foregroundStyle(item.characters.isEmpty ? .orange : .primary)
                            }
                        }
                        .onDelete { found.remove(atOffsets: $0) }
                    }
                    Section {
                        Button {
                            let boards = toMake
                            for board in boards { store.save(board) }
                            if let first = boards.first { onCreated(first) }
                            Haptics.success()
                            dismiss()
                        } label: {
                            Label(toMake.isEmpty ? "No new boards to make" : "Make \(toMake.count) board\(toMake.count == 1 ? "" : "s")",
                                  systemImage: "plus.circle.fill")
                        }
                        .disabled(toMake.isEmpty)
                    } footer: {
                        Text("One board for each character in each ticked scene. A scene with no character gets none: type one in. Boards you already have are not made again.")
                    }
                }
            }
            .navigationTitle("Set up the day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
            .onAppear { department = store.boards.max { $0.created < $1.created }?.department ?? .hair }
        }
        .preferredColorScheme(.dark)
    }

    private func read(_ images: [UIImage]) {
        reading = true
        message = nil
        Task {
            var added: [[TextBox]] = []
            for image in images { added.append(await CallSheetScanner.boxes(in: image)) }
            let readable = added.filter { !$0.isEmpty }
            pages += readable
            let scenes = DaySetup.parse(pages: pages)
            reading = false
            // Keep what was already ticked or fixed; add what the new pictures found.
            var kept = found
            for scene in scenes where !kept.contains(where: { $0.scene.caseInsensitiveCompare(scene.scene) == .orderedSame }) {
                kept.append(scene)
            }
            found = kept
            if found.isEmpty {
                message = pages.isEmpty
                    ? "Nothing readable in that picture. Try again in better light, with the whole page in view."
                    : "No scenes found. Scenes are read from lines like \"12 INT. KITCHEN - DAY\" or a scene column next to \"EXT - DOCK\"."
            } else if readable.count < images.count {
                message = "\(images.count - readable.count) of those pictures had nothing readable."
            } else if found.allSatisfy({ $0.characters.isEmpty }) {
                message = "Scenes read, but no cast list matched them. Type each scene's characters in."
            }
        }
    }
}
