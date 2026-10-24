# Measurements

Measured with the playground's measure mode (`docs/swift-port/PLAYGROUND.md`):

```sh
swift build -c release --product RobotPlayground
.build/release/RobotPlayground --measure <scenario> [--seconds 30] [--size 240] [--budget auto|full|reduced|low]
```

It shows only the robot (240 pt box, 2× display) in a window, settles for 3 s, then samples for 30 s. **CPU %** is
the whole process's user + system time over wall time (100% = one core), so it includes AppKit, Core Animation and
the Metal driver, not just our code. **CPU ms/frame** is our part: advancing the sim and encoding the frame.
**GPU ms/frame** is command-buffer GPU time.

Machine: MacBook Pro, Apple M4 Pro, macOS 27.0, **on battery** (so `auto` is the 30 fps `reduced` tier). Release
build, 2026-10-24, commit `7b15236`.

## Results

| Scenario | Budget | fps | CPU % | CPU ms/frame | GPU ms/frame |
|---|---|---|---|---|---|
| idle (state idle, pointer still) | auto (battery → 30) | 30.0 | **3.8** | 0.34 | 0.21 |
| speaking, live `SpeechPlayer` (muted) | auto | 29.9 | 4.3 | 0.38 | 0.22 |
| speaking, procedural jaw | auto | 29.7 | 4.1 | 0.42 | 0.22 |
| floating panel, click-through on | auto | 29.9 | 4.8 | 0.37 | 0.20 |
| paused (still pose) | auto | 0 | **0.03** | – | – |
| hidden (window covered) | auto | 0 | **0.27** | – | – |
| idle | full (60) | 60.0 | 6.3 | 0.33 | 0.21 |
| speaking, live | full (60) | 60.0 | 6.6 | 0.35 | 0.22 |
| idle | low (20, light mesh, no MSAA) | 19.8 | 2.8 | 0.44 | 0.18 |
| speaking, live | low (20) | 19.9 | 3.2 | 0.43 | 0.18 |

Idle at 30 fps came out at 3.84% and 3.78% on two repeat runs; a first run after a rebuild read 6.1% (warm-up),
discarded. In `paused` and `hidden` nothing is drawn; what remains is the app's own once-a-second sampling. The
rows other than idle, speaking and procedural are from the same day's run at `696b90c`, before the idle-pacing
change, which doesn't affect them.

## What it means for Buddy

- **Per frame the robot is cheap:** about 0.35 ms of CPU and 0.2 ms of GPU at any tier. The GPU cost barely moves
  with the tier because ~4k triangles and a 484 × 608 canvas are nothing for it; what costs power is waking up
  for each frame, so **frame rate is the lever**, and the pacer pulls it.
- Most of the process CPU at 30–60 fps (≈1 ms per frame in all) is AppKit/Core Animation/display-link/driver
  overhead per presented frame, not our code. It scales with fps, which is why the tiers trade fps first.
- **All-day idle on screen:** with the user present and nothing happening, 30–60 fps (3.8–6.3% of a core). After
  60 s with neither the user nor the character doing anything, the reduced 30 fps tier; after 5 min, **drawing
  stops** (≈0.03%). Covered, locked, display asleep: stopped. A state change, an action or speech wakes it at once
  and keeps it moving for the next minute.
- Speaking costs about the same as idle: the jaw is a uniform; the level is a lock-free read.

## Possible next steps (not done)

- A 24 fps "calm" tier for idle-with-user-present on mains, if 6% at 60 fps is too much for an all-day companion.
- Drawing into a `CAMetalLayer` directly instead of `MTKView` may shave some per-frame overhead; measure first.
- The web version was not measured side by side here (its CPU per frame was tuned in the TS N12 pass); the
  native per-frame CPU (0.35 ms) is well under that pass's 2 ms target.
