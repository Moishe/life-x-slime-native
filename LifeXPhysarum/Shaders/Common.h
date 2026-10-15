// Shared Metal helpers. The color functions mirror Core/ColorMath.swift; keep
// the two in sync (ColorShaderTests checks that they agree).

#ifndef Common_h
#define Common_h

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

constant float PI = 3.14159265358979;

struct AtomicCounters {
    atomic_uint head;
    atomic_uint childCount;
    atomic_uint aliveCount;
    atomic_uint childrenInserted;
};

// Branchless conversion, ported from Particles' Shaders.metal. Hue in [0, 1].
inline float3 rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    float h = abs(q.z + (q.w - q.y) / (6.0 * d + e));
    return float3(h, d / (q.x + e), q.x);
}

inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

// Distance between two HSV colors, treating hue as circular.
inline float hsv_distance(float3 a, float3 b) {
    float dh = abs(a.x - b.x);
    float hd = min(dh, 1.0 - dh);
    float sd = a.y - b.y;
    float vd = a.z - b.z;
    return sqrt(hd * hd + sd * sd + vd * vd);
}

// Blends two RGB colors in HSV space, going the short way around the hue
// circle. d is the weight toward rgb2.
inline float3 hsv_mix(float3 rgb1, float3 rgb2, float d) {
    float3 a = rgb2hsv(rgb1);
    float3 b = rgb2hsv(rgb2);
    float dh = abs(a.x - b.x);
    float h;
    if (dh < 1.0 - dh) {
        h = mix(a.x, b.x, d);
    } else if (a.x < b.x) {
        h = fract(mix(a.x + 1.0, b.x, d));
    } else {
        h = fract(mix(a.x, b.x + 1.0, d));
    }
    return hsv2rgb(float3(h, mix(a.y, b.y, d), mix(a.z, b.z, d)));
}

// Snaps hue to one of lockToHsvAngles directions (0 = off), then offsets hue
// and scales saturation/value.
inline float4 dominant_color(float4 rgb, uint lockToHsvAngles, float hsvAngleOffset, float satMul, float valMul) {
    if (lockToHsvAngles == 0) {
        return rgb;
    }
    float3 hsv = rgb2hsv(rgb.rgb);
    float n = float(lockToHsvAngles);
    hsv.x = fmod(floor(hsv.x * n + 0.5) / n + hsvAngleOffset, 1.0);
    hsv.y = min(1.0, hsv.y * satMul);
    hsv.z = min(1.0, hsv.z * valMul);
    return float4(hsv2rgb(hsv), rgb.a);
}

// xorshift32. Returns a float in [0, 1). The state must never be 0.
inline float rand(thread uint &state) {
    uint x = state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    state = x;
    return float(x >> 8) / 16777216.0;
}

// Nearest-pixel read where anything outside the texture reads as zero.
inline float4 load_or_zero(texture2d<float, access::read> t, float2 pos) {
    int2 p = int2(floor(pos));
    if (p.x < 0 || p.y < 0 || p.x >= int(t.get_width()) || p.y >= int(t.get_height())) {
        return float4(0.0);
    }
    return t.read(uint2(p));
}

// A triangle covering the whole viewport.
inline float2 fullscreen_corner(uint vid) {
    const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    return corners[vid];
}

// Field pixel coordinates (y down) to clip space (y up).
inline float4 field_to_clip(float2 p, float width, float height) {
    return float4(p.x / width * 2.0 - 1.0, 1.0 - p.y / height * 2.0, 0.0, 1.0);
}

#endif
