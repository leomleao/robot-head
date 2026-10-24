# Summary: the Iron Giant in Swift and Metal

Branch `leomleao/swift-metal-port`, based on local `main` (a70d4de). Not pushed.

## What was built

**RobotKit**, a Swift package at the repo root (tools 6.4, macOS 27, Swift 6 strict concurrency, no
dependencies). The TS library, the `site/` playground, the pnpm workspace and the Worker are unchanged and still
build.

| Target | What it is |
|---|---|
| `CharacterKit` | The contract every character conforms to (`CharacterRenderer`; open string-backed `CharacterExpression` / `CharacterAction`, closed `CharacterState`, `CharacterPalette`/`CharacterColor`, `LookTarget`, `SpeechLevelSource`), and what they share: `CharacterView` (transparent `MTKView` on a paced display link: pointer, clicks → `poke`, silhouette hit-testing, optional window click-through for a floating panel), `CharacterViewRepresentable` (SwiftUI), `RenderPacer` + `SystemSignals` (occlusion, lock, display/system sleep, user and character idle, Low Power Mode, thermal, battery, Reduce Motion → fps and quality tier), `SpeechPlayer` (plays PCM/files with a level envelope synced to playback, `volume`, `onFinish`) and `AudioLevelMeter` (a tap on any node), `OffscreenRenderer`, `CharacterRegistry` |
| `IronGiant` | `IronGiantCharacter`: the sculpt (same bytes as `model.ts`) rasterised on the GPU through a depth buffer with 4× MSAA, the light.ts lighting per fragment, the ink outline as a composite pass, each eye (socket, glow, pentagon, iris, lids, seam, bloom) analytically in a fragment shader; the sim and rig ported step for step; CPU hit-testing on the light mesh, cached per pose |
| `RobotPlayground` | `swift run RobotPlayground`: the web playground's controls natively, live fps/CPU/GPU, a click-through floating panel, and `--measure` |

## Evidence

- **73 tests** (`swift test`): golden traces recorded from the TS sim (11 scenarios × 6 seeds, every frame within
  5e-8), geometry vs TS values, contract semantics, pacer policy, audio mapping, view hit-testing, and visual
  parity and regression.
- **Parity** (`PARITY.md`): all 32 stills captured from the web playground's canvas match the Metal renders (mean
  difference 0.85–1.43/255; at most 1.5% of pixels past 24/255, all along edges). No visible deviation, so gate G1
  was not needed.
- **Measurements** (`MEASUREMENTS.md`, M4 Pro, on battery): 0.35 ms CPU + 0.2 ms GPU per frame; the whole
  process at 3.8% of a core at 30 fps idle, 4.3% speaking, 6.3% at 60 fps; 0.03% when stopped (paused, hidden,
  locked, or 5 minutes with neither the user nor the character doing anything).

## Deviations

None visible. Depth buffer instead of a painter's sort, exact per-triangle lighting instead of the TS's
quantised shade cache, MSAA instead of Canvas2D AA, occlusion/power pacing in place of IntersectionObserver, a
global pointer, and actions that keep time while hidden. Details in `PARITY.md`. Two TS quirks were ported as-is
and are worth fixing upstream (the springs' underdamped slots land on pitch, roll and red instead of
yaw/pitch/roll; actions play while sleeping).

## Contract changes after G0, for Leo to confirm

- `RGBColor` → `CharacterColor`: AppKit's QuickDraw also defines `RGBColor`, so every Buddy file importing both
  would have had to disambiguate. Same shape and meaning.
- Additions: `SpeechPlayer.volume` and `onFinish`, `PacingSignals.characterIdleSeconds`,
  `RenderPacer.onSignalsChange`.
- Documented: a character lives in one `CharacterView` at a time; `onClick` fires on mouse down.

## For Buddy

```swift
CharacterRegistry.register(IronGiantCharacter.self)
let robot = CharacterRegistry.make("iron-giant", seed: .random(in: 0..<1))!
let view = CharacterView(character: robot)          // in a borderless, non-activating, transparent NSPanel
view.managesWindowClickThrough = true
robot.state = .speaking
let voice = SpeechPlayer(); voice.onFinish = { robot.state = .idle }
try voice.play(buffer: elevenLabsPCM); robot.speechSource = voice
robot.expression = .curious                         // from the LLM's early cue
await robot.play(.nod)
```

## For WALL-E

`WALL-E.md`: what a second character implements, how the shared words map onto him (`defense` → compacting into
his cube, speech level → eyes and body), and the mesh vs SDF choice for a character built from primitives.

## How the work was run

Plan and DAG first (`PLAN.md`, `DAG.md`); Leo approved the contract at G0. Four supervised Orca workers in child
worktrees took the sim port (W1), pacing and audio (W2), web reference capture (W3) and the playground (W4); the
coordinator did the skeleton, geometry, renderer, view, integration, parity, measurements and docs, and merged
each branch. An independent code review of the view and renderer found six pacing/action bugs, all fixed with
tests where testable.
