// The Storyboard look over the whole app (Phil, 2026-11-18): Reset's live 3D view (camera picture and every placed
// object) drawn in the storyboard style, as SceneKit post-processing passes (StoryboardLook.swift). The same
// steps as Storyboard.ci.metal, simplified to run every frame: lines from two blurs, tone bands, colour,
// shadows, dots or hatching, paper. Worked out at half the screen's size, then drawn full screen.
#include <metal_stdlib>
#include <SceneKit/scn_metal>
using namespace metal;

struct LookVertexIn {
    float4 position [[attribute(SCNVertexSemanticPosition)]];
};

struct LookVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex LookVertexOut storyLookVertex(LookVertexIn in [[stage_in]]) {
    LookVertexOut out;
    out.position = in.position;
    out.uv = float2((in.position.x + 1.0) * 0.5, 1.0 - (in.position.y + 1.0) * 0.5);
    return out;
}

static float lookLuma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

static float lookHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float lookNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = lookHash(i);
    float b = lookHash(i + float2(1, 0));
    float c = lookHash(i + float2(0, 1));
    float d = lookHash(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// A soft 3 by 3 blur, `step` apart (in texture coordinates); each tap is itself filtered.
static float3 lookBlur(texture2d<float, access::sample> t, sampler s, float2 uv, float2 step) {
    float3 sum = t.sample(s, uv).rgb * 4.0;
    sum += t.sample(s, uv + float2(step.x, 0)).rgb * 2.0;
    sum += t.sample(s, uv - float2(step.x, 0)).rgb * 2.0;
    sum += t.sample(s, uv + float2(0, step.y)).rgb * 2.0;
    sum += t.sample(s, uv - float2(0, step.y)).rgb * 2.0;
    sum += t.sample(s, uv + step).rgb;
    sum += t.sample(s, uv - step).rgb;
    sum += t.sample(s, uv + float2(step.x, -step.y)).rgb;
    sum += t.sample(s, uv + float2(-step.x, step.y)).rgb;
    return sum / 16.0;
}

/// styleA: lines (0 off to 4 heavy), detail (0 simple to 2 detailed), shadows (0 to 3), tones (0 smooth, 1 to 5).
/// styleB: colour (0 none, 1 sepia, 2 muted, 3 full, 4 bold), texture (0 off, 1 dots, 2 tone, 3 hatch, 4 cross),
/// paper (0 to 3), on (1 when set; 0 means the values never arrived, so the picture shows as it is).
fragment half4 storyLookFragment(LookVertexOut in [[stage_in]],
                                 texture2d<float, access::sample> colorSampler [[texture(0)]],
                                 constant float4& styleA [[buffer(0)]],
                                 constant float4& styleB [[buffer(1)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(colorSampler.get_width(), colorSampler.get_height());
    float3 original = colorSampler.sample(s, in.uv).rgb;
    if (styleB.w < 0.5) { return half4(half3(original), 1.0h); }

    int lines = int(styleA.x + 0.5);
    int detail = clamp(int(styleA.y + 0.5), 0, 2);
    int shadows = clamp(int(styleA.z + 0.5), 0, 3);
    int tones = int(styleA.w + 0.5);
    int colourMode = int(styleB.x + 0.5);
    int dots = int(styleB.y + 0.5);
    int paperStep = clamp(int(styleB.z + 0.5), 0, 3);

    float unit = max(size.x, size.y) / 1000.0;
    float2 pixel = 1.0 / size;
    float sigmas[3] = {2.2, 1.6, 1.15};
    float sigma = max(sigmas[detail] * unit, 1.0);

    // Lines: extended difference of two blurs.
    float near = lookLuma(lookBlur(colorSampler, s, in.uv, pixel * sigma));
    float far = lookLuma(lookBlur(colorSampler, s, in.uv, pixel * sigma * 1.6));
    float epsilons[3] = {0.5, 0.55, 0.62};
    float shifts[5] = {0.0, -0.03, 0.0, 0.04, 0.08};
    float eps = epsilons[detail] + shifts[clamp(lines, 0, 4)];
    float d = 19.0 * near - 18.0 * far;
    float ink = d >= eps ? 1.0 : clamp(1.0 + tanh(12.0 * (d - eps)), 0.0, 1.0);
    float darkness[5] = {0.0, 0.7, 1.0, 1.0, 1.0};
    float lineDark = darkness[clamp(lines, 0, 4)];

    // Flattened colour for the tone bands.
    float spreads[3] = {5.0, 3.5, 2.4};
    float3 colour = clamp(lookBlur(colorSampler, s, in.uv, pixel * spreads[detail] * unit), 0.0, 1.0);
    float lum = lookLuma(colour);
    float tone = lum;
    if (tones > 0) {
        float levels = float(tones + 1);
        tone = clamp(floor(lum * levels) / (levels - 1.0), 0.0, 1.0);
    }
    float grey = mix(0.30, 1.0, tone);
    float3 c;
    if (colourMode == 0) {
        c = float3(grey);
    } else if (colourMode == 1) {
        c = grey * float3(1.0, 0.9, 0.74);
    } else {
        float saturations[5] = {0.0, 0.0, 0.45, 1.0, 1.45};
        float3 chroma = colour / max(lum, 0.04);
        c = clamp(mix(float3(grey), chroma * grey, saturations[clamp(colourMode, 0, 4)]), 0.0, 1.0);
    }

    float shadowLevels[4] = {0.0, 0.12, 0.2, 0.3};
    float shadow = shadowLevels[shadows];
    float2 xy = in.uv * size;
    float cell = max(5.0 * unit, 3.0);
    if (dots > 0 && lum > shadow && lum < 0.72) {
        float mark = 1.0;
        if (dots <= 2) {
            float a = 0.785398;
            float2 r = float2(xy.x * cos(a) + xy.y * sin(a), -xy.x * sin(a) + xy.y * cos(a)) / cell;
            float dist = length(r - round(r));
            float radius = dots == 1 ? sqrt(clamp(1.0 - lum, 0.0, 1.0)) * 0.55 : 0.28;
            mark = dist < radius ? 0.12 : 1.0;
        } else {
            float s1 = fract((xy.x + xy.y) / (cell * 1.2));
            mark = (s1 < 0.22 && lum < 0.62) ? 0.18 : 1.0;
            if (dots >= 4) {
                float s2 = fract((xy.x - xy.y) / (cell * 1.2));
                mark = min(mark, (s2 < 0.22 && lum < 0.42) ? 0.18 : 1.0);
            }
        }
        c *= mark;
    }
    if (shadow > 0.0) {
        c *= smoothstep(shadow - 0.02, shadow + 0.02, lum);
    }
    c *= mix(1.0, ink, lineDark);
    float papers[4] = {0.0, 0.06, 0.12, 0.2};
    float paper = papers[paperStep];
    if (paper > 0.0) {
        float grain = lookNoise(xy / max(1.5 * unit, 1.0)) * 0.6 + lookNoise(xy / max(14.0 * unit, 1.0)) * 0.4;
        c *= 1.0 - paper * grain;
        c *= float3(1.0, 0.985, 0.95);
    }
    return half4(half3(clamp(c, 0.0, 1.0)), 1.0h);
}

/// Draws the half-size styled picture over the whole screen.
fragment half4 storyLookShow(LookVertexOut in [[stage_in]],
                             texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return half4(colorSampler.sample(s, in.uv));
}
