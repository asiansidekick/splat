import ARKit
import AVFoundation
import SwiftUI

/// The phone's torch, usable while the AR camera runs (Phil, 2026-10-30). The LiDAR uses its own
/// infrared light, so the torch doesn't upset the depth; it does change how the set looks, so the
/// level is saved with each reference and turned back on when checking it.
@MainActor
final class Torch: ObservableObject {
    static let shared = Torch()

    @Published private(set) var on = false
    /// 0.05 to 1, as the dial sets it; remembered between launches.
    @Published private(set) var level: Float = UserDefaults.standard.object(forKey: "torchLevel") as? Float ?? 0.6
    /// Shown while the brightness is being set, then tucked away.
    @Published private(set) var dialShown = false
    private var hideTask: Task<Void, Never>?

    private init() {
        // iOS puts the torch out when the app goes to the background.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Torch.shared.on = false }
        }
    }

    /// After the AR camera (re)starts, which puts the torch out.
    func applySoon() {
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            apply()
        }
    }

    /// The camera ARKit is using (iOS 16 and later), which owns the torch.
    private var device: AVCaptureDevice? {
        ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
    }

    var available: Bool { device?.hasTorch == true }

    /// The level to save with a reference: nil when the torch is off.
    var savedLevel: Float? { on ? level : nil }

    func toggle() {
        set(on: !on)
        if on { showDial() }
    }

    func set(on: Bool, level: Float? = nil) {
        if let level { setLevel(level, apply: false) }
        self.on = on
        apply()
    }

    func setLevel(_ value: Float, apply now: Bool = true) {
        level = min(max(value, 0.05), 1)
        UserDefaults.standard.set(level, forKey: "torchLevel")
        if now && on { apply() }
        if now { showDial() }
    }

    func showDial() {
        dialShown = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { dialShown = false }
        }
    }

    /// Sets the torch on the camera. Running the AR session again turns the torch off, so the
    /// screens call this again once the camera is going.
    func apply() {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if on {
                try device.setTorchModeOn(level: min(level, AVCaptureDevice.maxAvailableTorchLevel))
            } else if device.torchMode != .off {
                device.torchMode = .off
            }
        } catch {
            Diagnostics.log("Torch failed: \(error.localizedDescription)")
        }
    }

    /// Off when leaving the camera, without forgetting the level.
    func switchOff() {
        guard on else { return }
        on = false
        apply()
    }
}

/// The top-bar torch: tap for on and off; press and hold for the brightness dial.
struct TorchButton: View {
    @ObservedObject var torch = Torch.shared

    var body: some View {
        if torch.available {
            Image(systemName: torch.on ? "flashlight.on.fill" : "flashlight.off.fill")
                .font(.title3)
                .foregroundStyle(torch.on ? Color.yellow : Color.white)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.tap()
                    torch.toggle()
                }
                .onLongPressGesture {
                    Haptics.tap()
                    if !torch.on { torch.set(on: true) }
                    torch.showDial()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(torch.on ? "Torch off" : "Torch on")
        }
    }
}

/// A scroll wheel for the torch's brightness, like the Camera app's zoom dial: drag the ticks
/// left or right. Shows while the torch is being set and tucks away after a moment.
struct TorchDial: View {
    @ObservedObject var torch = Torch.shared
    @State private var startLevel: Float?
    private let width: CGFloat = 240
    /// A full drag across the dial goes from dim to full.
    private let span: CGFloat = 240

    var body: some View {
        if torch.dialShown && torch.on {
            VStack(spacing: 4) {
                Text("Torch \(Int((torch.level * 100).rounded()))%")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.yellow)
                ZStack {
                    // Ticks slide with the level; the yellow mark in the middle stays put.
                    HStack(spacing: 8) {
                        ForEach(0..<61) { i in
                            Rectangle()
                                .fill(Color.white.opacity(i % 5 == 0 ? 0.9 : 0.45))
                                .frame(width: 1.5, height: i % 5 == 0 ? 16 : 9)
                        }
                    }
                    .offset(x: CGFloat(0.5 - torch.level) * span)
                    .frame(width: width, height: 30)
                    .clipped()
                    Rectangle().fill(Color.yellow).frame(width: 3, height: 24)
                }
                .frame(width: width, height: 30)
                .background(Color.black.opacity(0.45), in: Capsule())
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let start = startLevel ?? torch.level
                            startLevel = start
                            // Dragging the ticks left brings the brighter end to the middle.
                            torch.setLevel(start - Float(drag.translation.width / span))
                        }
                        .onEnded { _ in startLevel = nil })
            }
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Torch brightness")
            .accessibilityValue("\(Int((torch.level * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: torch.setLevel(torch.level + 0.1)
                case .decrement: torch.setLevel(torch.level - 0.1)
                @unknown default: break
                }
            }
        }
    }
}
