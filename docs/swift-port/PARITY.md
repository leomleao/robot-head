# Parity: the Metal Iron Giant against the TS one

## How it is checked

| What | How | Where |
|---|---|---|
| Behaviour (sim, rig, actions) | the real TS `RobotSim` run under Node through 11 scripted scenarios × 6 seeds, every frame recorded; the Swift sim replays them | `scripts/swift/sim-trace.mjs`, `Tests/IronGiantTests/SimTraceTests.swift` |
| Geometry and framing | decoded meshes, jaw panel, `frameFor`, `rotation`, `craniumFront` against values from the TS | `Tests/IronGiantTests/GeometryTests.swift` |
| Looks | the 32 stills captured from the web playground's own canvas (paused, 2×, transparent) rendered by Metal with the same parameters and compared over the same grey | `docs/swift-port/reference/web/`, `Tests/IronGiantTests/ParityTests.swift` |
| Regression | 32 stills + 7 motion poses against Metal baselines at 1× | `Tests/IronGiantTests/SnapshotTests.swift` |

Run `PARITY_OUT=/some/dir swift test --filter ParityTests` for per-image web | metal | difference ×4 sheets.

## Results

**Behaviour:** every frame of every trace matches within 5e-8, the fixtures' own rounding, and every action ends
in the same frame with the same outcome. 22 IronGiant sim/rig tests.

**Looks:** all 32 stills within bounds (mean |Δ| < 2/255, < 2% of pixels off by more than 24/255).

| Image | mean \|Δ\| /255 | pixels > 24 |
|---|---|---|
| 9 states at 240 | 0.85 – 1.07 | 0.60 – 0.92% |
| 17 expressions at 240 | 0.86 – 1.18 | 0.70 – 1.12% |
| 4 stills at 96 (light mesh) | 1.22 – 1.43 | 0.93 – 1.13% |
| rust shell, moonlight eyes | 1.15 | 1.51% |
| floor shadow off | 1.03 | 0.88% |

Per image: `parity/report.json`. Contact sheets (web above, Metal below):

- [`parity/states.png`](parity/states.png)
- [`parity/expressions.png`](parity/expressions.png)
- [`parity/other.png`](parity/other.png)

What differs is antialiasing on the silhouette, the crest and the socket rims, and a faint facet banding in the
TS's shading (below), all at the level of single pixels along edges. Nothing differs in shape, colour or placement.

## Checklist

Behaviour, all verified by the golden traces:

- [x] 9 states with their motion (glances, tilts, thinking's side switch, search sweep, listening cock and hum nods, speaking bob and phrases, working bob, happy hops and laughs, error shake and droop, sleeping breath)
- [x] 17 expressions with identical rig values; the eye colour replaced except for angry, attack and defense
- [x] face springs in Float32 with the head offsets' overshoot; colour blends in linear light
- [x] sequences: blink, defenseOn, defenseOff, wake, triggered on the same face changes
- [x] actions: blink, nod, shake, hmm, laugh, surprise, wake, defense (`hold`, default 1.6 s), interruption
- [x] blinks every 2.5–6.5 s, double blinks, none while sleeping
- [x] procedural jaw (phrase, hum, laugh) and the outside level's spring (quick open, slower close)
- [x] poke: blink, surprise flash, hop, nod
- [x] pointer and look-at following (eyes lead, head follows, 900 pt reach), none while sleeping
- [x] 120 Hz substeps, speed multiplier, seed determinism (bit-exact mulberry32)
- [x] still pose (paused, speed 0, Reduce Motion): `REST[state]` with the target face

Looks, all verified by the reference stills:

- [x] framing (`frameFor`): box, pads, unit; the canvas is the same pixel size as the web's
- [x] gunmetal shell lighting and the display curve; dark and inside materials; grime toward the bottom
- [x] ink outline
- [x] mouth plate and inner wall; the jaw's hinge, drop and smile bend; jaw-panel seams
- [x] sockets, the glow's gradient and core, the pentagon morph, the iris and its blades, lids (tilt, bow), shut lids with the seam's leak
- [x] bloom; floor shadow (shrinking with lift: motion snapshots)
- [x] light mesh below 230 device px per unit

## Deliberate deviations

None of these changes how the character looks or moves; none needed Leo's call (gate G1 was not triggered).

1. **Depth buffer, not a painter's sort.** Triangles are depth-tested instead of sorted per quad. The TS's crest
   bias is moot: this sculpt's crest is part of the cranium.
2. **No shade quantisation.** The TS caches lit colours on a 72 × 72 octahedral grid of normals (to save CPU); the
   GPU lights each triangle exactly, so the faint facet banding is gone. The TS's six grime steps are kept.
3. **Antialiasing.** 4× MSAA (none at the `low` tier) and analytic AA in the eye shader, instead of Canvas2D's path
   AA. The TS strokes every quad in its own colour to hide seams, which grows the silhouette by half a stroke; the
   ink outline reaches that much further, so the outer edge lands in the same place.
4. **Off-screen means occluded, and more.** IntersectionObserver becomes window occlusion, plus pacing the web
   version doesn't have: screen lock, display sleep, user idle, Low Power Mode, thermal state, battery.
5. **The pointer is global.** It is followed anywhere on screen, measured in points from between the eyes, as CSS
   px are in TS.
6. **Hidden actions keep time.** While nothing is drawn, a pending `play` still runs out on a 10 Hz tick, so it
   returns; the TS's would wait for the tab to show again.

## TS behaviour carried over as-is

Found while porting (W1), kept for parity, worth a look upstream:

- `FaceSprings` marks slots 23–25 as the underdamped head offsets, but with 10 eye keys × 2 + 5 face keys those
  are pitch, roll and the colour's red channel: yaw is critically damped and red overshoots a little on colour
  changes. The comment says yaw/pitch/roll were meant.
- Actions (nod, shake…) still play while sleeping, and a blink that falls due during sleep fires as soon as the
  robot wakes.
