import SceneKit
import SwiftUI
import UIKit

// Ready-made models to stand in the room (Phil, 2026-11-10): a woman and a man mannequin in set poses, and
// a few set pieces. Each is built here from simple shapes and saved as a USDZ, then placed like any
// imported model, so it is moved, saved with a reference and synced the same way.

enum Mannequin {
    typealias Body = MannequinBody

    /// Body measurements in metres before scaling to the height.
    private struct Build {
        var shoulders: Float, hips: Float, torso: Float, neck: Float, head: Float
        var upperArm: Float, forearm: Float, hand: Float, thigh: Float, shin: Float, foot: Float
        var armRadius: Float, legRadius: Float, waist: Float, chestDepth: Float, bust: Float

        var standing: Float { foot + shin + thigh + 0.04 + torso + neck + head }
    }

    private static func build(_ body: Body) -> Build {
        switch body {
        case .man:
            return Build(shoulders: 0.40, hips: 0.30, torso: 0.48, neck: 0.07, head: 0.23, upperArm: 0.30, forearm: 0.26, hand: 0.18,
                         thigh: 0.45, shin: 0.43, foot: 0.08, armRadius: 0.045, legRadius: 0.075, waist: 0.12, chestDepth: 0.12, bust: 0)
        case .woman:
            // Phil, 2026-11-10: a fashion-doll figure: narrow waist, full rib cage and bust, rounder hips, slim limbs.
            return Build(shoulders: 0.35, hips: 0.36, torso: 0.47, neck: 0.08, head: 0.22, upperArm: 0.29, forearm: 0.25, hand: 0.17,
                         thigh: 0.46, shin: 0.44, foot: 0.075, armRadius: 0.032, legRadius: 0.066, waist: 0.08, chestDepth: 0.1, bust: 0.056)
        }
    }

    static func defaultHeight(_ body: Body) -> Float { body == .man ? 1.78 : 1.65 }

    private static let skin: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(red: 0.80, green: 0.73, blue: 0.64, alpha: 1)
        m.roughness.contents = 0.6
        return m
    }()

    private static func shape(_ geometry: SCNGeometry, at position: SIMD3<Float>, scale: SIMD3<Float> = .one) -> SCNNode {
        geometry.materials = [skin]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = position
        node.simdScale = scale
        return node
    }

    /// A joint: turns out (z), then forward (x), then about its own length (y), as three nested nodes.
    private static func joint(_ name: String, at position: SIMD3<Float>, z: Float = 0, x: Float = 0, y: Float = 0) -> (outer: SCNNode, inner: SCNNode) {
        let a = SCNNode(); a.name = name; a.simdPosition = position; a.eulerAngles.z = z * .pi / 180
        let b = SCNNode(); b.eulerAngles.x = x * .pi / 180
        let c = SCNNode(); c.name = name + ".in"; c.eulerAngles.y = y * .pi / 180
        a.addChildNode(b); b.addChildNode(c)
        return (a, c)
    }

    /// An empty node marking a wrist, ankle or the head, for the pose editor's handles.
    private static func marker(_ name: String, at position: SIMD3<Float>) -> SCNNode {
        let node = SCNNode()
        node.name = name
        node.simdPosition = position
        return node
    }

    /// A limb hanging down from its joint.
    private static func limb(_ length: Float, radius: Float) -> SCNNode {
        shape(SCNCapsule(capRadius: CGFloat(radius), height: CGFloat(length + radius)), at: SIMD3(0, -length / 2, 0))
    }

    static func make(_ body: Body, pose: MannequinPose, height: Float? = nil) -> SCNNode {
        var d = build(body)
        let k = (height ?? defaultHeight(body)) / d.standing
        for path in [\Build.shoulders, \.hips, \.torso, \.neck, \.head, \.upperArm, \.forearm, \.hand, \.thigh, \.shin, \.foot,
                     \.armRadius, \.legRadius, \.waist, \.chestDepth, \.bust] as [WritableKeyPath<Build, Float>] {
            d[keyPath: path] *= k
        }
        let figure = SCNNode()
        figure.name = "Mannequin"
        let root = SCNNode()
        root.name = "pelvis"
        root.simdPosition = SIMD3(0, d.foot + d.shin + d.thigh + 0.04 * k, 0)
        figure.addChildNode(root)
        // Pelvis: the woman's is rounder and fuller than her waist.
        if body == .woman {
            root.addChildNode(shape(SCNSphere(radius: 1), at: SIMD3(0, -0.03 * k, -0.005 * k), scale: SIMD3(d.hips * 0.56, 0.13 * k, 0.105 * k)))
        } else {
            root.addChildNode(shape(SCNSphere(radius: 1), at: SIMD3(0, -0.02 * k, 0), scale: SIMD3(d.hips * 0.55, 0.11 * k, d.waist * 1.05)))
        }

        // Spine: abdomen, chest, neck, head.
        let spine = joint("spine", at: .zero, z: pose.spineSide, x: pose.spineForward)
        root.addChildNode(spine.outer)
        let s = spine.inner
        if body == .woman {
            // Hourglass: a slim waist between a tapering rib cage and the hips, the bust set into the chest.
            s.addChildNode(shape(SCNCapsule(capRadius: CGFloat(d.waist), height: CGFloat(d.torso * 0.5)), at: SIMD3(0, d.torso * 0.3, 0),
                                 scale: SIMD3(1.05, 1, 0.85)))
            s.addChildNode(shape(SCNSphere(radius: 1), at: SIMD3(0, d.torso * 0.08, -0.003 * k), scale: SIMD3(d.hips * 0.4, d.torso * 0.16, 0.085 * k)))
            s.addChildNode(shape(SCNSphere(radius: 1), at: SIMD3(0, d.torso * 0.7, 0), scale: SIMD3(d.shoulders * 0.43, d.torso * 0.29, d.chestDepth * 0.85)))
            for side: Float in [-1, 1] {
                s.addChildNode(shape(SCNSphere(radius: CGFloat(d.bust)), at: SIMD3(side * d.shoulders * 0.15, d.torso * 0.63, d.chestDepth * 0.5),
                                     scale: SIMD3(1, 0.92, 0.85)))
            }
        } else {
            s.addChildNode(shape(SCNCapsule(capRadius: CGFloat(d.waist), height: CGFloat(d.torso * 0.55)), at: SIMD3(0, d.torso * 0.35, 0),
                                 scale: SIMD3(1, 1, 0.8)))
            s.addChildNode(shape(SCNSphere(radius: 1), at: SIMD3(0, d.torso * 0.72, 0), scale: SIMD3(d.shoulders * 0.5, d.torso * 0.3, d.chestDepth)))
        }
        s.addChildNode(shape(SCNCapsule(capRadius: CGFloat((body == .woman ? 0.036 : 0.045) * k), height: CGFloat(d.neck + 0.08 * k)), at: SIMD3(0, d.torso + d.neck * 0.4, 0)))
        let neck = joint("neck", at: SIMD3(0, d.torso + d.neck, 0), x: pose.headDown, y: pose.headTurn)
        s.addChildNode(neck.outer)
        neck.inner.addChildNode(shape(SCNSphere(radius: 1), at: SIMD3(0, d.head * 0.5, 0.01 * k), scale: SIMD3(0.085 * k, d.head * 0.5, 0.1 * k)))
        neck.inner.addChildNode(marker("end.head", at: SIMD3(0, d.head * 0.5, 0)))

        // Arms.
        for (side, arm) in [(Float(1), pose.left), (Float(-1), pose.right)] {
            let name = side > 0 ? "L" : "R"
            let shoulder = joint("shoulder.\(name)", at: SIMD3(side * d.shoulders / 2, d.torso - 0.03 * k, 0),
                                 z: side * arm.out, x: -arm.forward, y: -side * arm.inward)
            s.addChildNode(shoulder.outer)
            shoulder.inner.addChildNode(shape(SCNSphere(radius: CGFloat(d.armRadius * 1.25)), at: .zero))
            shoulder.inner.addChildNode(limb(d.upperArm, radius: d.armRadius))
            let elbow = joint("elbow.\(name)", at: SIMD3(0, -d.upperArm, 0), x: -arm.elbow)
            shoulder.inner.addChildNode(elbow.outer)
            elbow.inner.addChildNode(shape(SCNSphere(radius: CGFloat(d.armRadius * 0.95)), at: .zero))
            elbow.inner.addChildNode(limb(d.forearm, radius: d.armRadius * 0.82))
            elbow.inner.addChildNode(marker("end.hand.\(name)", at: SIMD3(0, -d.forearm, 0)))
            elbow.inner.addChildNode(shape(SCNSphere(radius: 1), at: SIMD3(0, -d.forearm - d.hand * 0.4, 0),
                                           scale: SIMD3(d.armRadius * 0.55, d.hand * 0.45, d.armRadius * 1.0)))
        }

        // Legs.
        for (side, leg) in [(Float(1), pose.leftLeg), (Float(-1), pose.rightLeg)] {
            let name = side > 0 ? "L" : "R"
            let hip = joint("hip.\(name)", at: SIMD3(side * d.hips * 0.3, -0.04 * k, 0), z: side * leg.out, x: -leg.forward, y: -side * leg.inward)
            root.addChildNode(hip.outer)
            hip.inner.addChildNode(limb(d.thigh, radius: d.legRadius))
            let knee = joint("knee.\(name)", at: SIMD3(0, -d.thigh, 0), x: leg.knee)
            hip.inner.addChildNode(knee.outer)
            knee.inner.addChildNode(shape(SCNSphere(radius: CGFloat(d.legRadius * 0.8)), at: .zero))
            knee.inner.addChildNode(limb(d.shin, radius: d.legRadius * 0.7))
            knee.inner.addChildNode(marker("end.foot.\(name)", at: SIMD3(0, -d.shin, 0)))
            let foot = SCNBox(width: CGFloat(d.legRadius * 1.3), height: CGFloat(d.foot), length: CGFloat(d.foot * 3.2), chamferRadius: CGFloat(d.foot * 0.35))
            knee.inner.addChildNode(shape(foot, at: SIMD3(0, -d.shin - d.foot * 0.5, d.foot * 0.9)))
        }

        // Stand it on the floor whatever the pose.
        let (low, _) = figure.boundingBox
        figure.simdPosition.y -= Float(low.y)
        return figure
    }
}

/// Set pieces: simple, real-size stand-ins.
enum SetPiece: String, CaseIterable {
    case chair = "Chair", table = "Table", appleBox = "Apple box (full)", cStand = "C-stand with flag", dolly = "Camera on a dolly"

    private static func material(_ colour: UIColor, rough: CGFloat = 0.6, metal: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = colour
        m.roughness.contents = rough
        m.metalness.contents = metal
        return m
    }
    private static let wood = material(UIColor(red: 0.55, green: 0.38, blue: 0.24, alpha: 1))
    private static let steel = material(UIColor(white: 0.7, alpha: 1), rough: 0.35, metal: 0.9)
    private static let black = material(UIColor(white: 0.08, alpha: 1), rough: 0.5)
    private static let rubber = material(UIColor(white: 0.15, alpha: 1), rough: 0.9)

    private static func box(_ w: Float, _ h: Float, _ l: Float, at p: SIMD3<Float>, _ m: SCNMaterial, chamfer: Float = 0.004) -> SCNNode {
        let g = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(l), chamferRadius: CGFloat(chamfer))
        g.materials = [m]
        let n = SCNNode(geometry: g); n.simdPosition = p
        return n
    }

    /// A rod from a to b.
    private static func rod(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, _ m: SCNMaterial) -> SCNNode {
        let length = simd_length(b - a)
        let g = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = (a + b) / 2
        let up = SIMD3<Float>(0, 1, 0), dir = simd_normalize(b - a)
        let axis = simd_cross(up, dir)
        if simd_length(axis) > 1e-5 {
            n.simdOrientation = simd_quatf(angle: acos(max(-1, min(1, simd_dot(up, dir)))), axis: simd_normalize(axis))
        } else if dir.y < 0 {
            n.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
        }
        return n
    }

    func make() -> SCNNode {
        let n = SCNNode()
        n.name = rawValue
        switch self {
        case .chair:
            let s: Float = 0.42
            n.addChildNode(Self.box(s + 0.02, 0.04, s, at: SIMD3(0, 0.45, 0), Self.wood))
            for x: Float in [-1, 1] {
                for z: Float in [-1, 1] {
                    let top: Float = z < 0 ? 0.92 : 0.43
                    n.addChildNode(Self.box(0.035, top, 0.035, at: SIMD3(x * (s / 2 - 0.02), top / 2, z * (s / 2 - 0.02)), Self.wood))
                }
            }
            n.addChildNode(Self.box(s, 0.13, 0.025, at: SIMD3(0, 0.82, -(s / 2 - 0.02)), Self.wood))
            n.addChildNode(Self.box(s, 0.05, 0.025, at: SIMD3(0, 0.62, -(s / 2 - 0.02)), Self.wood))
        case .table:
            n.addChildNode(Self.box(1.2, 0.035, 0.75, at: SIMD3(0, 0.74, 0), Self.wood))
            for x: Float in [-1, 1] {
                for z: Float in [-1, 1] {
                    n.addChildNode(Self.box(0.05, 0.72, 0.05, at: SIMD3(x * 0.55, 0.36, z * 0.32), Self.wood))
                }
            }
        case .appleBox:
            // 20 x 12 x 8 inches, lying flat, with the hand holes as dark slots on the ends.
            n.addChildNode(Self.box(0.508, 0.203, 0.305, at: SIMD3(0, 0.1015, 0), Self.wood))
            for x: Float in [-1, 1] {
                n.addChildNode(Self.box(0.004, 0.035, 0.12, at: SIMD3(x * 0.2545, 0.13, 0), Self.black, chamfer: 0.001))
            }
        case .cStand:
            let riser: Float = 1.8
            // Turtle base: three legs at different heights, as on a real stand.
            for (i, angle) in [Float(0), 2.1, 4.2].enumerated() {
                let foot = SIMD3(sin(angle) * 0.42, 0.01, cos(angle) * 0.42)
                n.addChildNode(Self.rod(SIMD3(0, 0.22 + Float(i) * 0.06, 0), foot, radius: 0.011, Self.steel))
                n.addChildNode(Self.rod(foot, foot + SIMD3(0, 0.02, 0), radius: 0.015, Self.rubber))
            }
            n.addChildNode(Self.rod(SIMD3(0, 0.12, 0), SIMD3(0, riser, 0), radius: 0.014, Self.steel))
            n.addChildNode(Self.box(0.05, 0.06, 0.05, at: SIMD3(0, riser, 0), Self.black))
            let armEnd = SIMD3<Float>(0, riser + 0.05, 0.95)
            n.addChildNode(Self.rod(SIMD3(0, riser, -0.25), armEnd, radius: 0.01, Self.steel))
            n.addChildNode(Self.box(0.6, 0.45, 0.01, at: armEnd + SIMD3(0, -0.05, 0.02), Self.black, chamfer: 0.002))
        case .dolly:
            // A generic camera dolly: chassis on four wheels, a centre column, a head and a camera with a lens and matte box.
            n.addChildNode(Self.box(0.7, 0.16, 1.05, at: SIMD3(0, 0.17, 0), Self.black, chamfer: 0.02))
            for x: Float in [-1, 1] {
                for z: Float in [-1, 1] {
                    let wheel = Self.rod(SIMD3(x * 0.36, 0.08, z * 0.42), SIMD3(x * 0.40, 0.08, z * 0.42), radius: 0.08, Self.rubber)
                    n.addChildNode(wheel)
                }
            }
            n.addChildNode(Self.box(0.6, 0.05, 0.35, at: SIMD3(0, 0.27, -0.38), Self.rubber))  // operator's step
            n.addChildNode(Self.rod(SIMD3(0, 0.25, 0.15), SIMD3(0, 1.1, 0.15), radius: 0.075, Self.steel))  // column
            n.addChildNode(Self.box(0.2, 0.12, 0.2, at: SIMD3(0, 1.17, 0.15), Self.black))  // head
            n.addChildNode(Self.rod(SIMD3(0.1, 1.17, 0.15), SIMD3(0.1, 1.17, -0.35), radius: 0.012, Self.steel))  // pan bar
            n.addChildNode(Self.box(0.15, 0.17, 0.3, at: SIMD3(0, 1.32, 0.13), Self.black, chamfer: 0.01))  // camera body
            n.addChildNode(Self.rod(SIMD3(0, 1.32, 0.28), SIMD3(0, 1.32, 0.5), radius: 0.055, Self.black))  // lens
            n.addChildNode(Self.box(0.2, 0.15, 0.08, at: SIMD3(0, 1.32, 0.54), Self.black))  // matte box
            n.addChildNode(Self.box(0.17, 0.11, 0.02, at: SIMD3(-0.13, 1.42, 0.02), Self.black))  // monitor
        }
        return n
    }
}

enum Examples {
    /// Writes the node as a USDZ under a readable name, ready for ModelPlacer to add.
    static func file(for node: SCNNode, name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Examples", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).usdz")
        try? FileManager.default.removeItem(at: url)
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil), FileManager.default.fileExists(atPath: url.path) else {
            Diagnostics.log("Example not written: \(name)")
            return nil
        }
        return url
    }
}

/// The list of examples: pick a body and a pose, or a set piece. It goes in facing the camera.
struct ExamplesSheet: View {
    let placer: ModelPlacer
    /// Where it goes when there is no live camera (Review); nil places it where the camera points.
    var base: simd_float4x4? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exampleBody") private var personName: String = Mannequin.Body.woman.rawValue
    @State private var heightText = ""

    private var person: Mannequin.Body { Mannequin.Body(rawValue: personName) ?? .woman }
    private var height: Float {
        if let cm = Float(heightText.replacingOccurrences(of: ",", with: ".")), cm >= 50, cm <= 230 { return cm / 100 }
        return Mannequin.defaultHeight(person)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Person", selection: $personName) {
                        ForEach(Mannequin.Body.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Height (cm)") {
                        TextField(String(Int(Mannequin.defaultHeight(person) * 100)), text: $heightText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    if base == nil, PoseCopier.supported {
                        Button {
                            placer.poseCopier = PoseCopier(placer: placer, body: person)
                            dismiss()
                        } label: {
                            Label("Copy the actor's pose", systemImage: "figure.stand.line.dotted.figure.stand")
                                .fontWeight(.semibold)
                        }
                    }
                    ForEach(MannequinPose.all, id: \.name) { item in
                        Button {
                            add(Mannequin.make(person, pose: item.pose, height: height), name: "\(person.rawValue), \(item.name.lowercased())",
                                spec: MannequinSpec(body: person, height: height, pose: item.pose))
                        } label: {
                            Label(item.name, systemImage: symbol(item.name))
                        }
                    }
                } header: {
                    Text("A stand-in person")
                } footer: {
                    Text("A plain mannequin at real height, facing the camera. Move, turn and size it like any 3D model. Copy the actor's pose stands one in their stance, on their spot.")
                }
                Section("Set pieces") {
                    ForEach(SetPiece.allCases, id: \.self) { piece in
                        Button { add(piece.make(), name: piece.rawValue) } label: { Label(piece.rawValue, systemImage: symbol(piece)) }
                    }
                }
            }
            .navigationTitle("Examples")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func symbol(_ pose: String) -> String {
        switch pose {
        case "Sitting": return "figure.seated.side"
        case "Walking": return "figure.walk"
        case "Arms crossed": return "figure.stand.line.dotted.figure.stand"
        case "Hands on hips": return "figure.arms.open"
        default: return "figure.stand"
        }
    }

    private func symbol(_ piece: SetPiece) -> String {
        switch piece {
        case .chair: return "chair"
        case .table: return "table.furniture"
        case .appleBox: return "shippingbox"
        case .cStand: return "lamp.floor"
        case .dolly: return "video"
        }
    }

    private func add(_ node: SCNNode, name: String, spec: MannequinSpec? = nil) {
        guard let url = Examples.file(for: node, name: name) else {
            placer.modelError = "Could not make \(name)."
            return
        }
        Diagnostics.log("Example added: \(name)")
        let before = placer.selectedModel
        placer.addFacingCamera(from: [url], base: base)
        if let spec, let id = placer.selectedModel, id != before { placer.setMannequin(spec, for: id) }
        Haptics.success()
        dismiss()
    }
}
