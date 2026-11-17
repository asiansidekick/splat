import QuickLookThumbnailing
import SwiftUI
import simd

/// 3D models brought into Reset, kept so they can be placed again without finding the file (Phil, 2026-11-17).
enum ModelLibrary {
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ModelLibrary", isDirectory: true)
    }

    private static let removedKey = "modelLibraryRemoved"
    private static var removed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: removedKey) }
    }

    /// Keeps a copy of a stored model (a USDZ) under its name. A model of the same name is replaced.
    static func keep(_ stored: URL, name: String, replacing: Bool = true) {
        let clean = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard stored.pathExtension.lowercased() == "usdz", !clean.isEmpty, !clean.hasPrefix("Scan ") else { return }
        let target = folder.appendingPathComponent("\(clean).usdz")
        let exists = FileManager.default.fileExists(atPath: target.path)
        if exists, !replacing { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if exists { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: stored, to: target)
            if replacing { removed.remove(clean) }
        } catch {
            Diagnostics.log("Could not keep \(clean) in the gallery: \(error.localizedDescription)")
        }
    }

    /// Newest first.
    static func all() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "usdz" }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func delete(_ url: URL) {
        removed.insert(url.deletingPathExtension().lastPathComponent)
        try? FileManager.default.removeItem(at: url)
    }

    /// Models already placed in earlier references come into the gallery too, once each.
    static func gatherFromReferences() {
        let skipped = removed
        let examples = Set(SetPiece.allCases.map(\.rawValue))
        var found = 0
        for reference in ReferenceStore.all() {
            for model in reference.models where model.mannequin == nil && !examples.contains(model.name) && !skipped.contains(model.name) {
                let file = ReferenceStore.folder(for: reference.id).appendingPathComponent(model.file)
                guard file.pathExtension.lowercased() == "usdz", FileManager.default.fileExists(atPath: file.path),
                      !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(model.name).usdz").path)
                else { continue }
                keep(file, name: model.name, replacing: false)
                found += 1
            }
        }
        if found > 0 { Diagnostics.log("Gallery: \(found) models gathered from earlier references") }
    }
}

/// Everything that can be stood in the room, in one place: 3D scans, 3D models used before, and cut-outs. Tap one
/// to place it.
struct AssetGallery: View {
    let placer: ModelPlacer
    /// Where it goes when there is no live camera (Review); nil places it where the camera points.
    var base: simd_float4x4? = nil
    @Environment(\.dismiss) private var dismiss

    private enum Asset: Identifiable {
        case scan(ScanFolder)
        case model(URL)
        case cutout(CutoutLibrary.Entry)

        var id: String {
            switch self {
            case .scan(let folder): return "scan " + folder.url.path
            case .model(let url): return "model " + url.path
            case .cutout(let entry): return "cutout " + entry.id.uuidString
            }
        }
        var name: String {
            switch self {
            case .scan(let folder): return folder.name
            case .model(let url): return url.deletingPathExtension().lastPathComponent
            case .cutout(let entry): return entry.package.name
            }
        }
        var kind: String {
            switch self {
            case .scan: return "3D scan"
            case .model: return "3D model"
            case .cutout: return "Cut-out"
            }
        }
        var file: URL? {
            switch self {
            case .scan(let folder): return folder.model
            case .model(let url): return url
            case .cutout: return nil
            }
        }
    }

    @State private var assets: [Asset] = []
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let message {
                    Text(message).font(Theme.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                if loaded, assets.isEmpty {
                    Text("Nothing here yet. Scans, 3D models and cut-outs you add show here, ready to place again.")
                        .font(Theme.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 12) {
                    ForEach(assets) { asset in
                        Button { place(asset) } label: {
                            VStack(spacing: 4) {
                                AssetPicture(file: asset.file, cutout: Self.picture(of: asset))
                                    .frame(height: 100)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                Text(asset.name).font(Theme.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                                Text(asset.kind).font(Theme.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if case .scan = asset {
                                Text("Delete scans from the Scans list")
                            } else {
                                Button(role: .destructive) { delete(asset) } label: { Label("Delete from the gallery", systemImage: "trash") }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle("Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private static func picture(of asset: Asset) -> Data? {
        guard case .cutout(let entry) = asset else { return nil }
        return (entry.package.views.first { $0.angle == 0 } ?? entry.package.views.first)?.png
    }

    private func load() async {
        refresh()
        // Models from earlier references are copied in off the main thread, then the list is read again.
        await Task.detached(priority: .utility) { ModelLibrary.gatherFromReferences() }.value
        refresh()
        loaded = true
    }

    private func refresh() {
        assets = ScanFolder.all().filter(\.hasModel).map(Asset.scan) + ModelLibrary.all().map(Asset.model) + CutoutLibrary.all().map(Asset.cutout)
    }

    private func place(_ asset: Asset) {
        placer.modelError = nil
        let before = placer.models.count
        switch asset {
        case .scan(let folder): placer.addFacingCamera(from: [folder.model], base: base)
        case .model(let url): placer.addFacingCamera(from: [url], base: base)
        case .cutout(let entry): _ = placer.addCutout(entry.package, at: base)
        }
        if placer.models.count > before {
            Diagnostics.log("Gallery: placed \(asset.kind) \(asset.name)")
            Haptics.success()
            dismiss()
        } else {
            // Said here, in the gallery, instead of in an alert behind it.
            message = placer.modelError ?? "Could not place \(asset.name)."
            placer.modelError = nil
            Haptics.warning()
        }
    }

    private func delete(_ asset: Asset) {
        switch asset {
        case .model(let url): ModelLibrary.delete(url)
        case .cutout(let entry): CutoutLibrary.delete(entry.id)
        case .scan: return
        }
        refresh()
    }
}

/// A small picture of an asset: a cut-out's own photo, or a rendering of the 3D file.
private struct AssetPicture: View {
    let file: URL?
    let cutout: Data?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(4)
            } else {
                Image(systemName: file == nil ? "figure.stand" : "cube").font(.system(size: 30)).foregroundStyle(.secondary)
            }
        }
        .task(id: file?.path ?? "cutout") {
            if let cutout {
                image = UIImage(data: cutout)
            } else if let file {
                let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 200, height: 200), scale: 2, representationTypes: .thumbnail)
                image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            }
        }
    }
}
