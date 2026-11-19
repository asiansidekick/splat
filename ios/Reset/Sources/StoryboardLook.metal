// The Storyboard look over the whole app (Phil, 2026-11-18): Reset's live 3D view (camera picture and every placed
// object) drawn in the storyboard style, as SceneKit post-processing passes (StoryboardLook.swift). The same
// steps as Storyboard.ci.metal, simplified to run every frame: lines from two blurs, tone bands, colour,
// shadows, dots or hatching, paper. Worked out at half the screen's size, then drawn full screen.
#include <metal_stdlib>
using namespace metal;
// SceneKit's header expects the metal namespace already in use.
#include <SceneKit/scn_metal>

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

/// The style arrives as the size of a small texture (`styleCode`), which SceneKit always passes along. Build 1360 sent
/// it as two vec4 values instead; they never reached the shader on Phil's phone, so the picture showed plain.
/// Width - 1 = lines + 5 * detail + 20 * shadows + 80 * light; height - 1 = tones + 7 * colour + 35 * texture
/// + 175 * paper.
fragment half4 storyLookFragment(LookVertexOut in [[stage_in]],
                                 texture2d<float, access::sample> colorSampler [[texture(0)]],
                                 texture2d<float, access::sample> styleCode [[texture(1)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(colorSampler.get_width(), colorSampler.get_height());

    int a = int(styleCode.get_width()) - 1;
    int b = int(styleCode.get_height()) - 1;
    // Not a style code (SceneKit sized the texture another way): Marker.
    if (a < 0 || a >= 400 || b < 0 || b >= 700) { a = 3 + 5 * 1 + 20 * 1 + 80 * 2; b = 4; }
    int lines = a % 5;
    int detail = (a / 5) % 4;
    int shadows = (a / 20) % 4;
    int light = clamp(a / 80, 0, 4);
    int tones = b % 7;
    int colourMode = (b / 7) % 5;
    int dots = (b / 35) % 5;
    int paperStep = clamp(b / 175, 0, 3);
    float gammas[5] = {1.6, 1.25, 1.0, 0.75, 0.55};
    float gamma = gammas[light];

    float unit = max(size.x, size.y) / 1000.0;
    float2 pixel = 1.0 / size;
    float sigmas[4] = {2.2, 1.6, 1.15, 0.85};
    float sigma = max(sigmas[detail] * unit, 1.0);

    // Lines: extended difference of two blurs.
    float near = lookLuma(lookBlur(colorSampler, s, in.uv, pixel * sigma));
    float far = lookLuma(lookBlur(colorSampler, s, in.uv, pixel * sigma * 1.6));
    float epsilons[4] = {0.5, 0.55, 0.62, 0.68};
    float shifts[5] = {0.0, -0.03, 0.0, 0.04, 0.08};
    float eps = epsilons[detail] + shifts[clamp(lines, 0, 4)];
    float d = 19.0 * near - 18.0 * far;
    float ink = d >= eps ? 1.0 : clamp(1.0 + tanh(12.0 * (d - eps)), 0.0, 1.0);
    float darkness[5] = {0.0, 0.7, 1.0, 1.0, 1.0};
    float lineDark = darkness[clamp(lines, 0, 4)];

    // Flattened colour for the tone bands.
    float spreads[4] = {5.0, 3.5, 2.4, 1.5};
    float3 colour = pow(clamp(lookBlur(colorSampler, s, in.uv, pixel * spreads[detail] * unit), 0.0, 1.0), float3(gamma));
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

/// Fills the style code target; only its size matters.
fragment half4 storyLookCode(LookVertexOut in [[stage_in]]) { return half4(0.0h); }

/// Draws the half-size styled picture over the whole screen.
fragment half4 storyLookShow(LookVertexOut in [[stage_in]],
                             texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return half4(colorSampler.sample(s, in.uv));
}
