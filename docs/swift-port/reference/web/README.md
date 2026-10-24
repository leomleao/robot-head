# Web reference images

Stills of the TS robot (`src/`), captured from its own canvas, for checking the Metal port against. Each PNG is
exactly what `<RobotHead paused interactive={false}>` paints: the canvas's pixels via `toDataURL('image/png')`,
not a screenshot, with a transparent background.

## How they are made

- **Page:** `site/src/lab/capture.html` (module `capture-main.tsx`), dev-only like the rest of the lab: Vite's build
  only takes `site/index.html`, so it never reaches the published site. It renders one `<RobotHead>` from the query
  string (`state`, `expression`, `size`, `color`, `eyeColor`, `floorShadow`), always `paused` and
  `interactive={false}`, and exposes `window.capture` (canvas, pixel and CSS size, `frameFor(size)`).
- **Scale:** `window.devicePixelRatio` is defined as 2 on the page before the robot renders (RobotHead uses
  `min(2, devicePixelRatio)`), and Chrome also runs with `--force-device-scale-factor=2`. The script fails if a
  canvas's pixel size isn't exactly 2 × its CSS size.
- **Browser:** headless Google Chrome, driven over the DevTools protocol by plain Node (no packages). Its canvas
  is rasterised on the CPU (`--disable-gpu --disable-accelerated-2d-canvas`): with GPU canvas, re-runs differed by
  a few hundred pixels in some images; on the CPU they are byte-identical. The Chrome version is recorded in
  `manifest.json` (`browser`); another version may rasterise slightly differently.
- Orca's embedded browser can return the data URL too, but took minutes per image and timed out on navigation,
  so the script doesn't use it.

## Re-running

From the repo root, with dependencies installed (`pnpm install`):

```sh
node scripts/swift/capture-web-references.mjs           # rewrite the PNGs and manifest.json
node scripts/swift/capture-web-references.mjs --check   # compare against the files here, write nothing
```

The script starts the site's dev server on port 5391 and stops it afterwards; `--url http://localhost:5173` uses
one that's already running instead. `--chrome <binary>` (or `$CHROME`) picks another Chrome or Chromium. `--check`
exits non-zero if an image is missing or a pixel differs, or `manifest.json` differs, and says so when only an
image's bytes differ.

Each image is also checked for being 2×, not blank, and transparent in its corners.

## The set (32 images)

Defaults unless stated: shell colour `rgb(60, 55, 63)`, eye colour `rgb(255, 236, 226)` (the library's defaults),
floor shadow on, device pixel ratio 2.

| Files | State | Expression | Size (CSS px) | Notes |
| --- | --- | --- | --- | --- |
| `state-<state>.png` × 9 | each state | (the state's own) | 240 | each state's still pose and face |
| `expression-<expression>.png` × 17 | `idle` | each expression | 240 | |
| `small-idle.png`, `small-happy.png`, `small-defense.png`, `small-asleep.png` | `idle` | –, happy, defense, asleep | 96 | low-detail mesh (`frame.unit × 2 < LOW_DETAIL_BELOW`, 230) |
| `colors-rust-moonlight.png` | `idle` | – | 240 | `color="#6b3f2e"`, `eyeColor="#bfe3ff"` |
| `floor-shadow-off.png` | `idle` | – | 240 | `floorShadow={false}` |

At 240 the canvas is 242 × 304 CSS px (484 × 608 pixels); at 96 it is 98 × 123 (196 × 246). The canvas reaches
past the `size` box: it is `box + 2·padSide` wide and `box + padTop + padBottom` tall, with the box at
(`padSide`, `padTop`).

## manifest.json

One entry per file: `params` (as passed to `RobotHead`), `canvas` (pixel size), `css` (CSS size), `frame` (the TS
`frameFor(size)`: `box`, `padTop`, `padBottom`, `padSide`, `unit`, `cx`, `cy`, in CSS px) and the PNG's `sha256`.

The playground's paused head (`pnpm run dev`, `/?state=…&paused`) was checked against this page at the same size:
identical pixels for sleeping, thinking, error and idle + defense.
