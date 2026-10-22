/* The lab: a dev-only page (never built or deployed) that puts the robot
   next to the reference stills, with every pose and face parameter on a
   slider. The stills are read from the private inspiration folder through
   the dev server. */

import { StrictMode, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { RobotHead, robotExpressions, robotHeadStates, type RobotExpression, type RobotHeadState } from 'robot-heads';
import { RobotRenderer, frameFor, palette, type RobotPose } from '../../../src/robot/render';
import { EXPRESSIONS, cloneFace, type FaceRig } from '../../../src/robot/rig';
import { targetFace } from '../../../src/robot/sim';
import './lab.css';

const REF = '/@fs/Users/leo/dev/robot-head/inspiration/frames/';
const SHELL: [number, number, number] = [66, 62, 60];

function Still({ pose, face, size = 300, shell = SHELL }: { pose: Partial<RobotPose>; face: FaceRig; size?: number; shell?: [number, number, number] }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const r = useRef(new RobotRenderer());
  const f = frameFor(size);
  useEffect(() => {
    const c = ref.current!;
    const dpr = Math.min(2, devicePixelRatio || 1);
    c.width = Math.round((f.box + 2 * f.padSide) * dpr);
    c.height = Math.round((f.box + f.padTop + f.padBottom) * dpr);
    const t0 = performance.now();
    r.current.draw(c.getContext('2d')!, f, dpr, { yaw: 0, pitch: 0, roll: 0, x: 0, lift: 0, breathe: 0, ...pose }, face, palette(shell), { shadow: true });
    c.dataset.ms = (performance.now() - t0).toFixed(2);
  });
  return (
    <span className="still" style={{ width: size, height: size }}>
      <canvas ref={ref} style={{ left: -f.padSide, top: -f.padTop, width: f.box + 2 * f.padSide, height: f.box + f.padTop + f.padBottom }} />
    </span>
  );
}

const LIKENESS: Array<{ label: string; pose: Partial<RobotPose>; ref: string; expr?: RobotExpression }> = [
  { label: 'Front', pose: {}, ref: '03-happy/09180.jpg', expr: 'happy' },
  { label: 'Three-quarter', pose: { yaw: -0.38, pitch: -0.04, roll: 0.05 }, ref: '01-neutral/08314.jpg' },
  { label: 'Profile-ish', pose: { yaw: 0.9, pitch: 0.05 }, ref: '14-head-shape/05724.jpg' },
  { label: 'From below', pose: { yaw: 0.22, pitch: 0.26, roll: -0.04 }, ref: '14-head-shape/06348.jpg' },
  { label: 'Looking down', pose: { yaw: -0.3, pitch: -0.3, roll: 0.1 }, ref: '02-curious/06692.jpg' },
];

function Likeness() {
  return (
    <section>
      <h2>G1 · Likeness</h2>
      <div className="pairs">
        {LIKENESS.slice(Number(new URLSearchParams(location.search).get('from') ?? 0)).map((l) => (
          <figure key={l.label}>
            <Still pose={l.pose} face={targetFace('idle', l.expr ?? 'neutral', [255, 244, 228])} size={only ? 210 : 240} />
            <img src={REF + l.ref} alt="" />
            <figcaption>{l.label} · {l.ref}</figcaption>
          </figure>
        ))}
      </div>
    </section>
  );
}

const SLIDERS: Array<[keyof RobotPose, number, number]> = [['yaw', -1.6, 1.6], ['pitch', -0.6, 0.6], ['roll', -0.5, 0.5]];
const FACE_SLIDERS: Array<[string, number, number]> = [
  ['lidTop', 0, 1], ['lidBottom', 0, 1], ['lidAngle', -0.6, 0.6], ['lidCurve', 0, 1], ['glow', 0, 1.5], ['size', 0.6, 1.3],
  ['shape', 0, 1], ['pupil', 0, 1], ['gazeX', -1, 1], ['gazeY', -1, 1],
];
const JAW_SLIDERS: Array<[keyof FaceRig, number, number]> = [['jawOpen', 0, 1], ['jawSmile', -1, 1], ['teeth', 0, 1]];

function Rig() {
  const [pose, setPose] = useState<Partial<RobotPose>>({ yaw: -0.25, pitch: 0, roll: 0 });
  const [base, setBase] = useState<RobotExpression>('neutral');
  const [face, setFace] = useState<FaceRig>(() => cloneFace(EXPRESSIONS.neutral));
  const [size, setSize] = useState(420);
  const pick = (e: RobotExpression) => {
    setBase(e);
    setFace(cloneFace(EXPRESSIONS[e]));
  };
  const eyeSet = (k: string, v: number) => setFace((f) => ({ ...f, left: { ...f.left, [k]: v }, right: { ...f.right, [k]: v } }));
  return (
    <section>
      <h2>Rig</h2>
      <div className="rig">
        <Still pose={pose} face={face} size={size} />
        <div className="controls">
          <label>expression <select value={base} onChange={(e) => pick(e.target.value as RobotExpression)}>{robotExpressions.map((e) => <option key={e}>{e}</option>)}</select></label>
          <label>size <input type="range" min={60} max={600} value={size} onChange={(e) => setSize(+e.target.value)} /> {size}</label>
          {SLIDERS.map(([k, lo, hi]) => (
            <label key={k}>{k} <input type="range" min={lo} max={hi} step={0.01} value={pose[k] ?? 0} onChange={(e) => setPose((p) => ({ ...p, [k]: +e.target.value }))} /> {(pose[k] ?? 0).toFixed(2)}</label>
          ))}
          <hr />
          {FACE_SLIDERS.map(([k, lo, hi]) => (
            <label key={k}>{k} <input type="range" min={lo} max={hi} step={0.01} value={(face.left as unknown as Record<string, number>)[k]} onChange={(e) => eyeSet(k, +e.target.value)} /> {(face.left as unknown as Record<string, number>)[k].toFixed(2)}</label>
          ))}
          {JAW_SLIDERS.map(([k, lo, hi]) => (
            <label key={k}>{k} <input type="range" min={lo} max={hi} step={0.01} value={face[k] as number} onChange={(e) => setFace((f) => ({ ...f, [k]: +e.target.value }))} /> {(face[k] as number).toFixed(2)}</label>
          ))}
        </div>
      </div>
    </section>
  );
}

function Live() {
  const [state, setState] = useState<RobotHeadState>('idle');
  const [expr, setExpr] = useState<RobotExpression | ''>('');
  return (
    <section>
      <h2>Live</h2>
      <div className="row">
        <RobotHead size={320} state={state} expression={expr || undefined} />
        <div className="controls">
          <label>state <select value={state} onChange={(e) => setState(e.target.value as RobotHeadState)}>{robotHeadStates.map((s) => <option key={s}>{s}</option>)}</select></label>
          <label>expression <select value={expr} onChange={(e) => setExpr(e.target.value as RobotExpression | '')}><option value="">(state's own)</option>{robotExpressions.map((e) => <option key={e}>{e}</option>)}</select></label>
        </div>
        <RobotHead size={64} state={state} expression={expr || undefined} />
        <RobotHead size={120} state={state} expression={expr || undefined} />
      </div>
    </section>
  );
}

/* ?only=likeness|rig|live shows one section, so it fits a screenshot */
const only = new URLSearchParams(location.search).get('only');

function Lab() {
  const show = (name: string) => !only || only === name;
  return (
    <main>
      {!only && <h1>Robot lab</h1>}
      {show('likeness') && <Likeness />}
      {show('rig') && <Rig />}
      {show('live') && <Live />}
    </main>
  );
}

/* hot reloads run this module again: reuse the root */
const host = document.getElementById('root')! as HTMLElement & { _root?: ReturnType<typeof createRoot> };
host._root ??= createRoot(host);
host._root.render(
  <StrictMode>
    <Lab />
  </StrictMode>,
);
