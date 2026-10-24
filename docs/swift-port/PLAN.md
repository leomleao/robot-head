# Plan: the Iron Giant in Swift and Metal (RobotKit)

A native port of the robot-heads renderer for **Buddy**, the macOS desktop companion: a Swift package at the repo root,
`RobotKit`, with a character-agnostic contract (`CharacterKit`), the Iron Giant as its first implementation
(`IronGiant`), a reusable Metal view, lip-sync from audio, a power-aware render pacer, and a playground app for
side-by-side comparison with the web playground. WALL-E is the next character on the same contract.

The TypeScript library, the `site/` playground, the pnpm workspace and the Cloudflare Worker stay as they are.

> **Base note.** Orca cut this worktree from `origin/main` (58ebf64, the upstream TV head). The Iron Giant lives on
> local `main` (a70d4de, 17 commits ahead, unpushed), so the branch was reset onto it before any work. The source of
> truth for parity is `src/robot/` at a70d4de.

## 1. What is being ported

| TS file | What it does | Port |
|---|---|---|
| `src/robot/model.ts` | the EMA Labs sculpt (CC BY 4.0): cranium + jaw, base64 int16 positions, uint16 triangles, int8 per-triangle normals, per-triangle material; a full and a low-detail mesh; eye, hinge, profile and bounds constants | generated into Swift by a script, same bytes |
| `src/robot/geometry.ts` | decoding, the head's measurements, `rotation`, `craniumFront`, the jaw's smile bend, the jaw's front panel | Swift for the CPU-side parts; the smile bend moves to the vertex shader |
| `src/robot/light.ts` | the studio lighting model (key, fill, sky, softbox, window reflection with Fresnel, rim) and the ACES-like display curve | MSL, evaluated per fragment |
| `src/robot/render.ts` | framing, per-frame CPU projection, per-quad lighting with a cached octahedral shade map, painter's sort, Canvas2D fills, ink outline, sockets, glow, iris, lids, seam, bloom, floor shadow | **GPU**: meshes through a depth buffer, the face as analytic shaders, ink as a composite pass |
| `src/robot/rig.ts` | the face rig, 17 expression presets, face springs (Float32), scripted sequences (blink, defence on/off, wake) | Swift, faithfully, Float32 where TS uses `Float32Array` |
| `src/robot/sim.ts` | the state machine: head springs, glances, blinks, tilts, procedural jaw (phrase, hum, laugh), actions with promises, surprise, poke, external mouth level, per-state motion, `REST` poses | Swift, faithfully, same RNG (mulberry32 with `Math.imul` semantics) |
| `src/audio.ts` | RMS of ~20 ms of audio → 0–1 jaw level, gated and curved | `AVAudioEngine` tap, same mapping |
| `src/ticker.ts`, `RobotHead.tsx` | the shared rAF loop, pointer tracking, IntersectionObserver pause, reduced motion, still pose | `CharacterView` + `RenderPacer` |

## 2. Package layout

`Package.swift` at the repo root (SwiftPM git dependencies need it there), tools-version 6.4, Swift 6 language mode
(strict concurrency), `platforms: [.macOS(.v27)]`. No external dependencies.

```
Package.swift
Sources/
  CharacterKit/            character-agnostic: the contract, the view, pacing, audio
    Vocabulary.swift         CharacterState, CharacterExpression, CharacterAction, ActionOptions, ActionOutcome
    Appearance.swift         RGBColor, CharacterPalette
    CharacterRenderer.swift  the protocol, FrameInput, CharacterFraming, RenderTarget, QualityTier
    Registry.swift           renderer id → factory, for Buddy's data-driven character packs
    View/CharacterView.swift       MTKView subclass: display link, pacing, pointer, click, hit-testing
    View/CharacterViewRepresentable.swift   SwiftUI wrapper
    View/OffscreenRenderer.swift   any character → CGImage (snapshots, tests, contact sheets)
    Pacing/RenderPacer.swift       pure policy: signals → budget (fps, quality tier)
    Pacing/SystemSignals.swift     occlusion, screen lock, display sleep, Low Power Mode, thermal, battery, Reduce Motion, user idle
    Audio/AudioLevelMeter.swift    AVAudioEngine tap → speech level (the TS mapping)
  IronGiant/
    IronGiantCharacter.swift  the public CharacterRenderer
    Model/ModelData.swift     generated from src/robot/model.ts (base64, identical bytes)
    Model/Meshes.swift        decoding, flat GPU vertex arrays, jaw panel, measurements
    Sim/Rig.swift             face rig, expressions, springs, sequences
    Sim/Sim.swift             the state machine
    Render/Framing.swift      frameFor, HeadTransform (CPU projection for eyes, plate, seams, hit-testing)
    Render/Shaders.swift      MSL source, compiled at runtime
    Render/IronGiantRenderer.swift   pipelines, buffers, encoding
    Render/HitTest.swift
  RobotPlayground/          executable: the macOS playground mirroring site/
Tests/
  CharacterKitTests/        pacer policy, vocabulary, meter mapping, registry
  IronGiantTests/           sim (incl. golden traces from the TS sim), rig, model decode, framing, hit-test, snapshots
scripts/swift/              model export, TS golden-trace and web-reference capture
docs/swift-port/            this plan, the DAG, parity report, measurements, WALL-E guide
```

### Why shaders are compiled at runtime

SwiftPM 6.4 compiles `.metal` files only with the separately downloaded *Metal Toolchain* component
(`xcodebuild -downloadComponent MetalToolchain`), which this machine does not have, and which every machine that
builds Buddy would then need. Compiling the MSL source with `MTLDevice.makeLibrary(source:)` needs nothing extra. A
cold compile measured here took ~0.2 s, so it runs asynchronously once per device and is cached. The source is a raw
Swift string literal, so there is no resource bundle to lose. For the same reason the model ships as base64 string
literals in a generated Swift file, not as a bundle resource.

## 3. The contract (`CharacterKit`), draft for review

**This shape is a one-way door: Leo must approve it before it is frozen (gate G0).**

Two faces on one protocol: a control surface that Buddy uses, and a render surface that `CharacterView` drives.
The character never owns a window or a view, and the shared view owns pacing, input, hit-testing and the Metal
layer, so WALL-E only writes the character.

```swift
// Vocabulary: shared by every character, so a character pack and the LLM's cue schema don't change when the character does.
public enum CharacterState: String, CaseIterable, Sendable, Codable {
    case idle, thinking, searching, listening, speaking, working, happy, error, sleeping
}

/// An open set: the 17 core expressions every character must accept (mapping to its nearest when it has no
/// exact face), plus any a character adds. String-backed, so packs and LLM cues are plain data.
public struct CharacterExpression: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public static let neutral, curious, happy, joyful, sad, sheepish, sleepy, suspicious, content, surprised,
                      afraid, determined, angry, attack, defense, peaceful, asleep: Self
    public static let core: [Self]
}

/// Same pattern. Core: blink, nod, shake, hmm, laugh, surprise, wake, defense.
public struct CharacterAction: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral { … }

public struct ActionOptions: Sendable { public var hold: Duration? }        // defense: how long the eyes stay red
public enum ActionOutcome: Sendable { case completed, interrupted, unsupported }

public struct RGBColor: Sendable, Hashable, Codable { public var red, green, blue: Double /* sRGB 0–1 */; init?(hex:) }
/// Every slot optional: nil means the character's own default.
public struct CharacterPalette: Sendable, Hashable, Codable {
    public var body: RGBColor?      // Iron Giant: the shell.  WALL-E: the body.
    public var eyes: RGBColor?      // the eyes' glow / lens tint
    public var accent: RGBColor?    // a character's third colour (WALL-E's treads); Iron Giant ignores it
}

public enum LookTarget: Sendable, Equatable {
    case pointer                    // follow the mouse (the view polls it; the default)
    case point(CGPoint)             // a point in global screen coordinates (AppKit points, y up)
    case ahead                      // nothing in particular: the character's own glances
}

/// Polled once per rendered frame; must be cheap and thread-safe. AudioLevelMeter conforms.
public protocol SpeechLevelSource: AnyObject, Sendable { var speechLevel: Float { get } }

public enum QualityTier: Int, Comparable, Sendable { case low, reduced, full }

@MainActor
public protocol CharacterRenderer: AnyObject {
    // Identity
    static var characterID: String { get }                       // "iron-giant"; packs refer to it
    var supportedExpressions: Set<CharacterExpression> { get }   // core ∪ extras
    var supportedActions: Set<CharacterAction> { get }

    // What it is doing
    var state: CharacterState { get set }
    var expression: CharacterExpression? { get set }             // a face over the state's own; nil = the state's
    @discardableResult
    func play(_ action: CharacterAction, options: ActionOptions) async -> ActionOutcome
    func poke()                                                  // a click on the character

    // Speech: "how loud is it talking", 0–1. Each character maps it its own way (a jaw; WALL-E: eyes and body).
    var speechLevel: Float? { get set }                          // a fixed level; nil = none (the TS `mouth`)
    var speechSource: (any SpeechLevelSource)? { get set }       // a live level, read every frame (the TS `audio`)

    // Where it looks
    var lookTarget: LookTarget { get set }

    // Looks and timing
    var palette: CharacterPalette { get set }
    var speed: Double { get set }                                // multiplier on every animation
    var isPaused: Bool { get set }                               // hold the state's still pose
    var showsFloorShadow: Bool { get set }
    var seed: Double { get }                                     // 0–1, fixed at init

    // Driven by CharacterView
    func framing(forBox box: CGFloat) -> CharacterFraming        // canvas size and where the resting box sits in it
    func prepare(device: any MTLDevice) async throws             // compile pipelines, upload meshes
    func advance(by seconds: Double, input: FrameInput) -> Bool  // step the sim; false = nothing is moving
    func encode(into target: RenderTarget, commandBuffer: any MTLCommandBuffer)
    func hitTest(_ point: CGPoint, framing: CharacterFraming) -> Bool  // point in canvas points, y down
    var hasPendingActions: Bool { get }                          // keeps logical time running while hidden
}
```

`CharacterView` (an `MTKView` subclass) holds one `any CharacterRenderer`, sizes it to its bounds, pulls the pointer,
turns clicks into `poke()`, exposes `hitTest(_:)` for Buddy's click-through panel, and runs the `RenderPacer`.
`CharacterViewRepresentable` wraps it for SwiftUI. A `CharacterRegistry` maps `characterID` → factory, so Buddy's
pack data can name a renderer.

Semantics carried over from TS:
- `play` resolves when the action ends; a new action cuts the last one short (`.interrupted`). A still or paused
  character resolves at once (`.completed`, as in TS). An action that isn't in `supportedActions` returns
  `.unsupported` immediately.
- While the pacer has stopped drawing (occluded, locked), logical time still runs at a low tick for as long as an
  action is pending, so `await play(…)` never hangs on a hidden character.
- An expression outside `supportedExpressions` falls back to the state's face.

## 4. Rendering approach: GPU meshes, an analytic face, one composite

### Options considered

| | Rasterised meshes (chosen) | SDF raymarch (Claud-y's approach) | CPU transliteration (CoreGraphics) |
|---|---|---|---|
| Parity | exact: the same sculpt triangles, normals and lighting model | an approximation of the sculpt: the likeness that G1 approved would be lost | exact |
| Cost | ~4k triangles and a few screen quads: well under 1 ms GPU, ~0 CPU per frame | a full-screen march per pixel per frame: more GPU work for less fidelity | the TS cost, on the CPU, every frame |
| Fits | the head is a decimated sculpt, not a construct of primitives | characters built from primitives (WALL-E could suit it) | rejected by the brief |

The Iron Giant's head *is* a mesh, so raymarching it would mean modelling it again as SDFs and losing the
approved likeness. Rasterising its ~3.9k triangles costs almost nothing. The face, which the TS draws as 2D shapes
in each eye's tangent plane, is exactly the kind of thing a fragment shader does analytically.

### Frame structure (two passes)

1. **Head pass** (offscreen, 4× MSAA with depth, resolved into a head texture, transparent clear):
   - the dark mouth plate and inner wall first, with no depth test (the TS draws them before everything);
   - cranium and jaw meshes, flat vertices (per-triangle normal, as the TS lights per quad); the vertex shader does
     the pose rotation about the pivot, the jaw's hinge swing and drop, the jaw's smile bend (`shapeJaw`) and the TS
     back-face rule (a triangle whose turned normal has z < −0.04 is dropped); the fragment shader evaluates
     `radiance()` with the grime ramp and the display curve; `inside` triangles are the flat cavity colour;
   - the jaw panel's two ink seams, as screen-space capsules.
2. **Drawable pass** (1×, premultiplied alpha over transparent):
   - the floor shadow (an elliptical radial gradient quad);
   - the composite: the ink outline (the head's alpha sampled at 8 offsets, combined as eight source-over layers
     would be, `1 − Π(1 − aₖ)`) under the head texture;
   - each eye as a quad in its tangent plane (the TS's affine `setTransform`): socket, glow (two-point conical
     gradient, circle → pentagon morph), iris aperture with blade lines, lids (tilted top, bowed bottom), the shut
     seam, all analytically antialiased, clipped to the socket; then the bloom, additively.

Everything is written as sRGB-encoded values into a `.bgra8Unorm` layer tagged sRGB, and blended in that space, as
Canvas2D does, so colours and the bloom's falloff match the browser.

Per frame the CPU steps the sim, writes one small uniform buffer, and encodes about ten draws. Meshes are uploaded
once (low-detail mesh too, used below 230 device px per head unit as in TS, and always at `.low` quality).

### Hit-testing

On the CPU, on demand: project the low-detail mesh with the current pose (the same `HeadTransform` the renderer
uses for the eyes and the mouth plate) and test the point against front-facing triangles, plus the ink width.
About 1.3k triangle tests, a few microseconds, with no GPU readback and no frame latency. It answers "is this point
on the character", so Buddy can toggle `ignoresMouseEvents` on its panel.

## 5. Pacing and power

`RenderPacer` is pure: `PacingSignals → RenderBudget { framesPerSecond (0 = stop), quality: QualityTier }`, so the
policy is unit-tested without a window. `SystemSignals` feeds it from:

| Signal | Source |
|---|---|
| occluded / off-screen | `NSWindow.occlusionState`, window/screen changes |
| screen locked, display asleep, system sleep | `com.apple.screenIsLocked`/`Unlocked` distributed notifications, `NSWorkspace` screensDidSleep/Wake, willSleep/didWake |
| user idle | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`, sampled every few seconds |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChange` |
| thermal state | `ProcessInfo.thermalState` + `thermalStateDidChangeNotification` |
| on battery | IOKit power sources (`IOPSNotificationCreateRunLoopSource`) |
| Reduce Motion | `NSWorkspace.accessibilityDisplayShouldReduceMotion` + its notification |
| character at rest | `advance` returning false (paused, or Reduce Motion still pose) |

Default policy (all overridable through `PacingPolicy`):

| Condition | fps | tier |
|---|---|---|
| occluded, locked, display asleep, user idle ≥ 5 min, paused | 0 (stop; redraw on change) | – |
| Reduce Motion | 0 after drawing the still pose (as TS) | full |
| thermal critical | 10 | low |
| thermal serious, or Low Power Mode | 20 | low |
| on battery, or user idle ≥ 60 s | 30 | reduced |
| otherwise | 60 | full |

Tiers: **full** is 4× MSAA, the full mesh and native scale. **reduced** is the same at a lower fps. **low** is the
low-detail mesh with no MSAA. Speaking (a live speech source) lifts the cap to at least 30 fps so lip-sync reads.
The pacer exposes `policy`, `signals`, `budget` and `forcedBudget` (the playground uses it to compare tiers).

## 6. Lip-sync

`AudioLevelMeter` installs a tap on any `AVAudioNode` of the caller's engine (Buddy's ElevenLabs player node, or
the main mixer), computes the RMS over the last ~1024 samples (≈ 20 ms at 48 kHz) on the audio thread, maps it as
the TS does (`t = clamp((rms − 0.012) / 0.16)`, `level = t^0.75`), and publishes it through an `Atomic`. It conforms
to `SpeechLevelSource`. The character's own springs smooth it (quick to open, slower to close), as in TS. A
convenience `SpeechPlayer` plays a file or PCM buffer through its own engine with a meter attached, for the
playground and simple uses.

## 7. Parity checklist

Behaviour (verified by unit tests, most by golden traces recorded from the TS sim with the same seeds):
- [ ] 9 states with their motion: glances, tilts, thinking side switch, search sweep, listening cock + hum nods,
      speaking bob + phrases, working bob, happy hop + laughs, error shake + droop, sleeping breathing
- [ ] 17 expressions with identical rig values; eye colour replaced except angry/attack/defense
- [ ] face springs (Float32) with head-offset overshoot; colour blends in linear light
- [ ] sequences: blink, defenseOn, defenseOff, wake, triggered on the same face changes
- [ ] actions: blink, nod, shake, hmm, laugh, surprise, wake, defense (`hold`, default 1.6 s), interruption
- [ ] blinks every 2.5–6.5 s, double blinks, none while sleeping
- [ ] procedural jaw (phrase, hum, laugh) and the external level's spring (11 Hz open, 6 Hz close)
- [ ] poke: blink, surprise flash, hop, nod
- [ ] pointer / lookAt following (eyes lead, head follows, 900 px reach), none while sleeping
- [ ] 120 Hz substeps, speed multiplier, seed-determinism
- [ ] still pose (paused / Reduce Motion): `REST[state]` with the target face

Looks (verified by snapshot comparisons against the web playground's canvas):
- [ ] framing (`frameFor`): box, pads, unit; head centred in the box
- [ ] gunmetal shell lighting and the display curve; dark and inside materials; grime toward the bottom
- [ ] ink outline width `max(1, U·0.008)`
- [ ] mouth plate and inner wall; the jaw's hinge, drop and smile bend; jaw-panel seams
- [ ] sockets, glow gradient and its core, pentagon morph, iris with blades, lids (tilt, bow), shut lids with the seam leak
- [ ] bloom; floor shadow shrinking with lift
- [ ] low-detail mesh below 230 device px per unit

## 8. Deliberate deviations (planned; final list in `PARITY.md`)

1. **Depth buffer instead of a painter's sort.** Correct where per-quad sorting can mis-order neighbours; the same
   picture otherwise. The TS crest bias is moot: the crest mesh is empty.
2. **No shade quantisation.** The TS caches lit colours on a 72×72 octahedral grid with 6 grime steps; the GPU
   evaluates them exactly, so faint banding disappears.
3. **MSAA and analytic AA** instead of Canvas2D's path AA and its per-quad stroke that hides seams.
4. **Off-screen means occluded.** IntersectionObserver becomes window occlusion; there is also user idle, lock and
   power pacing, which the web version doesn't have.
5. **The pointer is global.** Distances are in points from between the eyes, as CSS px are in TS.

None of these should change how the character looks or moves. If the side-by-side shows a visible difference
that is not a bug, it goes to Leo (gate G1).

## 9. Testing and measurement

- **Unit tests** (Swift Testing): vocabulary and protocol semantics (unsupported actions, interruption, still
  resolution), pacer policy tables, meter mapping on synthetic buffers, model decode (counts, bounds, jaw panel
  vs TS values), framing vs TS numbers, hit-testing on known points.
- **Golden traces:** a Node script runs the TS `RobotSim` with fixed seeds through scripted scenarios (state
  changes, actions, pointer, mouth levels) and records pose + face every 1/60 s; the Swift sim must match within
  1e-4 (Float32 slots within 1e-3).
- **Visual regression:** `OffscreenRenderer` renders each state's still pose and each expression to PNG; tests
  compare against committed baselines with a tolerance (`IRONGIANT_RECORD=1` re-records).
- **Parity report:** the same poses captured from the web playground's canvas (paused, transparent, same size and
  scale) and compared with the Metal output: a side-by-side contact sheet and a mean difference per image.
- **Measurements:** CPU (process `%cpu` sampled over 60 s) and GPU time (command-buffer GPU start/end) at idle and
  while speaking at 240 pt, per tier, recorded in `MEASUREMENTS.md`, with the web playground in Safari for scale.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Colour mismatch with Canvas2D (gamma, gradient interpolation, blending space) | write sRGB-encoded values to a non-sRGB format, blend in that space; compare against canvas pixels, not screenshots |
| Two-point conical gradient of the glow | solve the canvas spec's equation in the shader; test against reference |
| Golden traces drifting from float differences | Float32 where TS uses Float32Array; exact `Math.imul`-style RNG; trace tolerances; trace the RNG directly |
| Transparent `NSPanel` compositing (premultiplied alpha, `isOpaque = false`) | premultiplied output throughout; the playground has a floating-panel mode to verify it |
| Display link and Swift 6 isolation | `NSView.displayLink(target:selector:)` on the main actor; the audio tap only touches an `Atomic` |
| Runtime shader compile time on first launch | async compile at `prepare`, cached per device; the view draws nothing until ready |
| Protocol churn after Buddy and WALL-E adopt it | gate G0 before freezing; open string-backed vocabularies so characters add without breaking |

## 11. Work plan

See `DAG.md`. Workers in their own Orca worktrees take the sim port, pacing + audio, and the web reference capture
in parallel; the coordinator (this worktree) takes the skeleton, model, renderer, view, integration, snapshots,
measurements and docs.
