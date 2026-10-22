/* The robot as quad meshes in head units: x right, y down, z toward the
   viewer, the origin at the middle of the mouth line (the cranium's lower
   edge). Every frame the head's meshes are turned about the neck and
   projected orthographically; the shoulders never turn, so they are drawn
   once per size and reused.

   The head, its jaw and the crest come from a sculpt (see model.ts),
   decimated to a few thousand triangles: a domed cranium round in section
   with a slot over the top for the crest, and a jaw like a bucket hanging
   from two arms pinned at the back of the head, so opening it swings the
   chin down and back. Triangles are stored as quads repeating their last
   vertex. The neck, collar and shoulders are built here. */

import { MODEL, MODEL_EYES, MODEL_HINGE, MODEL_Q } from './model';

export type V3 = [number, number, number];

/* the head's measurements in head units */
export const HEAD = {
  /* the cranium's radius below the dome */
  r: 0.299,
  /* the eyes: centres, the socket's radius, the glow's share of it */
  eyeX: MODEL_EYES[1][0],
  eyeY: MODEL_EYES[1][1],
  eyeZ: MODEL_EYES[1][2],
  socket: MODEL_EYES[1][3],
  glow: 0.6,
  /* the jaw's hinge pins */
  hingeY: MODEL_HINGE[0],
  hingeZ: MODEL_HINGE[1],
  /* where the head turns: inside the jaw, at the top of the neck */
  pivot: 0.2,
} as const;

/* the top of the crest, for framing */
export const HEAD_TOP = -0.545;

export interface Mesh {
  /* x, y, z per vertex */
  pos: Float32Array;
  /* four vertex indices per quad (a triangle repeats its last vertex) */
  quads: Uint16Array;
  /* outward x, y, z per quad */
  normals: Float32Array;
  /* each quad's height in the model, for the grime toward the bottom */
  ys: Float32Array;
  /* a material slot per quad */
  mats: Uint8Array;
}

export const MAT = { shell: 0, dark: 1, inside: 2 } as const;

/** v' = Roll · Yaw · Pitch · v, row-major. */
export function rotation(yaw: number, pitch: number, roll: number, out: number[] = new Array(9)): number[] {
  const cy = Math.cos(yaw), sy = Math.sin(yaw);
  const cp = Math.cos(pitch), sp = Math.sin(pitch);
  const cr = Math.cos(roll), sr = Math.sin(roll);
  const a0 = cy, a1 = sy * sp, a2 = sy * cp, a3 = 0, a4 = cp, a5 = -sp, a6 = -sy, a7 = cy * sp, a8 = cy * cp;
  out[0] = cr * a0 - sr * a3; out[1] = cr * a1 - sr * a4; out[2] = cr * a2 - sr * a5;
  out[3] = sr * a0 + cr * a3; out[4] = sr * a1 + cr * a4; out[5] = sr * a2 + cr * a5;
  out[6] = a6; out[7] = a7; out[8] = a8;
  return out;
}

const norm = (x: number, y: number, z: number): V3 => {
  const l = Math.hypot(x, y, z) || 1;
  return [x / l, y / l, z / l];
};

const TAU = Math.PI * 2;

/* ── building ────────────────────────────────────────────────────────── */

class Builder {
  pos: number[] = [];
  quads: number[] = [];
  mats: number[] = [];
  vertex(x: number, y: number, z: number): number {
    this.pos.push(x, y, z);
    return this.pos.length / 3 - 1;
  }
  quad(a: number, b: number, c: number, d: number, mat: number = MAT.shell) {
    this.quads.push(a, b, c, d);
    this.mats.push(mat);
  }
  /** Normals from each quad's diagonals, turned to face away from `inside(centroid)`. */
  finish(inside: (x: number, y: number, z: number) => V3): Mesh {
    const P = this.pos, Q = this.quads;
    const nq = Q.length / 4;
    const normals = new Float32Array(nq * 3);
    const ys = new Float32Array(nq);
    for (let q = 0; q < nq; q++) {
      const i0 = Q[q * 4] * 3, i1 = Q[q * 4 + 1] * 3, i2 = Q[q * 4 + 2] * 3, i3 = Q[q * 4 + 3] * 3;
      const d1x = P[i2] - P[i0], d1y = P[i2 + 1] - P[i0 + 1], d1z = P[i2 + 2] - P[i0 + 2];
      const d2x = P[i3] - P[i1], d2y = P[i3 + 1] - P[i1 + 1], d2z = P[i3 + 2] - P[i1 + 2];
      let [nx, ny, nz] = norm(d1y * d2z - d1z * d2y, d1z * d2x - d1x * d2z, d1x * d2y - d1y * d2x);
      const cx = (P[i0] + P[i1] + P[i2] + P[i3]) / 4;
      const cy = (P[i0 + 1] + P[i1 + 1] + P[i2 + 1] + P[i3 + 1]) / 4;
      const cz = (P[i0 + 2] + P[i1 + 2] + P[i2 + 2] + P[i3 + 2]) / 4;
      const o = inside(cx, cy, cz);
      if (nx * (cx - o[0]) + ny * (cy - o[1]) + nz * (cz - o[2]) < 0) {
        nx = -nx; ny = -ny; nz = -nz;
      }
      normals[q * 3] = nx; normals[q * 3 + 1] = ny; normals[q * 3 + 2] = nz;
      ys[q] = cy;
    }
    return { pos: new Float32Array(P), quads: new Uint16Array(Q), normals, ys, mats: new Uint8Array(this.mats) };
  }
}

/** A solid of revolution about a vertical axis: `profile` is [radius, y] from top to bottom. */
function lathe(b: Builder, profile: Array<[number, number]>, segments: number, cx = 0, cz = 0, mat: number = MAT.shell) {
  const base = b.pos.length / 3;
  for (const [r, y] of profile) {
    for (let j = 0; j < segments; j++) {
      const a = (j / segments) * TAU;
      b.vertex(cx + Math.cos(a) * r, y, cz + Math.sin(a) * r);
    }
  }
  for (let k = 0; k < profile.length - 1; k++) {
    for (let j = 0; j < segments; j++) {
      const j2 = (j + 1) % segments;
      b.quad(base + k * segments + j, base + k * segments + j2, base + (k + 1) * segments + j2, base + (k + 1) * segments + j, mat);
    }
  }
}

/** A box with its corners at ±h about `c`, each face one quad. */
function box(b: Builder, c: V3, h: V3, mat: number = MAT.shell) {
  const v: number[] = [];
  for (let i = 0; i < 8; i++) {
    v.push(b.vertex(c[0] + (i & 1 ? h[0] : -h[0]), c[1] + (i & 2 ? h[1] : -h[1]), c[2] + (i & 4 ? h[2] : -h[2])));
  }
  b.quad(v[0], v[1], v[3], v[2], mat); /* back */
  b.quad(v[4], v[5], v[7], v[6], mat); /* front */
  b.quad(v[0], v[1], v[5], v[4], mat); /* top */
  b.quad(v[2], v[3], v[7], v[6], mat); /* bottom */
  b.quad(v[0], v[2], v[6], v[4], mat); /* left */
  b.quad(v[1], v[3], v[7], v[5], mat); /* right */
}

/* ── the head, from the sculpt ───────────────────────────────────────── */

/* the cranium's radius at each height, measured off the sculpt: round in
   section, straight up to the eyes, then the dome */
const PROFILE: Array<[number, number]> = [
  [0.02, 0.299], [-0.283, 0.299], [-0.354, 0.26], [-0.424, 0.217], [-0.467, 0.176], [-0.495, 0.133], [-0.512, 0.09], [-0.521, 0],
];

function craniumRadius(y: number): number {
  if (y >= PROFILE[0][0]) return PROFILE[0][1];
  for (let i = 1; i < PROFILE.length; i++) {
    const [y1, r1] = PROFILE[i];
    if (y >= y1) {
      const [y0, r0] = PROFILE[i - 1];
      return r0 + ((y - y0) / (y1 - y0)) * (r1 - r0);
    }
  }
  return 0;
}

/** Where the cranium's front surface is at (x, y), and its outward normal there. */
export function craniumFront(x: number, y: number): { z: number; n: V3 } {
  const f = (xx: number, yy: number) => {
    const r = craniumRadius(yy);
    return Math.sqrt(Math.max(0, r * r - xx * xx));
  };
  const z = f(x, y);
  const e = 0.002;
  const dzdx = (f(x + e, y) - f(x - e, y)) / (2 * e);
  const dzdy = (f(x, y + e) - f(x, y - e)) / (2 * e);
  return { z, n: norm(-dzdx, -dzdy, 1) };
}

const decode = (b64: string) => {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
};

/* one part of the sculpt, as quads */
function sculpt(part: { pos: string; tri: string; nrm: string; mat: string }): Mesh {
  const p16 = new Int16Array(decode(part.pos));
  const tri = new Uint16Array(decode(part.tri));
  const n8 = new Int8Array(decode(part.nrm));
  const mats = new Uint8Array(decode(part.mat));
  const pos = new Float32Array(p16.length);
  for (let i = 0; i < p16.length; i++) pos[i] = p16[i] / MODEL_Q;
  const nt = tri.length / 3;
  const quads = new Uint16Array(nt * 4);
  const normals = new Float32Array(nt * 3);
  const ys = new Float32Array(nt);
  for (let t = 0; t < nt; t++) {
    const a = tri[t * 3], b = tri[t * 3 + 1], c = tri[t * 3 + 2];
    quads[t * 4] = a; quads[t * 4 + 1] = b; quads[t * 4 + 2] = c; quads[t * 4 + 3] = c;
    const [nx, ny, nz] = norm(n8[t * 3], n8[t * 3 + 1], n8[t * 3 + 2]);
    normals[t * 3] = nx; normals[t * 3 + 1] = ny; normals[t * 3 + 2] = nz;
    ys[t] = (pos[a * 3 + 1] + pos[b * 3 + 1] + pos[c * 3 + 1]) / 3;
  }
  return { pos, quads, normals, ys, mats };
}

/*
 * The jaw's top edge bends for a smile: the front of the band, near its
 * top, rises at the corners (and falls for a frown), most at the corners
 * and not at all at the middle or round the back.
 */
let jawTop = 0;
export function shapeJaw(rest: Float32Array, pos: Float32Array, smile: number) {
  pos.set(rest);
  if (Math.abs(smile) < 1e-3) return;
  for (let i = 0; i < rest.length; i += 3) {
    const x = rest[i], y = rest[i + 1], z = rest[i + 2];
    if (z < 0.05) continue;
    const near = 1 - Math.min(1, Math.max(0, (y - jawTop) / 0.05));
    if (near <= 0) continue;
    const across = Math.min(1, Math.abs(x) / 0.29);
    pos[i + 1] = y - smile * 0.075 * across * across * near * Math.min(1, z / 0.15);
  }
}

/* ── neck and shoulders ──────────────────────────────────────────────── */

function neck(): Mesh {
  const b = new Builder();
  const profile: Array<[number, number]> = [];
  /* ribbed: a ridge every 0.03 */
  for (let i = 0; i <= 5; i++) {
    const y = 0.18 + i * 0.03;
    profile.push([0.155, y], [0.14, y + 0.015]);
  }
  lathe(b, profile, 28, 0, -0.02, MAT.dark);
  return b.finish((_x, y) => [0, y, -0.02]);
}

function collar(): Mesh {
  const b = new Builder();
  lathe(b, [[0.15, 0.305], [0.22, 0.29], [0.28, 0.295], [0.305, 0.315], [0.31, 0.345], [0.29, 0.375], [0.2, 0.385]], 40, 0, -0.03);
  return b.finish((_x, y) => [0, Math.min(0.35, Math.max(y, 0.33)), -0.03]);
}

/*
 * One shoulder: a wedge whose top slopes down toward the front and away
 * from the neck, so it shows its top like the original's; four ridges run
 * down the slope by the neck. Lofted between its inner and outer side
 * profiles. `s` is the side.
 */
const SHOULDER = { inner: 0.27, outer: 0.9, back: -0.32, front: 0.24, bottom: 1 };
/* the top's height at a point: up at the back by the neck, down toward the front and the outside */
export const SHOULDER_FRONT = SHOULDER.front;
const shoulderTop = (x: number, z: number) => 0.2 + (x - SHOULDER.inner) * 0.2 + (z - SHOULDER.back) * 0.3;

function shoulder(b: Builder, s: number) {
  const { inner, outer, back, front, bottom } = SHOULDER;
  const ch = 0.035;
  /* a side profile at x: back bottom, back top, front top (chamfered), front bottom */
  const side = (x: number) => [
    b.vertex(s * x, bottom, back),
    b.vertex(s * x, shoulderTop(x, back), back),
    b.vertex(s * x, shoulderTop(x, front - ch), front - ch),
    b.vertex(s * x, shoulderTop(x, front) + ch, front),
    b.vertex(s * x, bottom, front),
  ];
  const xs = [inner, inner + ch, outer - ch, outer];
  const loops = xs.map((x, i) => {
    const v = side(x);
    /* the end profiles are pulled in a little at the top: a chamfer round the edge */
    if (i === 0 || i === 3) {
      const k = b.pos;
      for (const idx of [v[1], v[2], v[3]]) k[idx * 3 + 1] += ch * 0.8;
    }
    return v;
  });
  for (let k = 0; k < loops.length - 1; k++) {
    for (let i = 0; i < 4; i++) b.quad(loops[k][i], loops[k][i + 1], loops[k + 1][i + 1], loops[k + 1][i]);
    b.quad(loops[k][4], loops[k][0], loops[k + 1][0], loops[k + 1][4]);
  }
  b.quad(loops[0][0], loops[0][1], loops[0][2], loops[0][3]);
  b.quad(loops[0][0], loops[0][3], loops[0][4], loops[0][4]);
  b.quad(loops[3][0], loops[3][1], loops[3][2], loops[3][3]);
  b.quad(loops[3][0], loops[3][3], loops[3][4], loops[3][4]);
  /* ridges down the slope by the neck */
  for (const fx of [0.36, 0.44, 0.52, 0.6]) {
    const w = 0.016, h = 0.026;
    const z0 = back + 0.05, z1 = front - 0.08;
    const lift = -0.004;
    const p = (x: number, z: number, up: number) => b.vertex(s * x, shoulderTop(x, z) + lift - up, z);
    const bl0 = p(fx - w, z0, 0), br0 = p(fx + w, z0, 0), bl1 = p(fx - w, z1, 0), br1 = p(fx + w, z1, 0);
    const tl0 = p(fx - w * 0.6, z0, h), tr0 = p(fx + w * 0.6, z0, h), tl1 = p(fx - w * 0.6, z1, h * 0.8), tr1 = p(fx + w * 0.6, z1, h * 0.8);
    b.quad(tl0, tr0, tr1, tl1);
    b.quad(bl0, tl0, tl1, bl1);
    b.quad(tr0, br0, br1, tr1);
    b.quad(tl1, tr1, br1, bl1);
    b.quad(bl0, br0, tr0, tl0);
  }
}

function shoulders(): Mesh {
  const b = new Builder();
  shoulder(b, -1);
  shoulder(b, 1);
  return b.finish((x) => [Math.sign(x) * 0.58, 0.6, -0.04]);
}

/* the chest between the shoulders, under the collar: dark, with ribs */
function chest(): Mesh {
  const b = new Builder();
  box(b, [0, 0.66, -0.06], [0.27, 0.3, 0.26], MAT.dark);
  for (let i = -3; i <= 3; i++) box(b, [i * 0.07, 0.66, 0.2], [0.02, 0.3, 0.02]);
  return b.finish((_x, y) => [0, y, -0.06]);
}

export interface RobotMeshes {
  cranium: Mesh;
  crest: Mesh;
  jaw: Mesh;
  neck: Mesh;
  collar: Mesh;
  shoulders: Mesh;
  chest: Mesh;
}

let meshes: RobotMeshes | null = null;
export function robotMeshes(): RobotMeshes {
  if (!meshes) {
    meshes = {
      cranium: sculpt(MODEL.head),
      crest: sculpt(MODEL.crest),
      jaw: sculpt(MODEL.jaw),
      neck: neck(),
      collar: collar(),
      shoulders: shoulders(),
      chest: chest(),
    };
    const j = meshes.jaw.pos;
    jawTop = Infinity;
    for (let i = 0; i < j.length; i += 3) if (j[i + 2] > 0.15 && Math.abs(j[i]) < 0.1) jawTop = Math.min(jawTop, j[i + 1]);
  }
  return meshes;
}
