import SwiftUI
import UIKit

/// Small always-there cues from the audit of 2026-11-05: things a person would otherwise have to guess.

/// Shows where the ghost strength sits, quietly, once the swipe demonstration has gone. Not a slider
/// (Phil, build 73: no sliders): swiping anywhere still sets it.
struct StrengthIndicator: View {
    /// 0 is all THEN (the ghost), 1 is all NOW (the live camera).
    let value: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left")
            Text("THEN")
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.35)).frame(width: 84, height: 3)
                Circle().fill(Color.white).frame(width: 9, height: 9)
                    .offset(x: CGFloat(min(1, max(0, value))) * 75)
            }
            .frame(width: 84, height: 9)
            Text("NOW")
            Image(systemName: "chevron.right")
        }
        .font(Theme.font(size: 13, weight: .heavy))
        .foregroundStyle(.white.opacity(0.75))
        .shadow(color: .black.opacity(0.8), radius: 2)
        .padding(.bottom, 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .hiddenInScreenshots()
    }
}

/// When Photos access has been refused, a toast cannot fix it: this offers the Settings page directly.
enum SettingsPrompt {
    @MainActor static func photos() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        if top is UIAlertController { return }
        let alert = UIAlertController(
            title: "Photos is switched off for Reset",
            message: "Turn Photos on in Settings to save pictures there.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel))
        top.present(alert, animated: true)
    }
}
