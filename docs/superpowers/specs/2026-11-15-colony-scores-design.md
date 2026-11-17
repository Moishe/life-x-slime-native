# Colony scores: design

Date: 2026-11-15.

## Intent

A **colony score** is a JSON file that describes, over time, what a
Physarum simulation does:

- create **colonies**: groups of actors that share behavior parameters
  such as look distance, speed range and spawn probability;
- **spawn** actors into a colony at given times, with a position, heading,
  speed and color;
- **change** a colony's parameters, or the field-wide parameters, at
  given times, at once, as a ramp, or by following a curve.

A **score renderer** turns a score into an MP4 without using the UI. An
optional soundtrack can be added to the movie. The same renderer runs
from a command-line tool and from a new menu item in the app.

The first use is music. In `~/src/audio-analysis`, `audiomap` turns a
recording into curves and events. A Python mapper turns those into a
score, and the renderer turns the score into a movie with the recording
as its soundtrack.

## Decisions

- **Scores are source-agnostic.** A score knows nothing about audio. Every
  mapping from analysis to score (onsets → spawns, loudness → speed,
  chords → parameter changes) lives in Python, outside this repo. Video or
  spoken-word analysis can produce scores the same way.
- **JSON is the only format.** It matches audiomap's output and this app's
  settings files. A text syntax for writing scores by hand can be added
  later as another front end that produces the same model.
- **The soundtrack is only something muxed into the movie.** The score
  never refers to it. The movie's length comes from the score.
- **One renderer, two front ends.** `ScoreRenderer` has no UI and does not
  depend on `SimulationModel`. The `physarum-render` command-line tool
  and the app's "Render Movie from Score…" both call it.
- **Renders are deterministic.** The same score, settings, soundtrack,
  size and pool size give the same frames. Each render starts from a
  clear field and an RNG seeded by the score.
- **Single colony first.** Phase 1 changes no shaders: the one colony's
  parameters are the global `PhysarumParams`. Phase 2 adds per-colony
  parameters on the GPU. The phase 1 format is already the final format,
  so phase 1 scores stay valid.

## Non-goals (for now)

- Mixing scores with Life, camera or live-audio seeding. A score render
  uses only the score.
- Playing a score live in the app (phase 3).
- Interactions between colonies other than what color-based sensing
  already gives (for example, explicit attraction or repulsion between
  colonies).
- Food. With no Life board there are no deaths and so no food; a score
  `food` op can come later.
- Rotation and zoom over time (phase 3, as world parameters).

## The score format

### Top level

```json
{
  "format": "physarum-score",
  "version": 1,
  "duration": 186.6,
  "seed": 1,
  "world": { "fadeDecrement": 0.002, "physarumOpacity": 1.0 },
  "events": [ ... ],
  "curves": [ ... ]
}
```

| Key | Required | Meaning |
|---|---|---|
| `format` | yes | Always `"physarum-score"`. |
| `version` | yes | `1`. Other versions are an error. |
| `duration` | no | Seconds. Defaults to the last event or curve end plus 5 s. |
| `seed` | no | Seeds every random choice in the render. Defaults to 1. |
| `world` | no | Starting values for world parameters (see Parameters), overriding the base settings. |
| `events` | yes | Timed operations (see below). May be empty. |
| `curves` | no | Parameters that follow a curve over time. |

### Coordinates and units

- **Time** `t` is seconds from the start of the movie, a non-negative
  number.
- **Positions** are fractions of the field: `[x, y]` with `x, y` in
  `[0, 1]`. The origin is the top-left corner and `y` points down, which
  is how the field and the actors' `pos` work. They don't depend on the
  field size.
- **Lengths** used in shapes (`radius`, `width`) are fractions of the
  field side.
- **Angles** are radians, as in the existing parameters (`lookRadians`,
  `directionVariance`). `0` points right (+x). Positive angles turn toward
  +y, which is clockwise on screen.
- **Speeds** are field pixels per step, as in `minSpeed`/`maxSpeed`.
- **Colors** are `"#rrggbb"` or `[r, g, b]` with components in `[0, 1]`.

### Parameters

Parameter names are exactly the names in settings files. They split into
two groups.

**Colony parameters** describe how one colony's actors behave:
`lookSlices`, `lookRadians`, `lookDistance`, `directionRandomization`,
`directionMomentum`, `minSpeed`, `maxSpeed`, `intensity`, `minValue`,
`life`, `alwaysSpawnFromParent`, `spawnRandomOffset`, `spawnProbability`,
`spawnWithSeedColor`, `directionVariance`, `speedVariance`,
`crowdingLimit`, `lockToHsvAngles`, `hsvAngleOffset`,
`hsvSaturationMultiplier`, `hsvValueMultiplier`, `foodSensitivity`,
`foodExhaustion`.

**World parameters** describe the field and the picture:
`fadeDecrement`, `fadeInterval`, `blurMultiplier`, `blurInterval`,
`foodFadeDecrement`, `foodFadeInterval`, `wrapBounds`,
`physarumOpacity`, `relief`, `reliefHeight`, `lightAngle`,
`lightElevation`, `heightGain`, `heightDecay`.

Parameters that are neither, such as `rngSeed`, `poolSize`, the Life
settings and the palette, cannot be set in a score. The pool size comes
from the base settings or the command line.

A parameter's type is the type of its settings field. Integers
(`lookSlices`, `life`, `crowdingLimit`, `alwaysSpawnFromParent`,
`lockToHsvAngles`, the intervals) are rounded to the nearest integer
whenever a ramp or curve sets them. Booleans (`spawnWithSeedColor`,
`wrapBounds`) can only be set by `set` with no ramp.

### Events

Each event is an object with `t` and `op`. Events may appear in any order.
They are sorted by `t`, and events with the same `t` keep their file
order.

#### `create`: start a colony

```json
{ "t": 0, "op": "create", "colony": "melody", "color": "#ff8844",
  "params": { "lookDistance": 12, "minSpeed": 0.5, "maxSpeed": 2.0 } }
```

- `colony`: an identifier (`[A-Za-z_][A-Za-z0-9_-]*`), unique within the
  score. `world` is reserved.
- `color`: the default color for this colony's spawns. Defaults to white.
- `params`: colony parameters. Any not given take their values from the
  base settings.

A colony exists from its `create` event onward. Using it in an earlier
event is an error.

#### `spawn`: add actors

```json
{ "t": 1.32, "op": "spawn", "colony": "melody", "count": 107,
  "at": { "shape": "ring", "center": [0.5, 0.5], "radius": 0.1 },
  "heading": { "mode": "outward", "spread": 0.2 },
  "speed": [1.0, 2.0],
  "color": "#ffaa00" }
```

| Key | Required | Meaning |
|---|---|---|
| `colony` | yes | A colony created at or before `t`. |
| `count` | yes | Number of actors, a positive integer. |
| `at` | no | Where they appear. Defaults to `{"shape": "random"}`. |
| `heading` | no | Which way they face. Defaults to `{"mode": "random"}`. |
| `speed` | no | A number, or `[min, max]` for a uniform random speed per actor. Defaults to the colony's `minSpeed`. |
| `color` | no | The color they deposit. Defaults to the colony's color. |
| `seek` | no | The color they sense for (the actor's `seed`). Defaults to `color`. |
| `life` | no | Steps until the actor dies or respawns. Defaults to the colony's `life`. |

The agent pass already caps each actor's speed at the colony's
`maxSpeed`, so faster spawns are slowed on their first step.

**Shapes** (`at.shape`):

| Shape | Keys | Placement |
|---|---|---|
| `point` | `at: [x, y]` | All actors at one point. |
| `random` | none | Uniform over the field. |
| `rect` | `origin: [x, y]`, `size: [w, h]` | Uniform inside the rectangle. |
| `disc` | `center`, `radius` | Uniform over the disc's area. |
| `ring` | `center`, `radius`, `width` (default 0) | Uniform around the circle, spread ±`width`/2 across it. |
| `line` | `from: [x, y]`, `to: [x, y]` | Uniform along the segment. |

Positions outside the field are wrapped or clamped, following
`wrapBounds`, as respawns already are.

**Headings** (`heading.mode`). Each mode also accepts `spread`: a uniform
random offset in ±`spread` radians, default 0.

| Mode | Keys | Heading |
|---|---|---|
| `random` | none | Uniform in [0, 2π). |
| `fixed` | `angle` | `angle`. A bare number for `heading` means `{"mode": "fixed", "angle": n}`. |
| `outward` | none | Away from the shape's center. |
| `inward` | none | Toward the shape's center. |
| `tangent` | `direction`: `"cw"` or `"ccw"` (default `"cw"`) | Along the circle through the actor around the shape's center. |

`outward`, `inward` and `tangent` work with `point`, `disc` and `ring`.
With other shapes they are an error. With `point`, `outward` spreads
actors evenly over all directions.

#### `set`: change parameters

```json
{ "t": 30.0, "op": "set", "target": "melody",
  "params": { "lookDistance": 20, "lookRadians": 0.9 },
  "ramp": 2.0, "ease": "inOut" }
```

- `target`: a colony, or `"world"`. Colony parameters can only be set on
  a colony, and world parameters only on `"world"`.
- `params`: new values.
- `ramp`: seconds to move from the current value to the new one. Defaults
  to 0 (immediate).
- `ease`: `"linear"` (default), `"in"`, `"out"` or `"inOut"` (cubic).

A later `set` of the same parameter replaces any ramp that is still
running, starting from that parameter's value at that moment.

#### `dissolve`: end a colony (phase 2)

```json
{ "t": 90, "op": "dissolve", "colony": "melody", "fade": 3.0 }
```

All the colony's actors die, either immediately or spread evenly over
`fade` seconds. Their trail fades as usual. After this, the colony may
not be used again.

### Curves

A curve drives one parameter over a span of time.

Sampled, for analysis output on a fixed grid such as audiomap's 10 Hz:

```json
{ "target": "melody", "param": "maxSpeed",
  "start": 0.0, "rate": 10, "values": [1.0, 1.0, 1.3, 2.1] }
```

Keyframed, for hand-written scores:

```json
{ "target": "world", "param": "fadeDecrement",
  "keys": [[0, 0.001], [10, 0.003], [20, 0.001]], "interp": "linear" }
```

- Values between samples or keys are interpolated, `linear` by default
  or `step`.
- A curve controls its parameter from its first sample to its last. Before
  the curve starts, the parameter keeps whatever it had; after it ends,
  the parameter holds the curve's last value.
- Two curves on the same parameter may not overlap, and a `set` of a
  parameter while a curve controls it is an error. Either would be
  ambiguous, and a generated score is more likely to contain one by
  mistake than on purpose.

### Validation

Scores are mostly machine-generated, so validation is strict. A typo in a
parameter name that was silently ignored would waste a render.

- **Errors** stop the render before it starts. They cover structure and
  type mistakes, unknown ops, unknown parameter names (with a "did you
  mean" suggestion), parameters on the wrong kind of target, unknown or
  not-yet-created colonies, overlapping curves, and `set` during a curve.
  Each error gives a JSON path, for example
  `events[12].params.lookDistnce: unknown parameter (did you mean lookDistance?)`.
- **Warnings** are reported but don't stop the render. They cover values
  outside the inspector's ranges, and spawns that the per-step cap pushes
  into later frames (see Timing).
- **Phase 1** also rejects a second `create` and `dissolve`, saying that
  they need multi-colony support.

## Timing

The movie runs at `movieFPS` (30), with one Physarum step per frame, as in
today's audio-file render. Frame `f` stands for the time `f / 30`. Before
step `f`, the renderer:

1. applies every `create` and `set` with `t < (f + 1) / 30` that hasn't
   been applied yet, in sorted order;
2. evaluates ramps and curves at `f / 30` and writes their values;
3. builds the actors for every `spawn` with `t < (f + 1) / 30` that hasn't
   been applied yet, and appends them to a FIFO spawn queue;
4. takes up to `sim.maxSpawnsPerStep` actors from the front of the queue
   for this step. Any actors left over go in following steps, in order,
   and a warning reports them.

Every random choice (positions, headings, speeds) comes from one `Rng`
seeded by `seed`, used in event order. The GPU's per-actor RNG states come
from the same `Rng`, as in `birthsToActors`.

## Components

### `ScoreModel` (pure Swift, no Metal)

- `Score`: the parsed, validated, sorted score.
- `ScoreParser`: JSON → `Score`, or errors with JSON paths, plus warnings.
- `ScoreTimeline`: takes a `Score`, a base `PhysarumParams` and the
  world-related `AppSettings`. For each frame it returns
  `FrameUpdate { colonyParams, worldParams, spawns: [Actor] }`. All event,
  ramp, curve and spawn-geometry logic lives here, so it can be tested
  without a GPU.

### `ScoreRenderer` (Metal and AVFoundation, no UI)

```swift
final class ScoreRenderer {
    struct Options { var size: Int; var poolSize: Int; var soundtrack: URL? }
    init(context: MetalContext, score: Score, base: LoadedSettings, options: Options) throws
    func render(to url: URL, progress: (RenderProgress) -> Void,
                isCancelled: () -> Bool) async throws
}
```

It owns its own `PhysarumSim` (2048 field), `Compositor` and
`MovieRecorder`, so it shares no state with a running `SimulationModel`.
For each frame it gets the `FrameUpdate`, sets `sim.params` and the
height gain and decay, steps the sim, and adds the composited frame, with
the Life layer at opacity 0. Like today's render, it lets the recorder's
backpressure (`isBusy`) pace the loop.

### `physarum-render` (command-line tool)

```
physarum-render SCORE.json [-o OUT.mp4] [--settings BASE.json]
                [--soundtrack AUDIO] [--size 2048|1024] [--pool-size N]
                [--until SECONDS] [--check]
```

- `-o`: the output path. Defaults to `SCORE.mp4` next to the score.
- `--settings`: a settings file for the base parameters. Defaults to the
  app's built-in defaults, not the user's current inspector state, so a
  render doesn't depend on what the app last had.
- `--until`: renders only the start of the score, for quick previews.
- `--check`: validates and prints errors and warnings without rendering.
  It's quick, so the Python mapper can run it on every score it writes.
- `--size`: picks a size from the existing `MovieConfig` candidates. If
  the Mac can't encode the requested size or codec, the tool falls back
  and prints why.
- Progress goes to stderr: one line per second, or a live progress line
  on a TTY.
- Exit codes: 0 for success, 1 for score errors, 2 for usage or I/O
  errors, 3 for a GPU or encoder failure.

**Build.** A new Command Line Tool target in the existing project, built
from the same model, Metal, record and shader sources as the app, with
the same Swift settings (including MainActor default isolation). Today
`MetalContext` loads shaders with `makeDefaultLibrary()`. A tool doesn't
have a bundle with a metallib in it, so `MetalContext` gains an
initializer that loads `default.metallib` from next to the executable.
The tool's build phase puts the metallib there. Proving this works is the
first task of phase 1, because everything else depends on it.

### In the app: "Render Movie from Score…"

A File menu item next to "Render Movie from Audio File…". It opens a panel
for the score, then an optional panel for a soundtrack, then a save panel.
It uses the app's current inspector settings as the base settings: in
the app, what you see is what you render. The command-line tool's
`--settings` gives the same control.

Validation errors appear as a notice, listing at most the first 10 with a
count of the rest. Progress and cancelling use the existing
`renderProgress` status-bar display. The app's own simulation pauses
while the score renders and starts again afterward, as with audio
renders.

### Python side (in `~/src/audio-analysis`, outside this spec)

That repo needs a small `physarum_score` builder that writes valid scores
(with helpers such as `spawn(...)`, `set(...)`, `curve_from(audiomap_curve, ...)`)
and mapping scripts. The renderer's `--check` is the authority on
validity. The builder doesn't have to repeat every rule.

## Phase 2: multiple colonies

Engine changes:

- **Colony index.** `Actor.alive` becomes `colony + 1`, so 0 still means
  dead. Every `alive != 0` check is unchanged. Children copy the parent's
  value; spawns and respawns set it. `Actor` stays 64 bytes.
- **Per-colony parameters.** The colony fields move out of `SimParams`
  into a `ColonyParams` struct, one per colony in a constant buffer
  indexed by `alive - 1`. `SimParams` keeps the field and per-step values.
  The limit is 16 colonies.
- **Respawn within the colony.** A parent chosen from the pool is used
  only if it belongs to the same colony; otherwise the actor respawns at
  random. With many colonies, fewer respawns find a parent, which is
  acceptable for now.
- **Dissolve.** A kernel marks a colony's actors dead (all at once, or a
  fraction each frame over the `fade` time).
- **App path unchanged.** Life, camera and audio seeding use colony 0
  with the inspector's parameters, so `SimulationModel` behaves exactly as
  it does today.
- **Readouts.** Living actors are counted per colony, so the renderer can
  report them.

Open question for phase 2: all colonies share one ring of actors, so a
colony that spawns heavily overwrites everyone else's oldest actors.
Per-colony quotas are possible but complicate the ring. Decide after
seeing real renders.

## Phase 3 and later

- Play a score live in the app with its soundtrack (scrub, loop), to
  iterate on mappings quickly.
- Move "Render Movie from Audio File…" onto `ScoreRenderer`'s frame loop
  behind a per-frame "driver" protocol, so there's one render loop.
- World parameters for `rotation` and `zoom`.
- A `food` op (deposit food in a shape and color).
- A text syntax for writing scores by hand.

## Testing (Swift Testing, test-first, as in the rest of the app)

- **Parser:** valid scores round-trip into `Score`. Each validation rule
  has a failing example whose error path and message the test checks.
- **Timeline (CPU):** events land on the right frames (including at frame
  boundaries); ramps and eases; curve interpolation, holding the last
  value, and integer rounding; spawn-queue spillover; determinism (same
  seed gives identical `Actor` arrays).
- **Spawn geometry:** each shape stays in bounds and has roughly the
  right distribution; each heading mode points the right way.
- **GPU (phase 2):** actors keep their colony through stepping,
  reproduction and respawn; each colony's parameters affect only that
  colony; dissolve.
- **End to end:** a short score (about 2 s at 1024) renders an MP4 with
  the expected number of frames, and with a soundtrack it has an audio
  track as long as the score, following `AudioFileRenderTests`. The
  command-line tool's `--check` exit codes are tested on a valid and an
  invalid score.

## Phase 1 deliverables

1. `MetalContext` loads the metallib from next to the executable, and an
   empty `physarum-render` target builds and opens a Metal device.
2. `ScoreParser` and `ScoreTimeline` with tests (one colony).
3. `ScoreRenderer` and the command-line tool, with the end-to-end test.
4. The app's "Render Movie from Score…" item.
5. An example score in `docs/examples/` written by hand, to try the
   pipeline before the Python mapper exists.
