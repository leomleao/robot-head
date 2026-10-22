# robot-heads

A heavy, gentle robot head for React. A domed iron head with a crest, glowing eyes that do all the acting, and a hinged jaw that smiles, talks and lip-syncs to audio. It shows what your app or agent is doing (thinking, listening, speaking, working and more), wears seventeen expressions, and plays one-off actions like a nod or a blink.

Drawn on a 2D canvas: no WebGL, no runtime dependencies.

> Hmm? · Mm-hmm. · I fix. · You stay. I go.

## Install

```bash
npm install robot-heads
```

React 18 or newer is a peer dependency.

## Quick start

```tsx
import { RobotHead } from 'robot-heads';

function Agent({ status }: { status: 'idle' | 'thinking' | 'speaking' }) {
  return <RobotHead state={status} size={160} />;
}
```

## States

What it is doing. Each state has its own motion and a face to go with it. Everything is heavy and slow: he is fifty feet tall.

| State | Face | Motion |
|---|---|---|
| `idle` | neutral | slow glances and blinks, the odd "Hmm?" tilt of the head |
| `thinking` | curious | looks up, to one side and then the other |
| `searching` | suspicious | a slow sweep, the eyes a step ahead of the head |
| `listening` | neutral | head cocked toward you, nodding along with an "mm-hmm" |
| `speaking` | neutral | the jaw talks in short phrases with pauses; give it `audio` or `mouth` to lip-sync instead |
| `working` | content | eyes down on the work, a careful bob |
| `happy` | happy | arrives with a hop; a grin, a sway, a laugh now and then |
| `error` | sheepish | a slow shake of the head and a droop (never red: red means danger) |
| `sleeping` | asleep | eyes shut, slumped and breathing; waking opens the eyes from a lit seam |

The list is exported as `robotHeadStates`.

## Expressions

How it feels. An `expression` replaces the state's face but keeps the state's motion, so `state="speaking" expression="happy"` talks while smiling.

`neutral` `curious` `happy` `joyful` `sad` `sheepish` `sleepy` `suspicious` `content` `surprised` `afraid` `determined` `angry` `attack` `defense` `peaceful` `asleep`

The eyes do the acting. Each glows inside a dark socket, and dark lids cut into the glow from above and below: their height and tilt give a squint, a droop, a glare or a smile. `angry` and `defense` close a red camera-like iris over the eye (the lids open fully while it's in), and turning red, or back, plays out step by step. `attack` turns the eyes pink under heavy lids. The list is exported as `robotExpressions`.

## Actions

A `ref` reaches a handle that plays one-off actions over whatever the robot is doing:

```tsx
const robot = useRef<RobotHeadHandle>(null);

<RobotHead ref={robot} state="idle" />

await robot.current?.play('nod');
robot.current?.play('defense', { hold: 2 }); // red eyes for two seconds, then back
```

`blink` · `nod` · `shake` · `hmm` · `laugh` · `surprise` · `wake` · `defense`

`play()` resolves when the action ends; a new action cuts the last one short. The list is exported as `robotActions`. The handle's `canvas` is the canvas it draws on.

## Lip-sync

Give it something to listen to and the jaw follows its loudness:

```tsx
const [mic, setMic] = useState<MediaStream | null>(null);
// setMic(await navigator.mediaDevices.getUserMedia({ audio: true }))

<RobotHead state="speaking" audio={mic} />
```

`audio` takes a `MediaStream` (a microphone), an `<audio>` or `<video>` element (it keeps playing through the speakers), or an `AudioNode` in your own graph. Robots share one `AudioContext`, made the first time one is given audio; browsers start it after the first click or key press. If you already have a level (from a TTS engine, say), pass it as `mouth`, 0–1, instead.

## Props

```tsx
<RobotHead
  state="idle"            // what it is doing (above)
  expression="curious"    // how it feels; replaces the state's face
  size={160}              // px, the box the head rests in (below)
  color="#3c373f"         // the shell
  eyeColor="#ffece2"      // the glow; angry and defense turn it red, attack pink
  audio={stream}          // lip-sync to a stream, an element or an AudioNode
  mouth={0.4}             // or drive the jaw yourself, 0–1
  lookAt={inputRef}       // look at an element (or a ref, or { x, y } in viewport px) instead of the pointer
  speed={1}               // multiplier on every animation
  paused={false}          // hold the state's still pose
  interactive             // follow the pointer; blink and start at a click
  floorShadow             // the soft shadow under the head
  seed={0.3}              // 0–1, desyncs blinks and glances in a row of heads
/>
```

Any other attribute (`className`, `style`, `onClick`, `aria-label`, …) goes on the element.

## Sizing and layout

`size` is the head itself: the element is a `size` × `size` box with the head at rest centred in it and filling it. It lines up with text, sits in a flex row, and centres like an icon or an avatar would.

Its motion is not part of that box. Tilts, hops, the eyes' glow and the floor's shadow draw past its edges: like a CSS `box-shadow`, they overflow without taking any room in your layout, and only the box takes clicks. The one thing to watch is a parent with `overflow: hidden` right round it.

## Behaviour

- **Pointer play.** With `interactive` on (the default), the eyes follow a nearby pointer and the head turns after them, heavily. A click makes it blink and start. States that look elsewhere (thinking, searching, working) keep their own gaze; `lookAt` overrides everything but sleep.
- **Small sizes.** The mouth's dark slit never gets thinner than a few pixels, so a 48px avatar still has a mouth.
- **Reduced motion.** With `prefers-reduced-motion: reduce`, or `paused`, the still pose of the state is drawn instead of the animation, and `play()` resolves at once.
- **Accessible by default.** The element has `role="img"` and an `aria-label` naming the state and expression ("Robot, thinking"); pass your own `aria-label` to override it.
- **One loop for all.** Every head on the page shares one animation loop, which sleeps while the tab is hidden.

## How it is drawn

The head is a sculpted mesh (credited below), cut at the mouth line into a cranium and a hinged jaw and decimated to a few thousand triangles. Each frame it is turned with the pose and projected, back faces are culled, the triangles are sorted back to front and each is lit by a small studio model (a key light, a fill, a sky dome, a softbox and a rim light, pressed toward a flatter, painted look) and filled. The head is drawn on its own layer so its silhouette can be inked in a dark outline, as in hand-drawn animation; ink seams mark the jaw's front panel.

The eyes are drawn in the plane of the face: a dark socket, a disc of light with a small white core falling off to a warm rim, lids that clip it, an optional aperture iris, and a bloom. The jaw swings about its hinge, its top edge bending into a smile's crescent or a frown. Expressions are flat sets of numbers chased by springs, and scripted changes (a blink, waking, turning red and back) are keyframed from the film frames and laid over them.

## Development

The repo is a pnpm workspace: the library at the root, the playground in `site/`, a React app on [Vite](https://vite.dev) served by a [Cloudflare Worker](https://developers.cloudflare.com/workers/). The playground runs on the library's source, so edits hot-reload there. A dev-only lab (`/lab`, never built) puts the renders next to reference stills.

```bash
pnpm install
pnpm run dev       # the playground (and /lab)
pnpm run build     # the library, to dist/
pnpm run typecheck
pnpm run deploy    # build and deploy the playground Worker
```

```
src/              the library
  RobotHead.tsx     the component
  audio.ts          lip-sync from audio sources
  robot/            geometry, the mesh (model.ts, generated), lighting, the face rig, motion, renderer
scripts/model/    turning the sculpt into model.ts (Blender + Python)
site/             the playground and the lab
```

## Credits

- The head is adapted from a sculpt by [EMA Labs](https://www.printables.com/model/212558), licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/): re-oriented, rescaled, cut into cranium and jaw, the neck removed, decimated.
- Forked from [robot-heads](https://github.com/fayazara/robot-heads) by Fayaz Ahmed.

## License

[MIT](LICENSE) © [Fayaz Ahmed](https://x.com/fayazara); the head mesh is CC BY 4.0 as above.

The playground is set in [Open Runde](https://github.com/lauridskern/open-runde) by Laurids Kern, under the SIL Open Font License 1.1 (`site/public/fonts/OFL.txt`). The font is not part of the npm package.
