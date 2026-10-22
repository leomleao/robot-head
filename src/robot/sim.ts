/* The robot's life between frames: the head's pose chases targets on
   heavy springs, the face eases toward the expression it should wear, and
   blinks and glances come and go on their own. */

import type { RobotExpression, RobotHeadState } from '../types';
import { EXPRESSIONS, FaceSprings, SEQUENCES, applySequence, cloneFace, isRed, sequenceLength, type FaceRig, type RGB, type SequenceName } from './rig';
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

/** Things the robot can be asked to do once, over whatever it is doing. */
export type RobotAction = 'blink' | 'nod' | 'shake' | 'hmm' | 'laugh' | 'surprise' | 'wake' | 'defense';

export const ROBOT_ACTIONS: RobotAction[] = ['blink', 'nod', 'shake', 'hmm', 'laugh', 'surprise', 'wake', 'defense'];

export interface ActionOptions {
  /** For `defense`: how long the eyes stay red, in seconds. Default 1.6. */
  hold?: number;
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
  if (!isRed(name)) {
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
  /* something to look at instead, in the same terms, or null */
  lookAt: { x: number; y: number } | null = null;
  /* a level from outside (the `mouth` prop, or audio) that drives the jaw, 0–1, or null */
  mouth: number | null = null;
  readonly springs: FaceSprings;
  /* the face drawn this frame: the springs' face with any scripted change laid over it */
  readonly face: FaceRig;

  private target: FaceRig;
  private yaw = new Spring();
  private pitch = new Spring();
  private roll = new Spring();
  /* a bounce: a hop of the head that rings down */
  private bounce = new Spring();
  private random: () => number;
  private glance = { yaw: 0, pitch: 0, gx: 0, gy: 0 };
  private nextGlance = 0.8;
  private nextBlink = 2;
  /* the scripted change of face playing now, and how far into it */
  private seq: { name: SequenceName; t: number } | null = null;
  private surprise = -1;
  private jaw = new Jaw();
  private nextMumble = 6;
  private mouthLevel = new Spring();
  /* seconds in the current state */
  private since = 0;
  /* which way the head leans while thinking, and when it next changes its mind */
  private side = 1;
  private nextSide = 4;
  /* now and then, idle, the head cocks to one side for a moment: "Hmm?" */
  private nextTilt = 9;
  private tiltUntil = -1;
  /* the action playing now */
  private action: { name: RobotAction; t: number; length: number; hold: number; done: () => void } | null = null;
  /* a face an action wears for a while, over the expression */
  private override: RobotExpression | null = null;
  /* the face worn on the last step, to notice changes */
  private wearing: RobotExpression;

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
    this.side = this.random() < 0.5 ? 1 : -1;
    this.nextTilt = 6 + this.random() * 8;
    this.wearing = expression ?? STATE_FACE[state];
    const rest = REST[state];
    this.yaw.x = rest.yaw; this.pitch.x = rest.pitch; this.roll.x = rest.roll;
  }

  set(state: RobotHeadState, expression: RobotExpression | undefined, eye: RGB) {
    if (state !== this.state) {
      this.jaw.clear();
      this.since = 0;
      this.nextMumble = this.time + (state === 'speaking' ? 0.15 : 2 + this.random() * 4);
      /* happy arrives with a hop */
      if (state === 'happy') this.bounce.v += 0.9;
    }
    this.state = state;
    this.expression = expression;
    this.eye = eye;
  }

  /** Play a scripted change of face over whatever the face is doing. */
  play(name: SequenceName) {
    this.seq = { name, t: 0 };
  }

  /* the face to wear now: an action's, the expression, or the state's */
  private current(): RobotExpression {
    return this.override ?? this.expression ?? STATE_FACE[this.state];
  }

  /* when the face changes: the eyes turn red and back by the film's steps, and wake from a seam */
  private changed(was: RobotExpression, now: RobotExpression) {
    /* the iris faces (angry, defense) come and go by the film's steps; attack's pink just eases in */
    const iris = (n: RobotExpression) => n === 'angry' || n === 'defense';
    if (iris(now) && !isRed(was)) this.play('defenseOn');
    else if (iris(was) && !isRed(now)) this.play('defenseOff');
    else if (was === 'asleep' && now !== 'asleep') this.play('wake');
  }

  /**
   * Do something once, over whatever the robot is doing. A new action
   * cuts the one playing short; the promise resolves when the action ends,
   * either way.
   */
  act(name: RobotAction, opts: ActionOptions = {}): Promise<void> {
    this.finish();
    const hold = Math.max(0, opts.hold ?? 1.6);
    let length = 1;
    switch (name) {
      case 'blink':
        this.play('blink');
        length = sequenceLength(SEQUENCES.blink);
        break;
      case 'nod':
        length = 1;
        break;
      case 'shake':
        length = 1.2;
        break;
      case 'hmm':
        this.jaw.clear();
        this.jaw.hum(this.random);
        length = 1.6;
        break;
      case 'laugh':
        this.jaw.clear();
        this.jaw.laugh(this.random);
        this.bounce.v += 0.5;
        length = 1;
        break;
      case 'surprise':
        this.surprise = 0;
        if (!this.seq) this.play('blink');
        length = 0.9;
        break;
      case 'wake':
        this.play('wake');
        length = sequenceLength(SEQUENCES.wake);
        break;
      case 'defense':
        this.override = 'defense';
        length = hold + sequenceLength(SEQUENCES.defenseOff);
        break;
    }
    return new Promise((done) => {
      this.action = { name, t: 0, length, hold, done };
    });
  }

  /* end the action playing, if any */
  private finish() {
    const a = this.action;
    if (!a) return;
    this.action = null;
    if (a.name === 'defense') this.override = null;
    a.done();
  }

  /** A click: a blink, a flash of surprise, a small hop and a settling nod. */
  poke() {
    if (!this.seq) this.play('blink');
    this.surprise = 0;
    this.bounce.v += 0.5;
    this.pitch.v -= 0.6;
  }

  update(dt: number) {
    if (!(dt > 0)) return;
    const steps = Math.max(1, Math.ceil(dt / (1 / 120)));
    for (let i = 0; i < steps; i++) this.step(dt / steps);
  }

  private step(dt: number) {
    this.time += dt;
    this.since += dt;
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

    /* what this state does with the head, and with the eyes inside it; heavy throughout */
    let yaw = 0, pitch = 0, roll = 0, gx = 0, gy = 0, lift = 0;
    let freq = 0.9, damping = 0.75;
    /* whether the head turns to the pointer in this state */
    let follows = true;
    switch (this.state) {
      case 'idle':
        yaw = this.glance.yaw;
        pitch = this.glance.pitch;
        roll = -this.glance.yaw * 0.12;
        gx = this.glance.gx;
        gy = this.glance.gy;
        if (t > this.nextTilt) {
          this.tiltUntil = t + 1.4 + rand();
          this.nextTilt = t + 8 + rand() * 9;
        }
        if (t < this.tiltUntil) roll += 0.16 * this.side;
        break;
      case 'thinking':
        /* looking up and to one side, then the other, "Souls don't die" */
        if (t > this.nextSide) {
          this.side = -this.side;
          this.nextSide = t + 3.5 + rand() * 2.5;
        }
        yaw = 0.22 * this.side + Math.sin(t * 0.7) * 0.03;
        pitch = 0.16 + Math.sin(t * 0.9) * 0.02;
        roll = -0.1 * this.side;
        gx = 0.4 * this.side;
        gy = -0.6;
        freq = 0.7;
        follows = false;
        break;
      case 'searching': {
        /* a slow sweep, the eyes leading the head */
        const ph = t * 0.85;
        yaw = Math.sin(ph) * 0.5;
        pitch = 0.03 + Math.sin(ph * 2) * 0.03;
        roll = Math.sin(ph) * -0.05;
        gx = clamp(Math.sin(ph + 0.7) * 1.1, -1, 1);
        freq = 1.1;
        follows = false;
        break;
      }
      case 'listening':
        /* head cocked toward whoever is talking; the nods come with the mm-hmms */
        yaw = -0.12;
        pitch = 0.03;
        roll = 0.15;
        gx = -0.3;
        break;
      case 'speaking':
        yaw = Math.sin(t * 0.6) * 0.08;
        roll = Math.sin(t * 0.45) * 0.04;
        pitch = 0.02;
        break;
      case 'working':
        /* eyes down on the work, careful, a steady little bob */
        yaw = Math.sin(t * 0.5) * 0.06;
        pitch = -0.18;
        roll = Math.sin(t * 0.35) * 0.03;
        gy = 0.5;
        lift = Math.abs(Math.sin(t * 3.1)) * 0.008;
        follows = false;
        break;
      case 'happy':
        yaw = this.glance.yaw * 0.6;
        roll = Math.sin(t * 1.6) * 0.07;
        pitch = 0.04;
        /* now and then another little hop */
        if (this.since > 1.2 && rand() < dt * 0.25) this.bounce.v += 0.45;
        break;
      case 'error': {
        /* a slow shake of the head every few seconds, and a droop between */
        const c = ((this.since + 0.6) % 3.4) / 1.2;
        yaw = c < 1 ? Math.sin(c * Math.PI * 3) * 0.16 * (1 - c) : 0;
        pitch = -0.12;
        roll = -0.05;
        gy = 0.4;
        freq = 1.2;
        follows = false;
        break;
      }
      case 'sleeping':
        /* drooped, breathing slowly */
        pitch = -0.3;
        roll = 0.1;
        yaw = 0.05;
        lift = Math.sin(t * 0.9) * 0.012;
        freq = 0.4;
        damping = 0.9;
        follows = false;
        break;
    }

    /* the action playing: its own motion on top of the state's */
    let ay = 0, ap = 0, ar = 0, agy = 0;
    const a = this.action;
    if (a) {
      a.t += dt;
      const k = a.t / a.length;
      switch (a.name) {
        case 'nod':
          /* two slow dips */
          ap = -Math.max(0, Math.sin(k * Math.PI * 2)) * 0.18;
          break;
        case 'shake':
          ay = Math.sin(k * Math.PI * 3) * 0.18 * (1 - k);
          break;
        case 'hmm':
          ar = 0.18 * this.side * Math.sin(Math.min(1, k * 1.4) * Math.PI);
          agy = -0.4;
          break;
      }
      if (a.name === 'defense' && a.t >= a.hold) this.override = null;
      if (a.t >= a.length) this.finish();
    }
    const wearing = this.current();
    if (wearing !== this.wearing) {
      this.changed(this.wearing, wearing);
      this.wearing = wearing;
    }

    /* something to look at overrides the state's glances, the pointer only where the state allows */
    const look = this.state === 'sleeping' ? null : this.lookAt ?? (follows ? this.pointer : null);
    if (look) {
      /* the eyes lead, the head follows: heavy */
      gx = clamp(look.x / 160, -1, 1);
      gy = clamp(look.y / 200, -1, 1);
      yaw = clamp(look.x / 320, -1, 1) * 0.5;
      pitch = -clamp(look.y / 320, -1, 1) * 0.26;
      roll = -yaw * 0.1 + (this.state === 'listening' ? 0.12 : 0);
    }
    this.yaw.step(yaw + ay, dt, freq, damping);
    this.pitch.step(pitch + ap, dt, freq, damping);
    this.roll.step(roll + ar, dt, freq * 0.9, damping);
    gy += agy;
    this.bounce.step(0, dt, 1.7, 0.32);

    /* the face */
    targetFace(this.state, this.current(), this.eye, this.target);
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
    if (this.mouth !== null) this.jaw.clear();
    this.jaw.step(dt);
    /* a level from outside, eased so it never chatters: quick to open, slower to close */
    const outside = this.mouth === null ? 0 : clamp(this.mouth, 0, 1);
    const m = this.mouthLevel;
    m.step(outside, dt, outside > m.x ? 11 : 6, 0.85);

    /* blinks now and then, a double one sometimes */
    if (t > this.nextBlink && this.state !== 'sleeping') {
      if (!this.seq) this.play('blink');
      this.nextBlink = t + 2.5 + rand() * 4;
      if (rand() < 0.15) this.nextBlink = t + 0.4;
    }
    const S = this.springs.face, F = this.face;
    Object.assign(F.left, S.left);
    Object.assign(F.right, S.right);
    const talk = Math.max(0, this.jaw.spring.x) * 0.85 + Math.max(0, m.x) * 0.9;
    F.jawOpen = S.jawOpen + talk;
    F.jawSmile = S.jawSmile;
    F.yaw = S.yaw; F.pitch = S.pitch; F.roll = S.roll;
    F.color[0] = S.color[0]; F.color[1] = S.color[1]; F.color[2] = S.color[2];
    /* a scripted change, laid over the springs so it keeps its own timing */
    if (this.seq) {
      const seq = SEQUENCES[this.seq.name];
      applySequence(seq, this.seq.t, F);
      this.seq.t += dt;
      if (this.seq.t > sequenceLength(seq)) this.seq = null;
    }

    this.pose.yaw = this.yaw.x;
    /* talking nods the head a touch with each syllable */
    this.pose.pitch = this.pitch.x - talk * 0.04;
    this.pose.roll = this.roll.x;
    /* a slow float, the state's own bob, and any hop */
    this.pose.lift = Math.sin(t * 1.1) * 0.012 + lift + Math.max(0, this.bounce.x) * 0.25;
  }
}

/** Each state's pose at rest, for a first frame and for still or reduced-motion heads. */
export const REST: Record<RobotHeadState, RobotPose> = {
  idle: { yaw: -0.1, pitch: 0.02, roll: 0.02, x: 0, lift: 0 },
  thinking: { yaw: 0.22, pitch: 0.16, roll: -0.1, x: 0, lift: 0 },
  searching: { yaw: 0.3, pitch: 0.03, roll: -0.03, x: 0, lift: 0 },
  listening: { yaw: -0.12, pitch: 0.03, roll: 0.15, x: 0, lift: 0 },
  speaking: { yaw: 0.04, pitch: 0.02, roll: 0, x: 0, lift: 0 },
  working: { yaw: 0, pitch: -0.18, roll: 0, x: 0, lift: 0 },
  happy: { yaw: 0, pitch: 0.04, roll: 0.05, x: 0, lift: 0 },
  error: { yaw: 0, pitch: -0.12, roll: -0.05, x: 0, lift: 0 },
  sleeping: { yaw: 0.05, pitch: -0.3, roll: 0.1, x: 0, lift: 0 },
};
