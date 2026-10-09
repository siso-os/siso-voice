import simd

extension OrbRenderer {
    struct LayerMotion {
        var shellModel: float4x4
        var hazeModel: float4x4
        var ringModel: float4x4
        var innerModel: float4x4
        var boltModel: float4x4
        var shellTime: Float
        var hazeTime: Float
        var ringTime: Float
        var innerTime: Float
        var boltTime: Float
    }

    func makeLayerMotion(time: Float) -> LayerMotion {
        // Motion is ALWAYS the slow "chilling" speed — it NEVER speeds up. Shaan's
        // reactivity is COLOR + PULSE (handled in the shader via energy/mic), not rotation
        // speed. Speeding up on listen/speak felt frantic and bad. Shaan feedback 2026-06-05.
        let motionSpeed: Float = 1.75
        let angularBoost: Float = 1.0
        let layerTime = time * motionSpeed

        let shellA = time * 0.157 * angularBoost
        let hazeA = time * -0.052 * angularBoost
        let ringA = time * -0.489 * angularBoost
        let innerA = time * 0.733 * angularBoost

        let shellWobble = rotX(sin(layerTime * 0.41) * 0.08) * rotZ(sin(layerTime * 0.29) * 0.05)
        let ringPrecess = rotAxis(SIMD3<Float>(0.15, 0.25, 0.96), sin(layerTime * 0.33) * 0.10)
        let innerWobble = rotAxis(SIMD3<Float>(0.75, 0.10, 0.65), sin(layerTime * 0.77) * 0.11)

        let shellModel = rotAxis(SIMD3<Float>(0.00, 1.00, 0.08), shellA) * shellWobble
        let hazeModel = rotAxis(SIMD3<Float>(0.18, 1.00, 0.10), hazeA)
        let ringModel = ringPrecess * rotAxis(SIMD3<Float>(0.24, -0.80, 0.55), ringA)
        let innerModel = innerWobble * rotAxis(SIMD3<Float>(-0.36, 0.92, 0.18), innerA)

        return LayerMotion(
            shellModel: shellModel,
            hazeModel: hazeModel,
            ringModel: ringModel,
            innerModel: innerModel,
            boltModel: shellModel,
            shellTime: time * motionSpeed,
            hazeTime: time * motionSpeed * 0.82,
            ringTime: time * motionSpeed * 1.12,
            innerTime: time * motionSpeed * 1.28,
            boltTime: time * motionSpeed * 1.35
        )
    }

    private func rotY(_ a: Float) -> float4x4 {
        let c = cos(a)
        let s = sin(a)
        return float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private func rotX(_ a: Float) -> float4x4 {
        let c = cos(a)
        let s = sin(a)
        return float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private func rotZ(_ a: Float) -> float4x4 {
        let c = cos(a)
        let s = sin(a)
        return float4x4(columns: (
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private func rotAxis(_ axis: SIMD3<Float>, _ a: Float) -> float4x4 {
        let n = normalize(axis)
        let c = cos(a)
        let s = sin(a)
        let t = 1 - c
        let x = n.x
        let y = n.y
        let z = n.z
        return float4x4(columns: (
            SIMD4<Float>(t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0),
            SIMD4<Float>(t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0),
            SIMD4<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}
