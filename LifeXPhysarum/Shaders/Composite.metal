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

static float height_at(constant CompositeParams &composite, const device float *height, int2 c) {
    int w = int(composite.fieldWidth);
    int h = int(composite.fieldHeight);
    int2 q = clamp(c, int2(0), int2(w - 1, h - 1));
    return height[q.y * w + q.x];
}

// Lambert plus a little specular from the height field's slope, taken over a
// two-pixel radius. Flat ground shades to exactly 1, so it looks the same as
// with relief off.
static float relief_shade(constant CompositeParams &composite, const device float *height, float2 uv) {
    int2 c = int2(floor(uv * float2(composite.fieldWidth, composite.fieldHeight)));
    float dx = (height_at(composite, height, c + int2(2, 0)) - height_at(composite, height, c - int2(2, 0))) * composite.heightScale * 0.5;
    float dy = (height_at(composite, height, c + int2(0, 2)) - height_at(composite, height, c - int2(0, 2))) * composite.heightScale * 0.5;
    float3 n = normalize(float3(-dx, -dy, 1.0));
    float3 l = normalize(float3(composite.lightX, composite.lightY, composite.lightZ));
    float diffuse = max(dot(n, l), 0.0) / max(l.z, 0.05);
    float3 halfway = normalize(l + float3(0.0, 0.0, 1.0));
    float specular = pow(max(dot(n, halfway), 0.0), 24.0) - pow(halfway.z, 24.0);
    return diffuse + specular * 0.6;
}

// Physarum layer (alpha ignored) over black, shaded by the relief, then Life
// cells, then the placement ghost, each scaled by its opacity. height is one
// float per field pixel, row-major, in [0, 1].
fragment float4 composite_fragment(ScreenOut in [[stage_in]],
                                   constant CompositeParams &composite [[buffer(0)]],
                                   const device float *height [[buffer(1)]],
                                   texture2d<float> field [[texture(0)]],
                                   texture2d<float, access::read> life [[texture(1)]],
                                   texture2d<float, access::read> ghost [[texture(2)]],
                                   sampler fieldSampler [[sampler(0)]]) {
    float3 rgb = field.sample(fieldSampler, in.uv).rgb * composite.physarumOpacity;
    if (composite.relief > 0.0) {
        rgb *= mix(1.0, relief_shade(composite, height, in.uv), composite.relief);
    }
    float2 gridSize = float2(life.get_width(), life.get_height());
    uint2 cell = uint2(clamp(floor(in.uv * gridSize), float2(0.0), gridSize - float2(1.0)));
    float4 lifeCell = life.read(cell);
    rgb = mix(rgb, lifeCell.rgb, lifeCell.a * composite.lifeOpacity);
    float4 ghostCell = ghost.read(cell);
    rgb = mix(rgb, ghostCell.rgb, ghostCell.a * composite.ghostOpacity);
    return float4(rgb, 1.0);
}
