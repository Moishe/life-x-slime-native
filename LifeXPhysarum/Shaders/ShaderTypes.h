// Structs shared by the Metal shaders and Swift (through the bridging header),
// so the CPU and GPU always agree on layout. Scalars are 32-bit in both.

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// One Physarum actor (64 bytes). Slots start zeroed, i.e. not alive.
typedef struct {
    simd_float2 pos;
    float dir;
    float speed;
    simd_float4 seed;   // the color this actor senses for (rgb, a = 1)
    simd_float4 color;  // the color it deposits (rgb, a = intensity)
    unsigned int age;
    unsigned int life;
    unsigned int alive;
    unsigned int rng;   // xorshift32 state; never 0
} Actor;

// Per-step uniforms for the agent, inject and deposit passes. Bools are
// unsigned ints so the layout is plain 32-bit words.
typedef struct {
    float width;
    float height;
    unsigned int lookSlices;
    float lookRadians;
    float lookDistance;
    float directionRandomization;
    float directionMomentum;
    float minSpeed;
    float maxSpeed;
    float intensity;
    float foodSensitivity;
    float foodExhaustion;
    unsigned int life;
    int alwaysSpawnFromParent;
    float spawnRandomOffset;
    float spawnProbability;
    float directionVariance;
    float speedVariance;
    unsigned int lockToHsvAngles;
    float hsvAngleOffset;
    float hsvSaturationMultiplier;
    float hsvValueMultiplier;
    unsigned int wrapBounds;
    unsigned int step;
    unsigned int poolSize;
    unsigned int maxChildren;
    unsigned int spawnCount;
    unsigned int crowdingLimit;       // 0 = off
    float minValue;                   // 0 = off
    unsigned int spawnWithSeedColor;
    unsigned int pad1;
    unsigned int pad2;
} SimParams;

// GPU counters; the shaders treat each word as an atomic_uint.
typedef struct {
    unsigned int head;              // ring write head (persists across steps)
    unsigned int childCount;        // children queued this step
    unsigned int aliveCount;        // actors alive after this step's agent pass
    unsigned int childrenInserted;  // running total of children inserted
} Counters;

typedef struct {
    float decrement;
    float blurMultiplier;
    float pad0;
    float pad1;
} FadeParams;

typedef struct {
    float cellSize;
    float foodPerDeath;
    float width;
    float height;
} FoodParams;

// One dead Life cell's food deposit.
typedef struct {
    simd_float4 color;
    simd_uint2 cell;
    simd_uint2 pad;
} FoodSeed;

// Folds one step's pile counts into the height field.
typedef struct {
    float gain;
    float decay;
    unsigned int width;
    unsigned int height;
} HeightParams;

typedef struct {
    float physarumOpacity;
    float lifeOpacity;
    float ghostOpacity;
    float relief;        // relief shading of the Physarum layer from the height field: 0 = flat
    float heightScale;   // height-to-pixel scale for the slope
    float lightX;
    float lightY;
    float lightZ;
    unsigned int fieldWidth;
    unsigned int fieldHeight;
    float rotation;      // radians the field is turned counterclockwise about its center on screen
    float zoom;          // magnification about the center: 1 shows the whole field
} CompositeParams;

#endif
