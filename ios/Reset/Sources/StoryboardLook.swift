import ARKit
import SceneKit
import SwiftUI

/// The Storyboard look over the whole app (Phil, 2026-11-18: "think of storyboard mode as an overlay of the whole
/// Reset app"). The recording and reset screens' 3D views (camera picture plus every model, mannequin and cut-out)
/// are drawn in the storyboard style by a SceneKit technique (StoryboardLook.metal). Everything else works as
/// usual: tracking, placing, measuring and the buttons, which sit on top and stay sharp.
@MainActor
final class StoryboardLook: ObservableObject {
    static let shared = StoryboardLook()

    @Published private(set) var on: Bool
    @Published private(set) var styleName: String
    private var views = NSHashTable<ARSCNView>.weakObjects()
    private var loggedFrames = false

    private init() {
        on = UserDefaults.standard.bool(forKey: "storyLookOn")
        styleName = UserDefaults.standard.string(forKey: "storyStyleName") ?? "Marker"
    }

    /// The style Storyboard uses: the same keys as StoryboardScreen's, so the two always match.
    var style: DrawStyle {
        if let text = UserDefaults.standard.string(forKey: "storyStyle"), !text.isEmpty,
           let data = text.data(using: .utf8), var saved = try? JSONDecoder().decode(DrawStyle.self, from: data) {
            saved.splatter = 0
            return saved
        }
        return StylePreset.named(styleName)?.style ?? StylePreset.all[0].style
    }

    /// A live 3D view to draw in the look whenever it is on.
    func attach(_ view: ARSCNView) {
        views.add(view)
        apply(view)
    }

    func set(_ value: Bool) {
        on = value
        UserDefaults.standard.set(value, forKey: "storyLookOn")
        Diagnostics.log("Storyboard look \(value ? "on" : "off"), \(styleName)")
        refresh()
    }

    /// The next ready-made style, for the style pill.
    func nextStyle() {
        let all = StylePreset.all.filter { $0.name != "Photo" }
        let index = all.firstIndex { $0.name == styleName } ?? -1
        let preset = all[(index + 1) % all.count]
        styleName = preset.name
        UserDefaults.standard.set(preset.name, forKey: "storyStyleName")
        if let data = try? JSONEncoder().encode(preset.style) {
            UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "storyStyle")
        }
        refresh()
    }

    /// After Storyboard changed the style.
    func refresh() {
        styleName = UserDefaults.standard.string(forKey: "storyStyleName") ?? styleName
        for view in views.allObjects { apply(view) }
    }

    private func apply(_ view: ARSCNView) {
        guard on else {
            if view.technique != nil { view.technique = nil }
            return
        }
        guard let technique = view.technique ?? Self.makeTechnique() else {
            Diagnostics.log("Storyboard look: technique could not be made")
            return
        }
        let s = style
        technique.setValue(NSValue(scnVector4: SCNVector4(Float(s.lines), Float(s.detail), Float(s.shadows), Float(s.greys))), forKey: "styleA")
        technique.setValue(NSValue(scnVector4: SCNVector4(Float(s.colour), Float(s.dots), Float(s.paper), 1)), forKey: "styleB")
        // The view keeps its own copy of a technique, so it is handed the updated one each time.
        view.technique = technique
        if !loggedFrames {
            loggedFrames = true
            Diagnostics.log("Storyboard look drawing, preferred \(view.preferredFramesPerSecond) fps")
        }
    }

    /// Two passes: the style at half size, then that drawn over the whole screen.
    static func makeTechnique() -> SCNTechnique? {
        let definition: [String: Any] = [
            "passes": [
                "storyLookStyle": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "storyLookVertex",
                    "metalFragmentShader": "storyLookFragment",
                    "inputs": ["colorSampler": "COLOR", "styleA": "styleA", "styleB": "styleB"],
                    "outputs": ["color": "storyLookHalf"],
                ],
                "storyLookShow": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "storyLookVertex",
                    "metalFragmentShader": "storyLookShow",
                    "inputs": ["colorSampler": "storyLookHalf"],
                    "outputs": ["color": "COLOR"],
                ],
            ],
            "sequence": ["storyLookStyle", "storyLookShow"],
            "targets": [
                "storyLookHalf": ["type": "color", "scaleFactor": 0.5],
            ],
            "symbols": [
                "styleA": ["type": "vec4"],
                "styleB": ["type": "vec4"],
            ],
        ]
        return SCNTechnique(dictionary: definition)
    }

    /// The view as a plain photo (with its models), for a storyboard panel: the look is lifted for the moment it
    /// takes, so the panel can be drawn in any style later.
    func plainPhoto(of view: ARSCNView) -> UIImage {
        let technique = view.technique
        view.technique = nil
        let image = view.snapshot()
        view.technique = technique
        return image
    }
}

/// While the look is on: the style (tap for the next one), Make panel, and Off. Top of the recording and reset
/// screens, plain words.
struct StoryboardLookBar: View {
    @ObservedObject private var look = StoryboardLook.shared
    let makePanel: () -> Void

    var body: some View {
        if look.on {
            HStack(spacing: 8) {
                lookButton("Look: \(look.styleName) ›", name: "Look style", on: true) { look.nextStyle() }
                lookButton("Make panel", name: "Look panel", on: false) { makePanel() }
                lookButton("Look off", name: "Look off", on: false) { look.set(false) }
            }
            .transition(.opacity)
        }
    }

    private func lookButton(_ title: String, name: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { TapGate.run(name) { Haptics.tap(); action() } } label: {
            Text(title)
                .font(Theme.footnote.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(on ? Theme.active : Color.black.opacity(0.55), in: Capsule())
                .foregroundStyle(on ? Color.black : Color.white)
        }
        .caughtTap(name) { Haptics.tap(); action() }
    }
}

/// A panel made from the live view: drawn in the current style, then opened for bubbles and camera moves.
struct LookPanel: Identifiable {
    let panel: StoryPanel
    var id: UUID { panel.id }

    @MainActor static func make(from view: ARSCNView?, scene: String, shot: String) -> LookPanel? {
        guard let view else { return nil }
        let look = StoryboardLook.shared
        let photo = look.plainPhoto(of: view)
        let store = StoryboardStore.shared
        let style = look.style
        let name = StylePreset.matching(style)?.name ?? "Custom"
        let aspect = UserDefaults.standard.string(forKey: "storyAspect") ?? "16:9"
        guard let panel = store.add(photo: photo, scene: scene, shot: shot, style: style, styleName: name, aspect: aspect) else { return nil }
        Haptics.success()
        return LookPanel(panel: panel)
    }
}
