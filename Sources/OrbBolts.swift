import MetalKit
import simd

extension OrbRenderer {
    // MARK: Dynamic bolts

    private func emitBoltSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ energy: Float, _ branch: Float, into out: inout [BoltVtx]) {
        let combos: [(Float, Float)] = [(0, -1), (1, -1), (0, 1), (1, -1), (1, 1), (0, 1)]
        for (sel, side) in combos {
            out.append(BoltVtx(a: a, b: b, endSel: sel, side: side, energy: energy, branch: branch))
        }
    }

    private func jaggedPath(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ depth: Int,
        _ amp: Float,
        _ energy: Float,
        _ branch: Float,
        _ seed: Int,
        into out: inout [BoltVtx]
    ) {
        if depth == 0 {
            emitBoltSegment(a, b, energy, branch, into: &out)
            return
        }
        var mid = (a + b) * 0.5
        let chord = b - a
        let len = max(length(chord), 1e-4)
        let dir = chord / len
        var up = SIMD3<Float>(0, 1, 0)
        if abs(dot(dir, up)) > 0.9 { up = SIMD3<Float>(1, 0, 0) }
        let p1 = normalize(cross(dir, up))
        let p2 = cross(dir, p1)
        let off1 = (brand(seed) * 2 - 1) * amp * len
        let off2 = (brand(seed + 97) * 2 - 1) * amp * len
        mid += p1 * off1 + p2 * off2
        jaggedPath(a, mid, depth - 1, amp * 0.6, energy, branch, seed * 2 + 1, into: &out)
        jaggedPath(mid, b, depth - 1, amp * 0.6, energy, branch, seed * 2 + 7, into: &out)
    }

    private func boltCoreStart(strikeId: Int, slot: Int) -> SIMD3<Float> {
        let z = brand(strikeId * 911 + slot * 37) * 2 - 1
        let theta = brand(strikeId * 577 + slot * 131) * Float.pi * 2
        let r = sqrt(max(0, 1 - z * z))
        let dir = SIMD3<Float>(cos(theta) * r, z, sin(theta) * r)
        let radius = 0.035 + brand(strikeId * 353 + slot * 191) * 0.045
        return dir * radius
    }

    func generateBolts(time: Float) {
        guard baseShellNodeCount > 0 else { return }

        let intensity = clampF(0, 1.45, boltActivity + strike * 0.55)
        let slots = intensity > 1.05 ? 4 : 3

        // FAST EARLY-OUT: most frames emit NO bolt geometry. Each slot is visible only for a
        // narrow window (~22% of its cycle at idle), so on the majority of frames every slot is
        // outside its window and the loop below would allocate a 384-vertex array, run the full
        // per-slot math, and emit nothing. Cheaply check first whether ANY slot is live this
        // frame; if not, set count 0 and return BEFORE the array alloc + recursive jaggedPath.
        // This is bit-identical to the old output (same skip conditions) — pure waste removal.
        let visibleWindow = 0.18 + min(1, intensity) * 0.12
        var anyLive = false
        for s in 0..<slots {
            let cycle: Float = 1.1 + Float(s) * 0.4
            let phase = (time / cycle).truncatingRemainder(dividingBy: 1)
            if phase <= visibleWindow {
                let envelope = sin(phase / visibleWindow * Float.pi)
                let flick = 0.6 + 0.4 * sin(time * 40.0 + Float(s))
                let energy = envelope * flick * 1.8 * (0.30 + min(1.25, intensity) * 0.74)
                if energy >= 0.05 { anyLive = true; break }
            }
        }
        guard anyLive else { boltVertexCount = 0; return }

        var boltVerts: [BoltVtx] = []
        boltVerts.reserveCapacity(384)
        for s in 0..<slots {
            let cycle: Float = 1.1 + Float(s) * 0.4
            let slotT = time / cycle
            let strikeId = Int(floor(slotT))
            let phase = slotT - Float(strikeId)
            if phase > visibleWindow { continue }
            let envelope = sin(phase / visibleWindow * Float.pi)
            let flick = 0.6 + 0.4 * sin(time * 40.0 + Float(s))
            let energy = envelope * flick * 1.8 * (0.30 + min(1.25, intensity) * 0.74)
            if energy < 0.05 { continue }

            let start = boltCoreStart(strikeId: strikeId, slot: s)
            let ti = min(Int(brand(strikeId * 29 + s * 7) * Float(baseShellNodeCount)), nodes.count - 1)
            let target = nodes[ti]

            jaggedPath(start, target, 4, 0.16, energy, 0.0, strikeId * 1000 + s, into: &boltVerts)
            let branches = 1 + Int(brand(strikeId + s) * 2)
            for bi in 0..<branches {
                let mt = lerpVec(start, target, 0.45 + brand(strikeId + bi * 5) * 0.4)
                let bti = min(Int(brand(strikeId * 51 + bi * 17 + s) * Float(baseShellNodeCount)), nodes.count - 1)
                jaggedPath(mt, nodes[bti], 3, 0.14, energy * 0.65, 1.0, strikeId * 2000 + bi * 31 + s, into: &boltVerts)
            }
        }

        boltVertexCount = boltVerts.count
        if boltVerts.isEmpty { return }
        let bytes = MemoryLayout<BoltVtx>.stride * boltVerts.count
        if boltBuffer == nil || boltBuffer!.length < bytes {
            boltBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        boltBuffer?.contents().copyMemory(from: boltVerts, byteCount: bytes)
        if !didLogFirstBoltFrame {
            didLogFirstBoltFrame = true
            NSLog("[orb] bolts frame ready: boltVerts=\(boltVertexCount) centerOut=true")
        }
    }

}
