# Life × Physarum (native)

A native macOS port of [`life-x-slime`](../life-x-slime): a Conway's Life board whose
organisms seed an HSV-affinity Physarum (slime mold) simulation. SwiftUI interface,
Metal compute, no web view.

Requires macOS 26 and Xcode 26 (with the Metal Toolchain component).

## Build and run

Open `LifeXPhysarum.xcodeproj` and press ⌘R. The scheme runs the Release
configuration, so the simulation is fast; tests (⌘U) build Debug.

From the command line:

```sh
xcodebuild -project LifeXPhysarum.xcodeproj -scheme LifeXPhysarum -derivedDataPath build/DerivedData test
xcodebuild -project LifeXPhysarum.xcodeproj -scheme LifeXPhysarum -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/LifeXPhysarum.app
```

The project uses Xcode 26 synchronized folders: new files under `LifeXPhysarum/` or
`LifeXPhysarumTests/` are picked up automatically.

## Using it

- **Sidebar:** pick Paint Cells (click toggles a cell, drag paints) or a pattern to stamp.
  **R** rotates the pattern 90°.
- **Inspector** (⌥⌘I): every setting, in collapsible sections. Hover a control for what it
  does and its name in settings files and Particles; right-click to reset it to its default.
- **Toolbar:** play/pause, step, random fill, clear, trail/food view, record, inspector.
- **Status bar:** frame rate, Physarum steps per second, live actors, organisms, and actors
  added per second by Life births and by reproduction.

| Action | Shortcut |
| --- | --- |
| Play / pause | Space (in the field) or ⌘P |
| Step one generation | → (in the field) or ⌘↩ |
| Rotate pattern | R (in the field) or ⌘R |
| Show trail / food | ⌘1 / ⌘2, or T to toggle |
| Random fill / clear board | ⇧⌘F / ⇧⌘⌫ |
| Open / save settings | ⌘O / ⌘S |
| Export images | ⇧⌘E |
| Record movie / stop | ⇧⌘R |

Settings files are the web version's JSON format, so presets move between the two.
Export Images writes the Life layer, the trail and the mix as 2048×2048 PNGs into a new
folder. Movies are 2048×2048 H.264 at 30 fps (one frame per Physarum step), written
straight to disk; HEVC or 1024×1024 is used if this Mac can't encode that.

## How it's built

| Folder | What's there |
| --- | --- |
| `Core/` | Seedable RNG (bit-identical to the web's mulberry32) and the CPU color math |
| `Life/` | Life engine, organism tracker, palette, patterns, `LifeWorld`, and `LifeRunner`, which runs Life on its own queue |
| `Bridge/` | Births → actors, deaths → food, and the burst/trickle spawn scheduler |
| `Physarum/` | `PhysarumPasses` (each GPU pass) and `PhysarumSim` (one step, three frames in flight) |
| `Shaders/` | Metal kernels; `ShaderTypes.h` is shared with Swift through the bridging header |
| `Render/` | The compositor and snapshots |
| `Record/` | AVFoundation movie recorder, PNG export |
| `UI/`, `App/` | SwiftUI views, menus, the `SimulationModel`, settings and settings files |

The simulation follows the web version's spec
(`life-x-slime/docs/superpowers/specs/2026-10-03-life-x-physarum-design.md`), including its
fixes to Particles. Differences:

- **Deposit is a compute pass.** Rasterizing a million scattered 1-px points is ~9× slower
  on Apple's tile-based GPUs. Where several actors land on one pixel, which one wins is
  unspecified (it was the highest slot before); either way, one overwrites the rest.
- **Sensing skips empty food.** Where food alpha is 0 the food term is 0, so the HSV math
  is skipped; results are identical.
- **Life runs off the main thread,** so big boards don't stall drawing. While recording,
  each tick finishes before the step it feeds, as before.
- **Paint drag:** dragging in paint mode paints the state the first click produced.

## Tests

Swift Testing, hosted in the app so the GPU tests can use its shaders. The unit and GPU
integration tests are ported from the web version (Life, tracker, palette, spawner,
settings files, every Metal pass, the full step, the compositor), plus a Metal-vs-Swift
color check, the Life runner, and an end-to-end movie recording.

In Debug builds, `LXP_DEBUG_SNAPSHOT` (see `App/DebugSnapshot.swift`) scripts a scene and
saves the window, the field and the readouts into the app container's `tmp` folder.
