#include "Common.h"

struct ScreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenOut composite_vertex(uint vid [[vertex_id]]) {
    float2 c = fullscreen_corner(vid);
    ScreenOut out;
    out.position = float4(c, 0.0, 1.0);
    out.uv = float2((c.x + 1.0) * 0.5, (1.0 - c.y) * 0.5);
    return out;
}

// Physarum layer (alpha ignored) over black, then Life cells, then the
// placement ghost, each scaled by its opacity.
fragment float4 composite_fragment(ScreenOut in [[stage_in]],
                                   constant CompositeParams &composite [[buffer(0)]],
                                   texture2d<float> field [[texture(0)]],
                                   texture2d<float, access::read> life [[texture(1)]],
                                   texture2d<float, access::read> ghost [[texture(2)]],
                                   sampler fieldSampler [[sampler(0)]]) {
    float3 rgb = field.sample(fieldSampler, in.uv).rgb * composite.physarumOpacity;
    float2 gridSize = float2(life.get_width(), life.get_height());
    uint2 cell = uint2(clamp(floor(in.uv * gridSize), float2(0.0), gridSize - float2(1.0)));
    float4 lifeCell = life.read(cell);
    rgb = mix(rgb, lifeCell.rgb, lifeCell.a * composite.lifeOpacity);
    float4 ghostCell = ghost.read(cell);
    rgb = mix(rgb, ghostCell.rgb, ghostCell.a * composite.ghostOpacity);
    return float4(rgb, 1.0);
}
