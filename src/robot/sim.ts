/* The robot's life between frames: the head's pose chases targets on
   heavy springs, the face eases toward the expression it should wear, and
   blinks and glances come and go on their own. */

import type { RobotExpression, RobotHeadState } from '../types';
import { EXPRESSIONS, FaceSprings, cloneFace, type FaceRig, type RGB } from './rig';
import type { RobotPose } from './render';

class Spring {
  x = 0;
  v = 0;
  step(target: number, dt: number, freq: number, damping: number) {
    const w = freq * Math.PI * 2;
    this.v += (w * w * (target - this.x) - 2 * damping * w * this.v) * dt;
    this.x += this.v * dt;
  }
}

function rng(seed: number) {
  let a = Math.floor(seed * 4294967295) >>> 0 || 1;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/*
 * The jaw's own life: a queue of moves, each a target opening held for a
 * while, chased by a quick spring so the jaw snaps like a hinge rather
 * than floating. Speech is short phrases of one- and two-syllable words
 * with pauses between ("I fix." "You stay. I go."); a hum is a small drop
 * and close; a laugh is a quick run of wide opens.
 */
class Jaw {
  private queue: Array<[number, number]> = [];
  private hold = 0;
  private target = 0;
  readonly spring = new Spring();

  get busy() {
    return this.queue.length > 0 || this.hold > 0;
  }

  clear() {
    this.queue.length = 0;
    this.hold = 0;
    this.target = 0;
  }

  push(open: number, seconds: number) {
    this.queue.push([open, seconds]);
  }

  phrase(rand: () => number) {
    const words = 1 + Math.floor(rand() * 3);
    for (let w = 0; w < words; w++) {
      const syllables = rand() < 0.65 ? 1 : 2;
      for (let k = 0; k < syllables; k++) {
        this.push(0.45 + rand() * 0.45, 0.1 + rand() * 0.1);
        this.push(0.05 + rand() * 0.08, 0.05 + rand() * 0.05);
      }
      this.push(0, 0.16 + rand() * 0.22);
    }
    this.push(0, 0.6 + rand() * 0.9);
  }

  hum(rand: () => number) {
    this.push(0.16 + rand() * 0.08, 0.22);
    this.push(0, 0.4);
  }

  laugh(rand: () => number) {
    const n = 3 + Math.floor(rand() * 2);
    for (let i = 0; i < n; i++) {
      this.push(0.55 + rand() * 0.25, 0.09);
      this.push(0.15, 0.07);
    }
    this.push(0, 0.3);
  }

  step(dt: number) {
    this.hold -= dt;
    while (this.hold <= 0 && this.queue.length) {
      const [open, secs] = this.queue.shift()!;
      this.target = open;
      this.hold += secs;
    }
    if (this.hold <= 0 && !this.queue.length) {
      this.hold = 0;
      this.target = 0;
    }
    this.spring.step(this.target, dt, 7, 0.75);
  }
}

/** The face each state wears when no expression is given. */
export const STATE_FACE: Record<RobotHeadState, RobotExpression> = {
  idle: 'neutral',
  thinking: 'curious',
  searching: 'suspicious',
  listening: 'neutral',
  speaking: 'neutral',
  working: 'content',
  happy: 'happy',
  error: 'sheepish',
  sleeping: 'asleep',
};

/** The face to aim for: the expression, in the eye colour unless the colour is the point. */
export function targetFace(state: RobotHeadState, expression: RobotExpression | undefined, eye: RGB, out?: FaceRig): FaceRig {
  const name = expression ?? STATE_FACE[state];
  const f = out ?? cloneFace(EXPRESSIONS[name]);
  if (out) {
    const src = EXPRESSIONS[name];
    Object.assign(f.left, src.left);
    Object.assign(f.right, src.right);
    f.jawOpen = src.jawOpen; f.jawSmile = src.jawSmile;
    f.yaw = src.yaw; f.pitch = src.pitch; f.roll = src.roll;
    f.color[0] = src.color[0]; f.color[1] = src.color[1]; f.color[2] = src.color[2];
  }
  if (name !== 'defense' && name !== 'attack' && name !== 'angry') {
    f.color[0] = eye[0]; f.color[1] = eye[1]; f.color[2] = eye[2];
  }
  return f;
}

export class RobotSim {
  state: RobotHeadState;
  expression: RobotExpression | undefined;
  eye: RGB;
  time = 0;
  pose: RobotPose = { yaw: 0, pitch: 0, roll: 0, x: 0, lift: 0 };
  /* the pointer, relative to the head's centre in CSS px, or null */
  pointer: { x: number; y: number } | null = null;
  /* a level from outside (the `mouth` prop, or audio) that drives the jaw, 0–1, or null */
  mouth: number | null = null;
  readonly springs: FaceSprings;
  /* the face drawn this frame: the springs' face with blinks laid over it */
  readonly face: FaceRig;

  private target: FaceRig;
  private yaw = new Spring();
  private pitch = new Spring();
  private roll = new Spring();
  private random: () => number;
  private glance = { yaw: 0, pitch: 0, gx: 0, gy: 0 };
  private nextGlance = 0.8;
  private nextBlink = 2;
  private blinkAge = -1;
  private surprise = -1;
  private jaw = new Jaw();
  private nextMumble = 6;
  private mouthLevel = new Spring();

  constructor(seed: number, state: RobotHeadState, expression: RobotExpression | undefined, eye: RGB) {
    this.random = rng(seed);
    this.state = state;
    this.expression = expression;
    this.eye = eye;
    this.target = targetFace(state, expression, eye);
    this.springs = new FaceSprings(this.target);
    this.face = cloneFace(this.target);
    this.nextBlink = 1 + this.random() * 3;
    this.nextMumble = state === 'speaking' ? 0.3 : 3 + this.random() * 4;
  }

  set(state: RobotHeadState, expression: RobotExpression | undefined, eye: RGB) {
    if (state !== this.state) {
      this.jaw.clear();
      this.nextMumble = this.time + (state === 'speaking' ? 0.15 : 2 + this.random() * 4);
    }
    this.state = state;
    this.expression = expression;
    this.eye = eye;
  }

  /** A click: a blink, a flash of surprise, a settling nod. */
  poke() {
    this.blinkAge = 0;
    this.surprise = 0;
    this.pitch.v -= 0.6;
  }

  update(dt: number) {
    if (!(dt > 0)) return;
    const steps = Math.max(1, Math.ceil(dt / (1 / 120)));
    for (let i = 0; i < steps; i++) this.step(dt / steps);
  }

  private step(dt: number) {
    this.time += dt;
    const t = this.time;
    const rand = this.random;

    if (t > this.nextGlance) {
      this.glance = {
        yaw: (rand() - 0.5) * 0.5,
        pitch: (rand() - 0.5) * 0.16,
        gx: (rand() - 0.5) * 1.2,
        gy: (rand() - 0.5) * 0.5,
      };
      this.nextGlance = t + 2 + rand() * 3.5;
    }

    let yaw = 0, pitch = 0, roll = 0, gx = 0, gy = 0;
    if (this.state !== 'sleeping') {
      yaw = this.glance.yaw;
      pitch = this.glance.pitch;
      roll = -this.glance.yaw * 0.12;
      gx = this.glance.gx;
      gy = this.glance.gy;
    }
    const p = this.pointer;
    if (p && this.state !== 'sleeping') {
      /* the eyes lead, the head follows: heavy */
      gx = clamp(p.x / 160, -1, 1);
      gy = clamp(p.y / 200, -1, 1);
      yaw = clamp(p.x / 320, -1, 1) * 0.5;
      pitch = -clamp(p.y / 320, -1, 1) * 0.26;
      roll = -yaw * 0.1;
    }
    this.yaw.step(yaw, dt, 0.9, 0.75);
    this.pitch.step(pitch, dt, 0.9, 0.75);
    this.roll.step(roll, dt, 0.8, 0.8);

    /* the face */
    targetFace(this.state, this.expression, this.eye, this.target);
    const T = this.target;
    T.left.gazeX += gx; T.right.gazeX += gx;
    T.left.gazeY += gy; T.right.gazeY += gy;
    if (this.surprise >= 0) {
      this.surprise += dt;
      const k = Math.sin(clamp(this.surprise / 0.9, 0, 1) * Math.PI);
      for (const e of [T.left, T.right]) {
        e.size += 0.12 * k;
        e.glow += 0.2 * k;
        e.lidTop *= 1 - k;
      }
      T.jawOpen += 0.3 * k;
      if (this.surprise > 0.9) this.surprise = -1;
    }
    this.springs.step(T, dt);

    /* the jaw: talk while speaking, a hum or an mm-hmm now and then, a laugh when happy */
    if (this.mouth === null && t > this.nextMumble && !this.jaw.busy) {
      switch (this.state) {
        case 'speaking':
          this.jaw.phrase(rand);
          this.nextMumble = t;
          break;
        case 'happy':
          this.jaw.laugh(rand);
          this.nextMumble = t + 2.5 + rand() * 3;
          break;
        case 'listening':
          this.jaw.hum(rand);
          this.pitch.v -= 0.5;
          this.nextMumble = t + 3 + rand() * 3;
          break;
        case 'idle':
        case 'thinking':
          this.jaw.hum(rand);
          this.nextMumble = t + 6 + rand() * 8;
          break;
        default:
          this.nextMumble = t + 4;
      }
    }
    this.jaw.step(dt);
    /* a level from outside, eased a little so it never chatters */
    const outside = this.mouth;
    this.mouthLevel.step(outside === null ? 0 : Math.min(1, Math.max(0, outside)), dt, 9, 0.9);

    /* blinks, laid over the springs so they stay quick */
    if (t > this.nextBlink && this.state !== 'sleeping') {
      this.blinkAge = 0;
      this.nextBlink = t + 2.5 + rand() * 4;
      if (rand() < 0.15) this.nextBlink = t + 0.4;
    }
    let blink = 0;
    if (this.blinkAge >= 0) {
      this.blinkAge += dt;
      blink = Math.sin(clamp(this.blinkAge / 0.22, 0, 1) * Math.PI);
      if (this.blinkAge > 0.22) this.blinkAge = -1;
    }
    const S = this.springs.face, F = this.face;
    Object.assign(F.left, S.left);
    Object.assign(F.right, S.right);
    F.jawOpen = S.jawOpen + Math.max(0, this.jaw.spring.x) * 0.85 + Math.max(0, this.mouthLevel.x) * 0.9;
    F.jawSmile = S.jawSmile;
    F.yaw = S.yaw; F.pitch = S.pitch; F.roll = S.roll;
    F.color[0] = S.color[0]; F.color[1] = S.color[1]; F.color[2] = S.color[2];
    if (blink > 0) {
      for (const e of [F.left, F.right]) {
        e.lidTop += (0.62 - e.lidTop) * blink;
        e.lidBottom += (0.42 - e.lidBottom) * blink;
      }
    }

    this.pose.yaw = this.yaw.x;
    this.pose.pitch = this.pitch.x;
    this.pose.roll = this.roll.x;
    /* a slow float */
    this.pose.lift = Math.sin(t * 1.1) * 0.012;
  }
}
