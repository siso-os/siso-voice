import MetalKit
import simd

extension OrbRenderer {
    // MARK: Geometry

    func buildWebGeometry() {
        nodes.removeAll(keepingCapacity: true)
        nodeDirs.removeAll(keepingCapacity: true)
        nodeHeat.removeAll(keepingCapacity: true)
        nodeCluster.removeAll(keepingCapacity: true)
        nodeLayers.removeAll(keepingCapacity: true)
        edges.removeAll(keepingCapacity: true)

        let golden = Float.pi * (3 - sqrt(Float(5)))
        var seen = Set<Int64>()

        let continents: [Continent] = [
            Continent(c: normalize(SIMD3<Float>(-0.52,  0.42,  0.74)), spread: 0.34, weight: 1.20, count: 230, elong: 1.85, phase: 0.20),
            Continent(c: normalize(SIMD3<Float>( 0.03, -0.02,  1.00)), spread: 0.40, weight: 1.36, count: 430, elong: 2.10, phase: 1.50),
            Continent(c: normalize(SIMD3<Float>( 0.61,  0.45,  0.65)), spread: 0.32, weight: 1.08, count: 220, elong: 1.52, phase: 2.40),
            Continent(c: normalize(SIMD3<Float>(-0.88, -0.04,  0.37)), spread: 0.30, weight: 1.00, count: 155, elong: 1.42, phase: 0.90),
            Continent(c: normalize(SIMD3<Float>( 0.62, -0.63,  0.47)), spread: 0.31, weight: 0.98, count: 175, elong: 1.62, phase: 2.85),
            Continent(c: normalize(SIMD3<Float>(-0.18,  0.84, -0.52)), spread: 0.32, weight: 0.88, count: 105, elong: 1.42, phase: 1.15),
            Continent(c: normalize(SIMD3<Float>( 0.82,  0.04, -0.57)), spread: 0.31, weight: 0.86, count: 95, elong: 1.38, phase: 2.05),
            Continent(c: normalize(SIMD3<Float>(-0.44, -0.76, -0.48)), spread: 0.30, weight: 0.84, count: 90, elong: 1.55, phase: 0.45),
            Continent(c: normalize(SIMD3<Float>( 0.04,  0.02, -1.00)), spread: 0.38, weight: 1.02, count: 270, elong: 1.85, phase: 1.80),
            Continent(c: normalize(SIMD3<Float>(-0.04,  0.78,  0.56)), spread: 0.28, weight: 1.10, count: 180, elong: 2.15, phase: 2.70),
            Continent(c: normalize(SIMD3<Float>( 0.00, -0.58,  0.78)), spread: 0.29, weight: 1.06, count: 170, elong: 1.75, phase: 0.62),
        ]

        let basinSeeds: [SIMD3<Float>] = [
            normalize(SIMD3<Float>( 0.42,  0.24,  0.88)),
            normalize(SIMD3<Float>(-0.16, -0.52,  0.84)),
            normalize(SIMD3<Float>( 0.30,  0.82,  0.49)),
            normalize(SIMD3<Float>(-0.78,  0.28, -0.56)),
            normalize(SIMD3<Float>( 0.34, -0.58, -0.74)),
        ]

        func continentField(_ dir: SIMD3<Float>) -> (land: Float, id: Int, basin: Float) {
            var best: Float = 0
            var bestId = -1
            var sum: Float = 0
            for ci in 0..<continents.count {
                let c = continents[ci]
                let ang = acos(clampF(-1, 1, dot(dir, c.c)))
                let v = c.weight * exp(-(ang * ang) / (c.spread * c.spread))
                sum += v * 0.32
                if v > best {
                    best = v
                    bestId = ci
                }
            }

            var basin: Float = 0
            for bi in 0..<basinSeeds.count {
                let width = Float(0.28 + hash(bi * 97 + 11) * 0.16)
                let ang = acos(clampF(-1, 1, dot(dir, basinSeeds[bi])))
                basin = max(basin, exp(-(ang * ang) / (width * width)))
            }

            let coastline = (fbm(dir * 4.6 + SIMD3<Float>(9, 21, 4)) - 0.5) * 0.32
            let land = smoothstep(0.24, 0.88, best + sum + coastline - basin * 0.48)
            return (sat(land), bestId, sat(basin))
        }

        func canPlace(_ dir: SIMD3<Float>, _ minSep: Float) -> Bool {
            let minD2 = minSep * minSep
            for existing in nodeDirs {
                if distance_squared(existing, dir) < minD2 { return false }
            }
            return true
        }

        @discardableResult
        func appendNode(_ p: SIMD3<Float>, dir: SIMD3<Float>, heat: Float, cluster: Int, layer: OrbLayer) -> Int {
            nodes.append(p)
            nodeDirs.append(normalize(dir))
            nodeHeat.append(heat)
            nodeCluster.append(cluster)
            nodeLayers.append(layer)
            return nodes.count - 1
        }

        func addNode(_ dirInput: SIMD3<Float>, _ heatInput: Float, _ clusterId: Int, _ salt: Int, _ minSep: Float) {
            let dir = normalize(dirInput)
            if !canPlace(dir, minSep) { return }

            let f = continentField(dir)
            let assignedCluster = clusterId >= 0 ? clusterId : (f.land > 0.40 ? f.id : -1)
            let screenCenter = exp(-((dir.x * dir.x + dir.y * dir.y) / 0.18))
            let heat = sat(0.14 + heatInput * 0.70 + f.land * 0.18 + screenCenter * 0.16)
            let relief = fbm(dir * 5.8 + SIMD3<Float>(13, 31, 9)) * 2 - 1
            let shelf = fbm(dir * 2.2 + SIMD3<Float>(44, 6, 17)) * 2 - 1
            let micro = (hash(salt * 92821 + 17) * 2 - 1) * 0.026
            let radius = clampF(0.84, 1.11, 0.925 + heat * 0.145 + relief * 0.045 + shelf * 0.025 - f.basin * 0.060 + micro)

            appendNode(dir * radius, dir: dir, heat: heat, cluster: assignedCluster, layer: .shell)
        }

        @discardableResult
        func addEdge(_ a: Int, _ b: Int, _ energy: Float, layer: OrbLayer = .shell, crawl: Float = 1.0) -> Bool {
            if a == b { return false }
            let lo = min(a, b)
            let hi = max(a, b)
            let key = Int64(lo) * 100_000 + Int64(hi)
            if seen.contains(key) { return false }
            seen.insert(key)
            let phase = hash(lo * 73_856_093 + hi * 19_349_663 + layer.rawValue * 83_492_791)
            let tunedEnergy: Float
            switch layer {
            case .shell: tunedEnergy = min(0.62, energy * 0.76 + 0.010)
            case .haze: tunedEnergy = min(0.34, energy * 0.82 + 0.006)
            case .ring: tunedEnergy = min(1.0, energy)
            case .inner: tunedEnergy = min(0.80, energy * 0.88)
            case .lightning: tunedEnergy = min(1.0, energy)
            }
            edges.append(EdgeRecord(a: lo, b: hi, energy: clampF(0.045, 1.0, tunedEnergy), layer: layer, crawl: crawl, phase: phase))
            return true
        }

        for ci in 0..<continents.count {
            let c = continents[ci]
            let (t1, t2) = tangentBasis(c.c)
            for k in 0..<c.count {
                let u = hash(ci * 10007 + k * 37 + 3)
                let armCount = 5 + Int(hash(ci * 313 + 17) * 4)
                let arm = k % armCount
                let armAngle = (Float(arm) / Float(armCount)) * Float.pi * 2 + c.phase + (hash(ci * 3001 + k * 19) - 0.5) * 0.42
                let along = pow(hash(ci * 701 + k * 29 + 5), 0.68) * c.spread * (0.36 + hash(ci * 53 + arm * 11) * 0.76)
                let across = (hash(ci * 811 + k * 23 + 2) - 0.5) * c.spread * 0.18
                let diskAngle = golden * Float(k) + c.phase + (hash(ci * 2609 + k * 31) - 0.5) * 0.30
                let diskRad = sqrt(u) * c.spread * (0.22 + pow(hash(ci * 991 + k * 7), 1.7) * 0.80)
                let armMode = hash(ci * 4003 + k * 31 + 9) < 0.76
                let dx = armMode
                    ? (cos(armAngle) * along * c.elong + cos(armAngle + Float.pi * 0.5) * across)
                    : (cos(diskAngle) * diskRad * c.elong)
                let dy = armMode
                    ? (sin(armAngle) * along / max(0.62, c.elong) + sin(armAngle + Float.pi * 0.5) * across)
                    : (sin(diskAngle) * diskRad / max(0.62, c.elong))
                let angularRadius = sqrt(dx * dx + dy * dy)
                let wrinkle = (fbm(c.c * 2.0 + SIMD3<Float>(Float(k) * 0.07, Float(ci) * 0.19, 4.0)) - 0.5) * c.spread * 0.18
                let dir = normalize(c.c + t1 * (dx + wrinkle) + t2 * (dy - wrinkle * 0.45))
                let core = exp(-(angularRadius * angularRadius) / max(c.spread * c.spread * 0.30, 1e-4))
                let heat = sat(0.48 + core * 0.42 + c.weight * 0.12)
                addNode(dir, heat, ci, ci * 1000 + k, 0.0085 + (1 - core) * 0.0105)
            }
        }

        let candidateCount = 5200
        for ci in 0..<candidateCount {
            let y = 1 - (Float(ci) / Float(candidateCount - 1)) * 2
            let r = sqrt(max(0, 1 - y * y))
            let th = golden * Float(ci)
            var dir = SIMD3<Float>(cos(th) * r, y, sin(th) * r)
            dir = normalize(dir + SIMD3<Float>(hash(ci) * 2 - 1, hash(ci + 7) * 2 - 1, hash(ci + 13) * 2 - 1) * 0.045)

            let f = continentField(dir)
            let lace = fbm(dir * 8.0 + SIMD3<Float>(2, 15, 33))
            let screenCenter = exp(-((dir.x * dir.x + dir.y * dir.y) / 0.20))
            let keepProb = clampF(0.07, 0.62, 0.082 + f.land * 0.32 + lace * 0.095 - f.basin * 0.080 + screenCenter * 0.16)
            if hash(ci * 977 + 3) > keepProb { continue }
            let heat = sat(0.16 + f.land * 0.64 + lace * 0.14 + screenCenter * 0.18)
            let sep = 0.034 - f.land * 0.018 - screenCenter * 0.009
            addNode(dir, heat, -1, ci + 7000, sep)
        }
        baseShellNodeCount = nodes.count

        for i in 0..<baseShellNodeCount {
            var dists: [(j: Int, score: Float, chord: Float)] = []
            dists.reserveCapacity(max(0, baseShellNodeCount - 1))
            for j in 0..<baseShellNodeCount where j != i {
                let same = nodeCluster[i] >= 0 && nodeCluster[i] == nodeCluster[j]
                let heatAvg = (nodeHeat[i] + nodeHeat[j]) * 0.5
                let chord = distance(nodeDirs[i], nodeDirs[j])
                let reliefStep = abs(length(nodes[i]) - length(nodes[j]))
                let score = chord * (same ? 0.46 : 1.0) + reliefStep * 0.34 - heatAvg * (same ? 0.040 : 0.012)
                dists.append((j, score, chord))
            }
            dists.sort { $0.score < $1.score }

            let desired = nodeHeat[i] > 0.82 ? 7 : (nodeHeat[i] > 0.62 ? 5 : (nodeHeat[i] > 0.38 ? 3 : 2))
            var kept = 0
            for cand in dists {
                if kept >= desired { break }
                let j = cand.j
                let same = nodeCluster[i] >= 0 && nodeCluster[i] == nodeCluster[j]
                let heatAvg = (nodeHeat[i] + nodeHeat[j]) * 0.5
                let maxChord: Float = same ? 0.125 : (heatAvg > 0.58 ? 0.108 : 0.092)
                if cand.chord > maxChord && !(kept == 0 && cand.chord < maxChord * 1.35) { continue }

                let midSum = nodeDirs[i] + nodeDirs[j]
                let mid = length(midSum) > 0.001 ? normalize(midSum) : nodeDirs[i]
                let f = continentField(mid)
                let keep = clampF(0.14, 0.94, (same ? 0.76 : 0.20) + heatAvg * 0.21 - cand.chord * 1.18 - f.basin * 0.46)
                if hash(i * 4099 + j * 131 + 5) > keep { continue }

                let ridge: Float = same && hash(i * 211 + j * 17) > 0.70 ? 0.12 : 0
                let e = 0.08 + heatAvg * 0.32 + (same ? 0.06 : -0.045) + ridge * 0.55 + hash(i * 31 + j * 7) * 0.045
                if addEdge(i, j, e) { kept += 1 }
            }
        }

        var clusterMembers = Array(repeating: [Int](), count: continents.count)
        for i in 0..<baseShellNodeCount where nodeCluster[i] >= 0 && nodeCluster[i] < continents.count {
            clusterMembers[nodeCluster[i]].append(i)
        }

        func pickHotMember(_ members: [Int], _ salt: Int) -> Int? {
            if members.isEmpty { return nil }
            var best = members[0]
            var bestScore: Float = -1
            for t in 0..<9 {
                let p = min(members.count - 1, Int(hash(salt * 97 + t * 13) * Float(members.count)))
                let idx = members[p]
                let score = nodeHeat[idx] + hash(idx * 53 + salt * 17) * 0.18
                if score > bestScore {
                    bestScore = score
                    best = idx
                }
            }
            return best
        }

        func slerpDir(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
            let d = clampF(-1, 1, dot(a, b))
            let theta = acos(d)
            if theta < 0.001 { return normalize(a + (b - a) * t) }
            let s = sin(theta)
            return normalize(a * (sin((1 - t) * theta) / s) + b * (sin(t * theta) / s))
        }

        func bridgeWaypoint(_ target: SIMD3<Float>, _ ca: Int, _ cb: Int, _ salt: Int, _ used: Set<Int>) -> Int? {
            var best = -1
            var bestScore: Float = -999
            for i in 0..<baseShellNodeCount {
                if used.contains(i) { continue }
                let chord = distance(nodeDirs[i], target)
                if chord > 0.14 { continue }
                let preferred = nodeCluster[i] == ca || nodeCluster[i] == cb
                let score = -chord * 7.5 + nodeHeat[i] * 0.80 + (preferred ? 0.12 : 0) + hash(i * 97 + salt * 17) * 0.05
                if score > bestScore {
                    bestScore = score
                    best = i
                }
            }
            return best >= 0 ? best : nil
        }

        func addRoutedBridge(_ a: Int, _ b: Int, _ ca: Int, _ cb: Int, _ energy: Float, _ salt: Int) {
            let theta = acos(clampF(-1, 1, dot(nodeDirs[a], nodeDirs[b])))
            let steps = max(3, min(9, Int(ceil(theta / 0.17))))
            var path = [a]
            var used = Set<Int>()
            used.insert(a)
            used.insert(b)
            let bendAxisRaw = cross(nodeDirs[a], nodeDirs[b])
            let bendAxis = length(bendAxisRaw) > 0.001 ? normalize(bendAxisRaw) : SIMD3<Float>(0, 1, 0)
            for s in 1..<steps {
                let t = Float(s) / Float(steps)
                let base = slerpDir(nodeDirs[a], nodeDirs[b], t)
                let side = normalize(cross(bendAxis, base))
                let wobble = (hash(salt * 313 + s * 29) - 0.5) * 0.055
                let target = normalize(base + side * wobble)
                if let idx = bridgeWaypoint(target, ca, cb, salt + s * 23, used) {
                    path.append(idx)
                    used.insert(idx)
                }
            }
            path.append(b)

            for k in 0..<(path.count - 1) {
                let p = path[k]
                let q = path[k + 1]
                let chord = distance(nodeDirs[p], nodeDirs[q])
                if chord > 0.145 { continue }
                let segmentEnergy = energy * (0.88 + hash(salt * 41 + k * 17) * 0.14)
                addEdge(p, q, segmentEnergy)
            }
        }

        let bridgePairs: [(Int, Int)] = [
            (0, 1), (0, 2), (1, 4), (2, 3), (3, 5), (4, 6),
            (1, 9), (4, 10), (8, 6),
        ]
        for pi in 0..<bridgePairs.count {
            let (ca, cb) = bridgePairs[pi]
            guard let a = pickHotMember(clusterMembers[ca], pi * 100 + 1),
                  let b = pickHotMember(clusterMembers[cb], pi * 100 + 19) else { continue }
            let d = distance(nodeDirs[a], nodeDirs[b])
            if d < 0.36 || d > 1.72 { continue }
            let e = 0.54 + (nodeHeat[a] + nodeHeat[b]) * 0.08 + hash(pi * 71 + 13) * 0.05
            addRoutedBridge(a, b, ca, cb, e, pi * 101 + 7)
        }

        let hazeNodeStart = nodes.count
        let hazeCandidates = 1500
        var hazeIDs: [Int] = []
        hazeIDs.reserveCapacity(900)
        for i in 0..<hazeCandidates {
            let y = 1 - (Float(i) / Float(hazeCandidates - 1)) * 2
            let r = sqrt(max(0, 1 - y * y))
            let th = golden * Float(i) + hash(i * 313 + 9) * 0.18
            var dir = SIMD3<Float>(cos(th) * r, y, sin(th) * r)
            dir = normalize(dir + SIMD3<Float>(hash(i * 17) * 2 - 1, hash(i * 19 + 5) * 2 - 1, hash(i * 23 + 11) * 2 - 1) * 0.026)

            let f = continentField(dir)
            let lace = fbm(dir * 9.7 + SIMD3<Float>(31, 4, 18))
            let voidBias = 1 - f.land
            let keepProb = clampF(0.12, 0.78, 0.18 + voidBias * 0.43 + f.basin * 0.18 + lace * 0.10)
            if hash(i * 1427 + 17) > keepProb { continue }

            let shellish = hash(i * 3217 + 29) < 0.58
            let radius = shellish
                ? (0.83 + pow(hash(i * 701 + 3), 0.42) * 0.195)
                : (0.55 + pow(hash(i * 709 + 7), 0.62) * 0.34)
            let heat = clampF(0.045, 0.22, 0.050 + voidBias * 0.065 + lace * 0.040 + (shellish ? 0.020 : 0.0))
            hazeIDs.append(appendNode(dir * radius, dir: dir, heat: heat, cluster: -5, layer: .haze))
        }

        var hazeEdges = 0
        for localI in 0..<hazeIDs.count {
            let i = hazeIDs[localI]
            var dists: [(j: Int, score: Float, chord: Float)] = []
            dists.reserveCapacity(min(nodes.count, 180))

            for localJ in 0..<hazeIDs.count where localJ != localI {
                let j = hazeIDs[localJ]
                let chord = distance(nodeDirs[i], nodeDirs[j])
                if chord > 0.205 { continue }
                let radialStep = abs(length(nodes[i]) - length(nodes[j]))
                dists.append((j, chord + radialStep * 1.15 + hash(i * 53 + j * 11) * 0.012, chord))
            }

            for t in 0..<18 {
                let j = Int(hash(i * 811 + t * 97) * Float(baseShellNodeCount))
                let chord = distance(nodeDirs[i], nodeDirs[j])
                if chord > 0.185 { continue }
                let radialStep = abs(length(nodes[i]) - length(nodes[j]))
                let landPenalty: Float = nodeCluster[j] >= 0 ? 0.040 : 0
                dists.append((j, chord + radialStep * 1.35 + landPenalty + hash(i * 41 + j * 29) * 0.010, chord))
            }

            dists.sort { $0.score < $1.score }
            let desired = hash(i * 97 + 7) < 0.44 ? 2 : 3
            var kept = 0
            for cand in dists {
                if kept >= desired { break }
                if cand.chord > 0.210 { continue }
                let j = cand.j
                let energy = 0.050 + (nodeHeat[i] + nodeHeat[j]) * 0.105 + hash(i * 137 + j * 31) * 0.018
                if addEdge(i, j, energy, layer: .haze) {
                    hazeEdges += 1
                    kept += 1
                }
            }
        }
        hazeNodeCount = nodes.count - hazeNodeStart

        let ringNodeStart = nodes.count
        let ringNormal = normalize(SIMD3<Float>(0.24, -0.80, 0.55))
        let (ringBasisA, ringBasisB) = tangentBasis(ringNormal)
        let ringBasisSpin: Float = 0.34
        let ringU = normalize(ringBasisA * cos(ringBasisSpin) + ringBasisB * sin(ringBasisSpin))
        let ringV = normalize(cross(ringNormal, ringU))
        let ringSegments = 192
        let ringLanes = 8
        let ringTubeRadius: Float = 0.056
        let ringRadius: Float = 1.020
        let ringActiveCenter: Float = 4.44
        let ringActiveHalfWidth = Float.pi * 0.20
        let twoPi = Float.pi * 2

        func angleDistance(_ a: Float, _ b: Float) -> Float {
            abs(atan2(sin(a - b), cos(a - b)))
        }

        func ringPoint(theta: Float, laneOffset: Float, salt: Int) -> SIMD3<Float> {
            let base = normalize(ringU * cos(theta) + ringV * sin(theta))
            let tangent = normalize(ringU * -sin(theta) + ringV * cos(theta))
            let weave = (hash(salt * 7919 + 43) - 0.5) * 0.006
            let lane = laneOffset + (hash(salt * 4153 + 7) - 0.5) * 0.005
            let dir = normalize(base + ringNormal * lane + tangent * weave)
            let r = ringRadius + (hash(salt * 2221 + 17) - 0.5) * 0.010
            return dir * r
        }

        var ringNodeIDs = Array(repeating: Array(repeating: -1, count: ringSegments), count: ringLanes)
        for lane in 0..<ringLanes {
            let laneT = ringLanes == 1 ? Float(0) : Float(lane) / Float(ringLanes - 1)
            let laneOffset = (laneT - 0.5) * ringTubeRadius
            for s in 0..<ringSegments {
                let theta = (Float(s) / Float(ringSegments)) * twoPi
                let p = ringPoint(theta: theta, laneOffset: laneOffset, salt: lane * 1000 + s)
                let active = 1 - smoothstep(ringActiveHalfWidth * 0.72, ringActiveHalfWidth, angleDistance(theta, ringActiveCenter))
                let front = smoothstep(-0.26, 0.78, dot(normalize(p), SIMD3<Float>(0, 0, 1)))
                let heat = sat(0.14 + front * 0.12 + active * (0.58 + front * 0.16))
                ringNodeIDs[lane][s] = nodes.count
                appendNode(p, dir: p, heat: heat, cluster: -2, layer: .ring)
            }
        }

        var ringEdges = 0
        var hotRingEdges = 0
        for lane in 0..<ringLanes {
            for s in 0..<ringSegments {
                let next = (s + 1) % ringSegments
                let thetaMid = ((Float(s) + 0.5) / Float(ringSegments)) * twoPi
                let active = 1 - smoothstep(ringActiveHalfWidth * 0.72, ringActiveHalfWidth, angleDistance(thetaMid, ringActiveCenter))
                let front = smoothstep(-0.28, 0.76, dot(nodeDirs[ringNodeIDs[lane][s]], SIMD3<Float>(0, 0, 1)))
                let dash = (s + lane * 3) % 11
                let segmentBody = dash <= 7
                let microGap = hash(lane * 12011 + s * 97 + 5) > (active > 0.12 ? 0.035 : 0.18)
                let keep = (segmentBody || active > 0.18) && microGap
                if keep {
                    let body = 0.24 + front * 0.12
                    let hot = active * (0.48 + front * 0.22)
                    let energy = body + hot + hash(lane * 997 + s * 17) * 0.035
                    if addEdge(ringNodeIDs[lane][s], ringNodeIDs[lane][next], energy, layer: .ring, crawl: max(0.05, active)) {
                        ringEdges += 1
                        if energy > 0.72 { hotRingEdges += 1 }
                    }
                }

                if lane + 1 < ringLanes && hash(lane * 1777 + s * 83 + 11) > (active > 0.16 ? 0.42 : 0.62) {
                    let crossNext = (s + (hash(lane * 53 + s * 19) > 0.5 ? 1 : 0)) % ringSegments
                    let energy = 0.18 + front * 0.10 + active * (0.50 + front * 0.16) + hash(lane * 409 + s * 23) * 0.045
                    if addEdge(ringNodeIDs[lane][s], ringNodeIDs[lane + 1][crossNext], energy, layer: .ring, crawl: max(0.05, active)) {
                        ringEdges += 1
                        if energy > 0.72 { hotRingEdges += 1 }
                    }
                }
            }
        }

        let ringBeads = 84
        for b in 0..<ringBeads {
            let theta = (Float(b) / Float(ringBeads)) * twoPi + (hash(b * 97 + 3) - 0.5) * 0.050
            let active = 1 - smoothstep(ringActiveHalfWidth * 0.65, ringActiveHalfWidth * 1.10, angleDistance(theta, ringActiveCenter))
            let laneOffset = (hash(b * 137 + 9) - 0.5) * ringTubeRadius * 1.20
            let p = ringPoint(theta: theta, laneOffset: laneOffset, salt: 50000 + b)
            let front = smoothstep(-0.25, 0.78, dot(normalize(p), SIMD3<Float>(0, 0, 1)))
            appendNode(p, dir: p, heat: sat(0.16 + front * 0.14 + active * 0.74), cluster: -3, layer: .ring)
        }
        ringNodeCount = nodes.count - ringNodeStart

        innerNodeStart = nodes.count
        let innerTargetNodes = 620
        var innerIDs: [Int] = []
        innerIDs.reserveCapacity(innerTargetNodes)

        for i in 0..<innerTargetNodes {
            let y = 1 - (Float(i) / Float(innerTargetNodes - 1)) * 2
            let r = sqrt(max(0, 1 - y * y))
            let layer = i % 4
            let th = golden * Float(i) + Float(layer) * 0.91
            var dir = SIMD3<Float>(cos(th) * r, y, sin(th) * r)
            let twistA = fbm(dir * 3.1 + SIMD3<Float>(Float(layer) * 2.7, 11.0, 3.0)) - 0.5
            let twistB = fbm(dir * 5.7 + SIMD3<Float>(7.0, Float(i) * 0.013, 19.0)) - 0.5
            let (t1, t2) = tangentBasis(normalize(dir))
            dir = normalize(dir + t1 * twistA * 0.115 + t2 * twistB * 0.090)

            let shellBias = pow(hash(i * 977 + 31), 0.58)
            let radius = 0.330 + shellBias * 0.120 + (hash(i * 421 + 17) - 0.5) * 0.018
            innerIDs.append(nodes.count)
            appendNode(dir * radius, dir: dir, heat: sat(0.42 + shellBias * 0.28 + hash(i * 571 + 9) * 0.12), cluster: -4, layer: .inner)
        }

        var innerEdges = 0
        var hotInnerEdges = 0
        for localI in 0..<innerIDs.count {
            let i = innerIDs[localI]
            var dists: [(j: Int, score: Float, chord: Float)] = []
            dists.reserveCapacity(innerIDs.count - 1)
            for localJ in 0..<innerIDs.count where localJ != localI {
                let j = innerIDs[localJ]
                let chord = distance(nodeDirs[i], nodeDirs[j])
                let radialStep = abs(length(nodes[i]) - length(nodes[j]))
                let score = chord + radialStep * 1.85 - (nodeHeat[i] + nodeHeat[j]) * 0.030
                dists.append((j, score, chord))
            }
            dists.sort { $0.score < $1.score }

            let desired = nodeHeat[i] > 0.62 ? 7 : 6
            var kept = 0
            for cand in dists {
                if kept >= desired { break }
                if cand.chord > 0.155 { continue }
                let j = cand.j
                let heatAvg = (nodeHeat[i] + nodeHeat[j]) * 0.5
                let keep = clampF(0.45, 0.92, 0.74 + heatAvg * 0.18 - cand.chord * 1.35)
                if hash(i * 313 + j * 29 + 23) > keep { continue }
                let energy = 0.34 + heatAvg * 0.36 + hash(i * 41 + j * 17) * 0.08
                if addEdge(i, j, energy, layer: .inner) {
                    innerEdges += 1
                    if energy > 0.62 { hotInnerEdges += 1 }
                    kept += 1
                }
            }
        }

        let innerWrapNormals: [SIMD3<Float>] = [
            normalize(SIMD3<Float>( 0.92,  0.18,  0.34)),
            normalize(SIMD3<Float>(-0.36,  0.92,  0.18)),
            normalize(SIMD3<Float>( 0.18, -0.32,  0.93)),
            normalize(SIMD3<Float>( 0.74, -0.60,  0.30)),
            normalize(SIMD3<Float>(-0.66, -0.22,  0.72)),
            normalize(SIMD3<Float>( 0.28,  0.66, -0.70)),
        ]

        func nearestInnerNode(to target: SIMD3<Float>, salt: Int, excluding used: Set<Int>) -> Int? {
            var best = -1
            var bestScore: Float = 999
            for idx in innerIDs {
                if used.contains(idx) { continue }
                let chord = distance(nodeDirs[idx], target)
                if chord > 0.145 { continue }
                let outerBias = length(nodes[idx]) * -0.35
                let score = chord * 4.0 + outerBias - nodeHeat[idx] * 0.10 + hash(idx * 131 + salt * 17) * 0.025
                if score < bestScore {
                    bestScore = score
                    best = idx
                }
            }
            return best >= 0 ? best : nil
        }

        var innerWrapEdges = 0
        for wi in 0..<innerWrapNormals.count {
            let n = innerWrapNormals[wi]
            let (u0, v0) = tangentBasis(n)
            let spin = hash(wi * 877 + 13) * twoPi
            let u = normalize(u0 * cos(spin) + v0 * sin(spin))
            let v = normalize(cross(n, u))
            let steps = 88
            var path: [Int] = []
            var used = Set<Int>()
            for s in 0..<steps {
                let theta = (Float(s) / Float(steps)) * twoPi
                let base = normalize(u * cos(theta) + v * sin(theta))
                let wobble = sin(theta * 3.0 + Float(wi) * 1.7) * 0.050
                let target = normalize(base + n * wobble)
                if let idx = nearestInnerNode(to: target, salt: wi * 1000 + s, excluding: used) {
                    path.append(idx)
                    used.insert(idx)
                }
            }

            guard path.count > 4 else { continue }
            for p in 0..<path.count {
                let a = path[p]
                let b = path[(p + 1) % path.count]
                let chord = distance(nodeDirs[a], nodeDirs[b])
                if chord > 0.170 { continue }
                let energy = 0.58 + hash(wi * 1777 + p * 43) * 0.20
                if addEdge(a, b, energy, layer: .inner) {
                    innerEdges += 1
                    innerWrapEdges += 1
                    if energy > 0.62 { hotInnerEdges += 1 }
                }
            }
        }

        let innerWrapSteps = 72
        let innerWrapLanes = 2
        for wi in 0..<innerWrapNormals.count {
            let n = innerWrapNormals[wi]
            let (u0, v0) = tangentBasis(n)
            let spin = hash(wi * 577 + 101) * twoPi
            let u = normalize(u0 * cos(spin) + v0 * sin(spin))
            let v = normalize(cross(n, u))

            for lane in 0..<innerWrapLanes {
                var band: [Int] = []
                band.reserveCapacity(innerWrapSteps)
                let laneOffset = (Float(lane) - 0.5) * 0.050
                for s in 0..<innerWrapSteps {
                    let theta = (Float(s) / Float(innerWrapSteps)) * twoPi
                    let tangent = normalize(u * -sin(theta) + v * cos(theta))
                    let wobble = sin(theta * 3.0 + Float(wi) * 1.7 + Float(lane) * 0.8) * 0.040
                    let dir = normalize(u * cos(theta) + v * sin(theta) + n * (laneOffset + wobble) + tangent * (hash(wi * 811 + lane * 97 + s * 13) - 0.5) * 0.018)
                    let radius = 0.405 + Float(lane) * 0.026 + (hash(wi * 1201 + lane * 311 + s * 19) - 0.5) * 0.010
                    band.append(nodes.count)
                    appendNode(dir * radius, dir: dir, heat: 0.70 + hash(wi * 433 + lane * 59 + s * 7) * 0.16, cluster: -4, layer: .inner)
                }

                for s in 0..<innerWrapSteps {
                    let a = band[s]
                    let b = band[(s + 1) % innerWrapSteps]
                    let energy = 0.64 + hash(wi * 3301 + lane * 271 + s * 31) * 0.20
                    if addEdge(a, b, energy, layer: .inner) {
                        innerEdges += 1
                        innerWrapEdges += 1
                        if energy > 0.62 { hotInnerEdges += 1 }
                    }
                    if s % 3 == 0 {
                        let c = band[(s + 2) % innerWrapSteps]
                        let skipEnergy = 0.50 + hash(wi * 661 + lane * 173 + s * 43) * 0.14
                        if addEdge(a, c, skipEnergy, layer: .inner) {
                            innerEdges += 1
                            innerWrapEdges += 1
                            if skipEnergy > 0.62 { hotInnerEdges += 1 }
                        }
                    }
                }
            }
        }

        innerNodeCount = nodes.count - innerNodeStart
        let finalNodeCount = nodes.count

        var visibleDegree = Array(repeating: 0, count: finalNodeCount)
        for e in edges {
            visibleDegree[e.a] += 1
            visibleDegree[e.b] += 1
        }

        var lineVertsByLayer = Array(repeating: [LineVtx](), count: OrbLayer.allCases.count)
        let lineCombos: [(Float, Float)] = [(0, -1), (1, -1), (0, 1), (1, -1), (1, 1), (0, 1)]
        for edge in edges {
            let a = nodes[edge.a]
            let b = nodes[edge.b]
            let layerIndex = edge.layer.rawValue
            for (sel, side) in lineCombos {
                lineVertsByLayer[layerIndex].append(LineVtx(a: a, b: b, endSel: sel, side: side, energy: edge.energy, crawl: edge.crawl))
            }
        }

        var nodeDataByLayer = Array(repeating: [NodeVtx](), count: OrbLayer.allCases.count)
        for i in 0..<finalNodeCount {
            let deg = visibleDegree[i]
            switch nodeLayers[i] {
            case .ring:
                if nodeCluster[i] == -3 {
                    let e = min(0.98, 0.24 + nodeHeat[i] * 0.72)
                    nodeDataByLayer[OrbLayer.ring.rawValue].append(NodeVtx(p: nodes[i], energy: e, size: 1.15 + nodeHeat[i] * 1.25))
                } else {
                    let e = min(0.78, 0.20 + nodeHeat[i] * 0.44 + Float(deg) * 0.008)
                    nodeDataByLayer[OrbLayer.ring.rawValue].append(NodeVtx(p: nodes[i], energy: e, size: 0.75 + nodeHeat[i] * 0.55 + min(Float(deg), 8.0) * 0.030))
                }
            case .inner:
                let e = min(0.82, 0.28 + nodeHeat[i] * 0.42 + Float(deg) * 0.010)
                nodeDataByLayer[OrbLayer.inner.rawValue].append(NodeVtx(p: nodes[i], energy: e, size: 0.95 + nodeHeat[i] * 0.42 + min(Float(deg), 10.0) * 0.035))
            case .haze:
                let e = min(0.32, 0.08 + nodeHeat[i] * 0.58 + Float(deg) * 0.006)
                nodeDataByLayer[OrbLayer.haze.rawValue].append(NodeVtx(p: nodes[i], energy: e, size: 0.64 + min(Float(deg), 5.0) * 0.035))
            case .shell:
                let e = min(0.64, 0.14 + nodeHeat[i] * 0.18 + Float(deg) * 0.018)
                nodeDataByLayer[OrbLayer.shell.rawValue].append(NodeVtx(p: nodes[i], energy: e, size: 0.92 + min(Float(deg), 12.0) * 0.075))
            case .lightning:
                break
            }
        }

        for i in 0..<OrbLayer.allCases.count {
            let lineVerts = lineVertsByLayer[i]
            lineVertexCounts[i] = lineVerts.count
            lineBuffers[i] = lineVerts.isEmpty ? nil : device.makeBuffer(
                bytes: lineVerts,
                length: MemoryLayout<LineVtx>.stride * lineVerts.count,
                options: .storageModeShared
            )

            let nodeData = nodeDataByLayer[i]
            nodeVertexCounts[i] = nodeData.count * 6
            nodeBuffers[i] = nodeData.isEmpty ? nil : device.makeBuffer(
                bytes: nodeData,
                length: MemoryLayout<NodeVtx>.stride * nodeData.count,
                options: .storageModeShared
            )
        }

        let totalLineVertexCount = lineVertexCounts.reduce(0, +)
        let layerLineSummary = OrbLayer.allCases
            .map { "\($0.label)=\(lineVertexCounts[$0.rawValue])" }
            .joined(separator: " ")

        NSLog(
            "[orb] bolts geometry ready: nodes=\(finalNodeCount) shellNodes=\(baseShellNodeCount) hazeNodes=\(hazeNodeCount) ringNodes=\(ringNodeCount) innerNodes=\(innerNodeCount) edges=\(edges.count) hazeEdges=\(hazeEdges) ringEdges=\(ringEdges) hotRingEdges=\(hotRingEdges) innerEdges=\(innerEdges) innerWrapEdges=\(innerWrapEdges) hotInnerEdges=\(hotInnerEdges) lineVerts=\(totalLineVertexCount) layerLineVerts={\(layerLineSummary)}"
        )
    }

    // MARK: Math helpers

    func hash(_ i: Int) -> Float {
        let x = sin(Float(i) * 12.9898) * 43_758.547
        return x - floor(x)
    }

    func brand(_ s: Int) -> Float {
        let x = sin(Float(s) * 127.1 + 311.7) * 43_758.547
        return x - floor(x)
    }

    func hash3(_ p: SIMD3<Float>) -> Float {
        let x = sin(dot(p, SIMD3<Float>(12.9898, 78.233, 37.719))) * 43_758.547
        return x - floor(x)
    }

    func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    func lerpVec(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    func clampF(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
        min(hi, max(lo, x))
    }

    func sat(_ x: Float) -> Float {
        clampF(0, 1, x)
    }

    func smoothstep(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
        let t = sat((x - lo) / max(hi - lo, 1e-5))
        return t * t * (3 - 2 * t)
    }

    func vnoise(_ p: SIMD3<Float>) -> Float {
        let i = SIMD3<Float>(floor(p.x), floor(p.y), floor(p.z))
        var f = p - i
        f = f * f * (SIMD3<Float>(repeating: 3) - 2 * f)
        func g(_ o: SIMD3<Float>) -> Float { hash3(i + o) }
        let x00 = lerp(g(SIMD3<Float>(0, 0, 0)), g(SIMD3<Float>(1, 0, 0)), f.x)
        let x10 = lerp(g(SIMD3<Float>(0, 1, 0)), g(SIMD3<Float>(1, 1, 0)), f.x)
        let x01 = lerp(g(SIMD3<Float>(0, 0, 1)), g(SIMD3<Float>(1, 0, 1)), f.x)
        let x11 = lerp(g(SIMD3<Float>(0, 1, 1)), g(SIMD3<Float>(1, 1, 1)), f.x)
        return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z)
    }

    func fbm(_ p: SIMD3<Float>) -> Float {
        var s: Float = 0
        var a: Float = 0.5
        var q = p
        for _ in 0..<4 {
            s += a * vnoise(q)
            q = q * 2.03
            a *= 0.5
        }
        return s
    }

    func tangentBasis(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let ref = abs(n.y) < 0.82 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let t1 = normalize(cross(ref, n))
        return (t1, normalize(cross(n, t1)))
    }

}
