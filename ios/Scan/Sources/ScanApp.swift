import QuickLook
import RealityKit
import SwiftUI

@main
struct ScanApp: App {
    @StateObject private var model = ScanModel()

    var body: some SwiftUI.Scene {
        WindowGroup {
            ScanScreen()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    ScanLog.add("Launch: Scan \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    model.start()
                }
        }
    }
}

/// Opens straight into the camera, like the Camera app. One shutter does the next step:
/// box the object, start, finish. Apple's view draws the box, the dial and the points.
struct ScanScreen: View {
    @EnvironmentObject var model: ScanModel
    @State private var showLibrary = false
    @State private var preview: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = model.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
                    .id(ObjectIdentifier(session))
            }
            overlay
        }
        .sheet(isPresented: $showLibrary) {
            LibraryView(preview: $preview).environmentObject(model)
        }
        .quickLookPreview($preview)
        .statusBarHidden()
    }

    @ViewBuilder private var overlay: some View {
        switch model.phase {
        case .building(let fraction):
            BuildingView(fraction: fraction)
        case .cropping(let folder):
            CropScreen(folder: folder)
        case .done(let folder):
            DoneView(folder: folder, preview: $preview)
        case .unsupported(let text), .failed(let text):
            MessageView(text: text) { model.start() }
        default:
            captureControls
        }
    }

    private var captureControls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if model.phase == .passDone { passChoices }
            Text(stepText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
                .padding(.bottom, 10)
            bottomBar
        }
    }

    private var topBar: some View {
        HStack {
            if model.phase == .capturing || model.phase == .passDone {
                Text("\(model.shots) / \(model.maxShots)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
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

    private var stepText: String {
        switch model.phase {
        case .starting: return "Starting camera…"
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
        guard let first = files.filter({ $0.pathExtension.lowercased() == "heic" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
              let image = UIImage(contentsOfFile: first.path)?.preparingThumbnail(of: CGSize(width: 160, height: 160)) else { return nil }
        cache[folder.url] = image
        return image
    }
}

struct BuildingView: View {
    let fraction: Double

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
            Text("Building the 3D model on the phone").font(.headline)
            Text("Keep the app open. This takes a few minutes.").font(.footnote).foregroundStyle(.secondary)
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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.yellow)
            Text("Model ready").font(.title2.weight(.semibold))
            Text("\(folder.name).usdz, real size. Open it in Reset with 3D models, or from Files.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 30)
            HStack(spacing: 12) {
                Button("View") { preview = folder.model }
                    .buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                ShareLink(item: folder.model) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                Button("New scan") { model.start() }.buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onAppear { preview = folder.model }
    }
}

struct MessageView: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(text).multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("Start again", action: retry).buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
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

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.library) { folder in
                    HStack(spacing: 12) {
                        LibraryThumb(folder: folder)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.name).font(.subheadline.weight(.semibold))
                            Text(folder.hasModel ? "Model ready · \(folder.imageCount) pictures" : folder.hasFull ? "Built, not cropped yet" : "\(folder.imageCount) pictures, no model yet")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if folder.hasFull {
                            Button { dismiss(); model.openCrop(folder) } label: { Image(systemName: "crop") }
                                .buttonStyle(.bordered)
                        }
                        if folder.hasModel {
                            Button("View") { dismiss(); preview = folder.model }.buttonStyle(.bordered)
                            ShareLink(item: folder.model) { Image(systemName: "square.and.arrow.up") }
                                .buttonStyle(.bordered)
                        } else if !folder.hasFull && folder.imageCount >= 10 {
                            Button("Build") { dismiss(); model.build(folder) }.buttonStyle(.bordered)
                        }
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
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: ScanLog.url) { Text("Log") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
