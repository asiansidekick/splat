import SwiftUI

/// First-run guide and feedback: how to use Reset, and a way to send the diagnostics log.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("saveToPhotos") private var saveToPhotos = true
    @AppStorage("leftHanded") private var leftHanded = false

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
                    step("viewfinder", "Line the props up with the see-through ghost using the edge guides: a white stroke on each edge of the picture shows how far the ghost is off what the camera sees, beside a fixed hollow slot. Move the way the strokes are off until each sits in its slot; STEP IN or STEP BACK shows when you need to get closer or further away. Each one turns green with a tap as it seats; with all four in, the border and the shutter ring go green. A yellow arrow at the edge points the way when the reference is off screen.")
                    step("photo", "Tap the reference thumbnail at the top to hide or show the ghost. Press and hold it for all the references. Swipe left (THEN) or right (NOW) anywhere on the picture to fade the ghost (with 3D models placed, swipes move the models instead).")
                    step("pause.circle", "Pause (or a volume button) freezes the picture with the reference ghost over it. Swipe left (THEN) or right (NOW) anywhere to fade between the reference and now; tap to jump to the other end. Fade at the top switches to a wipe, with the reference left of the line. Play goes back to live. Left-handed controls in the ••• menu swap Pause and Log.")
                    if Restorer.offers3D {
                        step("cube.transparent", "3D ghost (LiDAR references): walk round the set from any side. The reference shows as dots in the props' own colours where they were, with the set visible between them. Blue dots mark something that has gone from that spot: put it back until the blue goes. Changes at the top adds LiDAR change colours to the photo ghost.")
                    }
                    step("square.fill", "With LiDAR, red marks something in front of where it was, blue where something is missing.")
                    step("checkmark.circle", "Log logs the take in one tap. Press and hold it to add a note. The shutter saves a snapshot to compare later.")
                    step("xmark", "The cross at the top goes back to recording.")
                }
                Section("Controls") {
                    Toggle("Left-handed controls", isOn: $leftHanded)
                    step("hand.raised", "Puts the controls down the left edge when the phone is turned sideways, and swaps Pause and Log.")
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
