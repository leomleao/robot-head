/* The lab: a dev-only page (never built or deployed) that puts the robot
   next to the reference stills, with every pose and face parameter on a
   slider. The stills are read from the private inspiration folder through
   the dev server. */

import { StrictMode, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { RobotHead, robotActions, robotExpressions, robotHeadStates, type RobotExpression, type RobotHeadHandle, type RobotHeadState } from 'robot-heads';
import { RobotRenderer, frameFor, palette, type RobotPose } from '../../../src/robot/render';
import { EXPRESSIONS, SEQUENCES, applySequence, cloneFace, mixFace, sequenceLength, type FaceRig, type SequenceName } from '../../../src/robot/rig';
import { targetFace } from '../../../src/robot/sim';
import { listen } from '../../../src/audio';
import './lab.css';

const REF = '/@fs/Users/leo/dev/robot-head/inspiration/frames/';
const SHELL: [number, number, number] = [60, 55, 63];

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
    r.current.draw(c.getContext('2d')!, f, dpr, { yaw: 0, pitch: 0, roll: 0, x: 0, lift: 0, ...pose }, face, palette(shell), { shadow: true });
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
  { label: 'Low angle', pose: { yaw: -0.5, pitch: 0.25 }, ref: '14-head-shape/06348.jpg' },
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
const JAW_SLIDERS: Array<[keyof FaceRig, number, number]> = [['jawOpen', 0, 1], ['jawSmile', -1, 1]];

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
  const [mouth, setMouth] = useState(-0.01);
  const q = new URLSearchParams(location.search);
  useEffect(() => {
    if (q.get('state')) setState(q.get('state') as RobotHeadState);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const m = mouth < 0 ? undefined : mouth;
  const robot = useRef<RobotHeadHandle>(null);
  const [doing, setDoing] = useState('');
  return (
    <section>
      <h2>Live</h2>
      <div className="row">
        <RobotHead ref={robot} size={320} state={state} expression={expr || undefined} mouth={m} />
        <div className="controls">
          <label>state <select value={state} onChange={(e) => setState(e.target.value as RobotHeadState)}>{robotHeadStates.map((s) => <option key={s}>{s}</option>)}</select></label>
          <label>expression <select value={expr} onChange={(e) => setExpr(e.target.value as RobotExpression | '')}><option value="">(state's own)</option>{robotExpressions.map((e) => <option key={e}>{e}</option>)}</select></label>
          <div className="actions">
            {robotActions.map((a) => (
              <button key={a} onClick={() => { setDoing(a); void robot.current?.play(a).then(() => setDoing((d) => (d === a ? '' : d))); }}>{a}</button>
            ))}
            <span>{doing && `playing ${doing}…`}</span>
          </div>
          <label>mouth <input type="range" min={-0.01} max={1} step={0.01} value={mouth} onChange={(e) => setMouth(+e.target.value)} /> {m === undefined ? 'auto' : m.toFixed(2)}</label>
        </div>
        <RobotHead size={64} state={state} expression={expr || undefined} />
        <RobotHead size={120} state={state} expression={expr || undefined} />
      </div>
    </section>
  );
}

function Mouth() {
  const big = new URLSearchParams(location.search).get('big');
  const bigExpr = (new URLSearchParams(location.search).get('expr') ?? 'neutral') as RobotExpression;
  const opens = big ? [Number(big)] : [0.14, 0.4, 0.7, 1];
  const yaw = Number(new URLSearchParams(location.search).get('yaw') ?? -0.25);
  const poses: Array<Partial<RobotPose>> = big ? [{ yaw }] : [{}, { yaw: -0.4, pitch: 0.12 }];
  return (
    <section>
      <h2>Mouth</h2>
      {poses.map((pose, i) => (
        <div className="row" key={i} style={{ gap: 8 }}>
          {opens.map((o) => {
            const f = cloneFace(EXPRESSIONS[big ? bigExpr : 'neutral']);
            if (!big || o > 0) f.jawOpen = o;
            return <Still key={o} pose={pose} face={f} size={big ? 560 : 260} />;
          })}
        </div>
      ))}
    </section>
  );
}

/* poses chosen to match reference stills, for exporting side by side */
const GALLERY: Array<{ name: string; pose: Partial<RobotPose>; expr: RobotExpression; jaw?: number }> = [
  { name: 'front-happy', pose: { pitch: -0.08 }, expr: 'happy' },
  { name: 'front-neutral', pose: {}, expr: 'neutral' },
  { name: 'three-quarter', pose: { yaw: -0.38, pitch: -0.04, roll: 0.05 }, expr: 'neutral' },
  { name: 'profile', pose: { yaw: 0.95, pitch: 0.05 }, expr: 'neutral' },
  { name: 'low-angle', pose: { yaw: 0.25, pitch: 0.28, roll: -0.05 }, expr: 'neutral' },
  { name: 'looking-down', pose: { yaw: -0.3, pitch: -0.3, roll: 0.1 }, expr: 'neutral' },
  { name: 'open-mouth', pose: { yaw: 0.1 }, expr: 'surprised', jaw: 0.75 },
  { name: 'sad', pose: { yaw: 0.15 }, expr: 'sad' },
  { name: 'angry', pose: { yaw: -0.1, pitch: -0.06 }, expr: 'angry' },
  { name: 'defense', pose: {}, expr: 'defense' },
];

function Gallery() {
  return (
    <section>
      <h2>Gallery</h2>
      <div className="row" style={{ gap: 8 }}>
        {GALLERY.map((g) => {
          const f = cloneFace(EXPRESSIONS[g.expr]);
          if (g.jaw !== undefined) f.jawOpen = g.jaw;
          f.yaw = f.pitch = f.roll = 0;
          return <span key={g.name} data-name={g.name}><Still pose={g.pose} face={f} size={Number(new URLSearchParams(location.search).get('size') ?? 420)} /></span>;
        })}
      </div>
    </section>
  );
}

/* each expression beside the frame it is tuned against; crops are [x, y, w, h] in fractions of the still */
const SHEET: Array<{ expr: RobotExpression; ref: string; crop: [number, number, number, number] }> = [
  { expr: 'neutral', ref: '01-neutral/08314.jpg', crop: [0.25, 0, 0.4, 0.95] },
  { expr: 'curious', ref: '02-curious/02740.jpg', crop: [0.22, 0, 0.42, 1] },
  { expr: 'happy', ref: '03-happy/08720.jpg', crop: [0.2, 0, 0.5, 1] },
  { expr: 'joyful', ref: '03-happy/09180.jpg', crop: [0.25, 0, 0.4, 0.95] },
  { expr: 'sad', ref: '04-sad/06800.jpg', crop: [0.45, 0, 0.55, 1] },
  { expr: 'sheepish', ref: '04-sad/06804.jpg', crop: [0.45, 0, 0.55, 1] },
  { expr: 'sleepy', ref: '05-squint-half-lid/03328.jpg', crop: [0.15, 0, 0.7, 0.75] },
  { expr: 'suspicious', ref: '05-squint-half-lid/05252.jpg', crop: [0.0, 0.1, 0.6, 0.9] },
  { expr: 'content', ref: '05-squint-half-lid/04496.jpg', crop: [0.3, 0, 0.5, 0.75] },
  { expr: 'surprised', ref: '09-eye-closeups/04796.jpg', crop: [0.3, 0, 0.6, 1] },
  { expr: 'afraid', ref: '04-sad/06808.jpg', crop: [0.45, 0, 0.55, 1] },
  { expr: 'determined', ref: '07-angry-determined/09752.jpg', crop: [0.25, 0.1, 0.45, 0.9] },
  { expr: 'angry', ref: '08-defense-red/06828.jpg', crop: [0.3, 0, 0.5, 0.9] },
  { expr: 'attack', ref: '07-angry-determined/09224.jpg', crop: [0.25, 0, 0.5, 1] },
  { expr: 'defense', ref: '08-defense-red/06832.jpg', crop: [0.3, 0, 0.5, 0.9] },
  { expr: 'peaceful', ref: '06-blink-eyelids/09928.jpg', crop: [0.3, 0, 0.5, 1] },
  { expr: 'asleep', ref: '13-wake-up-ending/10554.jpg', crop: [0.4, 0.2, 0.35, 0.6] },
];

function RefCrop({ src, crop, h }: { src: string; crop: [number, number, number, number]; h: number }) {
  /* the still is 1920 × 802 */
  const [x, y, w, hh] = crop;
  const scale = h / (hh * 802);
  return (
    <span style={{ display: 'block', width: w * 1920 * scale, height: h, overflow: 'hidden', borderRadius: 6, flex: 'none' }}>
      <img src={REF + src} alt="" style={{ width: 1920 * scale, height: 802 * scale, marginLeft: -x * 1920 * scale, marginTop: -y * 802 * scale, maxWidth: 'none' }} />
    </span>
  );
}

function Sheet() {
  const from = Number(new URLSearchParams(location.search).get('from') ?? 0);
  return (
    <section>
      <h2>G2 · Expressions</h2>
      <div className="sheet">
        {SHEET.slice(from, from + 9).map((x) => (
          <figure key={x.expr} className="pair">
            <Still pose={{}} face={targetFace('idle', x.expr, [255, 236, 226])} size={150} />
            <RefCrop src={x.ref} crop={x.crop} h={150} />
            <figcaption>{x.expr} · {x.ref}</figcaption>
          </figure>
        ))}
      </div>
    </section>
  );
}

/* each scripted change as a filmstrip over the frames it follows; the face it leaves and the one it ends on */
const STRIPS: Array<{ seq: SequenceName; from: RobotExpression; to: RobotExpression; refs: string[]; crop: [number, number, number, number] }> = [
  { seq: 'defenseOn', from: 'neutral', to: 'defense', refs: ['06825', '06827', '06828', '06829', '06830', '06831', '06832', '06834'].map((f) => `08-defense-red/${f}.jpg`), crop: [0.4, 0, 0.4, 1] },
  { seq: 'defenseOff', from: 'defense', to: 'neutral', refs: ['08290', '08309', '08310', '08311'].map((f) => `08-defense-red/${f}.jpg`).concat(['01-neutral/08312.jpg', '01-neutral/08313.jpg']), crop: [0.3, 0, 0.4, 1] },
  { seq: 'blink', from: 'neutral', to: 'neutral', refs: ['09920', '09922', '09923', '09924', '09925', '09926', '09927', '09929'].map((f) => `06-blink-eyelids/${f}.jpg`), crop: [0.33, 0, 0.42, 1] },
  { seq: 'wake', from: 'asleep', to: 'neutral', refs: ['10550', '10552', '10553', '10554', '10555', '10556', '10558', '10562'].map((f) => `13-wake-up-ending/${f}.jpg`), crop: [0.25, 0, 0.6, 1] },
];

function Strips() {
  const eye: [number, number, number] = [255, 236, 226];
  return (
    <section>
      <h2>G2 · Scripted changes</h2>
      {STRIPS.slice(Number(new URLSearchParams(location.search).get("from") ?? 0)).map((x) => {
        const seq = SEQUENCES[x.seq];
        const len = sequenceLength(seq);
        const a = targetFace('idle', x.from, eye), b = targetFace('idle', x.to, eye);
        return (
          <div key={x.seq} className="strip">
            <div className="row" style={{ gap: 2 }}>
              {Array.from({ length: 8 }, (_, i) => {
                const t = (i / 7) * len;
                /* the springs carry the face from one to the other underneath */
                const f = mixFace(a, b, Math.min(1, t / (len * 0.6)), cloneFace(a));
                applySequence(seq, t, f);
                f.yaw = f.pitch = f.roll = 0;
                return <Still key={i} pose={{}} face={f} size={110} />;
              })}
            </div>
            <div className="row" style={{ gap: 2 }}>
              {x.refs.map((r) => <RefCrop key={r} src={r} crop={x.crop} h={90} />)}
            </div>
            <p>{x.seq} · {len.toFixed(2)} s</p>
          </div>
        );
      })}
    </section>
  );
}

/* every state, live, and something to look at */
function Motion() {
  const [target, setTarget] = useState<{ x: number; y: number } | null>(null);
  return (
    <section onPointerMove={(e) => e.shiftKey && setTarget({ x: e.clientX, y: e.clientY })} onClick={() => setTarget(null)}>
      <h2>N7 · States (hold shift and move to set a lookAt point; click to clear)</h2>
      <div className="states">
        {robotHeadStates.map((st) => (
          <figure key={st}>
            <RobotHead size={140} state={st} lookAt={target} interactive={!target} />
            <figcaption>{st}</figcaption>
          </figure>
        ))}
      </div>
      {target && <span className="dot" style={{ left: target.x - 6, top: target.y - 6 }} />}
    </section>
  );
}

/* the robot lip-syncing to the film's lines, voice only (dev reference, never shipped) */
const CLIPS = ["01-blah-blah-blah", "02-rock", "03-rock-question-yes-rock-excited", "04-rock-tree", "05-hmm-question", "06-laugh", "07-bye", "08-superman-first-try", "09-mm-hmm", "10-rockwell-question", "11-rockwell-excited", "12-awww", "13-mmm", "14-hmm-look", "15-dean", "16-art-question", "17-banzai", "18-deer-question", "19-dead-question", "20-but-why", "21-gun", "22-guns-kill", "23-you-die", "24-i-die", "25-soul-question", "26-souls-dont-die", "27-no-atomo", "28-i-superman", "29-no-stop-why", "30-i-not-gun", "31-no-seeing-the-bus", "32-i-am-not-a-gun", "33-no-no-covering-eyes", "34-hogarth-snapping-back", "35-regretful-moan", "36-i-fix", "37-hogarth-you-stay-i-go", "38-no-following", "39-superman-final"];
const AUDIO = '/@fs/Users/leo/dev/robot-head/inspiration/audio/lines-isolated/';

function Voice() {
  const [clip, setClip] = useState(CLIPS[36]);
  const [el, setEl] = useState<HTMLAudioElement | null>(null);
  const meter = useRef<HTMLSpanElement>(null);
  /* a meter of what the robot hears */
  useEffect(() => {
    if (!el) return;
    const tap = listen(el);
    let raf = 0;
    const tick = () => {
      const v = tap?.level() ?? 0;
      if (meter.current) {
        meter.current.style.width = `${v * 100}%`;
        meter.current.dataset.v = v.toFixed(3);
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      tap?.stop();
    };
  }, [el]);
  return (
    <section>
      <h2>N6 · Voice</h2>
      <div className="row">
        <RobotHead size={300} state="speaking" audio={el} />
        <div className="controls">
          <label>clip <select value={clip} onChange={(e) => setClip(e.target.value)}>{CLIPS.map((c) => <option key={c}>{c}</option>)}</select></label>
          <audio ref={setEl} src={AUDIO + clip + '.wav'} controls crossOrigin="anonymous" />
          <span className="meter"><span ref={meter} /></span>
        </div>
      </div>
    </section>
  );
}

/* ?only=likeness|rig|live|mouth|gallery|sheet|strips|motion|voice shows one section, so it fits a screenshot */
const only = new URLSearchParams(location.search).get('only');

function Lab() {
  const show = (name: string) => !only || only === name;
  return (
    <main>
      {!only && <h1>Robot lab</h1>}
      {show('likeness') && <Likeness />}
      {show('rig') && <Rig />}
      {show('live') && <Live />}
      {show('mouth') && <Mouth />}
      {only === 'gallery' && <Gallery />}
      {show('sheet') && <Sheet />}
      {show('strips') && <Strips />}
      {show('motion') && <Motion />}
      {show('voice') && <Voice />}
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
