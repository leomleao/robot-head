/* The face as a flat set of numbers. Expressions are targets for it, the
   sim and the actions nudge it, and springs carry it from one target to
   the next, so any change of face eases across instead of cutting.

   Eyes do the acting. Each glows as a disc inside a dark socket, and two
   dark lids cut into the disc from above and below: the top lid's angle is
   the brow (inner corner down reads as anger, up as worry), the bottom
   lid's curve is a smile in the eyes. The jaw opens about its hinge, and
   its top edge bends into a smile or a frown. */

import type { RobotExpression } from '../types';

export type RGB = [number, number, number];

export interface EyeRig {
  /* how far each lid has closed over the disc, 0 open … 1 to the middle */
  lidTop: number;
  lidBottom: number;
  /* the top lid's tilt in radians; positive drops its inner corner (anger) */
  lidAngle: number;
  /* the bottom lid's edge: 0 straight, 1 curved up like a smiling cheek */
  lidCurve: number;
  /* the glow's brightness and size, 1 at rest */
  glow: number;
  size: number;
  /* 0 a round disc … 1 a pentagon (defence mode) */
  shape: number;
  /* the iris closing over the glow: 0 none, then an opening that narrows to a pinpoint at 1 */
  pupil: number;
  /* where the disc sits in the socket, −1 … 1 each way */
  gazeX: number;
  gazeY: number;
}

export interface FaceRig {
  left: EyeRig;
  right: EyeRig;
  /* the glow's colour, sRGB 0–255 */
  color: RGB;
  /* 0 shut … 1 wide */
  jawOpen: number;
  /* −1 frown … 1 smile */
  jawSmile: number;
  /* offsets added to the head's pose, radians */
  yaw: number;
  pitch: number;
  roll: number;
}

const eye = (o: Partial<EyeRig> = {}): EyeRig => ({
  lidTop: 0, lidBottom: 0, lidAngle: 0, lidCurve: 0, glow: 1, size: 1, shape: 0, pupil: 0, gazeX: 0, gazeY: 0, ...o,
});

export const WHITE: RGB = [255, 236, 226];
const RED: RGB = [255, 38, 24];

/* `left` and `right` are the robot's own, so they appear swapped on screen */
const face = (o: Partial<Omit<FaceRig, 'left' | 'right'>> & { eyes?: Partial<EyeRig>; left?: Partial<EyeRig>; right?: Partial<EyeRig> } = {}): FaceRig => {
  const { eyes, left, right, ...rest } = o;
  return {
    left: eye({ ...eyes, ...left }),
    right: eye({ ...eyes, ...right }),
    color: WHITE,
    jawOpen: 0.04,
    jawSmile: 0.3,
    yaw: 0,
    pitch: 0,
    roll: 0,
    ...rest,
  };
};

/**
 * Each expression as a full face; `color` is replaced by the `eyeColor`
 * prop except where the colour is the point (defence and attack).
 */
export const EXPRESSIONS: Record<RobotExpression, FaceRig> = {
  neutral: face(),
  curious: face({ eyes: { size: 1.06, lidTop: 0 }, left: { lidTop: 0.14, lidAngle: -0.12 }, roll: 0.16, yaw: -0.08, jawSmile: 0.1 }),
  happy: face({ eyes: { lidTop: 0, size: 1.03 }, jawSmile: 1, jawOpen: 0.36, pitch: 0.04 }),
  joyful: face({ eyes: { lidTop: 0, size: 1.06, glow: 1.1 }, jawSmile: 1, jawOpen: 0.8, pitch: 0.08 }),
  sad: face({ eyes: { lidTop: 0.36, lidAngle: -0.42, gazeY: 0.55, glow: 0.8 }, jawSmile: -0.55, jawOpen: 0.04, pitch: -0.16 }),
  sheepish: face({ eyes: { lidTop: 0.3, lidAngle: -0.3, gazeX: -0.35, gazeY: 0.35 }, jawSmile: -0.2, jawOpen: 0.1, roll: -0.08, pitch: -0.08 }),
  sleepy: face({ eyes: { lidTop: 0.55, glow: 0.75, gazeY: 0.3 }, jawSmile: 0, jawOpen: 0.04, pitch: -0.06 }),
  suspicious: face({ eyes: { lidTop: 0.4, lidBottom: 0.24, lidAngle: 0.12, gazeX: 0.45 }, left: { lidTop: 0.5 }, jawSmile: -0.1, jawOpen: 0.04, yaw: 0.06 }),
  content: face({ eyes: { lidTop: 0.38, lidBottom: 0.16, lidCurve: 0.6, glow: 0.9 }, jawSmile: 0.5, jawOpen: 0.06 }),
  surprised: face({ eyes: { lidTop: 0, size: 1.14, glow: 1.25 }, jawOpen: 0.55, jawSmile: 0, pitch: 0.06 }),
  determined: face({ eyes: { lidTop: 0.36, lidBottom: 0.2, lidAngle: 0.34 }, jawSmile: -0.15, jawOpen: 0.03, pitch: -0.05 }),
  angry: face({ eyes: { lidTop: 0.36, lidBottom: 0.1, lidAngle: 0.5, pupil: 0.42, glow: 1.15 }, color: RED, jawSmile: -0.3, jawOpen: 0.02, pitch: -0.06 }),
  attack: face({ eyes: { lidTop: 0.34, lidBottom: 0.24, lidAngle: 0.38, pupil: 0.6, glow: 1.3 }, color: RED, jawOpen: 0.4, jawSmile: 0.2, pitch: -0.08 }),
  defense: face({ eyes: { lidTop: 0.08, lidBottom: 0.04, lidAngle: 0.1, pupil: 1, glow: 1.2 }, color: RED, jawSmile: -0.2, jawOpen: 0.02 }),
  peaceful: face({ eyes: { lidTop: 0.5, lidBottom: 0.12, lidCurve: 0.8, glow: 0.85, gazeY: -0.2 }, jawSmile: 0.6, jawOpen: 0.05, pitch: 0.1 }),
  asleep: face({ eyes: { lidTop: 0.56, lidBottom: 0.46, glow: 0.2 }, jawSmile: 0, jawOpen: 0, pitch: -0.22 }),
};

export const EXPRESSION_NAMES = Object.keys(EXPRESSIONS) as RobotExpression[];

export const cloneFace = (f: FaceRig): FaceRig => ({ ...f, left: { ...f.left }, right: { ...f.right }, color: [...f.color] as RGB });

/* ── springs ─────────────────────────────────────────────────────────── */

const EYE_KEYS = ['lidTop', 'lidBottom', 'lidAngle', 'lidCurve', 'glow', 'size', 'shape', 'pupil', 'gazeX', 'gazeY'] as const;
const FACE_KEYS = ['jawOpen', 'jawSmile', 'yaw', 'pitch', 'roll'] as const;
/* every number in the rig, in a fixed order */
const SLOTS = EYE_KEYS.length * 2 + FACE_KEYS.length + 3;

function write(f: FaceRig, out: Float32Array) {
  let i = 0;
  for (const k of EYE_KEYS) out[i++] = f.left[k];
  for (const k of EYE_KEYS) out[i++] = f.right[k];
  for (const k of FACE_KEYS) out[i++] = f[k];
  /* colour blends in linear light, so red to white does not pass through mud */
  for (let c = 0; c < 3; c++) out[i++] = Math.pow(f.color[c] / 255, 2.2);
}

function read(v: Float32Array, f: FaceRig) {
  let i = 0;
  for (const k of EYE_KEYS) f.left[k] = v[i++];
  for (const k of EYE_KEYS) f.right[k] = v[i++];
  for (const k of FACE_KEYS) f[k] = v[i++];
  for (let c = 0; c < 3; c++) f.color[c] = 255 * Math.pow(Math.max(0, v[i++]), 1 / 2.2);
}

/* the lids move fastest, the head offsets slowest: a heavy robot with quick eyes */
const FREQ = new Float32Array(SLOTS);
{
  let i = 0;
  for (let s = 0; s < 2; s++) for (const k of EYE_KEYS) FREQ[i++] = k.startsWith('lid') ? 4.2 : k.startsWith('gaze') ? 5 : 3;
  for (const k of FACE_KEYS) FREQ[i++] = k === 'yaw' || k === 'pitch' || k === 'roll' ? 1.1 : 3.2;
  for (let c = 0; c < 3; c++) FREQ[i++] = 2.6;
}

/**
 * Springs on every number of the face, chasing a target face. Critically
 * damped but for the head offsets, which overshoot a little and settle.
 */
export class FaceSprings {
  readonly face: FaceRig;
  private x = new Float32Array(SLOTS);
  private v = new Float32Array(SLOTS);
  private t = new Float32Array(SLOTS);

  constructor(start: FaceRig) {
    this.face = cloneFace(start);
    write(start, this.x);
  }

  /** Jump straight to a face, with no easing (a first frame, a still head). */
  snap(f: FaceRig) {
    write(f, this.x);
    this.v.fill(0);
    read(this.x, this.face);
  }

  step(target: FaceRig, dt: number, speed = 1) {
    write(target, this.t);
    const x = this.x, v = this.v, t = this.t;
    const head = EYE_KEYS.length * 2 + 3;
    for (let i = 0; i < SLOTS; i++) {
      const w = FREQ[i] * speed * Math.PI * 2;
      const zeta = i >= head && i < head + 3 ? 0.62 : 1;
      v[i] += (w * w * (t[i] - x[i]) - 2 * zeta * w * v[i]) * dt;
      x[i] += v[i] * dt;
    }
    read(x, this.face);
  }
}

/** A face blended a share `k` of the way from `a` to `b`, into `out`. */
export function mixFace(a: FaceRig, b: FaceRig, k: number, out: FaceRig): FaceRig {
  const l = (p: number, q: number) => p + (q - p) * k;
  for (const k2 of EYE_KEYS) {
    out.left[k2] = l(a.left[k2], b.left[k2]);
    out.right[k2] = l(a.right[k2], b.right[k2]);
  }
  for (const k2 of FACE_KEYS) out[k2] = l(a[k2], b[k2]);
  for (let c = 0; c < 3; c++) out.color[c] = 255 * Math.pow(l(Math.pow(a.color[c] / 255, 2.2), Math.pow(b.color[c] / 255, 2.2)), 1 / 2.2);
  return out;
}

/* ── sequences ───────────────────────────────────────────────────────── */

/*
 * Scripted changes of face, keyed from the film frame by frame (at 24 fps
 * a frame is about 0.04 s). Each key sets some of the eyes' numbers and
 * perhaps the colour; `null` stands for the face the robot is aiming for,
 * so a sequence ending on `null` hands over to it without a jump. A field
 * a key leaves out takes the target's value at that key.
 */
type EyePatch = Partial<Pick<EyeRig, 'lidTop' | 'lidBottom' | 'glow' | 'shape' | 'pupil' | 'size'>>;
interface Patch {
  eyes?: EyePatch;
  color?: RGB;
}
export type Sequence = Array<[number, Patch | null]>;

const SHUT: EyePatch = { lidTop: 0.56, lidBottom: 0.46 };
const PINKISH: RGB = [255, 160, 150];

export const SEQUENCES = {
  /* 9920–9929: the lids meet and part again, quick */
  blink: [[0, null], [0.07, { eyes: SHUT }], [0.11, { eyes: SHUT }], [0.24, null]],
  /* 6825–6834: the white eye flushes pink, turns to a red pentagon, then the iris closes in */
  defenseOn: [
    [0, null],
    [0.08, { eyes: { shape: 0.6, pupil: 0, glow: 1.15 }, color: PINKISH }],
    [0.16, { eyes: { shape: 1, pupil: 0, glow: 1.25 }, color: RED }],
    [0.3, { eyes: { shape: 1, pupil: 0.35, glow: 1.2 }, color: RED }],
    [0.6, null],
  ],
  /* 8309–8312: the iris opens on a red pentagon that pales through pink back to white */
  defenseOff: [
    [0, null],
    [0.16, { eyes: { shape: 1, pupil: 0.25 }, color: RED }],
    [0.26, { eyes: { shape: 1, pupil: 0 }, color: PINKISH }],
    [0.4, { eyes: { shape: 0.4, pupil: 0 } }],
    [0.55, null],
  ],
  /* 10550–10562: the seam between the shut lids opens to slits, the glow comes up, the eyes open */
  wake: [
    [0, { eyes: { ...SHUT, glow: 0.15 } }],
    [0.35, { eyes: { lidTop: 0.42, lidBottom: 0.32, glow: 0.45 } }],
    [0.6, { eyes: { lidTop: 0.3, lidBottom: 0.18, glow: 0.8 } }],
    [1, null],
  ],
} satisfies Record<string, Sequence>;

export type SequenceName = keyof typeof SEQUENCES;

export const sequenceLength = (seq: Sequence) => seq[seq.length - 1][0];

const EYE_PATCH_KEYS = ['lidTop', 'lidBottom', 'glow', 'shape', 'pupil', 'size'] as const;

/** Lay a sequence, `t` seconds in, over `face` (which holds the target face), in place. */
export function applySequence(seq: Sequence, t: number, face: FaceRig) {
  let i = 0;
  while (i < seq.length - 2 && seq[i + 1][0] <= t) i++;
  const [t0, a] = seq[i], [t1, b] = seq[i + 1];
  const k = Math.min(1, Math.max(0, (t - t0) / Math.max(1e-6, t1 - t0)));
  /* ease each segment in and out */
  const e = k * k * (3 - 2 * k);
  for (const eye of [face.left, face.right]) {
    for (const key of EYE_PATCH_KEYS) {
      const va = a?.eyes?.[key] ?? eye[key];
      const vb = b?.eyes?.[key] ?? eye[key];
      eye[key] = va + (vb - va) * e;
    }
  }
  const ca = a?.color ?? face.color, cb = b?.color ?? face.color;
  for (let c = 0; c < 3; c++) {
    const la = Math.pow(ca[c] / 255, 2.2), lb = Math.pow(cb[c] / 255, 2.2);
    face.color[c] = 255 * Math.pow(la + (lb - la) * e, 1 / 2.2);
  }
}

/** Whether a face is one of the red ones, which the eyes turn to and from by a sequence. */
export const isRed = (name: RobotExpression | undefined) => name === 'angry' || name === 'attack' || name === 'defense';
