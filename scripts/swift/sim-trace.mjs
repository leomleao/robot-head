/* Golden traces for the Swift sim: runs the real TS RobotSim through scripted
   scenarios and records every frame, so Sources/IronGiant/Sim can be held to
   it. Writes Tests/IronGiantTests/Fixtures/sim/*.json.

   node scripts/swift/sim-trace.mjs   (Node 24: it reads the .ts directly)

   Each scenario is a seed, a starting state and a timeline of inputs keyed
   by frame. A frame applies its inputs in order, as RobotHead.tsx would
   between ticks, then steps the sim by dt × speed and records the pose and
   the face. The inputs go into the fixture, so the Swift test replays the
   same timeline. */

import { mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import './ts-resolve.mjs';

const { RobotSim, REST, STATE_FACE, ROBOT_ACTIONS, targetFace } = await import('../../src/robot/sim.ts');
const { EXPRESSIONS, EXPRESSION_NAMES, FaceSprings, SEQUENCES, WHITE, applySequence, cloneFace, mixFace, sequenceLength } =
  await import('../../src/robot/rig.ts');

const outDir = fileURLToPath(new URL('../../Tests/IronGiantTests/Fixtures/sim/', import.meta.url));

/* 1e-7 keeps the files small and is far inside the tests' tolerance */
const r = (v) => Math.round(v * 1e7) / 1e7 + 0;

const EYE_KEYS = ['lidTop', 'lidBottom', 'lidAngle', 'lidCurve', 'glow', 'size', 'shape', 'pupil', 'gazeX', 'gazeY'];
const COLUMNS = [
  'time', 'acting', 'pose.yaw', 'pose.pitch', 'pose.roll', 'pose.x', 'pose.lift',
  ...EYE_KEYS.map((k) => `left.${k}`), ...EYE_KEYS.map((k) => `right.${k}`),
  'color.r', 'color.g', 'color.b', 'jawOpen', 'jawSmile', 'yaw', 'pitch', 'roll',
];
const faceRow = (f) => [
  ...EYE_KEYS.map((k) => f.left[k]), ...EYE_KEYS.map((k) => f.right[k]),
  ...f.color, f.jawOpen, f.jawSmile, f.yaw, f.pitch, f.roll,
];
const faceJSON = (f) => faceRow(f).map(r);

const STATES = ['idle', 'thinking', 'searching', 'listening', 'speaking', 'working', 'happy', 'error', 'sleeping'];
const FPS = 60;
const at = (seconds) => Math.round(seconds * FPS);

/* ── scenarios ───────────────────────────────────────────────────────── */

/* events: [seconds, type, ...args]; see run() for the types */
const scenarios = [
  {
    name: 'idle-life',
    seed: 0.42,
    state: 'idle',
    seconds: 12,
    events: [],
  },
  {
    name: 'states-tour',
    seed: 0.42,
    state: 'idle',
    seconds: 12,
    events: STATES.slice(1).map((s, i) => [0.6 + i * 1.25, 'set', s]).concat([[10.6, 'set', 'idle']]),
  },
  {
    name: 'states-long',
    seed: 0.7,
    state: 'thinking',
    seconds: 12,
    events: [
      [4, 'set', 'speaking'],
      [8, 'set', 'error'],
    ],
  },
  {
    name: 'happy-and-sleep',
    seed: 0.91,
    state: 'sleeping',
    seconds: 12,
    events: [
      /* sleeping → idle wakes from the seam */
      [2, 'set', 'idle'],
      [3.5, 'set', 'happy'],
      [8, 'set', 'listening'],
      [10.5, 'set', 'happy'],
    ],
  },
  {
    name: 'expressions-tour',
    seed: 0.13,
    state: 'idle',
    seconds: 12,
    events: [
      ...EXPRESSION_NAMES.map((e, i) => [0.3 + i * 0.6, 'set', 'idle', e]),
      /* asleep back to the state's own face: a wake */
      [10.5, 'set', 'idle', null],
      /* not an expression: the state's face, as RobotHead does */
      [11.2, 'set', 'idle', 'grumpy'],
    ],
  },
  {
    name: 'red-eyes',
    seed: 0.91,
    state: 'idle',
    eye: [120, 200, 255],
    seconds: 10,
    events: [
      [0.5, 'set', 'idle', 'angry'],
      /* red to red: no sequence */
      [1.5, 'set', 'idle', 'defense'],
      [2.5, 'set', 'idle', 'neutral'],
      /* attack's pink just eases in, and out */
      [3.5, 'set', 'idle', 'attack'],
      [4.5, 'set', 'idle', 'angry'],
      [5.5, 'set', 'happy', 'attack'],
      [6.5, 'set', 'happy', null],
      /* the eye colour changing on its own */
      [7, 'set', 'happy', null, [255, 180, 60]],
      [7.5, 'act', 'defense', 0.5],
      [8.6, 'set', 'error', 'defense'],
      [9.2, 'set', 'error', null],
    ],
  },
  {
    name: 'actions',
    seed: 0.7,
    state: 'idle',
    seconds: 12,
    events: [
      [0.3, 'act', 'blink'],
      [0.8, 'act', 'nod'],
      [2.2, 'act', 'shake'],
      [4, 'act', 'hmm'],
      [5.8, 'act', 'laugh'],
      [7, 'act', 'surprise'],
      [8.1, 'act', 'wake'],
      [9.2, 'act', 'defense'],
    ],
  },
  {
    name: 'interruptions',
    seed: 0.7,
    state: 'listening',
    seconds: 9,
    events: [
      [0.2, 'act', 'nod'],
      [0.6, 'act', 'shake'],
      [1.0, 'act', 'defense', 0.5],
      [2.0, 'act', 'defense'],
      /* cut short while red: the eyes turn back */
      [2.8, 'act', 'hmm'],
      [3.1, 'act', 'laugh'],
      [3.4, 'act', 'surprise'],
      [3.5, 'act', 'blink'],
      [3.6, 'act', 'wake'],
      [4.2, 'act', 'defense', 0],
      [4.6, 'act', 'defense', 2],
      [5.2, 'set', 'sleeping'],
      [5.4, 'act', 'nod'],
      [7, 'set', 'speaking'],
      [7.2, 'act', 'hmm'],
    ],
  },
  {
    name: 'pointer-look-poke',
    seed: 0.13,
    state: 'idle',
    seconds: 12,
    events: [
      /* a pointer circling the head, then gone */
      ...Array.from({ length: at(3) }, (_, i) => {
        const a = (i / FPS) * 2.1;
        return [0.5 + i / FPS, 'pointer', Math.cos(a) * 380, Math.sin(a) * 260 - 40];
      }),
      [3.5, 'pointer', null],
      [3.6, 'poke'],
      [3.7, 'poke'],
      [4.2, 'set', 'listening'],
      [4.2, 'pointer', -220, 90],
      /* a lookAt wins over the pointer */
      [5.2, 'lookAt', 300, -250],
      [6.2, 'set', 'thinking'],
      [6.8, 'lookAt', null],
      /* thinking doesn't follow the pointer */
      [7.6, 'set', 'sleeping'],
      /* nor does anything follow while sleeping */
      [7.8, 'lookAt', 120, 40],
      [8.4, 'poke'],
      [9, 'set', 'searching'],
      [9.4, 'lookAt', -600, 900],
      [10.2, 'lookAt', null],
      [10.2, 'set', 'idle'],
      [10.6, 'pointer', 40, -30],
      [11, 'poke'],
    ],
  },
  {
    name: 'mouth-levels',
    seed: 0.555,
    state: 'speaking',
    seconds: 9,
    events: [
      [1.5, 'mouth', 0.5],
      [2.2, 'mouth', 1],
      [2.5, 'mouth', 0],
      [2.9, 'mouth', 1.4],
      [3.3, 'mouth', -0.2],
      ...Array.from({ length: at(1.5) }, (_, i) => [3.8 + i / FPS, 'mouth', 0.5 + 0.5 * Math.sin(i * 0.9)]),
      [5.3, 'mouth', null],
      [6.5, 'set', 'happy'],
      [7.5, 'mouth', 0.3],
      [8.5, 'mouth', null],
    ],
  },
  {
    name: 'speed-and-big-steps',
    seed: 0.29,
    state: 'working',
    seconds: 10,
    events: [
      [1, 'speed', 0.5],
      [2, 'act', 'nod'],
      [3, 'speed', 2],
      [3.2, 'act', 'shake'],
      [4.5, 'speed', 1],
      /* a slow frame, as the ticker allows (it clamps to 0.1 s) */
      [5, 'dt', 0.1],
      [5.5, 'act', 'laugh'],
      [6, 'set', 'happy'],
      [7, 'dt', 1 / 60],
      [7.5, 'dt', 0],
      [7.6, 'dt', 0.033],
      [8, 'act', 'defense', 0.7],
      [8.5, 'speed', 3],
      [9, 'dt', 1 / 60],
      [9, 'speed', 1],
    ],
  },
];

/* ── running one ─────────────────────────────────────────────────────── */

function run(sc) {
  const frames = at(sc.seconds);
  const eye0 = sc.eye ?? WHITE;
  /* RobotHead drops an expression it doesn't know */
  const known = (e) => (e && e in EXPRESSIONS ? e : undefined);
  const sim = new RobotSim(sc.seed, sc.state, known(sc.expression), [...eye0]);

  /* the timeline, by frame, keeping the order given */
  let nextId = 0;
  const events = sc.events
    .map(([t, type, ...args], order) => ({ t, type, args, order }))
    .sort((a, b) => at(a.t) - at(b.t) || a.order - b.order)
    .map(({ t, type, args }) => {
      const e = { frame: at(t), type };
      switch (type) {
        case 'set':
          e.state = args[0];
          e.expression = args[1] ?? null;
          if (args[2]) e.eye = args[2];
          break;
        case 'act':
          e.action = args[0];
          e.id = nextId++;
          e.hold = args[1] ?? null;
          break;
        case 'pointer':
        case 'lookAt':
          if (args[0] !== null && args[0] !== undefined) {
            e.x = r(args[0]);
            e.y = r(args[1]);
          }
          break;
        case 'mouth':
        case 'speed':
        case 'dt':
          e.value = args[0] === null ? null : r(args[0]);
          break;
        case 'poke':
          break;
        default:
          throw new Error(`unknown event ${type}`);
      }
      return e;
    });

  /* actions resolve through their promise; wrap `done` to see when, and whether a new act() cut them short */
  const resolutions = [];
  let frame = -1;
  let inAct = false;
  let eye = [...eye0];
  let dt = 1 / FPS;
  let speed = 1;

  const rows = [];
  const record = () => {
    const p = sim.pose;
    rows.push([sim.time, sim.action ? 1 : 0, p.yaw, p.pitch, p.roll, p.x, p.lift, ...faceRow(sim.face)].map(r));
  };
  record();

  let ei = 0;
  for (frame = 0; frame < frames; frame++) {
    for (; ei < events.length && events[ei].frame === frame; ei++) {
      const e = events[ei];
      switch (e.type) {
        case 'set':
          if (e.eye) eye = [...e.eye];
          sim.set(e.state, known(e.expression), [...eye]);
          break;
        case 'act': {
          inAct = true;
          sim.act(e.action, e.hold === null ? {} : { hold: e.hold });
          inAct = false;
          const a = sim.action;
          const done = a.done;
          const id = e.id;
          a.done = () => {
            resolutions.push({ id, action: e.action, outcome: inAct ? 'interrupted' : 'completed', frame, time: r(sim.time) });
            done();
          };
          break;
        }
        case 'poke':
          sim.poke();
          break;
        case 'pointer':
          sim.pointer = e.x === undefined ? null : { x: e.x, y: e.y };
          break;
        case 'lookAt':
          sim.lookAt = e.x === undefined ? null : { x: e.x, y: e.y };
          break;
        case 'mouth':
          sim.mouth = e.value;
          break;
        case 'speed':
          speed = e.value;
          break;
        case 'dt':
          dt = e.value;
          break;
      }
    }
    sim.update(dt * speed);
    record();
  }

  return {
    name: sc.name,
    seed: sc.seed,
    state: sc.state,
    expression: sc.expression ?? null,
    eye: eye0,
    dt: 1 / FPS,
    frames,
    events,
    actions: resolutions,
    columns: COLUMNS,
    /* rows[0] is the sim as constructed; rows[n] is after frame n − 1 */
    rows,
  };
}

/* ── the rig's tables ────────────────────────────────────────────────── */

function rigFixture() {
  const rngOut = {};
  for (const seed of [0, 0.5, 0.123456789, 0.987654321, 1]) {
    /* the sim's own generator: its first draws, made in the constructor's order, are hidden, so make one */
    const draws = [];
    let a = Math.floor(seed * 4294967295) >>> 0 || 1;
    for (let i = 0; i < 8; i++) {
      a = (a + 0x6d2b79f5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      draws.push(((t ^ (t >>> 14)) >>> 0) / 4294967296);
    }
    rngOut[String(seed)] = draws;
  }

  const expressions = Object.fromEntries(EXPRESSION_NAMES.map((n) => [n, faceJSON(EXPRESSIONS[n])]));
  const custom = [10, 200, 120];
  const targets = {
    eye: custom,
    states: Object.fromEntries(STATES.map((s) => [s, faceJSON(targetFace(s, undefined, custom))])),
    expressions: Object.fromEntries(EXPRESSION_NAMES.map((n) => [n, faceJSON(targetFace('idle', n, custom))])),
  };

  /* each sequence laid over a white neutral face and a red angry one, every 10 ms */
  const sequences = {};
  for (const [name, seq] of Object.entries(SEQUENCES)) {
    const len = sequenceLength(seq);
    const samples = [];
    for (let i = 0; i * 0.01 <= len + 0.05; i++) {
      const t = i * 0.01;
      const a = cloneFace(EXPRESSIONS.neutral);
      applySequence(seq, t, a);
      const b = cloneFace(EXPRESSIONS.angry);
      applySequence(seq, t, b);
      samples.push([r(t), faceJSON(a), faceJSON(b)]);
    }
    sequences[name] = { length: len, samples };
  }

  /* springs from neutral toward defense, at two speeds, and a snap */
  const springs = {};
  for (const speed of [1, 2]) {
    const s = new FaceSprings(EXPRESSIONS.neutral);
    const out = [];
    for (let i = 1; i <= 360; i++) {
      s.step(EXPRESSIONS.defense, 1 / 120, speed);
      if (i % 10 === 0) out.push(faceJSON(s.face));
    }
    springs[`speed${speed}`] = out;
  }
  {
    const s = new FaceSprings(EXPRESSIONS.neutral);
    s.step(EXPRESSIONS.angry, 0.05);
    s.snap(EXPRESSIONS.sad);
    springs.snap = faceJSON(s.face);
  }

  const mix = faceJSON(mixFace(EXPRESSIONS.neutral, EXPRESSIONS.angry, 0.3, cloneFace(EXPRESSIONS.neutral)));

  return {
    columns: COLUMNS.slice(7),
    names: EXPRESSION_NAMES,
    actions: ROBOT_ACTIONS,
    rng: rngOut,
    expressions,
    stateFace: STATE_FACE,
    rest: Object.fromEntries(STATES.map((s) => [s, [REST[s].yaw, REST[s].pitch, REST[s].roll, REST[s].x, REST[s].lift]])),
    targets,
    sequences,
    springs,
    mix,
  };
}

/* ── writing ─────────────────────────────────────────────────────────── */

mkdirSync(outDir, { recursive: true });
for (const f of readdirSync(outDir)) if (f.endsWith('.json')) rmSync(outDir + f);

/* one row per line: a readable diff when a trace changes */
const write = (file, obj) => {
  const { rows, ...rest } = obj;
  let s = JSON.stringify(rest);
  if (rows) s = s.slice(0, -1) + ',"rows":[\n' + rows.map((row) => JSON.stringify(row)).join(',\n') + '\n]}';
  writeFileSync(outDir + file, s + '\n');
};

write('rig.json', rigFixture());
const seen = { states: new Set(), expressions: new Set(), actions: new Set() };
for (const sc of scenarios) {
  const trace = run(sc);
  write(`trace-${sc.name}.json`, trace);
  seen.states.add(trace.state);
  if (trace.expression) seen.expressions.add(trace.expression);
  for (const e of trace.events) {
    if (e.type === 'set') {
      seen.states.add(e.state);
      if (e.expression) seen.expressions.add(e.expression);
    }
    if (e.type === 'act') seen.actions.add(e.action);
  }
  console.log(`${trace.name}: ${trace.frames} frames, ${trace.events.length} events, ${trace.actions.length} action ends`);
}

/* every state, expression and action in at least one trace */
const missing = [
  ...STATES.filter((s) => !seen.states.has(s)),
  ...EXPRESSION_NAMES.filter((e) => !seen.expressions.has(e)),
  ...ROBOT_ACTIONS.filter((a) => !seen.actions.has(a)),
];
if (missing.length) throw new Error(`not covered: ${missing.join(', ')}`);
