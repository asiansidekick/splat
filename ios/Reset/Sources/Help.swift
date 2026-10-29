import SwiftUI

/// First-run guide and feedback: how to use Reset, and a way to send the diagnostics log.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("saveToPhotos") private var saveToPhotos = true

    var body: some View {
        NavigationStack {
            List {
                Section("Recording a reference") {
                    step("camera.circle", "The app opens on the camera. In Quick Scan mode, point at the props and tap the shutter: that saves a reference for the setup shown at the top (tap it to change scene or setup).")
                    step("figure.walk", "For a fuller reference, swipe the modes to Walk around, tap record, walk slowly round the props and tap stop.")
                    step("cube", "Mock up the set: tap 3D models and pick one or more USDZ files. They appear at real size where the camera points. Drag to move, pinch to scale (the size shows as you pinch), twist to turn. Photo mode takes a picture with them in, ready to share.")
                    step("hourglass", "If the room is not mapped yet, it saves by itself as soon as it is. Move the phone gently side to side.")
                }
                Section("Between takes") {
                    step("photo.on.rectangle", "Tap the Reference thumbnail bottom left. Swipe to the setup you want and tap Load. The grid button shows them all by scene.")
                    step("circle.lefthalf.filled", "Line the props up with the see-through ghost using the two balls. Once you are close, the ghost photo snaps onto the live view (stretched to fit), so everything still in place lies exactly on top and anything that has moved shows double: a see-through one rides in front of the phone, and a solid one just like it hangs where the reference camera was looking. Move and turn until they become one ball, with both dividing lines level. The phone's ball tips to show tilt: more yellow showing means tilt up, more dark means tilt down. A yellow arrow at the edge points the way when the sphere is off screen. Once lined up, hold still for half a second until the banner turns green: a wobble passing through the right spot does not count. The spheres fade once lined up,.")
                    if Restorer.offers3D {
                        step("cube.transparent", "3D ghost (LiDAR references): walk round the set from any side. The reference shows as dots in the props' own colours where they were, with the set visible between them. Blue dots mark something that has gone from that spot: put it back until the blue goes. Changes at the top adds LiDAR change colours to the photo ghost.")
                    }
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
