// Storyboard drawing styles (Phil, 2026-11-18): Core Image kernels that turn a photo into an illustration.
// Built by the Core Image build rule in project.yml into Storyboard.ci.metallib, loaded by StoryboardRenderer.
#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" {
namespace coreimage {

static float storyLuma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

static float storyHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

/// Smooth value noise, 0 to 1, for paper grain.
static float storyNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = storyHash(i);
    float b = storyHash(i + float2(1, 0));
    float c = storyHash(i + float2(0, 1));
    float d = storyHash(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Extended difference of Gaussians (Winnenmoeller et al. 2012): ink lines from two blurs of the photo.
/// White paper, dark lines; `p` sharpens, `eps` sets how dark an edge must be, `phi` how soft the line edge is.
float4 storyLines(sample_t near, sample_t far, float p, float eps, float phi) {
    float d = (1.0 + p) * storyLuma(near.rgb) - p * storyLuma(far.rgb);
    float v = d >= eps ? 1.0 : 1.0 + tanh(phi * (d - eps));
    v = clamp(v, 0.0, 1.0);
    return float4(v, v, v, 1.0);
}

/// Everything but the lines' shape: grey or colour bands, solid black shadows, dots or hatching in the
/// mid tones, ink lines, paper grain and ink splatter. `unit` is the picture's width over 1000, so a preview
/// and the full-size panel look the same.
float4 storyCompose(sample_t smooth, sample_t lines,
                    float levels, float shadow, float colourMode, float saturation,
                    float dotMode, float lineDark, float paper, float splatter,
                    float unit, float gamma, destination dest) {
    float2 xy = dest.coord();
    // Brightness (Phil, 2026-11-19): a tone curve before anything is drawn; 1 leaves the picture as it is.
    float3 colour = pow(clamp(smooth.rgb, 0.0, 1.0), float3(gamma));
    float lum = storyLuma(colour);

    // Tone bands. levels < 2 keeps the tones smooth.
    float tone = lum;
    if (levels >= 2.0) {
        tone = clamp(floor(lum * levels) / (levels - 1.0), 0.0, 1.0);
    }
    float grey = mix(0.30, 1.0, tone);

    // Colour: 0 none, 1 sepia, 2 colour (strength in `saturation`).
    float3 c;
    if (colourMode < 0.5) {
        c = float3(grey);
    } else if (colourMode < 1.5) {
        c = grey * float3(1.0, 0.9, 0.74);
    } else {
        float3 chroma = colour / max(lum, 0.04);
        c = clamp(mix(float3(grey), chroma * grey, saturation), 0.0, 1.0);
    }

    // Mid-tone texture: 1 dots, 2 screen tone, 3 hatching, 4 cross-hatching.
    float cell = max(5.0 * unit, 3.0);
    if (dotMode > 0.5 && lum > shadow && lum < 0.72) {
        float ink = 1.0;
        if (dotMode < 2.5) {
            float a = 0.785398;
            float2 r = float2(xy.x * cos(a) + xy.y * sin(a), -xy.x * sin(a) + xy.y * cos(a)) / cell;
            float dist = length(r - round(r));
            float radius = dotMode < 1.5 ? sqrt(clamp(1.0 - lum, 0.0, 1.0)) * 0.55 : 0.28;
            ink = dist < radius ? 0.12 : 1.0;
        } else {
            float s1 = fract((xy.x + xy.y) / (cell * 1.2));
            ink = (s1 < 0.22 && lum < 0.62) ? 0.18 : 1.0;
            if (dotMode > 3.5) {
                float s2 = fract((xy.x - xy.y) / (cell * 1.2));
                ink = min(ink, (s2 < 0.22 && lum < 0.42) ? 0.18 : 1.0);
            }
        }
        c *= ink;
    }

    // Solid black shadows, with a soft edge.
    if (shadow > 0.0) {
        c *= smoothstep(shadow - 0.02, shadow + 0.02, lum);
    }

    // Ink lines.
    c *= mix(1.0, lines.r, lineDark);

    // Ink splatter: a few blots, each with droplets round it, placed by a hash per cell.
    if (splatter > 0.0) {
        float size = 60.0 * unit;
        float2 cellId = floor(xy / size);
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                float2 id = cellId + float2(dx, dy);
                if (storyHash(id + 7.1) > splatter) continue;
                float2 centre = (id + float2(storyHash(id + 1.3), storyHash(id + 2.9))) * size;
                float r = (0.12 + 0.3 * storyHash(id + 4.4)) * size * 0.5;
                float d = length(xy - centre);
                float edge = r * (0.8 + 0.4 * storyNoise((xy - centre) / (r * 0.35)));
                if (d < edge) c = float3(0.02);
                for (int k = 0; k < 5; k++) {
                    float fk = float(k);
                    float ang = 6.2831 * storyHash(id + fk * 3.7);
                    float far = r * (1.4 + 1.6 * storyHash(id + fk * 5.3));
                    float2 drop = centre + float2(cos(ang), sin(ang)) * far;
                    if (length(xy - drop) < r * (0.08 + 0.14 * storyHash(id + fk * 9.1))) c = float3(0.02);
                }
            }
        }
    }

    // Paper: warm white with grain.
    if (paper > 0.0) {
        float grain = storyNoise(xy / max(1.5 * unit, 1.0)) * 0.6 + storyNoise(xy / max(14.0 * unit, 1.0)) * 0.4;
        c *= 1.0 - paper * grain;
        c *= float3(1.0, 0.985, 0.95);
    }
    return float4(clamp(c, 0.0, 1.0), 1.0);
}

}
}
