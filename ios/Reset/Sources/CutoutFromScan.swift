import simd
import SwiftUI
import UIKit

/// Picks, from a scan of a prop or a person, the frames that see it from different sides, with the side
/// each one shows. Kept free of the camera and the views so it can be reasoned about on its own.
enum ScanViews {
    /// The point the scan's cameras look at: the spot nearest to every camera's line of sight.
    static func subject(of frames: [Keyframe]) -> SIMD3<Float>? {
        guard frames.count >= 2 else { return nil }
        var a = simd_float3x3(0)
        var b = SIMD3<Float>.zero
        for frame in frames {
            let d = simd_normalize(frame.forward)
            let p = frame.position
            // (I - d dᵀ): the part of a offset that is sideways to the view line.
            let side = matrix_identity_float3x3 - simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
            a += side
            b += side * p
        }
        guard abs(simd_determinant(a)) > 1e-4 else { return nil }
        let point = a.inverse * b
        return point.x.isFinite && point.y.isFinite && point.z.isFinite ? point : nil
    }

    /// Up to sixteen frames round the subject, one every 22.5 degrees where the walk-round has one, with the angle each
    /// shows (0 front, 90 its left, 180 back, -90 its right). The first frame is the front. Phil, 2026-11-09: more
    /// photos, so the cut-out turns more smoothly as you walk round it.
    static func pick(from frames: [Keyframe], within tolerance: Float = 28) -> [(frame: Keyframe, angle: Float)] {
        guard let first = frames.first else { return [] }
        guard let centre = subject(of: frames) else { return [(frame: first, angle: Float(0))] }
        let toFirst = SIMD3<Float>(first.position.x - centre.x, 0, first.position.z - centre.z)
        guard simd_length(toFirst) > 0.2 else { return [(frame: first, angle: Float(0))] }
        let front = simd_normalize(toFirst)
        let angles = frames.map { Cutout.viewAngle(camera: $0.position, position: centre, front: front) }
        var chosen: [(frame: Keyframe, angle: Float)] = []
        var used = Set<Int>()
        let main: [Float] = [0, 90, 180, -90, 45, -45, 135, -135]
        let between: [Float] = [22.5, -22.5, 67.5, -67.5, 112.5, -112.5, 157.5, -157.5]
        for want in main + between {
            // The in-between sides only take a frame close to them, so they never steal one a main side needs.
            let allowed = main.contains(want) ? tolerance : min(tolerance, 10)
            let best = frames.indices.filter { !used.contains($0) && Cutout.gap(angles[$0], want) <= allowed }
                .min { Cutout.gap(angles[$0], want) < Cutout.gap(angles[$1], want) }
            guard let index = best else { continue }
            used.insert(index)
            chosen.append((frames[index], want))
        }
        return chosen.isEmpty ? [(frame: first, angle: Float(0))] : chosen
    }
}

/// Makes a cut-out from the frames of a reference scan, and keeps it in the cut-out library.
struct CutoutFromScan: View {
    let reference: Reference
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id = UUID()
        let preview: UIImage
        let png: Data
        let aspect: Float
        let angle: Float
    }

    @State private var items: [Item] = []
    @State private var working = true
    @State private var tried = 0
    @State private var name = ""
    @State private var heightText = "170"
    @State private var saved = false

    private var heightMetres: Float? {
        guard let value = Float(heightText.replacingOccurrences(of: ",", with: ".")), value >= 2, value <= 500 else { return nil }
        return value / 100
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if working {
                        HStack { ProgressView(); Text("Cutting out the subject from \(tried) frames…").foregroundStyle(.secondary) }
                    } else if items.isEmpty {
                        Text("Nothing could be lifted out of these frames. A scan that walks round one clear subject works best.")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("The subject is lifted out of the frames that see it from different sides, the way touching and holding a subject in Photos does.")
                }
                if !items.isEmpty {
                    Section("Views found") {
                        ForEach(items) { item in
                            HStack(spacing: 12) {
                                Image(uiImage: item.preview)
                                    .resizable().scaledToFit()
                                    .frame(width: 64, height: 84)
                                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                Text(Self.sideName(item.angle)).font(Theme.headline)
                            }
                        }
                    }
                    Section("The cut-out") {
                        LabeledContent("Name") {
                            TextField(reference.title.isEmpty ? "Optional" : reference.title, text: $name).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Real height (cm)") {
                            TextField("170", text: $heightText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    }
                    Section {
                        Button { save() } label: { Label(saved ? "Saved" : "Save to cut-outs", systemImage: "square.and.arrow.down") }
                            .disabled(heightMetres == nil || saved)
                            .tint(Theme.accent)
                    } footer: {
                        Text("Then use Add to the room, Cut-out from photos, and pick it from Saved cut-outs.")
                    }
                }
            }
            .navigationTitle("Cut-out from scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(saved ? "Done" : "Cancel") { dismiss() } } }
            .task { await build() }
        }
        .preferredColorScheme(.dark)
    }

    static func sideName(_ angle: Float) -> String {
        if angle.truncatingRemainder(dividingBy: 45) != 0 {
            // An in-between side: name the two it sits between.
            let lower = (angle / 45).rounded(.down) * 45
            return "Between \(sideName(lower).lowercased()) and \(sideName(lower + 45 > 180 ? -135 : lower + 45).lowercased())"
        }
        switch angle {
        case 0: return "Front"
        case 45: return "Front left"
        case 90: return "Left side"
        case 135: return "Back left"
        case 180, -180: return "Back"
        case -135: return "Back right"
        case -90: return "Right side"
        default: return "Front right"
        }
    }

    private func build() async {
        let picks = ScanViews.pick(from: reference.keyframes)
        tried = picks.count
        let folder = ReferenceStore.folder(for: reference.id)
        var found: [Item] = []
        for pick in picks {
            let path = folder.appendingPathComponent(pick.frame.imageFile).path
            let orientation = pick.frame.uprightOrientation
            let result = await Task.detached(priority: .userInitiated) { () -> CutoutLift.Lifted? in
                guard let cg = UIImage(contentsOfFile: path)?.cgImage else { return nil }
                // A little smaller than a hand-made cut-out's photos: there can be twice as many.
                return CutoutLift.lift(UIImage(cgImage: cg, scale: 1, orientation: orientation), longSide: 900)
            }.value
            // A frame with no clear subject would stand the whole room up as the cut-out: leave it out.
            if let result, !result.whole { found.append(Item(preview: result.preview, png: result.png, aspect: result.aspect, angle: pick.angle)) }
        }
        items = found
        working = false
    }

    private func save() {
        guard let height = heightMetres, !items.isEmpty else { return }
        let label = name.trimmingCharacters(in: .whitespaces)
        let package = CutoutPackage(
            name: label.isEmpty ? (reference.title.isEmpty ? "Cut-out" : reference.title) : label,
            height: height,
            views: items.map { CutoutPackage.View(angle: $0.angle, png: $0.png, aspect: $0.aspect) })
        CutoutLibrary.save(package)
        Haptics.success()
        saved = true
    }
}
