/* The robot as quad meshes in head units: x right, y down, z toward the
   viewer, the origin at the middle of the mouth line (the cranium's lower
   edge). Every frame the head's meshes are turned about the neck and
   projected orthographically; the shoulders never turn, so they are drawn
   once per size and reused.

   The cranium is a sweep: a rounded-square section (a superellipse) whose
   scale follows a profile, straight-sided below the eyes and a dome above.
   The jaw is a larger sweep below it, a bucket that hangs from two arms
   hinged at lugs on the sides of the head, so opening it swings the chin
   down and back. A blade runs over the dome and down the forehead, and the
   top of the dome carries a dent. */

export type V3 = [number, number, number];

/* the head's measurements, from stills of the original at rest */
export const HEAD = {
  /* the cranium's half width and half depth, and the section's squareness */
  a: 0.3,
  c: 0.29,
  n: 3,
  /* straight sides up to `straight`, then a dome of height `dome` */
  straight: 0.19,
  dome: 0.29,
  /* the eyes: centres, the socket's radius, the glow's share of it */
  eyeX: 0.135,
  eyeY: -0.27,
  socket: 0.093,
  glow: 0.6,
  /* the jaw: a bucket from just under the mouth line to the chin, hinged at the lugs */
  jawA: 0.316,
  jawC: 0.302,
  jawTop: 0.03,
  jawBottom: 0.27,
  hingeY: -0.11,
  /* where the head turns: inside the jaw, at the top of the neck */
  pivot: 0.24,
} as const;

/* the top of the crest's spike, for framing */
export const HEAD_TOP = -(HEAD.straight + HEAD.dome) - 0.045;

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

/* a point on a superellipse of exponent n, at angle t */
function superPoint(t: number, n: number): [number, number] {
  const c = Math.cos(t), s = Math.sin(t);
  const e = 2 / n;
  return [Math.sign(c) * Math.pow(Math.abs(c), e), Math.sign(s) * Math.pow(Math.abs(s), e)];
}

interface Ring {
  y: number;
  /* the section's half width and half depth */
  sx: number;
  sz: number;
  /* the section's centre, front to back */
  z?: number;
}

/**
 * Rings of a superellipse section stacked along y, stitched into quads.
 * Each end closes to a point when its ring has no size.
 */
function sweep(b: Builder, rings: Ring[], n: number, samples: number, mat: (k: number) => number = () => MAT.shell) {
  const base = b.pos.length / 3;
  for (const r of rings) {
    for (let j = 0; j < samples; j++) {
      const [px, pz] = superPoint((j / samples) * TAU, n);
      b.vertex(px * r.sx, r.y, (r.z ?? 0) + pz * r.sz);
    }
  }
  for (let k = 0; k < rings.length - 1; k++) {
    for (let j = 0; j < samples; j++) {
      const j2 = (j + 1) % samples;
      b.quad(base + k * samples + j, base + k * samples + j2, base + (k + 1) * samples + j2, base + (k + 1) * samples + j, mat(k));
    }
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

/* ── the cranium ─────────────────────────────────────────────────────── */

/** The cranium's section scale at height y: 1 on the straight sides, falling to 0 over the dome. */
export function craniumScale(y: number): number {
  const u = (-y - HEAD.straight) / HEAD.dome;
  if (u <= 0) return 1;
  if (u >= 1) return 0;
  return Math.pow(1 - Math.pow(u, 2.6), 1 / 2.6);
}

/** Where the cranium's front surface is at (x, y), and its outward normal there. */
export function craniumFront(x: number, y: number): { z: number; n: V3 } {
  const f = (xx: number, yy: number) => {
    const s = craniumScale(yy);
    const u = Math.min(1, Math.abs(xx) / Math.max(1e-4, HEAD.a * s));
    return HEAD.c * s * Math.pow(1 - Math.pow(u, HEAD.n), 1 / HEAD.n);
  };
  const z = f(x, y);
  const e = 0.002;
  const dzdx = (f(x + e, y) - f(x - e, y)) / (2 * e);
  const dzdy = (f(x, y + e) - f(x, y - e)) / (2 * e);
  return { z, n: norm(-dzdx, -dzdy, 1) };
}

/* the dent: a shallow dish pressed into the top of the dome, on the viewer's right */
const DENT = { x: 0.17, y: -0.41, r: 0.085, depth: 0.028 };

function cranium(): Mesh {
  const b = new Builder();
  const rings: Ring[] = [];
  /* a flat underside, then the straight sides, then the dome closing to a point */
  rings.push({ y: 0, sx: 0.0001, sz: 0.0001 });
  rings.push({ y: 0, sx: HEAD.a * 0.94, sz: HEAD.c * 0.94 });
  rings.push({ y: -0.006, sx: HEAD.a, sz: HEAD.c });
  for (let i = 1; i <= 6; i++) {
    const y = -0.006 - (i / 6) * (HEAD.straight - 0.006);
    rings.push({ y, sx: HEAD.a, sz: HEAD.c });
  }
  const steps = 22;
  for (let i = 1; i <= steps; i++) {
    const u = i / steps;
    /* finer toward the top, where the dome turns fastest */
    const uu = 1 - Math.pow(1 - u, 1.4);
    const y = -HEAD.straight - uu * HEAD.dome;
    const s = i === steps ? 0.0001 : craniumScale(y);
    rings.push({ y, sx: HEAD.a * s, sz: HEAD.c * s });
  }
  sweep(b, rings, HEAD.n, 88, (k) => (k === 0 ? MAT.inside : MAT.shell));
  /* press the dent in */
  const P = b.pos;
  for (let i = 0; i < P.length; i += 3) {
    const dx = P[i] - DENT.x, dy = P[i + 1] - DENT.y;
    const d2 = (dx * dx + dy * dy) / (DENT.r * DENT.r);
    if (d2 >= 1 || P[i + 2] < -0.05) continue;
    const k = DENT.depth * (1 - d2) * (1 - d2);
    /* inward, along the line to the dome's centre */
    const [ux, uy, uz] = norm(P[i], P[i + 1] + HEAD.straight, P[i + 2]);
    P[i] -= ux * k; P[i + 1] -= uy * k; P[i + 2] -= uz * k;
  }
  return b.finish((_x, y) => [0, Math.min(-0.05, Math.max(y, -HEAD.straight - 0.05)), 0]);
}

/* ── the crest ───────────────────────────────────────────────────────── */

/*
 * The blade over the top of the dome: it rises out of the shell part way
 * up the front, runs over the top growing taller, and ends in a spike a
 * little behind it. (Down the forehead the crest is a groove, drawn with
 * the face.) Each flank is a strip of quads.
 */
function crest(): Mesh {
  const b = new Builder();
  const N = 14;
  const left: number[] = [], right: number[] = [], ridge: number[] = [];
  for (let i = 0; i <= N; i++) {
    const t = i / N;
    const phi = (0.42 + t * 0.72) * (Math.PI / 2);
    const top = Math.min(phi, Math.PI / 2);
    const y = -HEAD.straight - Math.sin(top) * HEAD.dome;
    const z = Math.cos(phi) * HEAD.c;
    const [nx, ny, nz] = norm(0, -Math.sin(phi) * HEAD.c, Math.cos(phi) * HEAD.dome);
    /* the blade's height and half thickness grow toward the spike */
    const h = 0.002 + Math.pow(t, 1.6) * 0.05;
    const w = 0.003 + t * 0.012;
    const sink = 0.008;
    left.push(b.vertex(-w, y - ny * sink, z - nz * sink));
    right.push(b.vertex(w, y - ny * sink, z - nz * sink));
    ridge.push(b.vertex(nx, y + ny * h, z + nz * h));
  }
  for (let i = 0; i < N; i++) {
    b.quad(left[i], left[i + 1], ridge[i + 1], ridge[i]);
    b.quad(ridge[i], ridge[i + 1], right[i + 1], right[i]);
  }
  b.quad(left[N], ridge[N], right[N], right[N]);
  return b.finish((x, y, z) => [x * 0.5, y + 0.05, z - 0.05]);
}

/** The groove down the forehead, as [x half width, y] from its top to its point, on the front surface. */
export const GROOVE: Array<[number, number]> = [
  [0.024, -0.45], [0.022, -0.41], [0.019, -0.37], [0.016, -0.33], [0.012, -0.29], [0.008, -0.255], [0.0035, -0.225], [0, -0.205],
];

/* ── the jaw ─────────────────────────────────────────────────────────── */

/*
 * The jaw's rings are rebuilt each frame from the smile: the front of its
 * top edge rises at the corners for a smile and falls for a frown. Only
 * the top ring moves, so the mesh is built once with its top ring at rest
 * and `shapeJaw` writes the top ring in place.
 */
export const JAW_SAMPLES = 56;

function jaw(): Mesh {
  const b = new Builder();
  const rings: Ring[] = [
    { y: HEAD.jawTop, sx: 0.0001, sz: 0.0001 },
    { y: HEAD.jawTop, sx: HEAD.jawA * 0.9, sz: HEAD.jawC * 0.9 },
    { y: HEAD.jawTop, sx: HEAD.jawA, sz: HEAD.jawC },
  ];
  const body = HEAD.jawBottom - HEAD.jawTop - 0.06;
  for (let i = 1; i <= 5; i++) {
    const t = i / 5;
    /* the bucket narrows a little toward the chin */
    const s = 1 - 0.05 * t * t;
    rings.push({ y: HEAD.jawTop + t * body, sx: HEAD.jawA * s, sz: HEAD.jawC * s });
  }
  /* a rolled bottom edge */
  for (let i = 1; i <= 5; i++) {
    const t = (i / 5) * (Math.PI / 2);
    const s = 0.95 - (1 - Math.cos(t)) * 0.2;
    rings.push({ y: HEAD.jawBottom - 0.06 + Math.sin(t) * 0.06, sx: HEAD.jawA * s, sz: HEAD.jawC * s });
  }
  rings.push({ y: HEAD.jawBottom, sx: 0.0001, sz: 0.0001 });
  /* the top face is the inside of the mouth: dark */
  sweep(b, rings, 3, JAW_SAMPLES, (k) => (k < 2 ? MAT.inside : MAT.shell));
  return b.finish((_x, y) => [0, Math.min(HEAD.jawBottom - 0.06, Math.max(y, HEAD.jawTop + 0.06)), 0]);
}

/** Write the jaw's top edge for a smile (−1 frown … 1 smile), into `pos` (a copy of the mesh's). */
export function shapeJaw(rest: Float32Array, pos: Float32Array, smile: number) {
  pos.set(rest);
  /* rings 1 and 2 are the top edge (ring 0 is the centre of the top face) */
  for (const ring of [1, 2]) {
    for (let j = 0; j < JAW_SAMPLES; j++) {
      const i = (ring * JAW_SAMPLES + j) * 3;
      const x = rest[i] / HEAD.jawA, z = rest[i + 2] / HEAD.jawC;
      /* only the front of the edge bends, and most at the corners */
      const front = Math.max(0, z);
      pos[i + 1] = rest[i + 1] - smile * 0.1 * x * x * front;
    }
  }
}

/* the arms the jaw hangs from, and the lugs they pivot on */
function jawArms(): Mesh {
  const b = new Builder();
  for (const s of [-1, 1]) {
    const x = s * (HEAD.jawA + 0.002);
    box(b, [x, (HEAD.hingeY - 0.045 + HEAD.jawTop + 0.12) / 2, 0], [0.012, (HEAD.jawTop + 0.12 - HEAD.hingeY + 0.045) / 2, 0.062]);
  }
  return b.finish((x, y) => [x * 0.6, y, 0]);
}

function lugs(): Mesh {
  const b = new Builder();
  for (const s of [-1, 1]) {
    box(b, [s * (HEAD.jawA + 0.022), HEAD.hingeY, 0], [0.012, 0.03, 0.034]);
  }
  return b.finish((x, y) => [x * 0.85, y, 0]);
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
  arms: Mesh;
  lugs: Mesh;
  neck: Mesh;
  collar: Mesh;
  shoulders: Mesh;
  chest: Mesh;
}

let meshes: RobotMeshes | null = null;
export function robotMeshes(): RobotMeshes {
  if (!meshes) {
    meshes = {
      cranium: cranium(),
      crest: crest(),
      jaw: jaw(),
      arms: jawArms(),
      lugs: lugs(),
      neck: neck(),
      collar: collar(),
      shoulders: shoulders(),
      chest: chest(),
    };
  }
  return meshes;
}
