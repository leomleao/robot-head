# RobotPlayground

A macOS app that drives an `IronGiantCharacter` through every part of the CharacterKit contract, laid out like the
web playground (`site/src/App.tsx`) so the two can sit side by side. It also has a measurement mode that prints one
JSON line per run, for `MEASUREMENTS.md`.

```sh
swift run RobotPlayground                    # the playground
swift run -c release RobotPlayground --measure idle   # one measurement
```

For the web playground next to it: `pnpm install && pnpm run dev`.

Sources: `Sources/RobotPlayground/`. `PlaygroundModel` holds the character and what the controls show, and writes
every change straight through to the character; the views (`PlaygroundView`, `ControlsColumn`) only read and set the
model. `FloatingPanel.swift` is the desktop panel, `StatsSampler.swift` the readouts, `Measure.swift` the
measurement mode and `SpeechBuffer.swift` its generated speech.

## The window

**Stage.** The robot large in the middle, in a transparent `CharacterView` over the site's background: a soft radial
glow, dark by night and light by day. The sun/moon button at the top right switches it (and the controls' colour
scheme). Under the robot, the caption: the expression's name, or the state's, with the state's line from the site.

**States** (bottom row): the nine `CharacterState`s.

**Actions** (left): the eight core actions. The playing one is marked, and under the dock is what is playing and how
the last one ended (`completed`, `interrupted` when another action cut it short, `unsupported`). *Defense hold* is
`ActionOptions.hold` for `defense`, 0.5–6 s.

**Quality** (left, under the actions):

| Control | What it does |
|---|---|
| Auto / Full / Reduced / Low | `view.pacer.forcedBudget`: Auto follows the pacer's policy; the others force its rows, 60 fps full, 30 fps reduced, 20 fps low |
| drawn | frames actually drawn per second, from `view.stats.frames` deltas once a second |
| CPU / frame | `view.stats.cpuTime`: advancing and encoding one frame, a moving average |
| GPU / frame | `view.stats.gpuTime`: the command buffer's GPU start to end, a moving average |
| process CPU | the whole process's user + system CPU time over wall time (`getrusage`), sampled each second, in % of one core |
| budget | the pacer's current budget, and whether it is forced |
| signals | the pacer signals that are set: occluded, locked, user idle, low power, thermal, battery, paused, at rest, speaking… |
| Floating panel | moves the robot to the desktop panel (below); the stage shows a note until it comes back |

**Controls** (right):

| Control | What it does |
|---|---|
| Shell, Eyes | the site's swatches (`palette.body`, `palette.eyes`), plus the system colour picker for any other colour |
| Expression | `expression`: *none* wears the state's own face, or one of the 17 core expressions |
| Speed | `speed` 0.5×–2×; *Paused* is `isPaused` |
| Interactive | the view follows the pointer and turns clicks on the robot into `poke()` |
| Floor shadow | `showsFloorShadow` |
| Seed | makes a new robot with that `seed`, wearing the current settings |
| Mouth | off *Auto*, the slider holds the jaw at `speechLevel`; *Auto* sets `speechLevel = nil`, so the robot talks on its own when speaking, or from the file below |
| Lip-sync a file… | an audio file, played by a `SpeechPlayer` set as the robot's `speechSource` while it plays; it also switches *Auto* on and the state to speaking. *Stop* ends it |
| Look at | `lookTarget`: the pointer, ahead, or a point (the main screen's top-left or bottom-right corner) |
| Reset | the site's defaults; the seed stays |

## The floating panel

A borderless, transparent, non-activating `NSPanel` at the floating level on every Space, with no shadow, holding a
`CharacterView` with `managesWindowClickThrough` on. Clicks pass through it everywhere but the robot's silhouette;
a click on the robot pokes it, and holding the button and moving drags the panel by the robot
(`performDrag(with:)` from the view's `onClick`). It starts at the bottom right of the main screen; the *Close
floating panel* or *Bring it back* button returns the robot to the stage.

It shows the same character as the stage. A character lives in one view at a time (each view advances it every frame
and takes its `onChange`), so the stage lets go of the robot while the panel is open and makes a fresh view when it
comes back.

## Measure mode

```sh
swift run -c release RobotPlayground --measure <scenario> [--seconds 30] [--size 240] [--budget auto|full|reduced|low]
```

It opens only the robot, with no controls, at a resting box of `--size` points, in a normal titled window (kept at the
floating level so the terminal that started it can't cover it), or in the floating panel for `panel`. `--budget`
forces a tier as the playground's Quality control does; `auto` leaves the pacer to decide (on battery, that is 30 fps).
It waits 3 s to settle (pipelines compiled, the window shown), samples for `--seconds`, prints one JSON line to
stdout and exits with status 0. Bad arguments print the usage to stderr and exit with status 2. A line on stderr says
what the pacer ended on, and why. Leave the mouse alone while it runs: nothing moves it for you.

| Scenario | What runs |
|---|---|
| `idle` | state idle, looking at the pointer, which isn't moved |
| `speaking` | state speaking with a live `speechSource`: a `SpeechPlayer` playing generated speech (a 150 Hz buzz in 3–6 Hz syllables, phrases with pauses) at volume 0, so nothing is heard |
| `procedural` | state speaking with no source: the sim's own talking |
| `paused` | `isPaused` |
| `hidden` | idle, and the window is miniaturised half a second in, so occlusion stops drawing |
| `panel` | idle in the floating panel with click-through on |

The line:

```json
{"scenario":"idle","seconds":30.01,"size":240.00,"budget":"auto","fps":29.97,"cpuPercent":3.10,"cpuMsPerFrame":0.31,"gpuMsPerFrame":0.20,"frames":899}
```

| Field | Meaning |
|---|---|
| `scenario`, `size`, `budget` | as given |
| `seconds` | the wall time actually sampled |
| `fps` | frames drawn while sampling, per second |
| `cpuPercent` | the process's user + system CPU time over the wall time, × 100 (100 = one core) |
| `cpuMsPerFrame`, `gpuMsPerFrame` | the view's moving averages at the end, in ms; `null` when no frame was drawn while sampling |
| `frames` | frames drawn while sampling |
