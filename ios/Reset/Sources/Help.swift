import SwiftUI

/// First-run guide and feedback: how to use Reset, and a way to send the diagnostics log.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Before the first take") {
                    step("plus", "Tap + to record a reference for the setup. Scene and setup letter are filled in for you.")
                    step("figure.walk", "Walk around: move slowly round the props, pointing at them from a few angles. Or pick Quick snapshot, sway the phone for a couple of seconds and tap the shutter.")
                    step("checkmark.circle", "Save when the status says Mapped or Ready to save.")
                }
                Section("Between takes") {
                    step("arrow.uturn.backward", "Open the reference. Start where it was recorded so it can find the room; the first photo is shown to help.")
                    step("circle.lefthalf.filled", "Line the props up with the see-through ghost. Follow the directions to stand where a photo was taken, or switch to the 3D ghost (open the controls with the arrow) to check from anywhere.")
                    step("square.fill", "With LiDAR, red marks something in front of where it was, blue where something is missing.")
                    step("camera", "Camera saves a snapshot to compare later. Log records the take with notes.")
                }
                Section("Your work") {
                    step("lock", "Everything stays on this device and works with no signal. References are also in the Files app, On My iPhone, Reset.")
                    step("square.and.arrow.up", "Take log, Share sends a PDF or text take report.")
                }
                Section {
                    ShareLink(item: Diagnostics.reportURL()) {
                        Label("Send feedback log", systemImage: "ladybug")
                    }
                } header: {
                    Text("Testing")
                } footer: {
                    Text("Sends a record of what the app did on this device (no photos), to help fix problems. Add screenshots in the same message.")
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

    private func step(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }
}
