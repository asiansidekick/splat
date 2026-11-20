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
        let kind = stored.pathExtension.lowercased()
        guard kind == "usdz" || kind == "fbx", !clean.isEmpty, !clean.hasPrefix("Scan ") else { return }
        let target = folder.appendingPathComponent("\(clean).\(kind)")
        let exists = FileManager.default.fileExists(atPath: target.path)
        if exists, !replacing { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if exists { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: stored, to: target)
            // Phil, 2026-11-18: imported FBX characters are kept too, with the pictures that came with them.
            if kind == "fbx" {
                let pictures = FBXImport.texturesFolder(for: target)
                try? FileManager.default.removeItem(at: pictures)
                if FileManager.default.fileExists(atPath: FBXImport.texturesFolder(for: stored).path) {
                    try FileManager.default.copyItem(at: FBXImport.texturesFolder(for: stored), to: pictures)
                }
            }
            if replacing { removed.remove(clean) }
        } catch {
            Diagnostics.log("Could not keep \(clean) in the gallery: \(error.localizedDescription)")
        }
    }

    /// Newest first.
    static func all() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { ["usdz", "fbx"].contains($0.pathExtension.lowercased()) }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Gives a kept model another name by renaming its file; a name already used gets a number.
    static func rename(_ url: URL, to text: String) {
        let clean = text.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != url.deletingPathExtension().lastPathComponent else { return }
        let kind = url.pathExtension
        var target = url.deletingLastPathComponent().appendingPathComponent("\(clean).\(kind)")
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("\(clean) \(number).\(kind)")
            number += 1
        }
        if kind.lowercased() == "fbx" { try? FileManager.default.moveItem(at: FBXImport.texturesFolder(for: url), to: FBXImport.texturesFolder(for: target)) }
        // The old name is remembered as gone, so models placed under it earlier don't bring it back.
        removed.insert(url.deletingPathExtension().lastPathComponent)
        try? FileManager.default.moveItem(at: url, to: target)
    }

    static func delete(_ url: URL) {
        removed.insert(url.deletingPathExtension().lastPathComponent)
        try? FileManager.default.removeItem(at: url)
        if url.pathExtension.lowercased() == "fbx" { try? FileManager.default.removeItem(at: FBXImport.texturesFolder(for: url)) }
    }

    /// Models already placed in earlier references come into the gallery too, once each.
    static func gatherFromReferences() {
        let skipped = removed
        let examples = Set(SetPiece.allCases.map(\.rawValue))
        var found = 0
        for reference in ReferenceStore.all() {
            for model in reference.models where model.mannequin == nil && !examples.contains(model.name) && !skipped.contains(model.name) {
                let file = ReferenceStore.folder(for: reference.id).appendingPathComponent(model.file)
                let kind = file.pathExtension.lowercased()
                guard model.scan != true, kind == "usdz" || kind == "fbx", FileManager.default.fileExists(atPath: file.path),
                      !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(model.name).\(kind)").path)
                else { continue }
                keep(file, name: model.name, replacing: false)
                found += 1
            }
        }
        if found > 0 { Diagnostics.log("Gallery: \(found) models gathered from earlier references") }
    }
}

/// What the top row of the gallery asks the screen behind it to do.
enum GalleryAction { case importModel, cutout, examples, scan }

/// Everything that can be stood in the room, in one place: 3D scans, 3D models used before, and cut-outs. Tap one
/// to place it.
struct AssetGallery: View {
    let placer: ModelPlacer
    /// Where it goes when there is no live camera (Review); nil places it where the camera points.
    var base: simd_float4x4? = nil
    /// Phil, 2026-11-18: one menu for 3D models, the gallery and the scans list. With this set, the top row adds
    /// things (scan, import, cut-out, people and props) and each scan has its own edit menu.
    var actions: ((GalleryAction) -> Void)? = nil
    var canScan = false
    /// Set when the device can't scan at all: the Scan button stays and says so.
    var scanApology: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var trimming: ScanFolder?
    /// Phil, 2026-11-20: a scan of a person made into a posable character (ScanCharacter.swift).
    @State private var makingPerson: ScanFolder?
    /// Phil, 2026-11-20: "I can't find the posable model I just made". The person just made goes first, marked New.
    @State private var newest: URL?
    @State private var preview: URL?
    @State private var version = 0
    @State private var renaming: Asset?
    @State private var newName = ""
    /// Phil, 2026-11-20: a scanned head going on an imported character.
    @State private var puttingHead: String?

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
            case .scan(let folder): return folder.title
            case .model(let url): return url.deletingPathExtension().lastPathComponent
            case .cutout(let entry): return entry.package.name
            }
        }
        var kind: String {
            switch self {
            case .scan: return "3D scan"
            case .model(let url): return url.pathExtension.lowercased() == "fbx" ? "Posable character" : "3D model"
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
    /// Phil, 2026-11-18: the grid scales in rows and columns. Pinch, or tap the grid button, to change.
    @AppStorage("galleryColumns") private var columns = 2

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            ScrollView {
                Color.clear.frame(height: 0).id("top")
                if let actions {
                    HStack(spacing: 6) {
                        if canScan { addButton("Scan", "viewfinder") { actions(.scan) } }
                        else if let apology = scanApology { addButton("Scan", "viewfinder") { message = apology }.opacity(0.5) }
                        addButton("Import", "square.and.arrow.down") { actions(.importModel) }
                        addButton("Cut-out", "scissors") { actions(.cutout) }
                        addButton("People", "figure.stand") { actions(.examples) }
                    }
                    .padding(.horizontal, 12).padding(.top, 8)
                }
                if let message {
                    Text(message).font(Theme.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                if loaded, assets.isEmpty {
                    Text("Nothing here yet. Scans, 3D models and cut-outs you add show here, ready to place again.")
                        .font(Theme.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: min(max(columns, 1), 5)), spacing: 12) {
                    ForEach(assets) { asset in
                        Button { place(asset) } label: {
                            VStack(spacing: 4) {
                                AssetPicture(file: asset.file, cutout: Self.picture(of: asset))
                                    .frame(maxWidth: .infinity)
                                    .aspectRatio(1, contentMode: .fit)
                                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                Text(asset.name).font(columns >= 4 ? Theme.caption2.weight(.semibold) : Theme.caption.weight(.semibold)).lineLimit(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                Text(asset.kind).font(Theme.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .overlay {
                            if let newest, asset.file?.standardizedFileURL == newest.standardizedFileURL {
                                RoundedRectangle(cornerRadius: 10).stroke(Theme.accent, lineWidth: 3)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let newest, asset.file?.standardizedFileURL == newest.standardizedFileURL {
                                Text("New").font(Theme.caption.weight(.bold)).foregroundStyle(Theme.onAccent)
                                    .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent, in: Capsule()).padding(6)
                            }
                        }
                        .overlay(alignment: .topTrailing) { editMenu(asset) }
                        .contextMenu { assetOptions(asset) }
                    }
                }
                .padding(12)
                .id(version)
            }
            .onChange(of: version) { _, _ in
                if newest != nil { withAnimation { scroller.scrollTo("top", anchor: .top) } }
            }
            }
            .gesture(MagnifyGesture().onEnded { value in
                if value.magnification > 1.2 { columns = max(1, columns - 1) }
                else if value.magnification < 0.83 { columns = min(5, columns + 1) }
            })
            .navigationTitle("3D models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    // 1 to 5 across, round again after 5.
                    Button { columns = columns >= 5 ? 1 : columns + 1 } label: {
                        Label("\(columns) across", systemImage: columns <= 1 ? "square" : columns == 2 ? "square.grid.2x2" : "square.grid.3x3")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .fullScreenCover(item: $trimming) { folder in
            ScanTrimScreen(folder: folder) { _ in
                trimming = nil
                version += 1
            }
        }
        .fullScreenCover(item: $makingPerson) { folder in
            ScanCharacterScreen(folder: folder, roomCamera: { on in
                // The model builder needs the phone's memory: the room camera rests while it works.
                if on {
                    if let configuration = placer.session.configuration { placer.session.run(configuration) }
                } else {
                    placer.session.pause()
                }
            }) { made, placeNow in
                makingPerson = nil
                guard let made else { return }
                newest = made
                refresh()
                version += 1
                Diagnostics.log("Scan person: \(placeNow ? "placed straight away" : "shown first in the gallery")")
                // After the cover has gone, so the gallery can close behind it.
                if placeNow { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { place(.model(made)) } }
            }
        }
        .overlay {
            if let puttingHead {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(puttingHead).font(Theme.subheadline.weight(.semibold)).foregroundStyle(.white)
                }
                .padding(20).background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .quickLookPreview($preview)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func commitRename() {
        guard let asset = renaming else { return }
        switch asset {
        case .scan(let folder): folder.rename(to: newName)
        case .model(let url): ModelLibrary.rename(url, to: newName)
        case .cutout(let entry): CutoutLibrary.rename(entry.id, to: newName)
        }
        renaming = nil
        refresh()
        version += 1
    }

    private func addButton(_ word: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                Text(word).font(Theme.caption.weight(.semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// The small ... on a tile: the same choices as holding it.
    private func editMenu(_ asset: Asset) -> some View {
        Menu {
            assetOptions(asset)
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 22))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.55))
                .padding(8)
        }
    }

    @ViewBuilder private func assetOptions(_ asset: Asset) -> some View {
        if case .scan(let folder) = asset {
            Button { place(asset) } label: { Label("Place", systemImage: "scope") }
            Button { newName = asset.name; renaming = asset } label: { Label("Rename", systemImage: "pencil") }
            Button { trimming = folder } label: { Label("Trim", systemImage: "scissors") }
            Button { makingPerson = folder } label: { Label("Make a posable person", systemImage: "figure.arms.open") }
            Button { preview = folder.model } label: { Label("View", systemImage: "eye") }
            ShareLink(item: folder.model) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { delete(asset) } label: { Label("Delete scan", systemImage: "trash") }
        } else {
            Button { place(asset) } label: { Label("Place", systemImage: "scope") }
            Button { newName = asset.name; renaming = asset } label: { Label("Rename", systemImage: "pencil") }
            // Phil, 2026-11-18: AirDrop objects.
            if case .model(let url) = asset, url.pathExtension.lowercased() == "fbx" {
                // Phil, 2026-11-20: "And swap to any of my imported mixamo fbx". Makes a copy with the scan's head.
                let people = ScanFolder.all().filter(\.hasModel)
                if !people.isEmpty {
                    Menu {
                        ForEach(people) { scan in
                            Button(scan.title) { putHead(from: scan, on: url) }
                        }
                    } label: { Label("Put a scanned head on", systemImage: "person.crop.circle.badge.plus") }
                }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            } else if case .model(let url) = asset {
                ShareLink(item: SharedModel(url: url, name: asset.name), preview: SharePreview(asset.name)) { Label("Share", systemImage: "square.and.arrow.up") }
            } else if case .cutout(let entry) = asset {
                ShareLink(item: SharedCutout(url: CutoutLibrary.file(for: entry.id), name: asset.name), preview: SharePreview(asset.name)) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Button(role: .destructive) { delete(asset) } label: { Label("Delete", systemImage: "trash") }
        }
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
        var all = ScanFolder.all().filter(\.hasModel).map(Asset.scan) + ModelLibrary.all().map(Asset.model) + CutoutLibrary.all().map(Asset.cutout)
        if let newest, let index = all.firstIndex(where: { $0.file?.standardizedFileURL == newest.standardizedFileURL }) {
            all.insert(all.remove(at: index), at: 0)
        }
        assets = all
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

    private func putHead(from scan: ScanFolder, on character: URL) {
        puttingHead = "Putting \(scan.title)'s head on…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                switch ScanCharacterMaker.prepare(scan) {
                case .success(let maker): do { return .success(try maker.putHead(on: character)) } catch { return .failure(error) }
                case .failure(let failure): return .failure(failure)
                }
            }.value
            puttingHead = nil
            switch result {
            case .success(let made):
                message = nil
                newest = made
                refresh()
                version += 1
            case .failure(let error):
                message = "Couldn't take that head: " + ((error as? ScanCharacterMaker.Failure)?.words ?? error.localizedDescription)
                Diagnostics.log("Scan person: head on \(character.lastPathComponent) failed: \(error)")
            }
        }
    }

    private func delete(_ asset: Asset) {
        switch asset {
        case .model(let url): ModelLibrary.delete(url)
        case .cutout(let entry): CutoutLibrary.delete(entry.id)
        case .scan(let folder): try? FileManager.default.removeItem(at: folder.url)
        }
        refresh()
    }
}

/// A small picture of an asset: a cut-out's own photo, or a rendering of the 3D file cropped close round the object.
private struct AssetPicture: View {
    let file: URL?
    let cutout: Data?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                if cutout != nil {
                    Image(uiImage: image).resizable().scaledToFit().padding(4)
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                Image(systemName: file == nil ? "figure.stand" : "cube").font(.system(size: 30)).foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: file?.path ?? "cutout") {
            if let cutout {
                image = UIImage(data: cutout).map { Self.fit($0) }
            } else if let file, file.pathExtension.lowercased() == "fbx" {
                guard let rendered = await FBXThumbnail.render(file) else { return }
                image = await Task.detached(priority: .utility) { Self.tightCrop(rendered) }.value
            } else if let file {
                let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 800, height: 800), scale: 1, representationTypes: .thumbnail)
                guard let rendered = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage else { return }
                // The crop is made off the main thread.
                image = await Task.detached(priority: .utility) { Self.tightCrop(rendered) }.value
            }
        }
    }

    /// A cut-out's photo: shown whole, padded to a square so it fills the tile evenly.
    private static func fit(_ picture: UIImage) -> UIImage { picture }

    /// Phil, 2026-11-18: "zoom in on the objects, reduce the white". The preview has the object small in a white
    /// square (and Apple's cube badge top right): find where the object is, cut a square close round it, and
    /// draw that at full size.
    private static func tightCrop(_ picture: UIImage) -> UIImage {
        guard let cg = picture.cgImage else { return picture }
        let width = cg.width, height = cg.height
        // Look at a 200-pixel copy.
        let probe = 200
        guard let context = CGContext(data: nil, width: probe, height: probe, bitsPerComponent: 8, bytesPerRow: probe * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return picture }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: probe, height: probe))
        context.interpolationQuality = .low
        context.draw(cg, in: CGRect(x: 0, y: 0, width: probe, height: probe))
        guard let data = context.data else { return picture }
        let pixels = data.bindMemory(to: UInt8.self, capacity: probe * probe * 4)
        var minX = probe, minY = probe, maxX = -1, maxY = -1
        for y in 0..<probe {
            for x in 0..<probe {
                // Apple's cube badge sits in the top right corner (the first rows in memory are the top of the picture).
                if x > probe * 74 / 100, y < probe * 26 / 100 { continue }
                let p = (y * probe + x) * 4
                if pixels[p] < 240 || pixels[p + 1] < 240 || pixels[p + 2] < 240 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX, maxY > minY else { return picture }
        // Back to full-size pixels, top row first.
        let scaleX = CGFloat(width) / CGFloat(probe), scaleY = CGFloat(height) / CGFloat(probe)
        let box = CGRect(x: CGFloat(minX) * scaleX, y: CGFloat(minY) * scaleY,
                         width: CGFloat(maxX - minX + 1) * scaleX, height: CGFloat(maxY - minY + 1) * scaleY)
        let side = max(box.width, box.height) * 1.06
        let crop = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        let out: CGFloat = 480
        let zoom = out / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: out, height: out))
            UIImage(cgImage: cg).draw(in: CGRect(x: -crop.minX * zoom, y: -crop.minY * zoom, width: CGFloat(width) * zoom, height: CGFloat(height) * zoom))
        }
    }
}
