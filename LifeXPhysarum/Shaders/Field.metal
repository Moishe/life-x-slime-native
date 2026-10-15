#include "Common.h"

// Optionally blurs (3x3 plus a weighted center), then fades, trailIn into trailOut.
// Pixels outside the texture count as zero. Alpha is always written as 1.
kernel void diffuse(constant FadeParams &fade [[buffer(0)]],
                    texture2d<float, access::read> trailIn [[texture(0)]],
                    texture2d<float, access::write> trailOut [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= trailIn.get_width() || gid.y >= trailIn.get_height()) {
        return;
    }
    float4 center = trailIn.read(gid);
    if (fade.blurMultiplier == 0.0) {
        trailOut.write(float4(max(center.rgb - fade.decrement, 0.0), 1.0), gid);
        return;
    }
    float4 total = float4(0.0);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            total += load_or_zero(trailIn, float2(int2(gid) + int2(dx, dy)));
        }
    }
    total += center * fade.blurMultiplier;
    float3 rgb = max(total.rgb / (fade.blurMultiplier + 9.0) - fade.decrement, 0.0);
    trailOut.write(float4(rgb, 1.0), gid);
}

struct SeedOut {
    float4 position [[position]];
    float4 color;
};

// One quad (two triangles) per dead Life cell, covering its block of the
// field. Drawn with additive blending.
vertex SeedOut food_seed_vertex(constant FoodParams &foodParams [[buffer(0)]],
                                const device FoodSeed *seeds [[buffer(1)]],
                                uint vid [[vertex_id]],
                                uint iid [[instance_id]]) {
    const float2 corners[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0),
    };
    FoodSeed seed = seeds[iid];
    float2 p = (float2(seed.cell) + corners[vid]) * foodParams.cellSize;
    SeedOut out;
    out.position = field_to_clip(p, foodParams.width, foodParams.height);
    out.color = float4(seed.color.rgb * foodParams.foodPerDeath, foodParams.foodPerDeath);
    return out;
}

fragment float4 food_seed_fragment(SeedOut in [[stage_in]]) {
    return in.color;
}

vertex float4 fullscreen_vertex(uint vid [[vertex_id]]) {
    return float4(fullscreen_corner(vid), 0.0, 1.0);
}

// Drawn with a reverse-subtract blend, so every channel of the target loses
// `decrement` (clamped at 0 by the unorm format) without reading the texture.
fragment float4 food_fade_fragment(constant FadeParams &fade [[buffer(0)]]) {
    return float4(fade.decrement);
}

// Writes each alive actor's deposit color into pixel floor(pos) of the trail,
// replacing what was there. Where several actors share a pixel, one of them wins.
kernel void deposit(constant SimParams &params [[buffer(0)]],
                    const device Actor *actors [[buffer(1)]],
                    texture2d<float, access::write> trail [[texture(0)]],
                    uint id [[thread_position_in_grid]]) {
    if (id >= params.poolSize) {
        return;
    }
    Actor a = actors[id];
    if (a.alive == 0) {
        return;
    }
    int2 p = int2(floor(a.pos));
    if (p.x < 0 || p.y < 0 || p.x >= int(trail.get_width()) || p.y >= int(trail.get_height())) {
        return;
    }
    trail.write(float4(a.color.rgb, 1.0), uint2(p));
}
