#include <metal_stdlib>
using namespace metal;

// L2 SPHERE WEB — node-graph rendered as additive billboard line-ribbons + node point-sprites.
// Lines are camera-facing quads (NOT 1px GPU lines) with a gaussian cross-section → per-line
// halo. Additive over black; dense overlaps stay saturated instead of washing to white.

struct Uniforms {
    float4x4 viewProj;
    float4x4 model;     // rotation (slow churn)
    float2   res;
    float    time;
    float    energy;
    float3   camPos;
    float4   activeColor;
    float    activation;
    float    backingLum;   // 0=dark bg, 1=light bg — drives adaptive dark backing disc
    float    bloomScale;   // bloom threshold scale (1=default); raised over light bg to tame haze
};

// Keep the known-working renderer ABI while the visual is supplied by Original V1.
// The installed Voice runtime still asks for the legacy passes by name; those passes
// become transparent below and haze_glow routes to the new fullscreen orb.
constant bool kOriginalV1Mode = true;

// ---- LINE RIBBON ----
// Each edge = 2 triangles (a quad). We pass per-vertex: the two endpoints (a,b), which end
// this vertex is, and a side (-1/+1) to offset perpendicular in screen space. cross = -1..1
// across the ribbon width → gaussian falloff in the fragment shader.
struct LineVtx {
    float3 a;       // endpoint A (model space)
    float3 b;       // endpoint B
    float  endSel;  // 0 → use a, 1 → use b
    float  side;    // -1 or +1 (ribbon half)
    float  energy;  // per-edge energy (brightness / future lightning)
    float  depthA;  // (unused placeholder for symmetry)
};

struct LineFragIn {
    float4 pos [[position]];
    float  cross;     // -1..1 across ribbon
    float  energy;
    float  depth01;   // 0 near .. 1 far (for depth dimming)
    float  phase;     // per-edge random phase (for re-wiring blink + pulse offset)
    float  along;     // 0 at A .. 1 at B (for traveling energy pulses)
    float3 mid;       // edge midpoint (model space, undisplaced) → SPATIAL crawl
};

// cheap hash for per-edge phase from its midpoint
static inline float ehash(float3 p){
    p = fract(p*0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x*p.y*p.z*(p.x+p.y+p.z));
}
static inline float vhash(float3 p){
    return fract(sin(dot(p, float3(12.9898,78.233,37.719)))*43758.5453);
}
// smooth 3D value noise (for flowing displacement)
static inline float vn(float3 x){
    float3 i=floor(x), f=fract(x); f=f*f*(3.0-2.0*f);
    float n000=vhash(i+float3(0,0,0)),n100=vhash(i+float3(1,0,0));
    float n010=vhash(i+float3(0,1,0)),n110=vhash(i+float3(1,1,0));
    float n001=vhash(i+float3(0,0,1)),n101=vhash(i+float3(1,0,1));
    float n011=vhash(i+float3(0,1,1)),n111=vhash(i+float3(1,1,1));
    return mix(mix(mix(n000,n100,f.x),mix(n010,n110,f.x),f.y),
               mix(mix(n001,n101,f.x),mix(n011,n111,f.x),f.y),f.z);
}

static inline float activation01(constant Uniforms& u) {
    return clamp(u.activation, 0.0, 1.0);
}

static inline float activePulse(constant Uniforms& u) {
    float wave = 0.5 + 0.5 * sin(u.time * 5.1);
    float shaped = smoothstep(0.12, 1.0, wave);
    return activation01(u) * shaped;
}

static inline float activeScale(constant Uniforms& u) {
    float a = activation01(u);
    float p = activePulse(u);
    return 1.0 + a * 0.014 + p * 0.026;
}

static inline float3 reactiveColor(float3 base, constant Uniforms& u) {
    float a = smoothstep(0.04, 0.95, activation01(u));
    float heat = clamp(max(max(base.r, base.g), base.b), 0.0, 1.0);
    float3 target = clamp(u.activeColor.rgb, float3(0.0), float3(1.2));
    float3 active = mix(target * 0.58, target, heat);
    return mix(base, active, a * 0.88);
}

// PHYSICAL DISPLACEMENT — move each node IN/OUT and flow it over time so the whole lattice
// breathes, unfurls, and reorganizes (JARVIS "thinking/working" motion). NOT a brightness
// trick: the actual vertex positions move, so edges stretch and flex with them.
static inline float3 displace(float3 p, float t){
    float r = length(p);
    float3 dir = p / max(r, 1e-4);
    // GENTLE breathe/churn — the orb stays a coherent ball, just flexes and reorganizes.
    // (1) flowing radial breathe: regions push out / draw in on a slow travelling wave
    float wave = vn(dir*2.3 + float3(0.0, 0.0, t*0.70));
    float wave2 = vn(dir*4.1 - float3(t*0.42, 0.0, t*0.38));
    float radial = (wave - 0.5)*0.095 + (wave2 - 0.5)*0.050;   // ±~0.075 in/out (subtle)
    // (2) global swell
    radial += sin(t*1.25)*0.018;
    // (3) small tangential churn so the lattice slides/reorganizes without flying apart
    float3 t1 = normalize(cross(dir, float3(0,1,0)) + 1e-4);
    float3 t2 = cross(dir, t1);
    float dx = (vn(dir*3.0 + float3(5.0,0.0,t*0.62)) - 0.5);
    float dy = (vn(dir*3.0 + float3(0.0,9.0,t*0.57)) - 0.5);
    float3 drift = (t1*dx + t2*dy) * 0.050;
    return dir*(r + radial) + drift;
}

vertex LineFragIn line_vertex(uint vid [[vertex_id]],
                              const device LineVtx* verts [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
    LineVtx v = verts[vid];
    // PHYSICALLY MOVE both endpoints in/out over time → the lattice breathes & reorganizes
    float scale = activeScale(u);
    float3 va = displace(v.a, u.time) * scale;
    float3 vb = displace(v.b, u.time) * scale;
    // transform both endpoints to clip space to compute the screen-space line direction
    float4 wA = u.model * float4(va, 1.0);
    float4 wB = u.model * float4(vb, 1.0);
    float4 cA = u.viewProj * wA;
    float4 cB = u.viewProj * wB;
    float4 cEnd = (v.endSel < 0.5) ? cA : cB;

    // screen-space perpendicular
    float2 sA = cA.xy / max(cA.w, 1e-4);
    float2 sB = cB.xy / max(cB.w, 1e-4);
    float2 dir = normalize(sB - sA + 1e-6);
    float2 perp = float2(-dir.y, dir.x);

    // ribbon half-width in NDC (aspect-corrected). Thin lines.
    float widthPx = 1.15;
    float2 ndcPerW = perp * (widthPx / u.res) * 2.0;
    // apply offset (scaled by w so it stays constant px after perspective divide)
    float4 outPos = cEnd;
    outPos.xy += v.side * ndcPerW * cEnd.w;

    LineFragIn o;
    o.pos = outPos;
    o.cross = v.side;
    o.energy = v.energy;
    // depth dim: use world z relative to camera (further = dimmer)
    float4 wEnd = (v.endSel < 0.5) ? wA : wB;
    float zc = (u.viewProj * wEnd).z / max((u.viewProj*wEnd).w, 1e-4);
    o.depth01 = clamp(zc * 0.5 + 0.5, 0.0, 1.0);
    // per-edge phase from midpoint (stable per edge) + along-edge param for traveling pulses
    o.phase = ehash((v.a + v.b) * 0.5);
    o.along = (v.endSel < 0.5) ? 0.0 : 1.0;
    o.mid = (v.a + v.b) * 0.5;   // undisplaced midpoint → spatial crawl key
    return o;
}

// Fire color by energy (0 dim ember .. 1 saturated hot gold).
float3 webColor(float e) {
    e = clamp(e, 0.0, 1.0);
    float3 ember = float3(0.55, 0.22, 0.04);   // #8C3A0A
    float3 amber = float3(1.00, 0.55, 0.10);   // #FF8C1A
    float3 gold  = float3(1.00, 0.76, 0.24);   // #FFC23D
    float3 hot   = float3(1.00, 0.82, 0.46);   // saturated highlight, not white
    if (e < 0.4) return mix(ember, amber, e/0.4);
    if (e < 0.75) return mix(amber, gold, (e-0.4)/0.35);
    return mix(gold, hot, (e-0.75)/0.25);
}

fragment float4 line_fragment(LineFragIn in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    if (kOriginalV1Mode) return float4(0.0);
    // gaussian cross-section → soft halo per line
    float g = exp(-in.cross * in.cross * 3.0);   // 1 at center, soft edges
    // depth dimming: far side goes genuinely DARK (quadratic, →0.10 not 0.45) so the back
    // hemisphere is near-black shadow and the front stays brilliant — real 3D depth. Shaan.
    float depthDim = mix(1.0, 0.10, in.depth01 * in.depth01);

    float ph = in.phase;   // per-edge 0..1

    // ---- SPATIAL CRAWLING REVEAL (AI crawling across the surface) ----
    // The lit zone is keyed on the edge's POSITION in space + time, NOT a fixed per-edge phase.
    // So an activation field FLOWS across the sphere — every region lights as the wave passes,
    // no permanent dead spaces. Multiple moving 3D noise lobes = organic "crawling" coverage.
    float3 m = in.mid;
    float t = u.time;
    // three slow-drifting noise fields sampled at the edge's position → activation that travels
    float f1 = vn(m*2.4 + float3(0.0,  0.0,  t*0.72));
    float f2 = vn(m*3.1 + float3(t*0.55, 0.0, 0.0));
    float f3 = vn(m*1.8 + float3(0.0, t*0.45, t*0.28));
    float act = (f1*0.5 + f2*0.3 + f3*0.4);            // ~0..1.2, region-coherent, moving
    // threshold so ~30-40% is lit at once; softer ramp so LINES read (not just node dots)
    act += (ph - 0.5)*0.06;
    float reveal = 1.0;
    float litFloor = 0.22;                              // brighter ghost → wrapped lattice still visible when inactive
    float gate = litFloor + (1.0 - litFloor) * reveal;

    // SLOW data pulse along currently-active edges (fewer + slower)
    float pulseGate = step(0.7, reveal) * step(0.82, ph);
    float travel = fract(t*0.85 + ph*3.0);
    float pdist = abs(in.along - travel);
    float voicePulse = activePulse(u);
    float dataPulse = exp(-pdist*pdist*70.0) * pulseGate * activation01(u) * 0.24;

    float e = clamp(in.energy * depthDim * (0.35 + reveal*0.85) + dataPulse*0.55 + voicePulse*0.18, 0.0, 1.0);
    float3 col = reactiveColor(webColor(e), u);
    // dimmer lines so the mixed-back haze + bolts have room (0.85 → 0.5)
    float a = g * depthDim * (0.5 + 0.5*u.energy) * gate + g*dataPulse*0.65;
    a *= 1.0 + activation01(u)*0.12 + voicePulse*0.52;
    return float4(col * a, a);
}

// ---- NODE POINT SPRITE ----
struct NodeVtx { float3 p; float energy; float size; float _pad; };
struct NodeFragIn { float4 pos [[position]]; float2 uv; float energy; float depth01; };

vertex NodeFragIn node_vertex(uint vid [[vertex_id]],
                              const device NodeVtx* nodes [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
    uint nodeIdx = vid / 6;
    uint corner = vid % 6;
    NodeVtx n = nodes[nodeIdx];
    float3 np = displace(n.p, u.time) * activeScale(u);   // node moves in/out with the lattice
    float4 w = u.model * float4(np, 1.0);
    float4 c = u.viewProj * w;
    // quad corners
    float2 offs[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,-1), float2(1,1), float2(-1,1) };
    float2 q = offs[corner];
    float sizePx = n.size * (1.0 + activePulse(u) * 0.28);
    c.xy += q * (sizePx / u.res) * 2.0 * c.w;
    NodeFragIn o;
    o.pos = c; o.uv = q; o.energy = n.energy;
    o.depth01 = clamp(c.z/max(c.w,1e-4)*0.5+0.5, 0.0, 1.0);
    return o;
}

fragment float4 node_fragment(NodeFragIn in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    if (kOriginalV1Mode) return float4(0.0);
    float d = length(in.uv);
    if (d > 1.0) discard_fragment();
    float g = exp(-d*d*3.5);          // soft dot
    float depthDim = mix(1.0, 0.5, in.depth01);
    float pulse = activePulse(u);
    float e = clamp(in.energy * depthDim + 0.25 + pulse*0.12, 0.0, 1.0);
    float3 col = reactiveColor(webColor(e), u);
    float a = g * depthDim * (0.8 + 0.6*u.energy) * (1.0 + pulse*0.46);
    return float4(col * a, a);
}

// ===================== HDR BLOOM + TONEMAP =====================
// The web renders additively into an RGBA16F target → where front+back lines overlap, values
// accumulate PAST 1.0 (HDR headroom). Bloom extracts the bright overlap and blurs it; tonemap
// compresses while preserving enough color for the dense center to remain saturated.

struct FSQ { float4 pos [[position]]; float2 uv; };
vertex FSQ fsq_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSQ o; o.pos = float4(p*2.0-1.0, 0, 1); o.uv = float2(p.x, 1.0-p.y); return o;
}

// ===================== ORIGINAL V1 =====================
// Direct Metal port of the first WebGL direction selected in the visual study.
// It intentionally keeps a quiet translucent core, one broad aurora shell, and
// a single moving hot point instead of rebuilding the retired lattice geometry.
static inline float ov1_hash31(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

static inline float ov1_noise3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(ov1_hash31(i), ov1_hash31(i + float3(1,0,0)), f.x),
            mix(ov1_hash31(i + float3(0,1,0)), ov1_hash31(i + float3(1,1,0)), f.x), f.y),
        mix(mix(ov1_hash31(i + float3(0,0,1)), ov1_hash31(i + float3(1,0,1)), f.x),
            mix(ov1_hash31(i + float3(0,1,1)), ov1_hash31(i + float3(1,1,1)), f.x), f.y),
        f.z
    );
}

static inline float ov1_fbm(float3 p) {
    float sum = 0.0;
    float amplitude = 0.55;
    for (int octave = 0; octave < 4; octave++) {
        sum += ov1_noise3(p) * amplitude;
        p = p * 2.03 + float3(11.7, 7.3, 5.1);
        amplitude *= 0.48;
    }
    return sum;
}

static inline float2 ov1_rotate(float2 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static inline float4 ov1_render(FSQ in, constant Uniforms& u) {
    float2 frag = in.uv * u.res;
    float2 p = (frag * 2.0 - u.res) / max(min(u.res.x, u.res.y), 1.0);
    p *= 1.22;

    // Audio is intentionally a small lighting/wobble input, never a time multiplier.
    // This keeps speech expressive without making the whole object jerk or accelerate.
    float audio = smoothstep(0.08, 0.86, clamp(u.energy, 0.0, 1.0)) * 0.32;
    float t = u.time * 0.18;
    float2 slowP = ov1_rotate(p, t * 0.018);
    float2 warp = float2(
        ov1_fbm(float3(slowP * 1.28 + float2(2.1, -1.7), t * 0.10)),
        ov1_fbm(float3(slowP * 1.46 + float2(-3.2, 4.5), -t * 0.085))
    ) - 0.52;

    float2 q = p + warp * 0.12 * (0.76 + audio * 0.04);
    float radius = length(q);
    float angle = atan2(q.y, q.x);
    float radialNoise = ov1_fbm(float3(q * 1.04, t * 0.12));
    float shellRadius = 0.64
        + (radialNoise - 0.50) * 0.10
        + 0.018 * sin(angle * 2.0 - t * 0.72)
        + audio * 0.006;

    float shellDistance = abs(radius - shellRadius);
    float shellWidth = 0.105 + audio * 0.004;
    float shell = exp(-shellDistance * shellDistance / (shellWidth * shellWidth));
    shell *= smoothstep(shellRadius + 0.13, shellRadius - 0.015, radius);

    float2 ribbonP = ov1_rotate(p + warp * 0.10, -0.48 + t * 0.028);
    float ribbonRadius = length(ribbonP * float2(0.84, 1.18));
    float ribbonDistance = abs(ribbonRadius - 0.50 - 0.025 * sin(angle * 3.0 + t * 0.42));
    float ribbon = exp(-ribbonDistance * ribbonDistance / 0.0105);
    ribbon *= smoothstep(0.82, 0.34, radius) * 0.48;

    float2 foldP = ov1_rotate(p, 0.72 - t * 0.018);
    float foldRadius = length(foldP * float2(1.20, 0.82));
    float fold = exp(-pow(abs(foldRadius - 0.46), 2.0) / 0.009);
    fold *= smoothstep(0.77, 0.28, radius) * 0.28;

    float body = smoothstep(shellRadius + 0.055, shellRadius - 0.20, radius);
    float cloud = ov1_fbm(float3(q * 1.92 + warp * 0.35, -t * 0.10));
    cloud = smoothstep(0.30, 0.82, cloud) * body;
    float innerLight = exp(-dot(p + warp * 0.15, p + warp * 0.15) * 3.6) * body;

    // The hotspot floats around the lower-right quadrant instead of orbiting the orb.
    float highlightAngle = 1.35 + 0.22 * sin(t * 0.36) + 0.07 * sin(t * 0.13);
    float2 highlightPosition = float2(cos(highlightAngle), sin(highlightAngle)) * shellRadius * 0.90;
    float highlight = exp(-dot(p - highlightPosition, p - highlightPosition) * 18.0);
    highlight *= shell * (0.72 + audio * 0.16);

    float angularMix = 0.5 + 0.5 * cos(angle + t * 0.18 + radialNoise * 1.7);
    float3 colorA = float3(0.43, 0.18, 0.98);
    float3 colorB = float3(0.94, 0.25, 0.72);
    // Preserve the purple/pink identity while retaining a restrained hint of the
    // app's existing listening/transcribing/error phase tint.
    float phaseTint = clamp(u.activation * 0.12, 0.0, 0.12);
    colorA = mix(colorA, u.activeColor.xyz, phaseTint);
    colorB = mix(colorB, u.activeColor.xyz, phaseTint * 0.55);
    float3 deep = float3(0.025, 0.018, 0.13);
    float3 color = mix(colorA, colorB, angularMix);

    float structure = shell * 0.88 + ribbon * 0.54 + fold * 0.34;
    float3 rgb = deep * body * 0.72;
    rgb += color * structure * (0.74 + audio * 0.08);
    rgb += mix(colorA, colorB, cloud) * cloud * 0.15;
    rgb += mix(colorA, colorB, 0.64) * innerLight * 0.17;

    float3 hotColor = float3(1.00, 0.58, 0.86);
    rgb += hotColor * highlight * (0.70 + audio * 0.14);

    float outside = max(radius - shellRadius, 0.0);
    float halo = exp(-outside * outside * 48.0)
        * smoothstep(shellRadius + 0.24, shellRadius - 0.01, radius);
    halo *= (0.12 + (0.58 + u.activation * 0.12) * 0.20) * shell;
    rgb += color * halo;

    float peak = max(max(rgb.r, rgb.g), rgb.b);
    rgb = rgb / (1.0 + rgb * 0.32);
    rgb = pow(max(rgb, 0.0), float3(0.92));

    float alpha = max(body * 0.58, structure * 0.92);
    alpha = max(alpha, highlight * 0.92);
    alpha = max(alpha, halo * (0.62 + (0.58 + u.activation * 0.12) * 0.28));
    alpha *= smoothstep(1.03, 0.77, radius);
    alpha = clamp(alpha, 0.0, 1.0);

    rgb = mix(rgb, hotColor * min(1.0, peak), highlight * 0.16);
    return float4(rgb * alpha, alpha);
}

fragment float4 original_v1(FSQ in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    return ov1_render(in, u);
}

// Subtle dark pane behind the additive orb. This is premultiplied-alpha output so the app can
// use normal alpha blending into the HDR scene before the gold web/glow passes add on top.
fragment float4 backing_disc(FSQ in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    if (kOriginalV1Mode) return float4(0.0);
    // Background-adaptive: the backing only appears over LIGHT backgrounds (backingLum→1) so the
    // additive gold web has something to sit on; over dark backgrounds it stays fully transparent
    // (gate→0) and the orb glows free, exactly as Shaan tuned it. smoothstep keeps the fade-in
    // gentle so scrolling across a light/dark edge doesn't pop.
    float gate = smoothstep(0.35, 0.72, u.backingLum);
    if (gate <= 0.0) return float4(0.0);
    float2 uv = in.uv * 2.0 - 1.0;
    float r = length(uv);
    float disc = 1.0 - smoothstep(0.82, 1.14, r);
    disc = clamp(disc, 0.0, 1.0);
    float center = 0.84 + 0.16 * (1.0 - smoothstep(0.0, 0.58, r));
    float alpha = pow(disc, 1.25) * center * 0.42 * gate;
    float3 color = float3(0.012, 0.012, 0.020);
    return float4(color * alpha, alpha);
}

// bright-pass: keep only what's above threshold (the overlap-hot regions)
fragment float4 bright_pass(FSQ in [[stage_in]], texture2d<float> src [[texture(0)]],
                            constant Uniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = src.sample(s, in.uv).rgb;
    float lum = dot(c, float3(0.299,0.587,0.114));
    // Over a light background bloomScale rises (>1), lifting the threshold further so the haze
    // stays contained. The darker-background baseline is also deliberately high for HUD-scale clarity.
    float thr = 0.84 * u.bloomScale;
    float k = max(0.0, lum - thr) / max(lum, 1e-4);
    return float4(c * k, 1.0);
}

// separable gaussian blur (9-tap). direction passed via uniform.
struct BlurU { float2 dir; float2 texel; };
fragment float4 blur_pass(FSQ in [[stage_in]], texture2d<float> src [[texture(0)]],
                          constant BlurU& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float w[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
    float3 acc = src.sample(s, in.uv).rgb * w[0];
    for (int i=1;i<5;i++){
        float2 off = u.dir * u.texel * float(i) * 1.12;
        acc += src.sample(s, in.uv + off).rgb * w[i];
        acc += src.sample(s, in.uv - off).rgb * w[i];
    }
    return float4(acc, 1.0);
}

// composite HDR scene + bloom, then ACES-ish tonemap → LDR
float3 aces(float3 x){
    float a=2.51,b=0.03,c=2.43,d=0.59,e=0.14;
    return clamp((x*(a*x+b))/(x*(c*x+d)+e), 0.0, 1.0);
}
fragment float4 composite_pass(FSQ in [[stage_in]],
                               texture2d<float> scene [[texture(0)]],
                               texture2d<float> bloom [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 sceneSample = scene.sample(s, in.uv);
    float3 hdr = sceneSample.rgb + bloom.sample(s, in.uv).rgb * 0.22;
    float3 ldr = aces(hdr * 0.76);
    // slight warm grade
    ldr *= float3(1.04, 1.0, 0.94);
    // ACES naturally drives dense HDR overlaps toward white. Pull only the brightest pixels
    // back toward the source hue so the core reads hot and saturated rather than chalky; because
    // the source has already passed through reactiveColor, this preserves phase-specific hues.
    float scenePeak = max(max(sceneSample.r, sceneSample.g), sceneSample.b);
    float ldrPeak = max(max(ldr.r, ldr.g), ldr.b);
    float3 sourceChroma = sceneSample.rgb / max(scenePeak, 0.0001);
    float highlightRecovery = smoothstep(0.54, 0.94, ldrPeak) * 0.38;
    ldr = mix(ldr, sourceChroma * ldrPeak, highlightRecovery);
    float glowAlpha = max(max(ldr.r, ldr.g), ldr.b) * 1.08;
    float alpha = clamp(max(glowAlpha, sceneSample.a * 0.92), 0.0, 1.0);
    return float4(ldr, alpha);
}

// ===================== INNER ORB + LIGHTNING (the core nucleus) =====================
// A separate INNER orb inside the outer lattice shell: a hot bright nucleus + crackling
// radial lightning bolts. Drawn as a fullscreen pass into the HDR scene (additive), BEFORE
// the web so the lattice overlays it. Uses the same Uniforms (time, energy, res).

static inline float ihash(float2 p){ return fract(sin(dot(p,float2(41.3,289.1)))*43758.5453); }
static inline float inoise(float2 p){
    float2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
    float a=ihash(i), b=ihash(i+float2(1,0)), c=ihash(i+float2(0,1)), d=ihash(i+float2(1,1));
    return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
}

fragment float4 inner_core(FSQ in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    if (kOriginalV1Mode) return float4(0.0);
    // centered, aspect-correct coords
    float2 uv = in.uv*2.0-1.0;
    uv.x *= u.res.x / max(u.res.y,1.0);
    float r = length(uv);
    float t = u.time;

    float3 col = float3(0.0);
    float pulse = activePulse(u);

    // --- DIM nucleus: small, NOT blown out. Just a warm seed, not a white blob. ---
    float breathe = 0.90 + 0.10*sin(t*1.25) + pulse*0.08;
    float coreR = 0.07 * breathe * (1.0 + pulse*0.22);
    float core = coreR*coreR / (r*r + coreR*coreR*0.5);
    core = pow(core, 1.7);
    col += reactiveColor(float3(1.0,0.80,0.40), u) * core * (0.55 + pulse*0.40);

    // --- LIGHTNING bolts that reach from the core OUT to TOUCH the outer shell (r≈1.0). ---
    // Fewer + slower. Angular gate keeps only a few bolts; each re-strikes on a slow cycle.
    float ang = atan2(uv.y, uv.x);
    float slot = floor(t * 1.55);
    float boltField = inoise(float2(ang*2.2, slot*1.3));
    float bolt = smoothstep(0.80, 0.97, boltField);       // higher gate → FEWER bolts (~3-5)
    // jagged path along the FULL radius (core → shell), so the bolt spans the whole orb
    float jag = (inoise(float2(ang*7.0, r*8.0 - t*4.4)) - 0.5) * 0.05;
    float boltR = r + jag;
    // reach: bright from ~0.06 all the way OUT to ~1.0 (touches the shell), fade just past it
    float radialGate = smoothstep(0.04, 0.12, boltR) * smoothstep(1.08, 0.9, boltR);
    // a bright travelling head runs out along the bolt (strike racing to the surface)
    float head = exp(-pow(boltR - fract(slot*0.37 + t*1.15), 2.0) * 30.0);
    float strike = bolt * radialGate * (0.4 + head*1.2) * (0.7 + u.energy*1.0) * (1.0 + pulse*0.45);
    strike = pow(strike, 1.3);
    col += reactiveColor(float3(1.0, 0.90, 0.62), u) * strike * 1.1;

    float a = max(core, strike);
    return float4(col, a);
}

// ===================== JAGGED LIGHTNING BOLTS (real electric arcs) =====================
// BoltVtx ribbon quads (same pattern as lines). Path is built CPU-side via midpoint
// displacement (jagged) + branches. Hot thin white-gold core + amber halo. Re-strikes.
struct BoltVtxIn {
    float3 a; float3 b; float endSel; float side; float energy; float branch;
};
struct BoltFragIn {
    float4 pos [[position]];
    float  cross;
    float  energy;
    float  branch;
    float  radial;
};
vertex BoltFragIn bolt_vertex(uint vid [[vertex_id]],
                              const device BoltVtxIn* verts [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
    BoltVtxIn v = verts[vid];
    float scale = activeScale(u);
    float4 wA = u.model * float4(v.a * scale,1.0);
    float4 wB = u.model * float4(v.b * scale,1.0);
    float4 cA = u.viewProj * wA;
    float4 cB = u.viewProj * wB;
    float4 cEnd = (v.endSel<0.5)?cA:cB;
    float2 sA = cA.xy/max(cA.w,1e-4), sB = cB.xy/max(cB.w,1e-4);
    float2 dir = normalize(sB-sA+1e-6);
    float2 perp = float2(-dir.y, dir.x);
    float3 endP = (v.endSel<0.5)?v.a:v.b;
    float radial = clamp(length(endP) / 1.05, 0.0, 1.0);
    float coreTaper = mix(1.35, 0.72, radial);
    // trunk wider than branches, and wider near the core origin.
    float widthPx = mix(3.0, 1.3, v.branch) * coreTaper;
    float2 ndcPerW = perp*(widthPx/u.res)*2.0;
    float4 outPos = cEnd; outPos.xy += v.side*ndcPerW*cEnd.w;
    BoltFragIn o; o.pos=outPos; o.cross=v.side; o.energy=v.energy; o.branch=v.branch; o.radial=radial;
    return o;
}
fragment float4 bolt_fragment(BoltFragIn in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    if (kOriginalV1Mode) return float4(0.0);
    // sharp hot core (tight gaussian) + wider soft amber halo
    float x = in.cross;
    float coreG = exp(-x*x*9.0);          // thin hot-gold core
    float haloG = exp(-x*x*2.0);          // wider amber halo
    float3 hotGold = float3(1.0,0.80,0.38);
    float3 amber = float3(1.0,0.62,0.18);
    float sourceBoost = mix(1.32, 0.78, clamp(in.radial, 0.0, 1.0));
    float pulse = activePulse(u);
    float3 col = reactiveColor(hotGold*coreG*1.0 + amber*haloG*0.55, u);
    float a = (coreG*1.0 + haloG*0.42) * in.energy * sourceBoost * (1.0 + pulse*0.50);
    return float4(col*a, a);
}

// ===================== VOLUMETRIC HAZE + INNER GLOW (mixed back from gen19) =====================
// Soft fbm cloud filling the sphere + a tight inner-orb glow. Additive fullscreen under the lines
// so gaps read as warm gas (not black) and the center has a contained glow. Brings back the
// "cloud stuff" + "old orb" feel on top of the new geometry.
static inline float h31(float3 p){ p=fract(p*0.1031); p+=dot(p,p.yzx+33.33); return fract((p.x+p.y)*p.z); }
static inline float vn3(float3 x){
    float3 i=floor(x),f=fract(x); f=f*f*(3.0-2.0*f);
    float n000=h31(i),n100=h31(i+float3(1,0,0)),n010=h31(i+float3(0,1,0)),n110=h31(i+float3(1,1,0));
    float n001=h31(i+float3(0,0,1)),n101=h31(i+float3(1,0,1)),n011=h31(i+float3(0,1,1)),n111=h31(i+float3(1,1,1));
    return mix(mix(mix(n000,n100,f.x),mix(n010,n110,f.x),f.y),mix(mix(n001,n101,f.x),mix(n011,n111,f.x),f.y),f.z);
}
// 3 octaves (was 4). This feeds ONLY the soft background haze cloud (haze_glow), where the
// 4th octave (amplitude 0.0625, under the rim smoothstep + mix) is visually imperceptible.
// Called twice per pixel, so trimming one octave cuts the orb's single heaviest per-pixel
// cost by ~25% — the main GPU lever behind the active-phase CPU spike.
static inline float fbm3(float3 p){ float s=0,a=0.5; for(int i=0;i<3;i++){s+=a*vn3(p);p*=2.03;a*=0.5;} return s; }

fragment float4 haze_glow(FSQ in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    if (kOriginalV1Mode) return ov1_render(in, u);
    float2 uv = in.uv*2.0-1.0;
    uv.x *= u.res.x/max(u.res.y,1.0);
    float r = length(uv);
    if (r > 1.15) return float4(0.0);
    float t = u.time;
    float3 col = float3(0.0);

    // volumetric CLOUD/HAZE: warm brown-gold fog filling the sphere, animated churn.
    // 2 fbm octaves in a fake-3D (uv + slow z drift) → soft moving cloud.
    float angle = t * 0.035;
    float2 huv = float2(cos(angle)*uv.x - sin(angle)*uv.y,
                        sin(angle)*uv.x + cos(angle)*uv.y);
    float3 p = float3(huv*1.6, t*0.18);
    float cloud = fbm3(p*1.4) * fbm3(p*2.7 + 4.0);
    cloud *= smoothstep(1.12, 0.2, r);                  // fade out toward rim, denser inside
    float pulse = activePulse(u);
    float3 hazeCol = mix(float3(0.18,0.07,0.02), float3(0.55,0.26,0.07), cloud); // deep ember→amber
    col += reactiveColor(hazeCol, u) * cloud * (0.30 + pulse*0.10);

    // INNER ORB glow (the old soft nucleus) — TIGHT + dim, just a warm contained seed.
    float breathe = 0.93 + 0.07*sin(t*1.05);
    float gR = 0.13*breathe;
    float glow = gR*gR/(r*r + gR*gR*0.6);
    glow = pow(glow, 1.5);
    col += reactiveColor(float3(1.0,0.66,0.26), u) * glow * (0.30 + pulse*0.16);

    // DARK SPHERE BODY — gives the orb its OWN dark side so it reads 3D and pops on ANY
    // background (was: additive-over-black, borrowing shadow from a black desktop → muddy
    // on white). Now opaque: a dark sphere baked under the web. Shaan 2026-06-05.
    float sphereBody = pow(smoothstep(1.0, 0.0, r), 0.5);   // 1 at center → 0 at rim
    float3 darkSphere = mix(float3(0.03,0.012,0.004), float3(0.09,0.035,0.012), sphereBody*0.5);
    col += darkSphere * sphereBody;

    // alpha owns the silhouette: opaque dark body (0.88) under the glow → real shadow side.
    float a = max(sphereBody * 0.88, max(cloud*0.4, glow*0.5));
    return float4(col, a);
}
