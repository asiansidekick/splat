import Photos
import SwiftUI
import UIKit

/// Phil, 2026-11-09: an editor "kinda like Photoshop for selecting parts of images". Select with Tap subject, Loop,
/// Magic select, Add and Remove brushes, Invert and Soften edge; then make a cut-out (saved to the cut-out menu),
/// show only the selection in the overlay, save it as a new reference, or save it to Photos with a clear background.
struct EditTarget: Identifiable {
    let id = UUID()
    let photo: UIImage
    /// The reference the photo came from, if any.
    var reference: Reference?
}

struct PhotoEditorSheet: View {
    let target: EditTarget
    /// Scene and take for a new reference made here, when the photo has no reference of its own.
    var scene = "1"
    var setup = "1"
    var onNewReference: (Reference) -> Void = { _ in }
    var onMaskChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = MaskCanvasHolder()
    @State private var tool: MaskTool = .pick
    @State private var parts: [CGImage] = []
    @State private var finding = true
    @State private var photo: UIImage?
    @State private var blank: CGImage?
    @State private var message: String?
    @State private var naming = false
    @State private var cutoutName = ""
    @State private var cutoutHeight = "170"
    @State private var busy = false

    private var help: String {
        switch tool {
        case .pick: return finding ? "Looking for people and things…" : (parts.isEmpty ? "Nothing found to tap. Try Loop or Magic." : "Tap a person or thing to select it. Tap again to drop it.")
        case .loop: return "Draw round what you want."
        case .magic: return "Tap a colour: everything joined to it in that colour is selected."
        case .keep: return "Paint to add to the selection."
        case .erase: return "Paint to take away from the selection."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // Phil, 2026-11-09: "Back" with the usual iPhone arrow, not Cancel; nothing here needs undoing on the way out.
                Button { dismiss() } label: { Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon) }
                Spacer()
                Text("Edit").font(Theme.headline)
                Spacer()
                Menu {
                    Button { naming = true } label: { Label("Make a cut-out", systemImage: "figure.stand") }
                    if target.reference?.photoOnly == true {
                        Button { showOnlyInOverlay() } label: { Label("Show only this in the overlay", systemImage: "square.on.square") }
                    }
                    Button { saveAsReference() } label: { Label("Save as a new reference", systemImage: "square.3.layers.3d") }
                    Button { saveToPhotos() } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                } label: {
                    Text("Use selection").fontWeight(.bold)
                }
                .tint(Theme.accent)
                .disabled(busy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ZStack(alignment: .top) {
                if let photo, let blank {
                    MaskCanvasView(photo: photo, mask: blank, parts: parts, tool: tool, holder: holder)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(message ?? help)
                    .font(Theme.caption)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    choice("Tap subject", "hand.tap", .pick)
                    choice("Loop", "lasso", .loop)
                    choice("Magic", "wand.and.stars", .magic)
                    choice("Add", "paintbrush.pointed.fill", .keep)
                    choice("Remove", "eraser.fill", .erase)
                }
                HStack(spacing: 10) {
                    Button { holder.canvas?.invert() } label: { Label("Invert", systemImage: "circle.lefthalf.filled") }
                    Button { holder.canvas?.soften() } label: { Label("Soften edge", systemImage: "aqi.medium") }
                    Button { holder.canvas?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!holder.canUndo)
                }
            }
            .buttonStyle(.bordered)
            .font(Theme.footnote)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await prepare() }
        .alert("Make a cut-out", isPresented: $naming) {
            TextField("Name, for example Bob", text: $cutoutName)
            TextField("Real height in cm", text: $cutoutHeight).keyboardType(.decimalPad)
            Button("Save") { makeCutout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes into your saved cut-outs, ready to stand in any reference.")
        }
    }

    private func choice(_ word: String, _ symbol: String, _ value: MaskTool) -> some View {
        Button { tool = value } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                Text(word).fixedSize()
            }
            .fontWeight(tool == value ? .bold : .regular)
            .frame(minWidth: 52)
        }
        .tint(tool == value ? Theme.accent : .gray)
    }

    private func prepare() async {
        guard photo == nil, let editable = GhostMask.editable(target.photo), let cg = editable.cgImage else { return }
        blank = MaskCanvas.empty(width: cg.width, height: cg.height)
        photo = editable
        Diagnostics.log("Edit window opened")
        parts = await Task.detached(priority: .userInitiated) { CutoutLift.parts(of: cg) }.value
        finding = false
        if parts.isEmpty, tool == .pick { tool = .loop }
    }

    /// The selection, or nil (with a note) when nothing is selected.
    private func selection() -> (photo: CGImage, mask: CGImage)? {
        guard let cg = photo?.cgImage, let mask = holder.canvas?.paintedMask, CutoutMask.compose(cg, mask: mask) != nil else {
            message = "Select something first."
            return nil
        }
        return (cg, mask)
    }

    private func makeCutout() {
        guard let picked = selection(), let made = CutoutMask.compose(picked.photo, mask: picked.mask) else { return }
        let height = (Float(cutoutHeight.replacingOccurrences(of: ",", with: ".")) ?? 170) / 100
        let name = cutoutName.trimmingCharacters(in: .whitespaces)
        let package = CutoutPackage(name: name.isEmpty ? "Cut-out" : name, height: min(max(height, 0.02), 5),
                                    views: [CutoutPackage.View(angle: 0, png: made.png, aspect: made.aspect)])
        CutoutLibrary.save(package)
        Haptics.success()
        Diagnostics.log("Edit: cut-out saved to the library")
        message = "Saved to your cut-outs. Stand it from the cut-out menu."
    }

    private func showOnlyInOverlay() {
        guard let reference = target.reference, let picked = selection() else { return }
        _ = GhostMask.save(picked.mask, reference: reference.id)
        onMaskChanged()
        Haptics.success()
        dismiss()
    }

    private func saveAsReference() {
        guard let picked = selection(), let jpeg = UIImage(cgImage: picked.photo).jpegData(compressionQuality: 0.9) else { return }
        do {
            var reference = try PhotoLibrary.makeReference(from: jpeg, scene: target.reference?.scene ?? scene,
                                                           setup: target.reference?.setup ?? setup)
            reference.name = "Selection"
            if let shot = target.reference?.shot { reference.shot = shot }
            try ReferenceStore.save(reference)
            _ = GhostMask.save(picked.mask, reference: reference.id)
            onNewReference(reference)
            Haptics.success()
            Diagnostics.log("Edit: selection saved as a new reference")
            message = "Saved as a new reference. Add it as a layer, or load it as the overlay."
        } catch {
            message = "Couldn't save the reference."
        }
    }

    private func saveToPhotos() {
        guard let picked = selection(), let made = CutoutMask.compose(picked.photo, mask: picked.mask) else { return }
        busy = true
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            var saved = false
            if status == .authorized || status == .limited {
                saved = (try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: made.png, options: nil)
                }) != nil
            }
            busy = false
            message = saved ? "Saved to Photos with a clear background." : "Couldn't save to Photos. Allow Photos for Reset in Settings."
        }
    }
}
