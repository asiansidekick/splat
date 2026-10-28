import SwiftUI

/// First-run guide and feedback: how to use Reset, and a way to send the diagnostics log.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Recording a reference") {
                    step("camera.circle", "The app opens on the camera. Point at the props and tap the shutter: that saves a reference for the setup shown at the top (tap it to change scene or setup).")
                    step("figure.walk", "For a fuller reference, swipe the modes to Walk around, tap record, walk slowly round the props and tap stop.")
                    step("hourglass", "If the room is not mapped yet, it saves by itself as soon as it is. Move the phone gently side to side.")
                }
                Section("Between takes") {
                    step("photo.on.rectangle", "Tap the thumbnail bottom left. Swipe to the setup you want and tap Load. The grid button shows them all by scene.")
                    step("circle.lefthalf.filled", "Line the props up with the see-through ghost. Follow the directions to stand where a photo was taken, or swipe the modes to 3D ghost to check from anywhere.")
                    step("square.fill", "With LiDAR, red marks something in front of where it was, blue where something is missing.")
                    step("checkmark.circle", "Log logs the take in one tap. Press and hold it to add a note. The shutter saves a snapshot to compare later.")
                    step("xmark", "The cross at the top goes back to recording.")
                }
                Section("Your work") {
                    step("lock", "Everything stays on this device and works with no signal. References are also in the Files app, On My iPhone, Reset.")
                    step("square.and.arrow.up", "Press and hold a reference in the gallery for its take log and PDF report.")
                }
                Section {
                    ShareLink(item: Diagnostics.reportURL()) {
                        Label("Send feedback log", systemImage: "ladybug")
                    }
                } header: {
                    Text("Testing")
                } footer: {
                    Text("Sends a record of what the app did on this device (no photos), to help fix problems. Add screenshots in the same message.\n\n\(HelpView.buildLabel)")
                }
            }
            .navigationTitle("How Reset works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Matches the number in the downloaded file's name, Reset-build-N.ipa.
    static let buildLabel: String = {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Reset build \(build)"
    }()

    private func step(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }
}
