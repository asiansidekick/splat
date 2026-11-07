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
                    PhotosPicker(selection: $picked, maxSelectionCount: 4, matching: .images) {
                        Label("Pick a photo of one", systemImage: "photo")
                    }
                    if reading { HStack { ProgressView(); Text("Reading…").foregroundStyle(.secondary) } }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
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
                            .tint(.yellow)
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
            var lines: [String] = []
            for image in images { lines += await CallSheetScanner.lines(in: image) }
            let scenes = CallSheetParser.parse(lines)
            Diagnostics.log("Call sheet: \(lines.count) lines read, \(scenes.count) scenes found")
            reading = false
            found = scenes
            if scenes.isEmpty {
                message = lines.isEmpty
                    ? "Nothing readable in that picture. Try again in better light, with the whole page in view."
                    : "No scenes found. Scene lines look like \"12 INT. KITCHEN - DAY\" or \"Sc 12 Kitchen\"."
            }
        }
    }
}
