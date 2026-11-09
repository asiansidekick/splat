import CoreImage
import simd
import PhotosUI
import SwiftUI
import UIKit
import Vision

/// Lifts the subject out of a photo, the same trick as touching and holding a subject in Photos.
enum CutoutLift {
    struct Lifted {
        /// The photo, upright and no bigger than needed, and the mask the cut-out was made with (kept for touching up).
        var photo: UIImage
        var mask: CGImage
        /// What the reader found, for Start again.
        var found: CGImage
        var png: Data
        var aspect: Float
        var preview: UIImage
        /// No subject was found, so the whole photo was kept.
        var whole: Bool
        /// Each subject on its own, for Tap subject.
        var parts: [CGImage] = []
    }

    /// The subject on a transparent background, cropped to it, as PNG, with its width over height. With no clear
    /// subject the whole photo is kept, to be touched up by hand.
    nonisolated static func lift(_ original: UIImage, longSide: CGFloat = 1100) -> Lifted? {
        // Upright, and no bigger than needed (a cut-out is a few hundred pixels tall on screen).
        let scale = min(1, longSide / max(original.size.width, original.size.height))
        let size = CGSize(width: (original.size.width * scale).rounded(), height: (original.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
        guard let cg = upright.cgImage else { return nil }
        var mask: CGImage?
        var parts: [CGImage] = []
        let handler = VNImageRequestHandler(cgImage: cg)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            if let result = request.results?.first, !result.allInstances.isEmpty {
                let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                let alpha = CIImage(cvPixelBuffer: buffer).applyingFilter("CIMaskToAlpha")
                let whole = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
                let context = CIContext()
                mask = context.createCGImage(alpha, from: whole, format: .RGBA8, colorSpace: CutoutMask.space)
                for instance in result.allInstances.prefix(8) {
                    let one = try result.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
                    if let part = context.createCGImage(CIImage(cvPixelBuffer: one).applyingFilter("CIMaskToAlpha"), from: whole,
                                                        format: .RGBA8, colorSpace: CutoutMask.space) { parts.append(part) }
                }
            }
        } catch {
            Diagnostics.log("Cut-out lift failed: \(error)")
        }
        let whole = mask == nil
        guard let used = mask ?? CutoutMask.full(width: cg.width, height: cg.height),
              let made = CutoutMask.compose(cg, mask: used) else { return nil }
        return Lifted(photo: upright, mask: used, found: used, png: made.png, aspect: made.aspect, preview: made.preview, whole: whole, parts: parts)
    }
}

extension CutoutLift {
    /// Each subject the phone finds in the picture on its own, as masks the picture's size, for Tap subject.
    nonisolated static func parts(of cg: CGImage) -> [CGImage] {
        let handler = VNImageRequestHandler(cgImage: cg)
        let request = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return [] }
        let whole = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let context = CIContext()
        return result.allInstances.prefix(12).compactMap { instance in
            guard let one = try? result.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler) else { return nil }
            return context.createCGImage(CIImage(cvPixelBuffer: one).applyingFilter("CIMaskToAlpha"), from: whole,
                                         format: .RGBA8, colorSpace: CutoutMask.space)
        }
    }
}

/// Every cut-out made on this phone, kept so it can be stood in any reference later (Phil, 2026-11-07).
enum CutoutLibrary {
    struct Entry: Identifiable {
        let id: UUID
        let package: CutoutPackage
    }

    private static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CutoutLibrary", isDirectory: true)
    }

    static func save(_ package: CutoutPackage) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(package).write(to: folder.appendingPathComponent("\(UUID().uuidString).\(Cutout.fileExtension)"), options: .atomic)
        } catch {
            Diagnostics.log("Could not keep the cut-out in the library: \(error)")
        }
    }

    /// Newest first.
    static func all() -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let dated = files.filter { $0.pathExtension == Cutout.fileExtension }.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        return dated.compactMap { url, _ in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url), let package = try? JSONDecoder().decode(CutoutPackage.self, from: data) else { return nil }
            return Entry(id: id, package: package)
        }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).\(Cutout.fileExtension)"))
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
        var photo: UIImage
        var mask: CGImage
        var found: CGImage
        var parts: [CGImage]
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
    @State private var saved: [CutoutLibrary.Entry] = []
    @State private var touching: UUID?

    private var heightMetres: Float? {
        guard let value = Float(heightText.replacingOccurrences(of: ",", with: ".")), value >= 2, value <= 500 else { return nil }
        return value / 100
    }

    var body: some View {
        NavigationStack {
            List {
                if !saved.isEmpty {
                    Section("Saved cut-outs") {
                        ForEach(saved) { entry in
                            Button { stand(entry.package) } label: {
                                HStack(spacing: 12) {
                                    if let png = (entry.package.views.first { $0.angle == 0 } ?? entry.package.views.first)?.png, let image = UIImage(data: png) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(width: 48, height: 64)
                                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    VStack(alignment: .leading) {
                                        Text(entry.package.name).font(Theme.headline)
                                        Text("\(Int((entry.package.height * 100).rounded())) cm · \(entry.package.views.count) photo\(entry.package.views.count == 1 ? "" : "s")")
                                            .font(Theme.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Stand it").font(Theme.subheadline).foregroundStyle(Theme.accent)
                                }
                            }
                            .tint(.primary)
                        }
                        .onDelete { offsets in
                            for index in offsets { CutoutLibrary.delete(saved[index].id) }
                            saved.remove(atOffsets: offsets)
                        }
                    }
                }
                Section {
                    PhotosPicker(selection: $picked, maxSelectionCount: 8, matching: .images) {
                        Label(items.isEmpty ? "Pick photos from different sides" : "Add more photos", systemImage: "photo.stack")
                    }
                    if working > 0 { HStack { ProgressView(); Text("Cutting out \(working) photo\(working == 1 ? "" : "s")…").foregroundStyle(.secondary) } }
                    if skipped > 0 { Text("\(skipped) photo\(skipped == 1 ? "" : "s") had no clear subject, so the whole photo was kept. Tap Touch up to erase the background or loop round the subject.").font(Theme.footnote).foregroundStyle(.orange) }
                    if let message { Text(message).font(Theme.footnote).foregroundStyle(.orange) }
                } footer: {
                    Text("One clear subject per photo. Front, side and back work best. Choose the side each photo shows, and touch up any edge the phone got wrong.")
                }
                if !items.isEmpty {
                    Section("Photos") {
                        ForEach($items) { $item in
                            HStack(spacing: 12) {
                                Button { touching = item.id } label: {
                                    Image(uiImage: item.preview)
                                        .resizable().scaledToFit()
                                        .frame(width: 64, height: 84)
                                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.borderless)
                                VStack(alignment: .leading, spacing: 6) {
                                    Picker("Shows the", selection: $item.angle) {
                                        ForEach(Self.sides, id: \.angle) { side in Text(side.name).tag(side.angle) }
                                    }
                                    .pickerStyle(.menu)
                                    Button { touching = item.id } label: { Label("Touch up", systemImage: "paintbrush.pointed") }
                                        .buttonStyle(.borderless)
                                        .font(Theme.subheadline)
                                }
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
            .onAppear { saved = CutoutLibrary.all() }
            .fullScreenCover(item: Binding(get: { touching.flatMap { id in items.first { $0.id == id } }.map(Touch.init) },
                                           set: { touching = $0?.id })) { touch in
                MaskBrushSheet(title: "Touch up", photo: touch.item.photo, mask: touch.item.mask, original: touch.item.found, parts: touch.item.parts) { mask in
                    retouch(touch.item.id, mask: mask)
                }
            }
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
                let result = await Task.detached(priority: .userInitiated) { () -> CutoutLift.Lifted? in
                    guard let data, let image = UIImage(data: data) else { return nil }
                    return CutoutLift.lift(image)
                }.value
                working -= 1
                if let result {
                    let angle = Self.suggested.first { want in !items.contains { $0.angle == want } } ?? 0
                    items.append(Item(preview: result.preview, png: result.png, aspect: result.aspect, angle: angle,
                                      photo: result.photo, mask: result.mask, found: result.found, parts: result.parts))
                    if result.whole { skipped += 1 }
                } else {
                    message = "Couldn't read that photo."
                }
            }
        }
    }

    private struct Touch: Identifiable {
        let item: Item
        var id: UUID { item.id }
    }

    /// Makes the cut-out again from a hand-painted mask.
    private func retouch(_ id: UUID, mask: CGImage) {
        guard let photo = items.first(where: { $0.id == id })?.photo.cgImage else { return }
        Task {
            let made = await Task.detached(priority: .userInitiated) { CutoutMask.compose(photo, mask: mask) }.value
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            guard let made else {
                message = "Nothing was kept. Paint with Keep over what you want."
                return
            }
            items[index].mask = mask
            items[index].png = made.png
            items[index].aspect = made.aspect
            items[index].preview = made.preview
            message = nil
            Diagnostics.log("Cut-out touched up by hand")
        }
    }

    private func place() {
        guard let height = heightMetres, !items.isEmpty else { return }
        let package = CutoutPackage(
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Cut-out" : name.trimmingCharacters(in: .whitespaces),
            height: height,
            views: items.map { CutoutPackage.View(angle: $0.angle, png: $0.png, aspect: $0.aspect) })
        if stand(package) { CutoutLibrary.save(package) }
    }

    /// Puts a cut-out in the room; true when it worked.
    @discardableResult
    private func stand(_ package: CutoutPackage) -> Bool {
        if placer.addCutout(package, at: base) {
            Haptics.success()
            dismiss()
            return true
        }
        message = placer.modelError ?? "Could not place the cut-out."
        Haptics.warning()
        return false
    }
}
