#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// MARK: - F9.1 Breathing background

[[ stitchable ]] half4 breathingGlow(float2 pos, half4 color, float2 size, float time, float intensity) {
    float2 uv = pos / size;
    float aspect = size.x / max(size.y, 1.0);
    float2 center = float2(0.25, 0.05);
    float d = distance(float2(uv.x * aspect, uv.y), float2(center.x * aspect, center.y));
    float pulse = 0.5 + 0.5 * sin(time);
    float wobble = sin(uv.x * 6.3 + time * 0.45) * 0.02 + sin(uv.y * 4.1 - time * 0.6) * 0.02;
    float glow = smoothstep(0.95, 0.0, d + wobble) * (0.35 + 0.65 * pulse) * intensity;
    half3 purple = half3(0.32, 0.07, 0.52);
    return half4(color.rgb + purple * half(glow), color.a);
}

// MARK: - F9.2 Neon bloom

[[ stitchable ]] half4 neonBloom(float2 pos, SwiftUI::Layer layer, float strength, float radius) {
    half4 c = layer.sample(pos);
    half3 acc = half3(0.0);
    float total = 0.0;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            float w = 1.0 / (1.0 + float(x * x + y * y));
            acc += layer.sample(pos + float2(float(x), float(y)) * radius).rgb * half(w);
            total += w;
        }
    }
    half3 blur = acc / half(total);
    half lum = dot(blur, half3(0.30, 0.59, 0.11));
    return half4(c.rgb + blur * lum * half(strength), c.a);
}

// MARK: - F9.3 Message materialize-in

[[ stitchable ]] float2 materialize(float2 pos, float2 size, float progress) {
    float p = clamp(1.0 - progress, 0.0, 1.0);
    float wave = sin(pos.y * 0.15 + p * 20.0) * 18.0 * p;
    float stretch = (pos.x - size.x * 0.5) * 0.6 * p;
    return float2(pos.x + wave + stretch, pos.y);
}

// MARK: - F9.4 Chromatic glitch (error state)

[[ stitchable ]] half4 chromaticGlitch(float2 pos, SwiftUI::Layer layer, float amount, float time) {
    float slice = floor(pos.y / 9.0);
    float rnd = fract(sin(slice * 12.9898 + floor(time * 30.0) * 78.233) * 43758.5453);
    float jitter = (rnd - 0.5) * 24.0 * amount;
    float2 p = float2(pos.x + jitter, pos.y);
    half r = layer.sample(p + float2(6.0 * amount, 0.0)).r;
    half g = layer.sample(p).g;
    half b = layer.sample(p - float2(6.0 * amount, 0.0)).b;
    half a = layer.sample(p).a;
    return half4(r, g, b, a);
}
