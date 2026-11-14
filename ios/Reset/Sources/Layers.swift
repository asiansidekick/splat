import SwiftUI
import UIKit

/// Phil, 2026-11-09: several references over the camera at once. Each layer is another reference's photo laid flat
/// over the picture, with its own strength, switched on and off by tapping its chip; hold the chip for strength and
/// Remove. Kept per reference on this phone.
struct OverlayLayer: Codable, Identifiable, Equatable {
    var id: UUID { reference }
    var reference: UUID
    var strength: Double = 0.5
    var shown = true

    static func load(for id: UUID) -> [OverlayLayer] {
        guard let data = UserDefaults.standard.data(forKey: "layers.\(id.uuidString)"),
              let layers = try? JSONDecoder().decode([OverlayLayer].self, from: data) else { return [] }
        return layers
    }

    static func save(_ layers: [OverlayLayer], for id: UUID) {
        if let data = try? JSONEncoder().encode(layers) { UserDefaults.standard.set(data, forKey: "layers.\(id.uuidString)") }
    }

    /// The reference's first photo, upright, and its painted mask if it has one.
    static func picture(of reference: Reference) -> (photo: UIImage, mask: UIImage?)? {
        guard let first = reference.keyframes.first else { return nil }
        let url = ReferenceStore.folder(for: reference.id).appendingPathComponent(first.imageFile)
        guard let cg = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        return (UIImage(cgImage: cg, scale: 1, orientation: first.uprightOrientation), GhostMask.load(reference.id))
    }
}

/// The layers' pictures, drawn flat over the camera at their strengths.
struct LayerPictures: View {
    let layers: [OverlayLayer]
    let pictures: [UUID: (photo: UIImage, mask: UIImage?)]
    let size: CGSize

    var body: some View {
        ZStack {
            ForEach(layers.filter(\.shown)) { layer in
                if let picture = pictures[layer.reference] {
                    Image(uiImage: picture.photo)
                        .resizable()
                        .mask { if let mask = picture.mask { Image(uiImage: mask).resizable() } else { Color.white } }
                        .aspectRatio(picture.photo.size, contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .opacity(layer.strength)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// One chip per layer down the right edge: tap to show or hide, hold for strength and Remove.
struct LayerChips: View {
    @Binding var layers: [OverlayLayer]
    let references: [Reference]
    @ObservedObject var thumbnails: Thumbnails

    var body: some View {
        VStack(spacing: 10) {
            ForEach($layers) { $layer in
                let reference = references.first { $0.id == layer.reference }
                Button {
                    TapGate.run("Layer \(layer.id)") {
                        layer.shown.toggle()
                        Haptics.tap()
                    }
                } label: {
                    VStack(spacing: 2) {
                        ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 40)
                            .opacity(layer.shown ? 1 : 0.35)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(layer.shown ? Theme.accent : .clear, lineWidth: 2))
                        Text(layer.shown ? "\(Int((layer.strength * 100).rounded()))%" : "Off")
                            .font(Theme.font(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                            .fixedSize()
                    }
                }
                .buttonStyle(PressScale())
                .caughtTap("Layer \(layer.id)") {
                    layer.shown.toggle()
                    Haptics.tap()
                }
                .contextMenu {
                    Text(reference.map { $0.slate.isEmpty ? "Layer" : $0.slate } ?? "Layer")
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { value in
                        Button {
                            layer.strength = value
                            layer.shown = true
                        } label: { Label("\(Int(value * 100))% strength", systemImage: layer.strength == value ? "checkmark" : "circle.lefthalf.filled") }
                    }
                    Button(role: .destructive) {
                        layers.removeAll { $0.reference == layer.reference }
                    } label: { Label("Remove layer", systemImage: "trash") }
                }
            }
        }
    }
}

/// Pick another reference to lay over this one.
struct LayerPicker: View {
    let references: [Reference]
    @ObservedObject var thumbnails: Thumbnails
    let pick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 14) {
                    ForEach(references) { reference in
                        Button {
                            pick(reference.id)
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                ReferenceThumbnail(reference: reference, thumbnails: thumbnails, size: 96)
                                Text(reference.slate.isEmpty ? "Reference" : reference.slate)
                                    .font(Theme.footnote)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }
                        .buttonStyle(PressScale())
                    }
                }
                .padding(16)
            }
            .navigationTitle("Add a layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
