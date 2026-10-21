#include "Common.h"

// Starting "worst" sensor score, as in Particles.
constant float MIN_DISTANCE = 5.0;

// The agent kernel's bindings, passed down to its helpers.
#define AGENT_ARGS constant SimParams &params, device Actor *actors, device Actor *children, \
    device AtomicCounters &counters, device atomic_uint *density, \
    texture2d<float, access::read> trail, texture2d<float, access::read> food
#define AGENT_PASS params, actors, children, counters, density, trail, food

static bool is_out_of_bounds(constant SimParams &params, float2 p) {
    return p.x < 0.0 || p.y < 0.0 || p.x >= params.width || p.y >= params.height;
}

// Wraps into the field when wrapBounds is on, otherwise clamps.
static float2 keep_in_field(constant SimParams &params, float2 p) {
    float2 dims = float2(params.width, params.height);
    float2 inside = dims - float2(0.001);
    if (params.wrapBounds != 0) {
        return min(p - floor(p / dims) * dims, inside);
    }
    return clamp(p, float2(0.0), inside);
}

// The field pixel under p. Respawns can land just outside the field, so it clamps.
static uint pixel_index(constant SimParams &params, float2 p) {
    uint2 c = uint2(clamp(floor(p), float2(0.0), float2(params.width, params.height) - 1.0));
    return c.y * uint(params.width) + c.x;
}

static float4 hue_lock(constant SimParams &params, float3 rgb) {
    return dominant_color(float4(rgb, 1.0), params.lockToHsvAngles, params.hsvAngleOffset,
                          params.hsvSaturationMultiplier, params.hsvValueMultiplier);
}

// Respawn in place, per alwaysSpawnFromParent (> 0 from a random living
// parent, otherwise at a random position keeping its own color). A parent
// passes on its trail-blended color, or its seed when spawnWithSeedColor is on.
static void respawn(AGENT_ARGS, thread Actor &a, thread uint &rng) {
    bool fromParent = false;
    if (params.alwaysSpawnFromParent > 0) {
        uint parentId = uint(rand(rng) * float(params.poolSize)) % params.poolSize;
        // Another thread may be updating this slot: a benign race, as in Particles.
        Actor parent = actors[parentId];
        if (parent.alive != 0) {
            a.pos = parent.pos;
            a.dir = parent.dir;
            a.color = hue_lock(params, params.spawnWithSeedColor != 0 ? parent.seed.rgb : parent.color.rgb);
            fromParent = true;
        }
    }
    if (!fromParent) {
        a.pos = float2(rand(rng) * params.width, rand(rng) * params.height);
        a.color = hue_lock(params, a.seed.rgb);
    }
    a.seed = a.color;
    float side = a.dir + PI / 2.0;
    if (rand(rng) < 0.5) {
        side -= PI;
    }
    a.pos += float2(cos(side), sin(side)) * params.spawnRandomOffset;
    a.age = 0;
    a.life = params.life;
    a.speed = params.minSpeed;
}

// Returns the direction of the best-scoring sensor (lower score is better).
static float sense(AGENT_ARGS, Actor a) {
    float3 seedHsv = rgb2hsv(a.seed.rgb);
    uint slices = max(params.lookSlices, 1u);
    float newDir = a.dir;
    float minScore = MIN_DISTANCE;
    for (uint i = 0; i < slices; i++) {
        for (uint j = 0; j < 2; j++) {
            float offset = float(i) / float(slices) * params.lookRadians;
            if (j == 0) {
                offset = -offset;
            }
            float t = a.dir + offset;
            float2 look = a.pos + float2(cos(t), sin(t)) * params.lookDistance;
            float dist = hsv_distance(rgb2hsv(load_or_zero(trail, look).rgb), seedHsv);
            float foodVal = 0.0;
            if (params.foodSensitivity > 0.0) {
                float4 f = load_or_zero(food, look);
                // Most of the field has no food, where foodVal is 0 anyway.
                if (f.a > 0.0) {
                    float fd = hsv_distance(rgb2hsv(f.rgb), seedHsv);
                    foodVal = params.foodSensitivity * f.a * max(0.0, 1.0 - fd);
                }
            }
            float score = dist - foodVal;
            if (score < minScore) {
                newDir = t;
                minScore = score;
            }
        }
    }
    return newDir;
}

static void maybe_spawn_child(AGENT_ARGS, Actor a, thread uint &rng) {
    if (rand(rng) >= params.spawnProbability) {
        return;
    }
    uint index = atomic_fetch_add_explicit(&counters.childCount, 1u, memory_order_relaxed);
    if (index >= params.maxChildren) {
        return;
    }
    Actor c = a;
    if (params.spawnWithSeedColor != 0) {
        c.color = a.seed;
    }
    float offset = (rand(rng) * 2.0 - 1.0) * params.spawnRandomOffset;
    c.pos = keep_in_field(params, a.pos + float2(-sin(a.dir), cos(a.dir)) * offset);
    c.dir = a.dir + (rand(rng) * 2.0 - 1.0) * params.directionVariance;
    float speedCap = max(params.maxSpeed, params.minSpeed);
    c.speed = clamp(a.speed * (1.0 + (rand(rng) * 2.0 - 1.0) * params.speedVariance), params.minSpeed, speedCap);
    c.age = 0;
    c.life = params.life;
    c.alive = 1;
    c.rng = (rng ^ 0x9e3779b9u) | 1u;
    children[index] = c;
}

// Advances one actor by a step; returns whether it is alive afterwards.
static bool step_actor(AGENT_ARGS, uint id) {
    Actor a = actors[id];
    if (a.alive == 0) {
        return false;
    }
    uint rng = a.rng;

    a.pos += a.speed * float2(cos(a.dir), sin(a.dir));
    bool outOfBounds = is_out_of_bounds(params, a.pos);
    if (outOfBounds && params.wrapBounds != 0) {
        a.pos = keep_in_field(params, a.pos);
        outOfBounds = false;
    }

    float4 foodHere = load_or_zero(food, a.pos);
    bool exhausted = params.foodExhaustion > 0.0 && foodHere.a >= params.foodExhaustion;
    if (a.age > a.life || outOfBounds || exhausted) {
        if (params.alwaysSpawnFromParent < 0) {
            a.alive = 0;
            a.rng = rng;
            actors[id] = a;
            return false;
        }
        respawn(AGENT_PASS, a, rng);
    }

    float newDir = sense(AGENT_PASS, a) + (rand(rng) - 0.5) * params.directionRandomization;
    a.dir = mix(a.dir, newDir, 1.0 - params.directionMomentum);
    a.dir = fmod(a.dir, 2.0 * PI);
    a.speed = min(max(params.maxSpeed, params.minSpeed), a.speed + rand(rng) * 0.01);
    a.age += 1;

    float4 trailHere = load_or_zero(trail, a.pos);
    float3 rgb = hsv_mix(trailHere.rgb, a.color.rgb, params.intensity);
    // Floor the value so colonies wandering over the black field don't fade to black.
    if (params.minValue > 0.0) {
        float3 hsv = rgb2hsv(rgb);
        hsv.z = max(hsv.z, params.minValue);
        rgb = hsv2rgb(hsv);
    }
    a.color = float4(rgb, params.intensity);

    // Only the first crowdingLimit actors to reach a pixel this step may reproduce.
    bool crowded = params.crowdingLimit > 0
        && atomic_fetch_add_explicit(&density[pixel_index(params, a.pos)], 1u, memory_order_relaxed) >= params.crowdingLimit;
    if (!crowded) {
        maybe_spawn_child(AGENT_PASS, a, rng);
    }
    a.rng = rng;
    actors[id] = a;
    return true;
}

// Moves, kills/respawns, steers and reproduces every actor, counting the living.
// density counts actors per field pixel this step (for crowdingLimit); it must
// be cleared before the pass when crowdingLimit is on.
kernel void agent_step(constant SimParams &params [[buffer(0)]],
                       device Actor *actors [[buffer(1)]],
                       device Actor *children [[buffer(2)]],
                       device AtomicCounters &counters [[buffer(3)]],
                       device atomic_uint *density [[buffer(4)]],
                       texture2d<float, access::read> trail [[texture(0)]],
                       texture2d<float, access::read> food [[texture(1)]],
                       uint gid [[thread_position_in_grid]]) {
    bool alive = gid < params.poolSize && step_actor(AGENT_PASS, gid);
    // One global atomic per SIMD group instead of one per actor.
    uint n = simd_sum(alive ? 1u : 0u);
    if (simd_is_first() && n > 0) {
        atomic_fetch_add_explicit(&counters.aliveCount, n, memory_order_relaxed);
    }
}

// Copies this step's Life spawns and queued children into the actor ring,
// overwriting the oldest slots.
kernel void inject(constant SimParams &params [[buffer(0)]],
                   device Actor *actors [[buffer(1)]],
                   const device Actor *spawns [[buffer(2)]],
                   const device Actor *children [[buffer(3)]],
                   device AtomicCounters &counters [[buffer(4)]],
                   uint i [[thread_position_in_grid]]) {
    uint childCount = min(atomic_load_explicit(&counters.childCount, memory_order_relaxed), params.maxChildren);
    Actor source;
    if (i < params.spawnCount) {
        source = spawns[i];
    } else if (i - params.spawnCount < childCount) {
        source = children[i - params.spawnCount];
        atomic_fetch_add_explicit(&counters.childrenInserted, 1u, memory_order_relaxed);
    } else {
        return;
    }
    uint slot = atomic_fetch_add_explicit(&counters.head, 1u, memory_order_relaxed) & (params.poolSize - 1);
    actors[slot] = source;
}
