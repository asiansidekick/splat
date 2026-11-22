import QuickLook
import RealityKit
import SwiftUI

/// Scanning an object into a real-size USDZ with Apple's Object Capture (Phil, 2026-11-16: brought into Reset from the
/// separate Scan test app, so it arrives with every build). Full screen with its own camera: Reset's room tracking
/// waits meanwhile. "Place in the room" hands the model back.
struct ObjectScanView: View {
    let onPlace: (URL) -> Void
    /// Phil, 2026-11-22: a mannequin wearing a head just scanned, to stand in the room.
    var onMannequin: ((HeadFolder, MannequinBody, HeadFit) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ScanModel()
    /// "Head" among the scanner's modes (HeadScanScreen.swift). Remembered, like Object and Person.
    @AppStorage("scanHeadMode") private var headMode = false

    static var supported: Bool { ScanModel.supported }

    var body: some View {
        Group {
            if headMode {
                HeadScanScreen(close: { dismiss() }, place: { url in onPlace(url); dismiss() },
                               mannequin: { head, body, fit in onMannequin?(head, body, fit); dismiss() },
                               switchMode: { person in
                                   headMode = false
                                   model.personMode = person
                                   // The head camera lets go first.
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { model.start() }
                               })
            } else {
                ScanScreen(close: { model.close(); dismiss() }, place: { url in model.close(); onPlace(url); dismiss() },
                           chooseHead: {
                               model.close()
                               headMode = true
                           })
                    .environmentObject(model)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if !headMode { model.start() } }
        .onDisappear { model.close() }
    }
}

/// Opens straight into the camera, like the Camera app. One shutter does the next step:
/// box the object, start, finish. Apple's view draws the box, the dial and the points.
struct ScanScreen: View {
    @EnvironmentObject var model: ScanModel
    let close: () -> Void
    let place: (URL) -> Void
    /// "Head" in the modes: the head scanner takes over.
    let chooseHead: () -> Void
    @State private var showLibrary = false
    @State private var preview: URL?
    @State private var trimming: ScanFolder?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = model.session {
                captureView(session)
                    .ignoresSafeArea()
                    .id(ObjectIdentifier(session))
            } else if model.ownCamera {
                CameraView(session: model.own.session).ignoresSafeArea()
            }
            overlay
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(preview: $preview, place: place, trim: { folder in
                // The list closes first; then the trim screen opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { trimming = folder }
            }).environmentObject(model)
        }
        .fullScreenCover(item: $trimming) { folder in
            ScanTrimScreen(folder: folder) { _ in trimming = nil }
        }
        .quickLookPreview($preview)
        .statusBarHidden()
        // The camera restarting puts the torch out, so it is lit again after each step; off when the scanner closes.
        .onChange(of: model.phase) { _ in Torch.shared.applySoon() }
        .onDisappear { Torch.shared.switchOff() }
    }

    /// Area mode has no object to aim at, so Apple's object reticle is hidden (iOS 18+).
    @ViewBuilder private func captureView(_ session: ObjectCaptureSession) -> some View {
        if #available(iOS 18.0, *) {
            ObjectCaptureView(session: session).hideObjectReticle(true)
        } else {
            ObjectCaptureView(session: session)
        }
    }

    @ViewBuilder private var overlay: some View {
        switch model.phase {
        case .building(let fraction):
            building(fraction)
        case .person(let folder):
            person(folder)
        case .cropping(let folder):
            CropScreen(folder: folder)
        case .done(let folder):
            DoneView(folder: folder, preview: $preview, place: place, close: close, trim: { trimming = folder })
        case .unsupported(let text), .failed(let text):
            MessageView(text: text, close: close) { model.start() }
        default:
            captureControls
        }
    }

    private func building(_ fraction: Double) -> BuildingView {
        let skip: (() -> Void)? = model.buildingWords == ScanModel.personWords ? { model.skipPerson() } : nil
        return BuildingView(fraction: fraction, words: model.buildingWords, skip: skip)
    }

    /// "Scan a person": the person's dots, then back to the scan's own done screen (or into the room with the person).
    private func person(_ folder: ScanFolder) -> ScanCharacterScreen {
        ScanCharacterScreen(folder: folder, done: { (made: URL?, placeNow: Bool) in
            if let made, placeNow {
                place(made)
            } else {
                model.phase = .done(folder)
            }
        })
    }

    private var captureControls: some View {
        VStack(spacing: 0) {
            topBar
            TorchDial().padding(.top, 8)
            Spacer()
            if model.phase == .passDone { passChoices }
            if (model.phase == .ready || model.phase == .starting) && model.personMode && personWays.count > 1 { personWayPicker }
            if model.phase == .ready || model.phase == .starting { modePicker }
            Text(stepText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(.bottom, 10)
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button("Done", action: close)
                .font(.body.weight(.semibold))
                .fixedSize()
            if model.phase == .capturing || model.phase == .passDone {
                Text("\(model.shots) / \(model.maxShots)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            // Phil, 2026-11-18: a torch for the 3D scan. Tap for on and off, hold for the brightness.
            TorchButton()
            Spacer()
            Text(model.hint)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)
                .animation(.easeInOut, value: model.hint)
        }
        .foregroundStyle(.white)
        .shadow(radius: 3)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// Like the Camera app's modes: two words above the shutter, the chosen one in yellow.
    private var modePicker: some View {
        HStack(spacing: 22) {
            ForEach([false, true], id: \.self) { person in
                Button(person ? "Person" : "Object") { model.personMode = person }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(model.personMode == person ? Color.yellow : Color.white)
                    .fixedSize()
            }
            // Phil, 2026-11-22: a head on its own, selfie or walking round, to put on any character.
            if PhotogrammetrySession.isSupported {
                Button("Head", action: chooseHead)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .fixedSize()
            }
        }
        .shadow(radius: 3)
        .padding(.bottom, 10)
    }

    private var personWays: [Int] {
        [0] + (OwnCapture.turningSupported ? [1] : []) + (OwnCapture.selfieTurnSupported ? [2] : [])
    }

    /// Phil, 2026-11-22: a person can also turn on the spot in front of the phone standing still.
    private var personWayPicker: some View {
        HStack(spacing: 22) {
            ForEach(personWays, id: \.self) { way in
                Button(["Walk round", "Turn on the spot", "Selfie turn"][way]) { model.personWay = way }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(model.personWay == way ? Color.yellow : Color.white)
                    .fixedSize()
            }
        }
        .shadow(radius: 3)
        .padding(.bottom, 8)
    }

    private var stepText: String {
        switch model.phase {
        case .starting: return "Starting camera…"
        case .ready where model.personMode && model.turningOnSpot:
            return model.own.selfieTurn
                ? "Stand the phone up, screen towards you, whole body in view. Tap, then turn slowly on the spot, arms a little out"
                : "Stand the phone up, whole body in view. Tap, then turn slowly on the spot, arms a little out"
        case .capturing where model.personMode && model.turningOnSpot: return "Small steps, all the way round. It stops by itself"
        case .ready where model.personMode: return "Tap to record, then walk slowly round the person, high and low"
        case .capturing where model.personMode: return "Arms a little out, standing still. Tap to stop"
        case .ready where model.ownCamera: return "Tap to record, then walk slowly round the object"
        case .capturing where model.ownCamera: return "Walk slowly round it, high and low. Tap to stop"
        case .ready: return ScanModel.usesBox ? "Aim at the object, then tap" : "Tap to record, then walk slowly round the object"
        case .detecting: return "Fit the box round the object, then tap to start"
        case .capturing: return "Walk slowly round it, high and low. Tap to stop"
        case .passDone: return "One turn done"
        case .finishing: return "Saving pictures…"
        default: return ""
        }
    }

    private var bottomBar: some View {
        HStack {
            Button { showLibrary = true } label: {
                LibraryThumb(folder: model.library.first)
            }
            .frame(width: 80)
            Spacer()
            Button(action: model.shutter) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    shutterInner
                }
            }
            .disabled(!(model.phase == .ready || model.phase == .detecting || model.phase == .capturing || model.phase == .passDone))
            Spacer()
            Group {
                if model.phase == .detecting {
                    Button("Reset box") { model.resetBox() }
                } else if model.phase == .capturing || model.phase == .passDone {
                    Button("Cancel") { model.cancel() }
                } else {
                    Color.clear
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 80, height: 44)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    @ViewBuilder private var shutterInner: some View {
        switch model.phase {
        case .capturing, .passDone:
            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
        case .detecting:
            Circle().fill(.red).frame(width: 60, height: 60)
        default:
            Circle().fill(.white).frame(width: 60, height: 60)
        }
    }

    /// Apple's advice: three turns (low, middle, high), or flip the object over for its underside.
    private var passChoices: some View {
        VStack(spacing: 10) {
            Text("For a better model, go round again from higher or lower, or turn the object over.")
                .font(.footnote)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                pill("Another turn") { model.anotherPass(flipped: false) }
                pill("Flip it") { model.anotherPass(flipped: true) }
                pill("Finish", strong: true) { model.finish() }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func pill(_ title: String, strong: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(strong ? Color.yellow : Color.white.opacity(0.18), in: Capsule())
            .foregroundStyle(strong ? Color.black : Color.white)
    }
}

struct LibraryThumb: View {
    let folder: ScanFolder?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15))
            if let folder, let image = FirstPicture.load(folder) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "cube").font(.title3).foregroundStyle(.white)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 1.5))
    }
}

enum FirstPicture {
    private static var cache: [URL: UIImage] = [:]

    static func load(_ folder: ScanFolder) -> UIImage? {
        if let hit = cache[folder.url] { return hit }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder.images, includingPropertiesForKeys: nil)) ?? []
        guard let first = files.filter({ ["heic", "jpg"].contains($0.pathExtension.lowercased()) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
              var image = UIImage(contentsOfFile: first.path)?.preparingThumbnail(of: CGSize(width: 160, height: 160)) else { return nil }
        // Reset's own pictures are saved as the camera sees them, on their side: stood up here.
        if first.pathExtension.lowercased() == "jpg", let cg = image.cgImage { image = UIImage(cgImage: cg, scale: 1, orientation: .right) }
        cache[folder.url] = image
        return image
    }
}

struct BuildingView: View {
    let fraction: Double
    var words = "Building the 3D model on the phone"
    var skip: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 6)
                Circle().trim(from: 0, to: max(0.02, fraction))
                    .stroke(.yellow, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: fraction)
                Text("\(Int(fraction * 100))%").font(.title3.monospacedDigit().weight(.semibold))
            }
            .frame(width: 110, height: 110)
            Text(words).font(.headline).multilineTextAlignment(.center)
            Text("Keep the app open. This takes a few minutes.").font(.footnote).foregroundStyle(.secondary)
            if let skip {
                Button("Skip", action: skip).font(.body.weight(.semibold)).foregroundStyle(.yellow).padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

struct DoneView: View {
    @EnvironmentObject var model: ScanModel
    let folder: ScanFolder
    @Binding var preview: URL?
    let place: (URL) -> Void
    let close: () -> Void
    let trim: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Theme.accent)
            Text("Model ready").font(.title2.weight(.semibold))
            Text("Real size. Kept in Files, Reset, Scans.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            Button("Place in the room") { place(folder.model) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
            HStack(spacing: 12) {
                Button("Trim", action: trim).buttonStyle(.bordered)
                Button("View") { preview = folder.model }.buttonStyle(.bordered)
                ShareLink(item: folder.model) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                Button("New scan") { model.start() }.buttonStyle(.bordered)
            }
            Button("Done", action: close).padding(.top, 6)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}

struct MessageView: View {
    let text: String
    let close: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(text).multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("Start again", action: retry).buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
            Button("Done", action: close)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @Binding var preview: URL?
    let place: (URL) -> Void
    let trim: (ScanFolder) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.library) { folder in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            LibraryThumb(folder: folder)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                Text(folder.hasModel ? "Model ready · \(folder.imageCount) pictures" : folder.hasFull ? "Built, not cropped yet" : "\(folder.imageCount) pictures, no model yet")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                            }
                            Spacer(minLength: 0)
                        }
                        // The buttons have a row to themselves, so no word is ever squeezed (Phil, 2026-11-17).
                        HStack(spacing: 8) {
                            if folder.hasModel {
                                Button("Place") { dismiss(); place(folder.model) }
                                Button("Trim") { dismiss(); trim(folder) }
                                Button("View") { dismiss(); preview = folder.model }
                                ShareLink(item: folder.model) { Image(systemName: "square.and.arrow.up") }
                            } else if !folder.hasFull && folder.imageCount >= 10 {
                                Button("Build") { dismiss(); model.build(folder) }
                            }
                            if folder.hasFull, folder.cameras == nil {
                                Button("Crop") { dismiss(); model.openCrop(folder) }
                            }
                        }
                        .buttonStyle(.bordered)
                        .lineLimit(1)
                        .fixedSize()
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { model.delete(folder) }
                    }
                }
            }
            .overlay {
                if model.library.isEmpty { Text("No scans yet").foregroundStyle(.secondary) }
            }
            .navigationTitle("Scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
