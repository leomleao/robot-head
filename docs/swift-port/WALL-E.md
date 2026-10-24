# Adding a character: what WALL-E implements

A character is a class conforming to `CharacterRenderer` (`Sources/CharacterKit/CharacterRenderer.swift`). Everything
round it is shared and comes for free: `CharacterView` (display link, pacing, pointer, clicks, hit-test API,
transparency, click-through panels), `RenderPacer` and `SystemSignals`, `SpeechPlayer` and `AudioLevelMeter`,
`OffscreenRenderer` for snapshots, `CharacterRegistry`, and the playground.

Use `Sources/IronGiant/` as the worked example; its layout is a good template.

## 1. A target

```swift
// Package.swift
.target(name: "WallE", dependencies: ["CharacterKit"]),
.testTarget(name: "WallETests", dependencies: ["WallE", "CharacterKit"], exclude: ["Snapshots"]),
// and a product: .library(name: "WallE", targets: ["WallE"])
```

Embed shader source as a Swift string and compile it with `device.makeLibrary(source:options:)`, cached per
device like `IronGiantPipelines.shared(for:)`. `.metal` files would need the separately downloaded Metal Toolchain
on every machine that builds Buddy. Ship geometry as generated Swift literals, not bundle resources.

## 2. The control surface: how WALL-E acts the shared words

| Contract | What WALL-E must decide |
|---|---|
| `CharacterState` (9, closed) | a motion and a face for each: e.g. `thinking` tilts the binocular head, `working` runs the treads in place, `sleeping` folds into the cube with the eyes dim |
| `CharacterExpression.core` (17) | every one accepted, each mapped to its nearest face (eye-plate tilt, eye height on the neck, iris size). `angry`/`attack`/`defense` don't need red: map them to what reads as alarm for him |
| `CharacterAction.core` (8) | every one accepted. `defense` with `hold` maps naturally to *compacting into the cube* and back; `laugh` is a bounce and a flap of the arms; `nod`/`shake` are neck motions |
| extras | add his own as `extension CharacterAction { static let compact: Self = "compact" }`, list them in `supportedActions`; Iron Giant answers `.unsupported` to them |
| `speechLevel` / `speechSource` | 0–1 "how loud he is talking". He has no jaw: map it to an eye-plate flutter, a neck bob, or a chest light. Read `speechLevel ?? speechSource?.speechLevel` once per `advance`, and smooth it with your own springs (quick to rise, slower to fall) |
| `lookTarget` | arrives in `advance`'s `FrameInput` as `pointer` / `lookPoint` in canvas points; measure from his eyes and turn the head (and the eyes inside it) toward it |
| `palette` | `body` = his yellow, `eyes` = lens tint, `accent` = treads. nil = his defaults |
| `speed`, `isPaused`, `showsFloorShadow`, `seed` | as Iron Giant: speed scales sim time, 0 or paused shows the still pose |

## 3. The render surface

| Method | Contract |
|---|---|
| `init(seed:)` | cheap; no GPU work |
| `framing(forBox:)` | the canvas a resting box of `box` points needs and where the box sits in it. The box is WALL-E at rest; leave room past it for motion, glow and the floor shadow |
| `prepare(device:)` | compile and upload; idempotent (the offscreen renderer calls it per image) |
| `advance(by:input:)` | step the sim by wall-clock seconds × `speed`; return **false** when nothing is moving (still pose), so the view stops drawing until `onChange` |
| `encode(into:commandBuffer:)` | draw into `target.texture`: `.bgra8Unorm`, sRGB-encoded values, **premultiplied alpha**, cleared to transparent first. `target.framing` places the box in the canvas; `target.scale` is pixels per point; honour `target.quality` (`full` / `reduced` / `low`) |
| `hitTest(_:framing:)` | is this canvas point (y down) on him as last advanced. Do it on the CPU against a coarse projected silhouette and cache the projection per pose (Iron Giant: `HeadHitTest`); it is polled at 20 Hz while the pointer moves |
| `onChange` | call it whenever something a still character must redraw for changes (state, expression, palette, pause, speed) and when an action or poke starts |
| `play` / `hasPendingActions` | resume the caller when the action ends; a new action ends the last one with `.interrupted`; a still character returns `.completed` at once; unknown actions return `.unsupported`. `hasPendingActions` keeps the view ticking logical time while hidden, so `play` always returns |

## 4. Rendering approach for him

WALL-E is built from primitives (boxes, cylinders, treads, binocular eyes), unlike the Iron Giant's sculpt. Both
approaches fit the contract:

- **Meshes, like Iron Giant:** model him (or generate the parts procedurally), flat or smooth shaded, through a
  depth buffer, with the eyes' glass and irises in a shader. Cheapest per frame; parity with any reference model.
- **One SDF raymarch shader** (Claud-y's approach): rounded boxes and capsules compose naturally, soft shadows
  and AO come cheaply, and tiers become step counts. More GPU per pixel; keep the canvas small and use the `low`
  tier's step budget on battery.

Either way, keep the CPU per frame to a sim step and a uniform write, as Iron Giant does (~0.1 ms).

## 5. Tests to copy

- Contract semantics: `Tests/IronGiantTests/IronGiantCharacterTests.swift` (unsupported, still, interrupted, held
  actions, `onChange`, hit-test against the drawn silhouette, registry).
- Snapshots: `SnapshotTests.swift` with `IRONGIANT_RECORD`-style recording, per state and per expression, plus
  motion poses from a deterministic sim.

## 6. Wiring into Buddy

```swift
CharacterRegistry.register(WallECharacter.self)          // at launch, next to IronGiantCharacter
let character = CharacterRegistry.make(pack.rendererID, seed: .random(in: 0..<1))!
character.palette = pack.palette
let view = CharacterView(character: character)
view.managesWindowClickThrough = true                    // in Buddy's borderless panel
```
