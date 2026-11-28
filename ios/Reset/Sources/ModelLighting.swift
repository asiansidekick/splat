import SceneKit
import SwiftUI
import UIKit

/// Phil, 2026-11-21: "control over lighting of each model". Each placed model can be made brighter or darker,
/// warmer or cooler, and lit from one side of the room (ModelLight in ReferenceModel.swift). It is done in the
/// model's own materials (a small shader step), so it changes only that model, never the others, the room's light
/// or the default lighting, and it works the same on lit models, scans and cut-outs.
extension ModelPlacer {
    /// The shader step (ModelLightShader.swift, checked by the light tests on a Mac).
    static var lightShader: String { ModelLightShader.source }

    /// Nodes that are handles, figures or shadows, not the model itself: never relit.
    static let unlitHelpers: Set<String> = [ModelDimensions.nodeName, "cutout-shadow", "posedot", "posehalo", "turnicon", "gizmo", lightSunName]
    static let lightSunName = "lightsun"

    /// The light the selected model has now (while dragging, before it is saved).
    var selectedLight: ModelLight {
        guard let id = selectedModel else { return ModelLight() }
        if let draft = lightDraft, draft.id == id { return draft.light }
        return models.first { $0.id == id }?.light ?? ModelLight()
    }

    /// Puts the light into every material of the model. A model never relit is left untouched.
    static func applyLight(_ light: ModelLight?, to node: SCNNode) {
        let light = light ?? ModelLight()
        let tint = light.tint
        let way = light.direction ?? SIMD3<Float>(0, 1, 0)
        let values: [String: Any] = [
            "resetTint": NSValue(scnVector3: SCNVector3(tint.x, tint.y, tint.z)),
            "resetLightWay": NSValue(scnVector3: SCNVector3(way.x, way.y, way.z)),
            "resetSideLight": NSNumber(value: light.direction == nil ? 0 : 1),
        ]
        var materials: [SCNMaterial] = []
        func gather(_ node: SCNNode) {
            if let name = node.name, unlitHelpers.contains(name) { return }
            if let geometry = node.geometry { materials.append(contentsOf: geometry.materials) }
            node.childNodes.forEach(gather)
        }
        gather(node)
        for material in materials {
            let has = material.shaderModifiers?[.fragment] == lightShader
            if !has {
                guard !light.isPlain else { continue }
                var modifiers = material.shaderModifiers ?? [:]
                modifiers[.fragment] = lightShader
                material.shaderModifiers = modifiers
            }
            for (key, value) in values { material.setValue(value, forKey: key) }
        }
    }

    func applyLight(_ id: UUID) {
        guard let node = modelNodes[id] else { return }
        let light = (lightDraft?.id == id ? lightDraft?.light : nil) ?? models.first { $0.id == id }?.light
        Self.applyLight(light, to: node)
    }

    /// One finger on the picture with the Light tool on: changes the part picked in the light bar.
    func lightDrag(_ moved: CGPoint, id: UUID, ended: Bool) {
        var light = selectedLight
        if lightPart == .direction, light.around == nil { light.around = startingAround(for: id) }
        light.change(lightPart, by: SIMD2(Float(moved.x), Float(moved.y)))
        lightDraft = (id: id, light: light)
        applyLight(id)
        refreshLightSun()
        // The bar's figures follow about ten times a second, not on every finger step.
        if ended || Date().timeIntervalSince(lastLightShown) > 0.1 {
            lastLightShown = Date()
            objectWillChange.send()
        }
        if ended { saveLight(id) }
    }

    /// Picks what one finger changes. Direction switches the side light on (from the camera's side, up and to the
    /// left, as a key light usually is) so it shows straight away.
    func pickLightPart(_ part: ModelLight.Part) {
        guard let id = selectedModel else { return }
        Haptics.tap()
        lightPart = part
        if part == .direction, selectedLight.around == nil {
            var light = selectedLight
            light.around = startingAround(for: id)
            lightDraft = (id: id, light: light)
            saveLight(id)
        }
        refreshLightSun()
    }

    /// Back to the light it always had.
    func plainLight() {
        guard let id = selectedModel, let index = models.firstIndex(where: { $0.id == id }) else { return }
        Haptics.tap()
        lightDraft = nil
        models[index].light = nil
        models[index].moved = Date()
        lightPart = .brightness
        applyLight(id)
        refreshLightSun()
        Diagnostics.log("Model light: back to normal")
    }

    private func saveLight(_ id: UUID) {
        guard let draft = lightDraft, draft.id == id, let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].light = draft.light.isPlain ? nil : draft.light
        models[index].moved = Date()
        lightDraft = nil
        applyLight(id)
        Diagnostics.log(String(format: "Model light: brightness %.2f, warmth %.2f, side light %@", draft.light.brightness, draft.light.warmth,
                               draft.light.around.map { String(format: "round %.0f°, up %.0f°", $0 * 180 / .pi, draft.light.height * 180 / .pi) } ?? "off"))
    }

    /// From the side of the model the camera is on, swung 45 degrees to the camera's left.
    private func startingAround(for id: UUID) -> Float {
        guard let node = modelNodes[id], let eye = self.eye else { return 0 }
        let toCamera = eye.columns.3.xyz - node.simdWorldPosition
        return atan2(toCamera.x, toCamera.z) - .pi / 4
    }

    /// A small sun on a stalk shows where the side light comes from while Direction is picked.
    func refreshLightSun() {
        guard cutoutJob == .light, lightPart == .direction, let id = selectedModel, let node = modelNodes[id],
              let way = selectedLight.direction else {
            lightSun?.removeFromParentNode()
            lightSun = nil
            return
        }
        let (middle, radius) = node.boundingSphere
        let centre = node.simdConvertPosition(SIMD3<Float>(middle), to: nil)
        let reach = max(Float(radius) * node.simdScale.x * 1.25, 0.25)
        let sun: SCNNode
        if let lightSun {
            sun = lightSun
        } else {
            sun = Self.makeSun()
            root.addChildNode(sun)
            lightSun = sun
        }
        sun.simdWorldPosition = centre
        // The stalk runs from the model's middle out to the sun, along the light's way.
        if let stalk = sun.childNode(withName: "stalk", recursively: false), let ball = sun.childNode(withName: "ball", recursively: false) {
            ball.simdPosition = way * reach
            ball.simdScale = SIMD3(repeating: max(reach * 0.25, 0.05))
            (stalk.geometry as? SCNCylinder)?.height = CGFloat(reach)
            stalk.simdPosition = way * reach / 2
            stalk.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: way)
        }
    }

    private static func makeSun() -> SCNNode {
        let colour = UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)
        func material(_ alpha: CGFloat) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = colour.withAlphaComponent(alpha)
            material.lightingModel = .constant
            // Seen through the model, so it is never lost behind it.
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            return material
        }
        let holder = SCNNode()
        holder.name = lightSunName
        let ball = SCNNode(geometry: SCNSphere(radius: 0.5))
        ball.name = "ball"
        ball.geometry?.materials = [material(0.95)]
        ball.renderingOrder = 3001
        let stalk = SCNNode(geometry: SCNCylinder(radius: 0.004, height: 1))
        stalk.name = "stalk"
        stalk.geometry?.materials = [material(0.6)]
        stalk.renderingOrder = 3000
        holder.addChildNode(stalk)
        holder.addChildNode(ball)
        return holder
    }
}

/// While the Light tool is on: what one finger changes (Direction, Brightness, Warmth, with the value now) and Normal,
/// along the top edge like the pose buttons. The picked one is mint.
struct ModelLightBar: View {
    @ObservedObject var placer: ModelPlacer

    var body: some View {
        let light = placer.selectedLight
        HStack(spacing: 2) {
            ForEach(ModelLight.Part.allCases, id: \.self) { part in
                LightWord(word: part.rawValue, value: light.words(part), symbol: Self.symbol(part), on: placer.lightPart == part) {
                    placer.pickLightPart(part)
                }
            }
            LightWord(word: "Normal", value: nil, symbol: "arrow.counterclockwise", on: false, dim: light.isPlain) { placer.plainLight() }
        }
        .fixedSize()
    }

    private static func symbol(_ part: ModelLight.Part) -> String {
        switch part {
        case .direction: return "sun.max"
        case .brightness: return "light.max"
        case .warmth: return "thermometer.sun"
        }
    }
}

/// One word of the light bar: a picture, the word, and the value under it, white with a soft shadow, no box.
private struct LightWord: View {
    let word: String
    let value: String?
    let symbol: String
    let on: Bool
    var dim = false
    let action: () -> Void

    var body: some View {
        Button { TapGate.run("Light " + word, action) } label: {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(word).font(.system(size: 11, weight: on ? .heavy : .semibold)).lineLimit(1).fixedSize()
                if let value { Text(value).font(.system(size: 10, weight: .semibold).monospacedDigit()).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(on ? Theme.accent : .white)
            .opacity(dim ? 0.5 : 1)
            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.5), radius: 6)
            .frame(minWidth: 64, minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .caughtTap("Light " + word, perform: action)
    }
}
