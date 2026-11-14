import Foundation
import simd

// Finding the joints of an imported character and posing it. Kept free of SceneKit so CI can test it on a Mac.

/// One node of an imported character, in the file's rest pose (metres, Y up).
struct RigNode {
    var name: String
    var parent: Int  // index into the nodes, -1 at the top
    var isBone: Bool
    var local: simd_float4x4  // node to parent
    var world: simd_float4x4  // node to the model's own space

    var position: SIMD3<Float> { SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z) }
}

/// Which nodes are the joints Reset poses. Arms and legs are upper, lower, end (hand or foot).
struct RigMap: Equatable {
    var hips: Int
    /// From just above the hips up to the chest, the bone the arms part from.
    var spine: [Int]
    var neck: Int?
    var head: Int?
    var armL: [Int]
    var armR: [Int]
    var legL: [Int]
    var legR: [Int]
    /// 1 when the character faces +Z in its file, -1 when it faces -Z.
    var facing: Float
    /// Found from the bone names; false when worked out from the skeleton's shape.
    var fromNames: Bool
}

/// Phil, 2026-11-11: characters come with bones named every which way (Mixamo, Unreal, Unity, Blender, 3ds Max,
/// Daz) or not usefully named at all. Names are tried first; only the elbow, wrist, knee, ankle and head need
/// a name, the rest follows from how the bones join. Failing that, the joints are found from the skeleton's shape.
enum RigFinder {
    static func find(_ nodes: [RigNode]) -> RigMap? {
        guard let skeleton = Skeleton(nodes) else { return nil }
        return skeleton.byNames() ?? skeleton.byShape()
    }

    /// What a bone's name says: its side, and the rest of the name run together in lower case ("forearm").
    struct Label: Equatable {
        var side = 0  // 1 left, -1 right
        var key = ""
        var twist = false
        var skip = false
    }

    static func label(_ name: String) -> Label {
        var text = Substring(name)
        if let colon = text.lastIndex(where: { $0 == ":" || $0 == "|" }) { text = text[text.index(after: colon)...] }
        let characters = Array(text)
        var tokens: [String] = []
        var current = ""
        func close() {
            if !current.isEmpty { tokens.append(current.lowercased()) }
            current = ""
        }
        for (i, c) in characters.enumerated() {
            guard c.isLetter else { close(); continue }
            if c.isUppercase, !current.isEmpty {
                let before = characters[i - 1]
                let nextIsLower = i + 1 < characters.count && characters[i + 1].isLowercase
                if before.isLowercase || (before.isUppercase && nextIsLower) { close() }
            }
            current.append(c)
        }
        close()
        var label = Label()
        var kept: [String] = []
        for token in tokens {
            switch token {
            case "l", "left", "lf", "lt": if label.side == 0 { label.side = 1 } else { kept.append(token) }
            case "r", "right", "rt": if label.side == 0 { label.side = -1 } else { kept.append(token) }
            case "twist", "roll": label.twist = true
            case "ik", "pole", "nub", "end", "target", "ctrl", "control", "mch", "org", "helper", "effector": label.skip = true
            case "bip", "biped", "def", "bone", "jnt", "joint", "j", "b", "bn", "mixamorig", "rig", "bend", "character", "skeleton", "skel", "sk": break
            default: kept.append(token)
            }
        }
        var key = kept.joined()
        if label.side == 0 {
            for (word, side) in [("left", 1), ("right", -1)] where key.count > word.count {
                if key.hasPrefix(word) { key.removeFirst(word.count); label.side = side; break }
                if key.hasSuffix(word) { key.removeLast(word.count); label.side = side; break }
            }
        }
        label.key = key
        return label
    }

    static let forearmKeys: Set<String> = ["forearm", "lowerarm", "loarm", "lowarm", "armlower", "elbow", "forarm"]
    static let handKeys: Set<String> = ["hand", "wrist"]
    static let shinKeys: Set<String> = ["lowerleg", "loleg", "lowleg", "leglower", "calf", "shin", "knee"]
    static let footKeys: Set<String> = ["foot", "ankle"]

    /// Only the bones, each knowing its nearest bone above it.
    struct Skeleton {
        var node: [Int] = []  // bone to node index
        var parent: [Int] = []
        var kids: [[Int]] = []
        var position: [SIMD3<Float>] = []
        var labels: [Label] = []
        var depth: [Int] = []
        var low: Float = 0
        var height: Float = 0

        init?(_ nodes: [RigNode]) {
            var boneOf = [Int](repeating: -1, count: nodes.count)
            for (i, n) in nodes.enumerated() where n.isBone {
                boneOf[i] = node.count
                node.append(i)
            }
            guard node.count >= 9 else { return nil }
            for i in node {
                var p = nodes[i].parent
                var guardCount = 0
                while p >= 0, p < nodes.count, boneOf[p] < 0, guardCount < nodes.count { p = nodes[p].parent; guardCount += 1 }
                parent.append(p >= 0 && p < nodes.count ? boneOf[p] : -1)
                position.append(nodes[i].position)
                labels.append(RigFinder.label(nodes[i].name))
            }
            kids = [[Int]](repeating: [], count: node.count)
            for (i, p) in parent.enumerated() where p >= 0 && p != i { kids[p].append(i) }
            depth = [Int](repeating: 0, count: node.count)
            for i in 0..<node.count {
                var p = parent[i], d = 0
                while p >= 0, d <= node.count { p = parent[p]; d += 1 }
                guard d <= node.count else { return nil }  // a loop: not a skeleton
                depth[i] = d
            }
            let ys = position.map(\.y)
            low = ys.min() ?? 0
            height = (ys.max() ?? 0) - low
            guard height > 0.01 else { return nil }
        }

        func subtree(_ i: Int) -> [Int] {
            var out = [i], next = 0
            while next < out.count { out.append(contentsOf: kids[out[next]]); next += 1 }
            return out
        }
        func distance(_ a: Int, _ b: Int) -> Float { simd_distance(position[a], position[b]) }
        func ancestors(_ i: Int) -> [Int] {
            var out: [Int] = [], p = parent[i]
            while p >= 0 { out.append(p); p = parent[p] }
            return out
        }
        func isUnder(_ i: Int, _ top: Int) -> Bool { i == top || ancestors(i).contains(top) }
        func commonAncestor(_ a: Int, _ b: Int) -> Int? {
            let above = Set([a] + ancestors(a))
            return ([b] + ancestors(b)).first { above.contains($0) }
        }
        /// The bones from `top` (left out) down to `bottom` (included); empty when `bottom` is not under `top`.
        func path(from top: Int, to bottom: Int) -> [Int] {
            var out: [Int] = [], p = bottom
            while p >= 0, p != top { out.append(p); p = parent[p] }
            return p == top ? out.reversed() : []
        }
        /// Follows the best child each time until `stop` says so or the bones run out.
        func chain(_ root: Int, score: (Int) -> Float, stop: (Int) -> Bool) -> [Int] {
            var c = [root]
            while let last = c.last, !stop(last), let next = kids[last].max(by: { score($0) < score($1) }) { c.append(next) }
            return c
        }
        func lowest(_ i: Int) -> Float { subtree(i).map { position[$0].y }.min() ?? position[i].y }
        func highest(_ i: Int) -> Float { subtree(i).map { position[$0].y }.max() ?? position[i].y }
        /// The joint between two ends of a chain: the bone furthest from both.
        func middle(_ c: ArraySlice<Int>, from a: Int, to b: Int) -> Int? {
            c.max { min(distance(a, $0), distance($0, b)) < min(distance(a, $1), distance($1, b)) }
        }

        private func finish(hips: Int, chest: Int, arms: [[Int]], legs: [[Int]], head named: Int?, facing: Float, fromNames: Bool) -> RigMap? {
            guard arms.count == 2, legs.count == 2, Set(arms[0] + arms[1] + legs[0] + legs[1]).count == 12 else { return nil }
            let top = commonAncestor(hips, chest) ?? hips
            let spine = chest == top ? [] : path(from: top, to: chest).filter { $0 != hips }
            var neck: Int?, head = named
            if let h = head, h == chest || !isUnder(h, chest) { head = nil }
            if head == nil {
                // The chest's branch that climbs highest and is not an arm.
                let used = Set(arms.flatMap { [$0[0]] + ancestors($0[0]) })
                let ups = kids[chest].filter { !used.contains($0) }
                if let k = ups.max(by: { highest($0) < highest($1) }), highest(k) > position[chest].y + 0.03 * height {
                    let c = chain(k, score: { highest($0) }, stop: { _ in false })
                    head = c.count >= 3 ? c[c.count - 2] : c[c.count - 1]
                }
            }
            if let head {
                let way = path(from: chest, to: head)
                if let first = way.first, first != head { neck = first }
            }
            func nodes(_ list: [Int]) -> [Int] { list.map { node[$0] } }
            return RigMap(hips: node[hips], spine: nodes(spine), neck: neck.map { node[$0] }, head: head.map { node[$0] },
                          armL: nodes(arms[0]), armR: nodes(arms[1]), legL: nodes(legs[0]), legR: nodes(legs[1]),
                          facing: facing, fromNames: fromNames)
        }

        // MARK: Names

        func byNames() -> RigMap? {
            func find(_ keys: Set<String>, side: Int) -> Int? {
                var best: Int?
                for i in 0..<node.count where labels[i].side == side && !labels[i].skip && !labels[i].twist && keys.contains(labels[i].key) {
                    if best == nil || depth[i] < depth[best!] { best = i }
                }
                return best
            }
            /// The bone above, past any twist bones in between, and up to the first piece of a limb made of several.
            func above(_ i: Int) -> Int? {
                var p = parent[i]
                while p >= 0, labels[p].twist || (labels[p].key == labels[i].key && labels[p].side == labels[i].side) { p = parent[p] }
                guard p >= 0 else { return nil }
                while parent[p] >= 0, labels[parent[p]].key == labels[p].key, labels[parent[p]].side == labels[p].side, !labels[p].key.isEmpty { p = parent[p] }
                return p
            }
            func below(_ i: Int, keys: Set<String>, side: Int) -> Int? {
                if let named = find(keys, side: side), named != i, isUnder(named, i) { return named }
                // No name: the next real bone down the limb.
                let c = chain(i, score: { Float(subtree($0).count) }, stop: { $0 != i && !labels[$0].twist })
                return c.count > 1 ? c.last : nil
            }
            var arms: [[Int]] = [], legs: [[Int]] = []
            for side in [1, -1] {
                guard let fore = find(RigFinder.forearmKeys, side: side), let upper = above(fore),
                      let hand = below(fore, keys: RigFinder.handKeys, side: side) else { return nil }
                arms.append([upper, fore, hand])
                // "Leg" alone is the shin where there is also a thigh or an upper leg (Mixamo), else it is unclear.
                var shin = find(RigFinder.shinKeys, side: side)
                if shin == nil, let leg = find(["leg"], side: side), let over = above(leg),
                   ["thigh", "upleg", "upperleg", "legupper", "hip"].contains(labels[over].key) { shin = leg }
                guard let shin, let thigh = above(shin), let foot = below(shin, keys: RigFinder.footKeys, side: side) else { return nil }
                legs.append([thigh, shin, foot])
            }
            guard arms[0][0] != arms[1][0], legs[0][0] != legs[1][0],
                  let chest = commonAncestor(arms[0][0], arms[1][0]), let hips = commonAncestor(legs[0][0], legs[1][0]),
                  chest != arms[0][0], chest != arms[1][0], hips != legs[0][0], hips != legs[1][0] else { return nil }
            var head: Int?
            for i in 0..<node.count where labels[i].key == "head" && !labels[i].skip && labels[i].side == 0 {
                if head == nil || depth[i] < depth[head!] { head = i }
            }
            let facing: Float = position[arms[0][0]].x >= position[arms[1][0]].x ? 1 : -1
            return finish(hips: hips, chest: chest, arms: arms, legs: legs, head: head, facing: facing, fromNames: true)
        }

        // MARK: Shape

        func byShape() -> RigMap? {
            let n = node.count
            let floor = low + 0.15 * height
            // Hips: the deepest bone with two branches that reach the floor.
            var hips = -1
            var legRoots: [Int] = []
            for i in 0..<n {
                let down = kids[i].filter { lowest($0) < floor }
                if down.count >= 2, hips < 0 || depth[i] > depth[hips] { hips = i; legRoots = down }
            }
            guard hips >= 0 else { return nil }
            legRoots = Array(legRoots.sorted { lowest($0) < lowest($1) }.prefix(2))
            var legs: [[Int]] = []
            var toes: Float = 0
            for root in legRoots {
                let c = chain(root, score: { -lowest($0) }, stop: { position[$0].y < low + 0.1 * height && $0 != root })
                guard c.count >= 3, let foot = c.last, let knee = middle(c[1..<(c.count - 1)], from: c[0], to: foot) else { return nil }
                if let toe = kids[foot].max(by: { abs(position[$0].z - position[foot].z) < abs(position[$1].z - position[foot].z) }) {
                    toes += position[toe].z - position[foot].z
                }
                legs.append([c[0], knee, foot])
            }
            // Chest: the deepest bone at or above the hips with a branch reaching out to each side.
            let centre = position[hips].x
            func reach(_ k: Int, _ side: Float) -> Float { subtree(k).map { side * (position[$0].x - centre) }.max() ?? 0 }
            func span(_ i: Int, _ k: Int) -> Float { subtree(k).map { distance(i, $0) }.max() ?? 0 }
            var chest = -1, left = -1, right = -1
            for i in 0..<n where position[i].y >= position[hips].y {
                func branches(_ side: Float) -> [Int] {
                    kids[i].filter { k in
                        !legRoots.contains(k) && (reach(k, side) > 0.2 * height || (span(i, k) > 0.3 * height && reach(k, side) > 0.05 * height))
                    }
                }
                let l = branches(1), r = branches(-1)
                guard let a = l.max(by: { reach($0, 1) < reach($1, 1) }), let b = r.max(by: { reach($0, -1) < reach($1, -1) }), a != b,
                      i != hips || kids[i].count >= 5 else { continue }
                if chest < 0 || depth[i] > depth[chest] { chest = i; left = a; right = b }
            }
            guard chest >= 0 else { return nil }
            var arms: [[Int]] = []
            for root in [left, right] {
                // Out along the arm to the hand, the bone the fingers spread from (or the last bone, with no fingers).
                let c = chain(root, score: { span(chest, $0) }, stop: { kids[$0].count >= 3 })
                guard let hand = c.last else { return nil }
                // A collar bone first: short next to the arm, and starting near the spine.
                var first = 0
                if c.count >= 4 {
                    var rest: Float = 0
                    for j in 1..<(c.count - 1) { rest += distance(c[j], c[j + 1]) }
                    let nearSpine = abs(position[c[0]].x - position[chest].x) < 0.6 * abs(position[c[1]].x - position[chest].x)
                    if distance(c[0], c[1]) < 0.3 * rest, nearSpine { first = 1 }
                }
                guard c.count - first >= 3, let elbow = middle(c[(first + 1)..<(c.count - 1)], from: c[first], to: hand) else { return nil }
                arms.append([c[first], elbow, hand])
            }
            let facing: Float = toes >= 0 ? 1 : -1
            if (position[legs[0][0]].x - position[legs[1][0]].x) * facing < 0 { legs.swapAt(0, 1) }
            if (position[arms[0][0]].x - position[arms[1][0]].x) * facing < 0 { arms.swapAt(0, 1) }
            return finish(hips: hips, chest: chest, arms: arms, legs: legs, head: nil, facing: facing, fromNames: false)
        }
    }
}

/// Poses an imported character with the same angles as the example mannequins (MannequinPose): each mapped bone
/// is turned from where it rests to where the mannequin's would point, so any rest pose (T or A) works.
struct RigPoser {
    let nodes: [RigNode]
    let map: RigMap
    /// The mannequin angles nearest to how the character rests in its file.
    let restPose: MannequinPose
    private let order: [Int]  // parents before children
    private let armFrames: [[simd_quatf]]  // per side: upper, lower, as the mannequin would hold them at rest
    private let legFrames: [[simd_quatf]]

    private static func turn(_ degrees: Float, _ axis: SIMD3<Float>) -> simd_quatf { simd_quatf(angle: degrees * .pi / 180, axis: axis) }
    private static let x = SIMD3<Float>(1, 0, 0), y = SIMD3<Float>(0, 1, 0), z = SIMD3<Float>(0, 0, 1)

    /// The mannequin joint that points a limb hanging down (-Y) along `direction`: out (z) then forward (x), in degrees.
    static func angles(_ direction: SIMD3<Float>) -> (z: Float, x: Float) {
        let d = simd_length(direction) > 1e-6 ? simd_normalize(direction) : SIMD3(0, -1, 0)
        let forward = asin(max(-1, min(1, -d.z)))
        let out = abs(d.x) < 1e-5 && abs(d.y) < 1e-5 ? 0 : atan2(d.x, -d.y)
        return (out * 180 / .pi, forward * 180 / .pi)
    }

    init(nodes: [RigNode], map: RigMap) {
        self.nodes = nodes
        self.map = map
        var depth = [Int](repeating: 0, count: nodes.count)
        for i in 0..<nodes.count {
            var p = nodes[i].parent, d = 0
            while p >= 0, p < nodes.count, d <= nodes.count { p = nodes[p].parent; d += 1 }
            depth[i] = d
        }
        order = (0..<nodes.count).sorted { depth[$0] < depth[$1] }
        let facing = map.facing
        // Directions as the mannequin sees them: facing +Z with its left at +X.
        func direction(_ a: Int, _ b: Int) -> SIMD3<Float> {
            let d = nodes[b].position - nodes[a].position
            return facing < 0 ? SIMD3(-d.x, d.y, -d.z) : d
        }
        func bend(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            guard simd_length(a) > 1e-6, simd_length(b) > 1e-6 else { return 0 }
            let angle = acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
            return angle < 5 ? 0 : angle
        }
        var pose = MannequinPose()
        var armFrames: [[simd_quatf]] = [], legFrames: [[simd_quatf]] = []
        for (index, limb) in [map.armL, map.armR].enumerated() {
            let side: Float = index == 0 ? 1 : -1
            let upper = direction(limb[0], limb[1]), lower = direction(limb[1], limb[2])
            let a = Self.angles(upper), b = Self.angles(lower)
            armFrames.append([Self.turn(a.z, Self.z) * Self.turn(a.x, Self.x), Self.turn(b.z, Self.z) * Self.turn(b.x, Self.x)])
            let arm = MannequinPose.Arm(out: side * a.z, forward: -a.x, inward: 0, elbow: bend(upper, lower))
            if index == 0 { pose.left = arm } else { pose.right = arm }
        }
        for (index, limb) in [map.legL, map.legR].enumerated() {
            let side: Float = index == 0 ? 1 : -1
            let upper = direction(limb[0], limb[1]), lower = direction(limb[1], limb[2])
            let a = Self.angles(upper), b = Self.angles(lower)
            legFrames.append([Self.turn(a.z, Self.z) * Self.turn(a.x, Self.x), Self.turn(b.z, Self.z) * Self.turn(b.x, Self.x)])
            let leg = MannequinPose.Leg(out: side * a.z, forward: -a.x, inward: 0, knee: bend(upper, lower))
            if index == 0 { pose.leftLeg = leg } else { pose.rightLeg = leg }
        }
        restPose = pose
        self.armFrames = armFrames
        self.legFrames = legFrames
    }

    /// How far each mapped bone turns from rest, in the model's own space.
    func turns(for pose: MannequinPose) -> [Int: simd_quatf] {
        let identity = simd_quatf(angle: 0, axis: Self.y)
        var out: [Int: simd_quatf] = [:]
        let spine = map.spine.isEmpty ? identity : Self.turn(pose.spineSide, Self.z) * Self.turn(pose.spineForward, Self.x)
        for (k, bone) in map.spine.enumerated() {
            out[bone] = simd_slerp(identity, spine, Float(k + 1) / Float(map.spine.count))
        }
        let look = Self.turn(pose.headDown, Self.x) * Self.turn(pose.headTurn, Self.y)
        if let head = map.head {
            out[head] = spine * look
            if let neck = map.neck { out[neck] = spine * simd_slerp(identity, look, 0.5) }
        }
        for (index, arm) in [pose.left, pose.right].enumerated() {
            let side: Float = index == 0 ? 1 : -1
            let limb = index == 0 ? map.armL : map.armR
            let upper = spine * Self.turn(side * arm.out, Self.z) * Self.turn(-arm.forward, Self.x) * Self.turn(-side * arm.inward, Self.y)
            out[limb[0]] = upper * armFrames[index][0].inverse
            out[limb[1]] = upper * Self.turn(-arm.elbow, Self.x) * armFrames[index][1].inverse
        }
        for (index, leg) in [pose.leftLeg, pose.rightLeg].enumerated() {
            let side: Float = index == 0 ? 1 : -1
            let limb = index == 0 ? map.legL : map.legR
            let upper = Self.turn(side * leg.out, Self.z) * Self.turn(-leg.forward, Self.x) * Self.turn(-side * leg.inward, Self.y)
            out[limb[0]] = upper * legFrames[index][0].inverse
            out[limb[1]] = upper * Self.turn(leg.knee, Self.x) * legFrames[index][1].inverse
        }
        if map.facing < 0 {
            // The character faces the other way in its file: the same turns, seen from behind.
            let about = simd_quatf(angle: .pi, axis: Self.y)
            for (bone, turn) in out { out[bone] = about * turn * about.inverse }
        }
        return out
    }

    /// Every node's place in the model for a pose (nil: as the file rests), and how far to lift the whole
    /// figure so its lowest bone is as low as it was at rest (feet stay on the floor when it sits or kneels).
    func worlds(for pose: MannequinPose?) -> (worlds: [simd_float4x4], lift: Float) {
        guard let pose else { return (nodes.map(\.world), 0) }
        let byBone = turns(for: pose)
        var worlds = nodes.map(\.world)
        for i in order {
            let parent = nodes[i].parent
            guard parent >= 0, parent < nodes.count else { continue }
            var world = worlds[parent] * nodes[i].local
            if let turn = byBone[i] {
                var rest = nodes[i].world
                rest.columns.3 = SIMD4(0, 0, 0, 1)
                var turned = simd_float4x4(turn) * rest
                turned.columns.3 = world.columns.3
                world = turned
            }
            worlds[i] = world
        }
        var restLow = Float.greatestFiniteMagnitude, low = Float.greatestFiniteMagnitude
        for i in 0..<nodes.count where nodes[i].isBone {
            restLow = min(restLow, nodes[i].world.columns.3.y)
            low = min(low, worlds[i].columns.3.y)
        }
        return (worlds, restLow < .greatestFiniteMagnitude ? restLow - low : 0)
    }

    /// Node-to-parent for every node, to set on the scene's nodes.
    func locals(for pose: MannequinPose?) -> (locals: [simd_float4x4], lift: Float) {
        guard pose != nil else { return (nodes.map(\.local), 0) }
        let posed = worlds(for: pose)
        var locals = nodes.map(\.local)
        for i in 0..<nodes.count {
            let parent = nodes[i].parent
            guard parent >= 0, parent < nodes.count else { continue }
            locals[i] = posed.worlds[parent].inverse * posed.worlds[i]
        }
        return (locals, posed.lift)
    }
}
