import MetalKit
import simd

/// OrbRenderer — native Metal JARVIS bolts orb.
/// Ports the recovered 6353-node layered renderer from tools/orb/jarvis-bolts-orb:
/// shell + haze + ring + inner graph layers, dynamic forked bolts, HDR bloom, and tonemap.
final class OrbRenderer: NSObject, MTKViewDelegate {

    enum Phase { case idle, listening, transcribing, speaking, thinking, jarvis, error }

    enum OrbLayer: Int, CaseIterable {
        case shell = 0
        case haze = 1
        case ring = 2
        case inner = 3
        case lightning = 4

        var label: String {
            switch self {
            case .shell: return "shell"
            case .haze: return "haze"
            case .ring: return "ring"
            case .inner: return "inner"
            case .lightning: return "lightning"
            }
        }
    }

    struct Continent {
        let c: SIMD3<Float>
        let spread: Float
        let weight: Float
        let count: Int
        let elong: Float
        let phase: Float
    }

    struct EdgeRecord {
        let a: Int
        let b: Int
        let energy: Float
        let layer: OrbLayer
        let crawl: Float
        let phase: Float
    }

    struct LineVtx {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var endSel: Float
        var side: Float
        var energy: Float
        var crawl: Float
    }

    struct NodeVtx {
        var p: SIMD3<Float>
        var energy: Float
        var size: Float
        var _pad: Float = 0
    }

    struct BoltVtx {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var endSel: Float
        var side: Float
        var energy: Float
        var branch: Float
    }

    struct Uniforms {
        var viewProj: float4x4
        var model: float4x4
        var res: SIMD2<Float>
        var time: Float
        var energy: Float
        var camPos: SIMD3<Float>
        var activeColor: SIMD4<Float>
        var activation: Float = 0
        var backingLum: Float = 0
        var bloomScale: Float = 1
    }

    struct BlurU {
        var dir: SIMD2<Float>
        var texel: SIMD2<Float>
    }



    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let hdrPixelFormat: MTLPixelFormat = .rgba16Float

    private var linePipeline: MTLRenderPipelineState?
    private var nodePipeline: MTLRenderPipelineState?
    private var brightPipeline: MTLRenderPipelineState?
    private var blurPipeline: MTLRenderPipelineState?
    private var compositePipeline: MTLRenderPipelineState?
    private var hazePipeline: MTLRenderPipelineState?
    private var boltPipeline: MTLRenderPipelineState?
    private var backingPipeline: MTLRenderPipelineState?

    private var sceneTexture: MTLTexture?
    private var brightTexture: MTLTexture?
    private var blurTextureA: MTLTexture?
    private var blurTextureB: MTLTexture?
    private var targetWidth = 0
    private var targetHeight = 0

    var lineBuffers = Array<MTLBuffer?>(repeating: nil, count: OrbLayer.allCases.count)
    var nodeBuffers = Array<MTLBuffer?>(repeating: nil, count: OrbLayer.allCases.count)
    var boltBuffer: MTLBuffer?
    var lineVertexCounts = Array(repeating: 0, count: OrbLayer.allCases.count)
    var nodeVertexCounts = Array(repeating: 0, count: OrbLayer.allCases.count)
    var boltVertexCount = 0

    var nodes: [SIMD3<Float>] = []
    var nodeDirs: [SIMD3<Float>] = []
    var nodeHeat: [Float] = []
    var nodeCluster: [Int] = []
    var nodeLayers: [OrbLayer] = []
    var edges: [EdgeRecord] = []
    var baseShellNodeCount = 0
    var hazeNodeCount = 0
    var ringNodeCount = 0
    var innerNodeStart = 0
    var innerNodeCount = 0
    var didLogFirstBoltFrame = false

    // state (targets lerped toward each frame)
    var phase: Phase = .idle
    var micTarget: Float = 0
    var mic: Float = 0
    var energy: Float = 0.30
    var activation: Float = 0
    var activeColor = SIMD3<Float>(1.0, 0.72, 0.20)
    var boltActivity: Float = 0.35
    /// Average luminance (0…1) of the screen behind the orb, fed in by the panel's
    /// BackgroundSampler. Drives the adaptive dark backing disc + bloom threshold.
    var backgroundLum: Float = 0
    private var startTime = CACurrentMediaTime()
    private var lastTime = CACurrentMediaTime()
    private var prevLoud: Float = 0
    private var lastStrikeT: Double = -1
    var strike: Float = 0

    init(device: MTLDevice, view: MTKView) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        super.init()
        buildPipelines(view: view)
        buildWebGeometry()
    }

    private func buildPipelines(view: MTKView) {
        guard let library = makeLibrary() else {
            NSLog("[orb] no metal library")
            return
        }
        linePipeline = makePipeline(library, "line_vertex", "line_fragment", hdrPixelFormat, additive: true)
        nodePipeline = makePipeline(library, "node_vertex", "node_fragment", hdrPixelFormat, additive: true)
        brightPipeline = makePipeline(library, "fsq_vertex", "bright_pass", hdrPixelFormat, additive: false)
        blurPipeline = makePipeline(library, "fsq_vertex", "blur_pass", hdrPixelFormat, additive: false)
        compositePipeline = makePipeline(library, "fsq_vertex", "composite_pass", view.colorPixelFormat, additive: false)
        hazePipeline = makePipeline(library, "fsq_vertex", "haze_glow", hdrPixelFormat, additive: true)
        boltPipeline = makePipeline(library, "bolt_vertex", "bolt_fragment", hdrPixelFormat, additive: true)
        backingPipeline = makePipeline(library, "fsq_vertex", "backing_disc", hdrPixelFormat, additive: false, alphaBlend: true)
    }

    private func makePipeline(
        _ library: MTLLibrary,
        _ vertex: String,
        _ fragment: String,
        _ pixelFormat: MTLPixelFormat,
        additive: Bool,
        alphaBlend: Bool = false
    ) -> MTLRenderPipelineState? {
        guard let vertexFunction = library.makeFunction(name: vertex),
              let fragmentFunction = library.makeFunction(name: fragment) else {
            NSLog("[orb] missing metal functions \(vertex)/\(fragment)")
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunction
        desc.fragmentFunction = fragmentFunction
        let attachment = desc.colorAttachments[0]!
        attachment.pixelFormat = pixelFormat
        if additive {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        } else if alphaBlend {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("[orb] pipeline error for \(vertex)/\(fragment): \(error)")
            return nil
        }
    }

    private func makeLibrary() -> MTLLibrary? {
        if let lib = device.makeDefaultLibrary() { return lib }
        let candidates = [
            Bundle.main.url(forResource: "orb", withExtension: "metal", subdirectory: "orb"),
            Bundle.main.url(forResource: "orb", withExtension: "metal"),
        ]
        for case let url? in candidates {
            if let src = try? String(contentsOf: url, encoding: .utf8) {
                do { return try device.makeLibrary(source: src, options: nil) }
                catch { NSLog("[orb] metal compile error: \(error)") }
            }
        }
        return nil
    }

    private func ensureRenderTargets(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if width == targetWidth, height == targetHeight,
           sceneTexture != nil, brightTexture != nil, blurTextureA != nil, blurTextureB != nil {
            return
        }
        targetWidth = width
        targetHeight = height
        let bloomWidth = max(1, width / 2)
        let bloomHeight = max(1, height / 2)
        sceneTexture = makeTexture(format: hdrPixelFormat, width: width, height: height)
        brightTexture = makeTexture(format: hdrPixelFormat, width: bloomWidth, height: bloomHeight)
        blurTextureA = makeTexture(format: hdrPixelFormat, width: bloomWidth, height: bloomHeight)
        blurTextureB = makeTexture(format: hdrPixelFormat, width: bloomWidth, height: bloomHeight)
    }

    private func makeTexture(format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: desc)
    }

    private func encodePass(
        commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        clear: Bool,
        body: (MTLRenderCommandEncoder) -> Void
    ) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = clear ? .clear : .load
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        body(enc)
        enc.endEncoding()
    }

    // MARK: State

    func setPhase(_ p: Phase) { phase = p }
    func setMic(_ v: Float) { micTarget = v }

    func fireStrike(amp: Float) {
        strike = max(strike, min(1, amp))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        updateState(view: view)
        guard linePipeline != nil,
              nodePipeline != nil,
              brightPipeline != nil,
              blurPipeline != nil,
              compositePipeline != nil,
              hazePipeline != nil,
              boltPipeline != nil,
              backingPipeline != nil,
              let drawable = view.currentDrawable,
              let finalRPD = view.currentRenderPassDescriptor,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        let width = max(1, Int(view.drawableSize.width.rounded()))
        let height = max(1, Int(view.drawableSize.height.rounded()))
        ensureRenderTargets(width: width, height: height)
        guard let sceneTexture,
              let brightTexture,
              let blurTextureA,
              let blurTextureB else { return }

        let time = Float(CACurrentMediaTime() - startTime)
        let motion = makeLayerMotion(time: time)
        generateBolts(time: motion.boltTime)

        // The known-working renderer still issues its normal passes. In Original V1 mode the
        // legacy fragment functions are transparent and haze_glow supplies the fullscreen orb.
        encodePass(commandBuffer: commandBuffer, target: sceneTexture, clear: true) { enc in
            if let backingPipeline {
                var backingUniforms = makeUniforms(width: width, height: height, shaderTime: time, model: motion.shellModel)
                enc.setRenderPipelineState(backingPipeline)
                enc.setFragmentBytes(&backingUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        encodePass(commandBuffer: commandBuffer, target: sceneTexture, clear: false) { enc in
            if let hazePipeline {
                var hazeUniforms = makeUniforms(width: width, height: height, shaderTime: time, model: motion.hazeModel)
                enc.setRenderPipelineState(hazePipeline)
                enc.setFragmentBytes(&hazeUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        encodePass(commandBuffer: commandBuffer, target: sceneTexture, clear: false) { enc in
            func drawLayer(_ layer: OrbLayer, uniforms: inout Uniforms) {
                let idx = layer.rawValue
                if let linePipeline, let lineBuffer = lineBuffers[idx], lineVertexCounts[idx] > 0 {
                    enc.setRenderPipelineState(linePipeline)
                    enc.setVertexBuffer(lineBuffer, offset: 0, index: 0)
                    enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: lineVertexCounts[idx])
                }
                if let nodePipeline, let nodeBuffer = nodeBuffers[idx], nodeVertexCounts[idx] > 0 {
                    enc.setRenderPipelineState(nodePipeline)
                    enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
                    enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nodeVertexCounts[idx])
                }
            }

            var hazeGraphUniforms = makeUniforms(width: width, height: height, shaderTime: motion.hazeTime, model: motion.hazeModel)
            var innerUniforms = makeUniforms(width: width, height: height, shaderTime: motion.innerTime, model: motion.innerModel)
            var shellUniforms = makeUniforms(width: width, height: height, shaderTime: motion.shellTime, model: motion.shellModel)
            var ringUniforms = makeUniforms(width: width, height: height, shaderTime: motion.ringTime, model: motion.ringModel)
            var boltUniforms = makeUniforms(width: width, height: height, shaderTime: motion.boltTime, model: motion.boltModel)

            drawLayer(.haze, uniforms: &hazeGraphUniforms)
            drawLayer(.inner, uniforms: &innerUniforms)
            drawLayer(.shell, uniforms: &shellUniforms)
            drawLayer(.ring, uniforms: &ringUniforms)

            if let boltPipeline, let boltBuffer, boltVertexCount > 0 {
                enc.setRenderPipelineState(boltPipeline)
                enc.setVertexBuffer(boltBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&boltUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setFragmentBytes(&boltUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: boltVertexCount)
            }
        }

        encodePass(commandBuffer: commandBuffer, target: brightTexture, clear: true) { enc in
            if let brightPipeline {
                var brightUniforms = makeUniforms(width: width, height: height, shaderTime: time, model: motion.shellModel)
                enc.setRenderPipelineState(brightPipeline)
                enc.setFragmentTexture(sceneTexture, index: 0)
                enc.setFragmentBytes(&brightUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        var blurH = BlurU(dir: SIMD2<Float>(1, 0), texel: SIMD2<Float>(1 / Float(max(1, brightTexture.width)), 1 / Float(max(1, brightTexture.height))))
        encodePass(commandBuffer: commandBuffer, target: blurTextureA, clear: true) { enc in
            if let blurPipeline {
                enc.setRenderPipelineState(blurPipeline)
                enc.setFragmentTexture(brightTexture, index: 0)
                enc.setFragmentBytes(&blurH, length: MemoryLayout<BlurU>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        var blurV = BlurU(dir: SIMD2<Float>(0, 1), texel: SIMD2<Float>(1 / Float(max(1, brightTexture.width)), 1 / Float(max(1, brightTexture.height))))
        encodePass(commandBuffer: commandBuffer, target: blurTextureB, clear: true) { enc in
            if let blurPipeline {
                enc.setRenderPipelineState(blurPipeline)
                enc.setFragmentTexture(blurTextureA, index: 0)
                enc.setFragmentBytes(&blurV, length: MemoryLayout<BlurU>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }

        guard let finalEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalRPD) else { return }
        if let compositePipeline {
            finalEncoder.setRenderPipelineState(compositePipeline)
            finalEncoder.setFragmentTexture(sceneTexture, index: 0)
            finalEncoder.setFragmentTexture(blurTextureB, index: 1)
            finalEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        finalEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateState(view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTime, 0.05))
        lastTime = now

        mic += (micTarget - mic) * 0.2
        let loud = mic
        let energyTarget: Float
        let boltTarget: Float
        let activationBaseTarget: Float
        let activeColorTarget: SIMD3<Float>
        switch phase {
        case .idle:
            energyTarget = 0.24 + loud * 0.14
            boltTarget = 0.08
            activationBaseTarget = loud * 0.08
            activeColorTarget = SIMD3<Float>(1.0, 0.72, 0.20)
        case .listening:
            energyTarget = 0.66 + loud * 0.42
            boltTarget = 0.62 + loud * 0.16
            activationBaseTarget = 0.64 + loud * 0.34
            activeColorTarget = SIMD3<Float>(0.25, 0.85, 1.0)
        case .transcribing:
            energyTarget = 0.48 + loud * 0.18
            boltTarget = 0.82
            activationBaseTarget = 0.48 + loud * 0.14
            activeColorTarget = SIMD3<Float>(1.0, 0.62, 0.12)
        case .speaking:
            energyTarget = 0.55 + loud * 0.35
            boltTarget = 0.52 + loud * 0.14
            activationBaseTarget = 0.74 + loud * 0.24
            activeColorTarget = SIMD3<Float>(0.55, 0.92, 1.0)
        case .thinking:
            energyTarget = 0.40 + loud * 0.15
            boltTarget = 0.76
            activationBaseTarget = 0.44 + loud * 0.10
            activeColorTarget = SIMD3<Float>(1.0, 0.62, 0.12)
        case .jarvis:
            // JARVIS mode — distinct VIOLET so it's unmistakable vs cyan(listen)/amber(process)/red.
            // "I'm listening as JARVIS, not dictating." Shaan 2026-06-05.
            energyTarget = 0.70 + loud * 0.30
            boltTarget = 0.64
            activationBaseTarget = 0.70 + loud * 0.28
            activeColorTarget = SIMD3<Float>(0.72, 0.40, 1.0)
        case .error:
            energyTarget = 0.78 + loud * 0.22
            boltTarget = 0.84
            activationBaseTarget = 0.90
            activeColorTarget = SIMD3<Float>(1.0, 0.25, 0.20)
        }
        let eRate: Float = energyTarget > energy ? 0.22 : 0.06
        energy += (energyTarget - energy) * eRate
        boltActivity += (boltTarget - boltActivity) * 0.18

        let onset = loud - prevLoud
        prevLoud = loud
        if onset > 0.10 && (now - lastStrikeT) > 0.12 {
            lastStrikeT = now
            fireStrike(amp: min(1, onset * 2.5))
        }
        strike *= (1 - dt * 3.0)
        if strike < 0.01 { strike = 0 }

        let activationTarget = clampF(0, 1, activationBaseTarget + strike * 0.35)
        let activationRate: Float = activationTarget > activation ? 0.28 : 0.075
        activation += (activationTarget - activation) * activationRate
        activeColor += (activeColorTarget - activeColor) * 0.18
    }

    // Camera is fixed; proj/view depend only on aspect (width/height). makeUniforms is called
    // ~8×/frame, so recomputing perspective()+lookAt()+(proj*view) each call burned ~16 trig +
    // matrix multiplies per frame on constants. Cache viewProj keyed on (w,h) — rebuilt only
    // when the drawable size changes (≈never after launch).
    private static let orbCamera = SIMD3<Float>(0, 0, 4.1)
    private var cachedViewProj = float4x4(1)
    private var cachedViewProjW: Float = -1
    private var cachedViewProjH: Float = -1

    private func viewProj(w: Float, h: Float) -> float4x4 {
        if w != cachedViewProjW || h != cachedViewProjH {
            let proj = perspective(0.62, w / h, 0.1, 100)
            let view = lookAt(Self.orbCamera, SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 1, 0))
            cachedViewProj = proj * view
            cachedViewProjW = w
            cachedViewProjH = h
        }
        return cachedViewProj
    }

    private func makeUniforms(width: Int, height: Int, shaderTime: Float, model: float4x4) -> Uniforms {
        let w = Float(max(1, width))
        let h = Float(max(1, height))
        // Camera pulled back 3.4 → 4.1 (~20% smaller orb) so it has headroom in the
        // 196px panel and doesn't clip when it scales up. Shaan feedback 2026-06-05.
        let camera = Self.orbCamera
        // Background-awareness: backgroundLum (0=dark…1=light) is fed in by the panel manager's
        // BackgroundSampler. Over a light bg, bring the backing disc up and raise the bloom
        // threshold a touch so the additive haze doesn't wash out. Over dark, both stay neutral.
        let lum = min(1, max(0, backgroundLum))
        return Uniforms(
            viewProj: viewProj(w: w, h: h),
            model: model,
            res: SIMD2<Float>(w, h),
            time: shaderTime,
            energy: min(1.4, energy),
            camPos: camera,
            activeColor: SIMD4<Float>(activeColor.x, activeColor.y, activeColor.z, 1),
            activation: min(1, max(0, activation)),
            backingLum: lum,
            bloomScale: 1 + 0.45 * self.smoothstep(0.45, 0.9, lum)
        )
    }

    // MARK: Render Math

    private func perspective(_ fovY: Float, _ aspect: Float, _ near: Float, _ far: Float) -> float4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    private func lookAt(_ eye: SIMD3<Float>, _ center: SIMD3<Float>, _ up: SIMD3<Float>) -> float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }


}
