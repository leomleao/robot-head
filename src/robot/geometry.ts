/* The robot as quad meshes in head units: x right, y down, z toward the
   viewer, the origin at the middle of the mouth line (the cranium's lower
   edge). Every frame the meshes are turned about the middle of the head
   and projected orthographically.

   The head, its jaw and the crest come from a sculpt (see model.ts),
   decimated to a few thousand triangles: a domed cranium round in section
   with a slot over the top for the crest, and a jaw like a bucket hanging
   from two arms pinned at the back of the head, so opening it swings the
   chin down and back. Triangles are stored as quads repeating their last
   vertex. */

import { MODEL, MODEL_BOUNDS, MODEL_EYES, MODEL_HINGE, MODEL_PROFILE, MODEL_Q } from './model';

export type V3 = [number, number, number];

/* the head's measurements in head units */
export const HEAD = {
  /* the cranium's radius at the mouth line */
  r: MODEL_PROFILE[0][1],
  /* the eyes: centres, the socket's radius, the glow's share of it */
  eyeX: MODEL_EYES[1][0],
  eyeY: MODEL_EYES[1][1],
  eyeZ: MODEL_EYES[1][2],
  socket: MODEL_EYES[1][3],
  glow: 0.75,
  /* the jaw's hinge pins */
  hingeY: MODEL_HINGE[0],
  hingeZ: MODEL_HINGE[1],
  /* where the head turns: its middle, a little behind the eyes */
  pivot: -0.16,
} as const;

/* the head's reach at rest, for framing: the top of the crest, the bottom
   of the jaw, the hinge lugs at the sides */
export const HEAD_TOP = MODEL_BOUNDS[0];
export const HEAD_BOTTOM = MODEL_BOUNDS[1];
export const HEAD_SIDE = MODEL_BOUNDS[2];

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

/* ── the head, from the sculpt ───────────────────────────────────────── */

const PROFILE = MODEL_PROFILE;

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

export interface RobotMeshes {
  cranium: Mesh;
  crest: Mesh;
  jaw: Mesh;
}

let meshes: RobotMeshes | null = null;
export function robotMeshes(): RobotMeshes {
  if (!meshes) {
    meshes = {
      cranium: sculpt(MODEL.head),
      crest: sculpt(MODEL.crest),
      jaw: sculpt(MODEL.jaw),
    };
    const j = meshes.jaw.pos;
    jawTop = Infinity;
    for (let i = 0; i < j.length; i += 3) if (j[i + 2] > 0.15 && Math.abs(j[i]) < 0.1) jawTop = Math.min(jawTop, j[i + 1]);
  }
  return meshes;
}
