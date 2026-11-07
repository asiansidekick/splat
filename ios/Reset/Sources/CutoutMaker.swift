import CoreImage
import simd
import PhotosUI
import SwiftUI
import UIKit
import Vision

/// Lifts the subject out of a photo, the same trick as touching and holding a subject in Photos.
enum CutoutLift {
    /// The subject on a transparent background, cropped to it, as PNG, with its width over height.
    nonisolated static func lift(_ original: UIImage, longSide: CGFloat = 1100) -> (png: Data, aspect: Float, preview: UIImage)? {
        // Upright, and no bigger than needed (a cut-out is a few hundred pixels tall on screen).
        let scale = min(1, longSide / max(original.size.width, original.size.height))
        let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
        guard let cg = upright.cgImage else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
            let image = CIImage(cvPixelBuffer: buffer)
            guard let out = CIContext().createCGImage(image, from: image.extent), out.height > 0,
                  let png = UIImage(cgImage: out).pngData() else { return nil }
            return (png, Float(out.width) / Float(out.height), UIImage(cgImage: out))
        } catch {
            Diagnostics.log("Cut-out lift failed: \(error)")
            return nil
        }
    }
}

/// Make a scrapbook cut-out: pick photos of a person or thing from different sides, say which side each
/// shows, give the real height, and stand it in the room. As you walk round it, the cut-out shows the
/// photo that matches your side.
struct CutoutMaker: View {
    let placer: ModelPlacer
    /// Where to stand it when there is no live camera (the review screen); nil = where the camera points.
    var base: simd_float4x4?
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id = UUID()
        var preview: UIImage
        var png: Data
        var aspect: Float
        var angle: Float
    }

    /// The sides on offer: what the photo shows, as the thing itself would say it.
    private static let sides: [(name: String, angle: Float)] = [
        ("Front", 0), ("Front left", 45), ("Left side", 90), ("Back left", 135),
        ("Back", 180), ("Back right", -135), ("Right side", -90), ("Front right", -45),
    ]
    /// Suggested sides for the 1st, 2nd, 3rd photo: the most useful first.
    private static let suggested: [Float] = [0, 90, 180, -90, 45, -45, 135, -135]

    @State private var picked: [PhotosPickerItem] = []
    @State private var items: [Item] = []
    @State private var working = 0
    @State private var skipped = 0
    @State private var name = ""
    @State private var heightText = "170"
    @State private var message: String?

    private var heightMetres: Float? {
        guard let value = Float(heightText.replacingOccurrences(of: ",", with: ".")), value >= 2, value <= 500 else { return nil }
        return value / 100
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotosPicker(selection: $picked, maxSelectionCount: 8, matching: .images) {
                        Label(items.isEmpty ? "Pick photos from different sides" : "Add more photos", systemImage: "photo.stack")
                    }
                    if working > 0 { HStack { ProgressView(); Text("Cutting out \(working) photo\(working == 1 ? "" : "s")…").foregroundStyle(.secondary) } }
                    if skipped > 0 { Text("\(skipped) photo\(skipped == 1 ? "" : "s") had nothing to lift out. Try one with the subject clearer.").font(Theme.footnote).foregroundStyle(.orange) }
                    if let message { Text(message).font(Theme.footnote).foregroundStyle(.orange) }
                } footer: {
                    Text("One clear subject per photo. Front, side and back work best. Choose the side each photo shows.")
                }
                if !items.isEmpty {
                    Section("Photos") {
                        ForEach($items) { $item in
                            HStack(spacing: 12) {
                                Image(uiImage: item.preview)
                                    .resizable().scaledToFit()
                                    .frame(width: 64, height: 84)
                                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                Picker("Shows the", selection: $item.angle) {
                                    ForEach(Self.sides, id: \.angle) { side in Text(side.name).tag(side.angle) }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                        .onDelete { items.remove(atOffsets: $0) }
                    }
                    Section("The cut-out") {
                        LabeledContent("Name") {
                            TextField("Optional, for example Bob", text: $name).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Real height (cm)") {
                            TextField("170", text: $heightText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    }
                    Section {
                        Button { place() } label: { Label("Stand it in the room", systemImage: "figure.stand") }
                            .disabled(heightMetres == nil || items.isEmpty)
                            .tint(Theme.accent)
                    } footer: {
                        Text("It stands where the camera points and turns to show the photo nearest your side. Drag it to move it, pinch to resize, twist to turn.")
                    }
                }
            }
            .navigationTitle("Cut-out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: picked) { _, chosen in
                guard !chosen.isEmpty else { return }
                picked = []
                lift(chosen)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func lift(_ chosen: [PhotosPickerItem]) {
        working += chosen.count
        message = nil
        Task {
            for entry in chosen {
                let data = try? await entry.loadTransferable(type: Data.self)
                let result = await Task.detached(priority: .userInitiated) { () -> (png: Data, aspect: Float, preview: UIImage)? in
                    guard let data, let image = UIImage(data: data) else { return nil }
                    return CutoutLift.lift(image)
                }.value
                working -= 1
                if let result {
                    let angle = Self.suggested.first { want in !items.contains { $0.angle == want } } ?? 0
                    items.append(Item(preview: result.preview, png: result.png, aspect: result.aspect, angle: angle))
                } else {
                    skipped += 1
                }
            }
        }
    }

    private func place() {
        guard let height = heightMetres, !items.isEmpty else { return }
        let package = CutoutPackage(
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Cut-out" : name.trimmingCharacters(in: .whitespaces),
            height: height,
            views: items.map { CutoutPackage.View(angle: $0.angle, png: $0.png, aspect: $0.aspect) })
        if placer.addCutout(package, at: base) {
            Haptics.success()
            dismiss()
        } else {
            message = placer.modelError ?? "Could not place the cut-out."
            Haptics.warning()
        }
    }
}
