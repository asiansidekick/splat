import SceneKit
import UIKit
import simd

/// Width, depth and height arrows with their lengths, drawn over a placed model like a
/// technical drawing. They hang off the model's box, so they move and turn with it, are drawn
/// on top of everything (never hidden inside the model), and the labels always face the camera.
@MainActor
enum ModelDimensions {
    static let nodeName = "dimensions"
    static let width = UIColor(red: 1, green: 0.35, blue: 0.3, alpha: 1)
    static let depth = UIColor(red: 0.3, green: 0.65, blue: 1, alpha: 1)
    static let height = UIColor(red: 0.35, green: 0.9, blue: 0.4, alpha: 1)

    /// A node to add to the model's node. `low` and `high` are the model's box in its own
    /// coordinates and `scale` its (even) scale; the node undoes the scale so the arrows keep
    /// the same thickness and the labels the same size whatever the model has been pinched to.
    static func make(low: SIMD3<Float>, high: SIMD3<Float>, scale: Float) -> SCNNode {
        let node = SCNNode()
        node.name = nodeName
        guard scale > 0 else { return node }
        node.simdScale = SIMD3(repeating: 1 / scale)
        let lo = low * scale
        let hi = high * scale
        let size = hi - lo
        let largest = max(size.x, size.y, size.z)
        guard largest > 0.001 else { return node }
        // Just outside the box, so the arrows sit beside the model rather than on it.
        let gap = min(max(largest * 0.05, 0.015), 0.1)
        let radius = min(max(largest * 0.005, 0.0015), 0.008)
        let label = min(max(largest * 0.07, 0.03), 0.15)

        // Width along the front bottom edge, depth along the right bottom edge, height up the
        // front right corner.
        let front = hi.z + gap
        let right = hi.x + gap
        let pieces: [(SIMD3<Float>, SIMD3<Float>, UIColor, String, SIMD3<Float>)] = [
            (SIMD3(lo.x, lo.y, front), SIMD3(hi.x, lo.y, front), width, "W", SIMD3(0, -1, 0)),
            (SIMD3(right, lo.y, lo.z), SIMD3(right, lo.y, hi.z), depth, "D", SIMD3(0, -1, 0)),
            (SIMD3(right, lo.y, front), SIMD3(right, hi.y, front), height, "H", SIMD3(1, 0, 0)),
        ]
        for (start, end, colour, letter, away) in pieces {
            let length = simd_distance(start, end)
            guard length > 0.001 else { continue }
            node.addChildNode(arrow(from: start, to: end, radius: radius, colour: colour))
            let text = "\(letter) \(ModelPlacer.length(length))"
            let middle = (start + end) / 2 + away * (label * 0.7)
            node.addChildNode(tag(text, colour: colour, height: label, at: middle))
        }
        onTop(node)
        return node
    }

    /// A line with a head at each end, from `a` to `b`.
    private static func arrow(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float, colour: UIColor) -> SCNNode {
        let length = simd_distance(a, b)
        let head = min(radius * 6, length / 3)
        let holder = SCNNode()
        holder.simdPosition = (a + b) / 2
        // Cylinders and cones stand along y; turn y onto the arrow's direction. The directions
        // used are +x, +z and +y, never straight down, so the turn is always well defined.
        holder.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: simd_normalize(b - a))

        let shaft = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius), height: CGFloat(max(length - head * 2, 0.0005))))
        holder.addChildNode(shaft)
        for end: Float in [1, -1] {
            let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: CGFloat(radius * 3), height: CGFloat(head)))
            cone.simdPosition = SIMD3(0, end * (length / 2 - head / 2), 0)
            // The cone's tip is at +y; flip the one at the start so it points outwards too.
            if end < 0 { cone.simdEulerAngles = SIMD3(.pi, 0, 0) }
            holder.addChildNode(cone)
        }
        for child in holder.childNodes { child.geometry?.materials = [flat(colour)] }
        return holder
    }

    /// The length on a dark rounded tag, `height` metres tall, turned to face the camera.
    static func tag(_ text: String, colour: UIColor, height: Float, at position: SIMD3<Float>) -> SCNNode {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 44, weight: .bold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(textSize.width) + 40, height: ceil(textSize.height) + 20)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let shape = UIBezierPath(roundedRect: box, cornerRadius: box.height / 2)
            UIColor.black.withAlphaComponent(0.7).setFill()
            shape.fill()
            colour.setStroke()
            shape.lineWidth = 4
            shape.stroke()
            (text as NSString).draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
        let plane = SCNPlane(width: CGFloat(height) * size.width / size.height, height: CGFloat(height))
        let material = flat(.white)
        material.diffuse.contents = image
        material.isDoubleSided = true
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.simdPosition = position
        let facing = SCNBillboardConstraint()
        facing.freeAxes = .all
        node.constraints = [facing]
        return node
    }

    /// A note as a comic-book speech bubble, its tail tip at `position`, turned to face the camera.
    /// `height` is how tall a single line of text should look, in metres.
    static func bubble(_ text: String, picked: Bool, height: Float, at position: SIMD3<Float>) -> SCNNode {
        let font = UIFont(name: "MarkerFelt-Wide", size: 44) ?? UIFont.systemFont(ofSize: 44, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black, .paragraphStyle: paragraph]
        let words = text.uppercased() as NSString
        let bounds = words.boundingRect(
            with: CGSize(width: 520, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
            attributes: attributes, context: nil)
        let textSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        let tail: CGFloat = 36
        let size = CGSize(width: textSize.width + 56, height: textSize.height + 36 + tail)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let body = CGRect(x: 5, y: 5, width: size.width - 10, height: size.height - tail - 10)
            let path = UIBezierPath(roundedRect: body, cornerRadius: 34)
            let spike = UIBezierPath()
            spike.move(to: CGPoint(x: size.width / 2 - 22, y: body.maxY - 2))
            spike.addLine(to: CGPoint(x: size.width / 2 - 8, y: size.height - 4))
            spike.addLine(to: CGPoint(x: size.width / 2 + 22, y: body.maxY - 2))
            spike.close()
            path.append(spike)
            // Outline first, then the white over its inner half, so no line shows across the tail.
            (picked ? Measurer.pickedColour : UIColor.black).setStroke()
            path.lineWidth = 10
            path.lineJoinStyle = .round
            path.stroke()
            UIColor.white.setFill()
            path.fill()
            words.draw(
                in: CGRect(x: (size.width - textSize.width) / 2, y: body.minY + (body.height - textSize.height) / 2,
                           width: textSize.width, height: textSize.height),
                withAttributes: attributes)
        }
        let unit = CGFloat(height) / 64
        let plane = SCNPlane(width: size.width * unit, height: size.height * unit)
        let material = flat(.white)
        material.diffuse.contents = image
        material.isDoubleSided = true
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.simdPosition = position
        // The tail tip, not the middle, sits on the spot.
        var pivot = matrix_identity_float4x4
        pivot.columns.3 = SIMD4(0, -Float(plane.height) / 2, 0, 1)
        node.simdPivot = pivot
        let facing = SCNBillboardConstraint()
        facing.freeAxes = .all
        node.constraints = [facing]
        return node
    }

    /// Unlit and drawn over the model and the room, like a drawing on the screen.
    static func flat(_ colour: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = colour
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        return material
    }

    static func onTop(_ node: SCNNode) {
        node.renderingOrder = 1000
        node.childNodes.forEach(onTop)
    }
}
