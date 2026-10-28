import SwiftUI

/// First-run guide and feedback: how to use Reset, and a way to send the diagnostics log.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("saveToPhotos") private var saveToPhotos = true

    var body: some View {
        NavigationStack {
            List {
                Section("Recording a reference") {
                    step("camera.circle", "The app opens on the camera. In Reference mode, point at the props and tap the shutter: that saves a reference for the setup shown at the top (tap it to change scene or setup).")
                    step("figure.walk", "For a fuller reference, swipe the modes to Walk around, tap record, walk slowly round the props and tap stop.")
                    step("cube", "Mock up the set: tap 3D models and pick one or more USDZ files. They appear at real size where the camera points. Drag to move, pinch to scale (the size shows as you pinch), twist to turn. Photo mode takes a picture with them in, ready to share.")
                    step("hourglass", "If the room is not mapped yet, it saves by itself as soon as it is. Move the phone gently side to side.")
                }
                Section("Between takes") {
                    step("photo.on.rectangle", "Tap the thumbnail bottom left. Swipe to the setup you want and tap Load. The grid button shows them all by scene.")
                    step("circle.lefthalf.filled", "Line the props up with the see-through ghost. Put the yellow ring on the cross with its ticks level, then step forward or back as the arrows round the cross show (in: forward, out: back) to stand where a photo was taken; the guide fades away once lined up, or swipe the modes to 3D ghost to check from anywhere.")
                    step("square.fill", "With LiDAR, red marks something in front of where it was, blue where something is missing.")
                    step("checkmark.circle", "Log logs the take in one tap. Press and hold it to add a note. The shutter saves a snapshot to compare later.")
                    step("xmark", "The cross at the top goes back to recording.")
                }
                Section("Photos") {
                    Toggle("Save shutter photos to Photos", isOn: $saveToPhotos)
                    step("square.and.arrow.down", "To use photos as ghosts, open the gallery and tap the import arrow. Pick as many as you like; each becomes its own reference.")
                    step("photo.on.rectangle.angled", "Press and hold a reference in the gallery and choose Save photos to Photos.")
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
