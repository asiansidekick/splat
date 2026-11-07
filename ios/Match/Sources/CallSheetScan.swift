import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

/// Reads the text on a picture of a call sheet, on the phone, with no internet.
enum CallSheetScanner {
    static func lines(in image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation)
                try? handler.perform([request])
                let observations = (request.results ?? []).sorted {
                    // Top to bottom, then left to right, so a table reads like the page.
                    abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
                }
                continuation.resume(returning: observations.compactMap { $0.topCandidates(1).first?.string })
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
                    PhotosPicker(selection: $picked, maxSelectionCount: 4, matching: .images) {
                        Label("Pick a photo of one", systemImage: "photo")
                    }
                    if reading { HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
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
                                    .font(.subheadline)
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
            var lines: [String] = []
            for image in images { lines += await CallSheetScanner.lines(in: image) }
            let scenes = DaySetup.parse(lines)
            reading = false
            found = scenes
            if scenes.isEmpty {
                message = lines.isEmpty
                    ? "Nothing readable in that picture. Try again in better light, with the whole page in view."
                    : "No scenes found. Scene lines look like \"12 INT. KITCHEN - DAY\" or \"Sc 12 Kitchen\"."
            } else if scenes.allSatisfy({ $0.characters.isEmpty }) {
                message = "Scenes read, but no cast list matched them. Type each scene's characters in."
            }
        }
    }
}
