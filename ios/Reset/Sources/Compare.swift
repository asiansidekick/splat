import CoreImage
import SwiftUI
import UIKit
import simd

/// Compares two saved views of a setup, with no camera and no internet: wipe between the photos,
/// and with LiDAR, highlight what moved between them. "Before" is the reference (its closest view
/// to the "after" photo) or an earlier snapshot; "after" is a snapshot.
struct CompareView: View {
    @Environment(\.dismiss) private var dismiss
    let reference: Reference
    @State private var beforeID = CompareView.referenceID
    @State private var afterID: UUID?
    @State private var wipe = 0.5
    @State private var showChanges = true
    @State private var result: Comparison?

    static let referenceID = "reference"

    init(reference: Reference) {
        self.reference = reference
        _afterID = State(initialValue: reference.snapshots.max { $0.taken < $1.taken }?.id)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if reference.snapshots.isEmpty {
                    ContentUnavailableView(
                        "No snapshots yet",
                        systemImage: "camera.on.rectangle",
                        description: Text("On the reset screen, tap Snapshot to save how the set looks, for example just before a take. Then compare it here."))
                } else {
                    pickers
                    if let result {
                        picture(result)
                        Slider(value: $wipe, in: 0...1) {
                            Text("Wipe")
                        } minimumValueLabel: {
                            Text("Before").font(.caption)
                        } maximumValueLabel: {
                            Text("After").font(.caption)
                        }
                        if result.changes != nil {
                            Toggle("Highlight changes", isOn: $showChanges)
                            if showChanges {
                                Text("Red: something is in front of where it was. Blue: something is missing.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(result.note).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxHeight: .infinity)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: "\(beforeID)|\(afterID?.uuidString ?? "")") {
                await update()
            }
        }
    }

    private var pickers: some View {
        HStack {
            Picker("Before", selection: $beforeID) {
                Text("Reference").tag(CompareView.referenceID)
                ForEach(reference.snapshots) { shot in
                    Text(shot.label).tag(shot.id.uuidString)
                }
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("After", selection: $afterID) {
                ForEach(reference.snapshots) { shot in
                    Text(shot.label).tag(Optional(shot.id))
                }
            }
        }
        .pickerStyle(.menu)
    }

    private func picture(_ result: Comparison) -> some View {
        // Photos are stored in the camera's landscape orientation and shown upright, so 3:4.
        let aspect = result.after.size.width / max(result.after.size.height, 1)
        return GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .leading) {
                Image(uiImage: result.after).resizable()
                Image(uiImage: result.before).resizable()
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: size.width * wipe)
                    }
                if showChanges, let changes = result.changes {
                    Image(uiImage: changes).resizable().allowsHitTesting(false)
                }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: size.width * wipe - 1)
                    .shadow(radius: 2)
            }
            .frame(width: size.width, height: size.height)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func update() async {
        guard let afterID, let after = reference.snapshots.first(where: { $0.id == afterID }) else {
            result = nil
            return
        }
        let before = reference.snapshots.first { $0.id.uuidString == beforeID }
        let saved = self.reference
        result = nil
        result = await Task.detached(priority: .userInitiated) {
            Comparison.make(reference: saved, before: before, after: after)
        }.value
    }
}

/// The two photos and the LiDAR difference between them, ready to show upright.
struct Comparison {
    let before: UIImage
    let after: UIImage
    let changes: UIImage?
    let note: String

    static func make(reference: Reference, before: Snapshot?, after: Snapshot) -> Comparison? {
        let folder = ReferenceStore.folder(for: reference.id)
        let afterFrame = after.frame
        let beforeFrames: [Keyframe]
        let note: String
        if let before {
            beforeFrames = [before.frame]
            note = "Comparing \(before.label) with \(after.label)."
        } else {
            // The reference view taken from nearest where the snapshot was taken.
            guard let closest = Guidance.closest(to: afterFrame.cameraToWorld, in: reference.keyframes) else { return nil }
            beforeFrames = [closest] + Guidance.closest(
                to: afterFrame.cameraToWorld, in: reference.keyframes.filter { $0.depthFile != nil && $0.id != closest.id }, count: 2)
            let cm = Int((simd_distance(closest.position, afterFrame.position) * 100).rounded())
            note = cm < 5
                ? "Reference photo taken from the same spot."
                : "Closest reference photo was taken \(cm) cm away, so the photos may not line up exactly. The highlights are worked out in 3D and do line up."
        }
        guard let beforeImage = upright(folder.appendingPathComponent(beforeFrames[0].imageFile)),
            let afterImage = upright(folder.appendingPathComponent(afterFrame.imageFile))
        else { return nil }

        var changes: UIImage?
        if let live = depthView(afterFrame, folder: folder) {
            let refs = beforeFrames.compactMap { depthView($0, folder: folder) }
            if !refs.isEmpty, let mask = DepthDiff.mask(live: live, references: refs),
                let cg = CIContext().createCGImage(mask, from: mask.extent)
            {
                changes = UIImage(cgImage: cg, scale: 1, orientation: .right)
            }
        }
        return Comparison(before: beforeImage, after: afterImage, changes: changes, note: note)
    }

    private static func upright(_ url: URL) -> UIImage? {
        guard let cg = UIImage(contentsOfFile: url.path)?.cgImage else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .right)
    }

    private static func depthView(_ frame: Keyframe, folder: URL) -> DepthView? {
        guard let file = frame.depthFile, let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        let depth = DepthMap.floats(data)
        guard depth.count == frame.depthWidth * frame.depthHeight else { return nil }
        return DepthView(
            depth: depth, width: frame.depthWidth, height: frame.depthHeight,
            cameraToWorld: frame.cameraToWorld, intrinsics: frame.cameraIntrinsics, imageWidth: frame.imageWidth)
    }
}
