#include "Common.h"

// Evaluates the shared color functions for ColorShaderTests, which compares
// them with Core/ColorMath.swift. Not used by the app itself.
kernel void color_probe(const device float4 *a [[buffer(0)]],
                        const device float4 *b [[buffer(1)]],
                        device float4 *out [[buffer(2)]],
                        uint i [[thread_position_in_grid]]) {
    float4 x = a[i];
    float4 y = b[i];
    out[i * 4 + 0] = float4(rgb2hsv(x.rgb), 0.0);
    out[i * 4 + 1] = float4(hsv2rgb(x.rgb), 0.0);
    out[i * 4 + 2] = float4(hsv_mix(x.rgb, y.rgb, x.w), hsv_distance(rgb2hsv(x.rgb), rgb2hsv(y.rgb)));
    out[i * 4 + 3] = dominant_color(float4(x.rgb, 1.0), 6, 0.1, 0.8, 1.2);
}
