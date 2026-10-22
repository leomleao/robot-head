/* Drawing the robot on a 2D canvas. The shoulders, chest, collar and neck
   never move with the head, so they are lit and painted once per size and
   colour and reused. Every frame the head's meshes are turned about the
   neck, projected, sorted back to front by quad and filled with their
   lighting; then the face goes on top: dark sockets, the glow inside them
   cut by the lids, and a bloom that spills onto the shell. */

import { HEAD, HEAD_TOP, MAT, SHOULDER_FRONT, craniumFront, robotMeshes, rotation, shapeJaw, type Mesh, type V3 } from './geometry';
import { css, linear, radiance, type Material } from './light';
import type { EyeRig, FaceRig, RGB } from './rig';

export interface Palette {
  shell: Material;
  dark: Material;
  inside: Material;
}

export function palette(shell: RGB): Palette {
  const a = linear(shell);
  return {
    shell: { albedo: a, f0: 0.02, metal: 0.25, spec: 0.16, shininess: 14, rim: 0.45, sheen: 0.45 },
    dark: { albedo: [a[0] * 0.32, a[1] * 0.32, a[2] * 0.32], f0: 0.03, metal: 0.3, spec: 0.12, shininess: 12, rim: 0.35 },
    inside: { albedo: [0.004, 0.0035, 0.003], f0: 0.02, metal: 0, spec: 0, shininess: 8, rim: 0 },
  };
}

export interface RobotPose {
  yaw: number;
  pitch: number;
  roll: number;
  /* the head's drift, sideways and up, in head units */
  x: number;
  lift: number;
  /* the shoulders rising with a breath, in head units */
  breathe: number;
}

export const REST_POSE: RobotPose = { yaw: 0, pitch: 0, roll: 0, x: 0, lift: 0, breathe: 0 };

export interface RenderOptions {
  shadow: boolean;
}

const makeCanvas = (w: number, h: number) => {
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.ceil(w));
  c.height = Math.max(1, Math.ceil(h));
  return c;
};

const smooth = (a: number, b: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

/* ── framing ─────────────────────────────────────────────────────────── */

/* the box holds, at rest, from a little over the crest's spike down to the
   bottom edge of the shoulders' crop */
const TOP = HEAD_TOP - 0.035;
const BOTTOM = 0.8;
/* room the head needs past the box when it tilts, nods or rises, and for the glow */
const REACH = { up: 0.16, side: 0.1 };

/**
 * Where the robot sits, in CSS px. The element is a `box` × `box` square
 * with the robot at rest filling it; the canvas reaches past it by `pad*`
 * on each side. `cx`, `cy` place the middle of the mouth line (the model's
 * origin) at rest; `unit` is one head unit.
 */
export interface Frame {
  box: number;
  padTop: number;
  padBottom: number;
  padSide: number;
  unit: number;
  cx: number;
  cy: number;
}

export function frameFor(box: number): Frame {
  const unit = box / (BOTTOM - TOP);
  const padTop = Math.ceil(REACH.up * unit + 1);
  const padSide = Math.ceil(REACH.side * unit + 1);
  return { box, padTop, padBottom: 1, padSide, unit, cx: padSide + box / 2, cy: padTop - TOP * unit };
}

/* ── projection ──────────────────────────────────────────────────────── */

/* the head's transform for a frame: turn about the pivot, then drift */
class HeadXform {
  R = new Array(9).fill(0);
  J = new Array(9).fill(0);
  cx = 0;
  cy = 0;
  U = 1;
  dx = 0;
  dy = 0;
  set(pose: RobotPose, face: FaceRig, cx: number, cy: number, U: number) {
    rotation(pose.yaw + face.yaw, pose.pitch + face.pitch, pose.roll + face.roll, this.R);
    /* the jaw swings down and back about its hinge */
    const th = Math.max(0, face.jawOpen) * 0.5;
    const c = Math.cos(th), s = Math.sin(th);
    this.J[0] = 1; this.J[4] = c; this.J[5] = s; this.J[7] = -s; this.J[8] = c;
    this.cx = cx; this.cy = cy; this.U = U;
    this.dx = pose.x; this.dy = -pose.lift;
  }
  /** A model point on the head → [screen x, screen y, depth toward the viewer]. */
  head(x: number, y: number, z: number, out: Float32Array, o: number) {
    const R = this.R;
    const py = y - HEAD.pivot;
    const wx = R[0] * x + R[1] * py + R[2] * z;
    const wy = R[3] * x + R[4] * py + R[5] * z + HEAD.pivot;
    const wz = R[6] * x + R[7] * py + R[8] * z;
    out[o] = this.cx + (wx + this.dx) * this.U;
    out[o + 1] = this.cy + (wy + this.dy) * this.U;
    out[o + 2] = wz;
  }
  /** A model point on the jaw (before it swings) → screen, through the hinge then the head. */
  jaw(x: number, y: number, z: number, out: Float32Array, o: number) {
    const J = this.J;
    const hy = y - HEAD.hingeY, hz = z - HEAD.hingeZ;
    this.head(x, HEAD.hingeY + J[4] * hy + J[5] * hz, HEAD.hingeZ + J[7] * hy + J[8] * hz, out, o);
  }
  /** A normal on the head → world. */
  normal(nx: number, ny: number, nz: number, out: V3) {
    const R = this.R;
    out[0] = R[0] * nx + R[1] * ny + R[2] * nz;
    out[1] = R[3] * nx + R[4] * ny + R[5] * nz;
    out[2] = R[6] * nx + R[7] * ny + R[8] * nz;
  }
  jawNormal(nx: number, ny: number, nz: number, out: V3) {
    const J = this.J;
    this.normal(nx, J[4] * ny + J[5] * nz, J[7] * ny + J[8] * nz, out);
  }
}

/* a mesh's vertices projected for this frame */
interface Projected {
  mesh: Mesh;
  scr: Float32Array;
  jaw: boolean;
}

/* how far forward the crest's quads sort (a sum over four corners) */
const CREST_BIAS = 0.1;

/* the face round each eye faces a little out and up from the round of the head */
const EYE_NORMAL_R: V3 = (() => {
  const l = Math.hypot(0.3, 0.16, 1);
  return [0.3 / l, -0.16 / l, 1 / l];
})();
const EYE_NORMAL_L: V3 = [-EYE_NORMAL_R[0], EYE_NORMAL_R[1], EYE_NORMAL_R[2]];

/* how far the body is tipped toward us, radians */
const BODY_VIEW = -0.16;
/* and lifted back up, so the collar's front edge stays just under the jaw */
const BODY_LIFT = -0.045;

/* the grime: a little darker toward the bottom of each part */
const grimeOf = (y: number) => 1 - 0.2 * smooth(-0.35, 0.3, y);

/* ── the eyes ────────────────────────────────────────────────────────── */

const PENTAGON = (() => {
  /* the radius of a regular pentagon, point up, at each of 60 angles round it */
  const out = new Float32Array(60);
  for (let i = 0; i < 60; i++) {
    const a = (i / 60) * Math.PI * 2;
    const k = ((a + Math.PI / 2) % ((2 * Math.PI) / 5) + (2 * Math.PI) / 5) % ((2 * Math.PI) / 5) - Math.PI / 5;
    out[i] = Math.cos(Math.PI / 5) / Math.cos(k);
  }
  return out;
})();

function glowPath(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, shape: number) {
  ctx.beginPath();
  if (shape < 0.01) {
    ctx.arc(x, y, r, 0, Math.PI * 2);
    return;
  }
  for (let i = 0; i < 60; i++) {
    const a = (i / 60) * Math.PI * 2;
    const rr = r * (1 + (PENTAGON[i] * 0.92 - 1) * shape);
    const px = x + Math.cos(a) * rr, py = y + Math.sin(a) * rr;
    if (i) ctx.lineTo(px, py);
    else ctx.moveTo(px, py);
  }
  ctx.closePath();
}

export class RobotRenderer {
  private bakeKey = '';
  private bake: HTMLCanvasElement | null = null;
  private proj: Projected[] = [];
  private zs = new Float32Array(0);
  private order = new Uint32Array(0);
  private owner = new Uint16Array(0);
  private jawPos: Float32Array | null = null;
  private x = new HeadXform();
  private nrm: V3 = [0, 0, 0];
  private col: V3 = [0, 0, 0];
  private pt = new Float32Array(9);

  private setup() {
    if (this.proj.length) return;
    const m = robotMeshes();
    const list: Array<[Mesh, boolean]> = [[m.cranium, false], [m.crest, false], [m.jaw, true]];
    this.proj = list.map(([mesh, jaw]) => ({ mesh, scr: new Float32Array(mesh.pos.length), jaw }));
    const total = list.reduce((n, [mesh]) => n + mesh.quads.length / 4, 0);
    this.zs = new Float32Array(total);
    this.order = new Uint32Array(total);
    this.owner = new Uint16Array(total);
    this.jawPos = new Float32Array(m.jaw.pos.length);
  }

  /* the shoulders, chest, collar and neck: lit once, clipped to the box, faded at the bottom */
  private bakeBody(w: number, h: number, frame: Frame, dpr: number, pal: Palette) {
    const key = `${w}x${h}:${frame.unit}:${dpr}:${pal.shell.albedo.join(',')}`;
    if (key === this.bakeKey && this.bake) return this.bake;
    this.bakeKey = key;
    const c = makeCanvas(w, h);
    const ctx = c.getContext('2d')!;
    const U = frame.unit * dpr;
    const cx = frame.cx * dpr, cy = frame.cy * dpr;
    const m = robotMeshes();
    /* the body is seen from a little above, so the tops of the shoulders and their fins catch the light */
    const V = rotation(0, BODY_VIEW, 0);
    const O = 0.35;
    const view = (x: number, y: number, z: number): V3 => [
      V[0] * x + V[1] * (y - O) + V[2] * z,
      V[3] * x + V[4] * (y - O) + V[5] * z + O + BODY_LIFT,
      V[6] * x + V[7] * (y - O) + V[8] * z,
    ];
    const meshes = [m.chest, m.shoulders, m.collar, m.neck];
    const items: Array<[number, Mesh, number, V3]> = [];
    for (const mesh of meshes) {
      for (let q = 0; q < mesh.quads.length / 4; q++) {
        const n = mesh.normals;
        const w: V3 = [
          V[0] * n[q * 3] + V[1] * n[q * 3 + 1] + V[2] * n[q * 3 + 2],
          V[3] * n[q * 3] + V[4] * n[q * 3 + 1] + V[5] * n[q * 3 + 2],
          V[6] * n[q * 3] + V[7] * n[q * 3 + 1] + V[8] * n[q * 3 + 2],
        ];
        if (w[2] < -0.02) continue;
        let z = 0;
        for (let k = 0; k < 4; k++) {
          const i = mesh.quads[q * 4 + k] * 3;
          z += view(mesh.pos[i], mesh.pos[i + 1], mesh.pos[i + 2])[2];
        }
        items.push([z / 4, mesh, q, w]);
      }
    }
    items.sort((a, b) => a[0] - b[0]);
    ctx.lineJoin = 'round';
    ctx.lineWidth = Math.max(0.6, U / 300);
    for (const [, mesh, q, w] of items) {
      const mat = mesh.mats[q] === MAT.dark ? pal.dark : mesh.mats[q] === MAT.inside ? pal.inside : pal.shell;
      const col = radiance(mat, w[0], w[1], w[2], this.col);
      const g = grimeOf(mesh.ys[q] - 0.45);
      col[0] *= g; col[1] *= g; col[2] *= g;
      const s = css(col);
      ctx.beginPath();
      for (let k = 0; k < 4; k++) {
        const i = mesh.quads[q * 4 + k] * 3;
        const p = view(mesh.pos[i], mesh.pos[i + 1], mesh.pos[i + 2]);
        const px = cx + p[0] * U, py = cy + p[1] * U;
        if (k) ctx.lineTo(px, py);
        else ctx.moveTo(px, py);
      }
      ctx.closePath();
      ctx.fillStyle = s;
      ctx.strokeStyle = s;
      ctx.fill();
      ctx.stroke();
    }
    /* rivets along the front edge of each shoulder */
    for (const s of [-1, 1]) {
      for (let i = 0; i < 4; i++) {
        const p = view(s * (0.4 + i * 0.12), 0.62, SHOULDER_FRONT + 0.002);
        this.rivet(ctx, cx + p[0] * U, cy + p[1] * U, U * 0.011, pal);
      }
    }
    /* clip to the box, and fade out toward its bottom edge */
    const bx = frame.padSide * dpr, by = frame.padTop * dpr, bw = frame.box * dpr;
    ctx.globalCompositeOperation = 'destination-in';
    const fade = ctx.createLinearGradient(0, by + bw * 0.78, 0, by + bw);
    fade.addColorStop(0, 'rgba(0,0,0,1)');
    fade.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = fade;
    ctx.fillRect(bx, 0, bw, by + bw);
    ctx.globalCompositeOperation = 'source-over';
    this.bake = c;
    return c;
  }

  private rivet(ctx: CanvasRenderingContext2D, x: number, y: number, r: number, pal: Palette) {
    const hi = css(radiance(pal.shell, -0.45, -0.6, 0.66, this.col));
    const lo = css(radiance(pal.shell, 0.4, 0.55, 0.73, this.col));
    ctx.fillStyle = 'rgba(0,0,0,0.35)';
    ctx.beginPath();
    ctx.arc(x + r * 0.35, y + r * 0.4, r * 1.05, 0, Math.PI * 2);
    ctx.fill();
    const g = ctx.createLinearGradient(x - r, y - r, x + r, y + r);
    g.addColorStop(0, hi);
    g.addColorStop(1, lo);
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fill();
  }

  /** Draw a frame; `frame` is in CSS px, the canvas in device px (`dpr` per CSS px). */
  draw(ctx: CanvasRenderingContext2D, frame: Frame, dpr: number, pose: RobotPose, face: FaceRig, pal: Palette, opts: RenderOptions) {
    this.setup();
    const W = ctx.canvas.width, H = ctx.canvas.height;
    const U = frame.unit * dpr;
    const cx = frame.cx * dpr, cy = frame.cy * dpr;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, W, H);

    /* the body, rising a little with each breath */
    const body = this.bakeBody(W, H, frame, dpr, pal);
    ctx.drawImage(body, 0, -pose.breathe * U);

    const X = this.x;
    X.set(pose, face, cx, cy - pose.breathe * U * 0.6, U);

    /* the shadow the head casts on its collar */
    if (opts.shadow) {
      const sx = cx + (pose.x + Math.sin(pose.yaw) * 0.05) * U;
      const sy = cy + (0.36 - pose.breathe * 0.6) * U;
      ctx.save();
      ctx.translate(sx, sy);
      ctx.scale(1, 0.32);
      const g = ctx.createRadialGradient(0, 0, 0, 0, 0, 0.36 * U);
      g.addColorStop(0, 'rgba(0,0,0,0.45)');
      g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(0, 0, 0.36 * U, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }

    /* project the head */
    const m = robotMeshes();
    shapeJaw(m.jaw.pos, this.jawPos!, face.jawSmile);
    for (const p of this.proj) {
      const pos = p.mesh === m.jaw ? this.jawPos! : p.mesh.pos;
      for (let i = 0; i < pos.length; i += 3) {
        if (p.jaw) X.jaw(pos[i], pos[i + 1], pos[i + 2], p.scr, i);
        else X.head(pos[i], pos[i + 1], pos[i + 2], p.scr, i);
      }
    }

    /* the inside of the mouth, behind everything else on the head */
    this.drawMouth(ctx, face, pal);

    /* every visible quad of the cranium, crest and jaw, back to front; the
       crest sits in a slot, so it is nudged forward to win against the
       slot's own walls */
    let count = 0;
    const N = this.nrm;
    for (let pi = 0; pi < 3; pi++) {
      const p = this.proj[pi];
      const { quads, normals } = p.mesh;
      for (let q = 0; q < quads.length / 4; q++) {
        if (p.jaw) X.jawNormal(normals[q * 3], normals[q * 3 + 1], normals[q * 3 + 2], N);
        else X.normal(normals[q * 3], normals[q * 3 + 1], normals[q * 3 + 2], N);
        if (N[2] < -0.04) continue;
        const s = p.scr;
        this.zs[count] = s[quads[q * 4] * 3 + 2] + s[quads[q * 4 + 1] * 3 + 2] + s[quads[q * 4 + 2] * 3 + 2] + s[quads[q * 4 + 3] * 3 + 2] + (pi === 1 ? CREST_BIAS : 0);
        this.owner[count] = pi;
        this.order[count] = q;
        count++;
      }
    }
    const idx = Array.from({ length: count }, (_, i) => i);
    const zs = this.zs;
    idx.sort((a, b) => zs[a] - zs[b]);

    ctx.lineJoin = 'round';
    ctx.lineWidth = Math.max(0.6, U / 300);
    for (const i of idx) this.fillQuad(ctx, this.proj[this.owner[i]], this.order[i], pal);

    this.drawEye(ctx, face.right, face, -1, pal);
    this.drawEye(ctx, face.left, face, 1, pal);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
  }

  /* one part alone, back to front */
  private drawPart(ctx: CanvasRenderingContext2D, p: Projected, pal: Palette) {
    const { quads, normals } = p.mesh;
    const N = this.nrm;
    const items: Array<[number, number]> = [];
    for (let q = 0; q < quads.length / 4; q++) {
      if (p.jaw) this.x.jawNormal(normals[q * 3], normals[q * 3 + 1], normals[q * 3 + 2], N);
      else this.x.normal(normals[q * 3], normals[q * 3 + 1], normals[q * 3 + 2], N);
      if (N[2] < -0.04) continue;
      const s = p.scr;
      items.push([s[quads[q * 4] * 3 + 2] + s[quads[q * 4 + 1] * 3 + 2] + s[quads[q * 4 + 2] * 3 + 2], q]);
    }
    items.sort((a, b) => a[0] - b[0]);
    for (const [, q] of items) this.fillQuad(ctx, p, q, pal);
  }

  private fillQuad(ctx: CanvasRenderingContext2D, p: Projected, q: number, pal: Palette) {
    const { quads, normals, ys, mats } = p.mesh;
    const N = this.nrm;
    if (p.jaw) this.x.jawNormal(normals[q * 3], normals[q * 3 + 1], normals[q * 3 + 2], N);
    else this.x.normal(normals[q * 3], normals[q * 3 + 1], normals[q * 3 + 2], N);
    const mat = mats[q] === MAT.dark ? pal.dark : mats[q] === MAT.inside ? pal.inside : pal.shell;
    const col = radiance(mat, N[0], N[1], N[2], this.col);
    const g = grimeOf(ys[q]);
    col[0] *= g; col[1] *= g; col[2] *= g;
    const s = css(col);
    const scr = p.scr;
    ctx.beginPath();
    for (let k = 0; k < 4; k++) {
      const i = quads[q * 4 + k] * 3;
      if (k) ctx.lineTo(scr[i], scr[i + 1]);
      else ctx.moveTo(scr[i], scr[i + 1]);
    }
    ctx.closePath();
    ctx.fillStyle = s;
    ctx.strokeStyle = s;
    ctx.fill();
    ctx.stroke();
  }

  /* the dark inside of the mouth, and the teeth along the top of it */
  private drawMouth(ctx: CanvasRenderingContext2D, face: FaceRig, pal: Palette) {
    void pal;
    const X = this.x, pt = this.pt;
    /* a dark plate just behind the face, from the mouth line down into the jaw */
    ctx.beginPath();
    const steps = 12;
    for (let i = 0; i <= steps; i++) {
      const x = -HEAD.r * 0.97 + (i / steps) * HEAD.r * 1.94;
      X.head(x, -0.02, craniumFront(x * 0.98, -0.01).z - 0.01, pt, 0);
      if (i) ctx.lineTo(pt[0], pt[1]);
      else ctx.moveTo(pt[0], pt[1]);
    }
    for (let i = steps; i >= 0; i--) {
      const x = -HEAD.r * 0.97 + (i / steps) * HEAD.r * 1.94;
      X.head(x, 0.2, craniumFront(x * 0.98, -0.01).z - 0.03, pt, 0);
      ctx.lineTo(pt[0], pt[1]);
    }
    ctx.closePath();
    ctx.fillStyle = '#070605';
    ctx.fill();
    if (face.teeth > 0.01) {
      /* a row of squared teeth hanging from the upper lip */
      ctx.globalAlpha = Math.min(1, face.teeth);
      const n = 9;
      for (let i = 0; i < n; i++) {
        const x0 = -HEAD.r * 0.78 + (i / n) * HEAD.r * 1.56 + 0.006;
        const x1 = x0 + (HEAD.r * 1.56) / n - 0.012;
        ctx.beginPath();
        const z = (x: number) => craniumFront(x, -0.01).z - 0.012;
        X.head(x0, 0, z(x0), pt, 0); ctx.moveTo(pt[0], pt[1]);
        X.head(x1, 0, z(x1), pt, 0); ctx.lineTo(pt[0], pt[1]);
        X.head(x1, 0.045, z(x1), pt, 0); ctx.lineTo(pt[0], pt[1]);
        X.head(x0, 0.045, z(x0), pt, 0); ctx.lineTo(pt[0], pt[1]);
        ctx.closePath();
        ctx.fillStyle = '#8f8a84';
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }
  }

  /*
   * One eye, drawn in its own patch of the face: the patch's tangent plane
   * is mapped to the screen, so everything inside is drawn in head units
   * centred on the socket. `side` is −1 for the eye on the viewer's left.
   */
  private drawEye(ctx: CanvasRenderingContext2D, e: EyeRig, face: FaceRig, side: number, pal: Palette) {
    const X = this.x, pt = this.pt;
    const ex = side * HEAD.eyeX, ey = HEAD.eyeY, z = HEAD.eyeZ;
    const n = side < 0 ? EYE_NORMAL_L : EYE_NORMAL_R;
    const N = this.nrm;
    X.normal(n[0], n[1], n[2], N);
    if (N[2] < 0.08) return;
    /* the tangent plane: a step along x and along y on the surface */
    const tx = 1 / Math.hypot(1, n[0] / n[2]), tzx = (-n[0] / n[2]) * tx;
    const ty = 1 / Math.hypot(1, n[1] / n[2]), tzy = (-n[1] / n[2]) * ty;
    X.head(ex, ey, z, pt, 0);
    X.head(ex + tx, ey, z + tzx, pt, 3);
    X.head(ex, ey + ty, z + tzy, pt, 6);
    const ox = pt[0], oy = pt[1];
    ctx.save();
    ctx.setTransform(pt[3] - ox, pt[4] - oy, pt[6] - ox, pt[7] - oy, ox, oy);
    /* how much the face is turned from us: the socket's rim shows its far wall */
    const facing = smooth(0.08, 0.6, N[2]);

    const R = HEAD.socket;
    /* the socket */
    ctx.beginPath();
    ctx.arc(0.003, 0.004, R, 0, Math.PI * 2);
    ctx.fillStyle = '#060504';
    ctx.fill();

    /* the glow, cut by the lids */
    const [r0, g0, b0] = face.color;
    const r = R * HEAD.glow * e.size;
    const travel = Math.max(0, R * 0.96 - r);
    const gx = e.gazeX * travel, gy = e.gazeY * travel;
    const bright = Math.max(0, e.glow);
    const open = this.openness(e);
    ctx.save();
    ctx.beginPath();
    ctx.arc(0, 0, R * 0.985, 0, Math.PI * 2);
    ctx.clip();
    if (open > 0.001 && bright > 0.001) {
      /* the disc: hot white at the core, the colour toward its edge */
      const dark = e.pupil;
      const core = (k: number) => `rgb(${Math.round(r0 + (255 - r0) * k)},${Math.round(g0 + (255 - g0) * k)},${Math.round(b0 + (255 - b0) * k)})`;
      const grad = ctx.createRadialGradient(gx, gy, 0, gx, gy, r);
      grad.addColorStop(0, core(0.8 * (1 - dark)));
      grad.addColorStop(0.45, core(0.45 * (1 - dark)));
      grad.addColorStop(0.85, core(0));
      grad.addColorStop(1, `rgb(${Math.round(r0 * 0.88)},${Math.round(g0 * 0.84)},${Math.round(b0 * 0.84)})`);
      ctx.globalAlpha = Math.min(1, bright) * (1 - dark * 0.92);
      glowPath(ctx, gx, gy, r, e.shape);
      ctx.fillStyle = grad;
      ctx.fill();
      /* defence mode: a pinpoint in the middle of the dark */
      if (dark > 0.01) {
        ctx.globalAlpha = Math.min(1, bright) * dark;
        const pr = r * (0.2 + 0.7 * (1 - dark));
        const pg = ctx.createRadialGradient(gx, gy, 0, gx, gy, pr);
        pg.addColorStop(0, core(0.4));
        pg.addColorStop(0.6, `rgb(${r0},${g0},${b0})`);
        pg.addColorStop(1, `rgba(${r0},${g0},${b0},0)`);
        glowPath(ctx, gx, gy, pr, e.shape);
        ctx.fillStyle = pg;
        ctx.fill();
      }
      ctx.globalAlpha = 1;
    }
    this.drawLids(ctx, e, side, R, r);
    ctx.restore();

    /* the bloom: the glow lighting the air and the shell round the socket */
    if (open > 0.001 && bright > 0.001) {
      ctx.globalCompositeOperation = 'lighter';
      const a = 0.3 * Math.min(1.4, bright) * Math.min(1, open * 1.6) * (1 - e.pupil * 0.5) * (0.6 + 0.4 * facing);
      const bloom = ctx.createRadialGradient(gx, gy, r * 0.6, gx, gy, R * 1.7);
      bloom.addColorStop(0, `rgba(${r0},${g0},${b0},${a})`);
      bloom.addColorStop(0.4, `rgba(${r0},${g0},${b0},${a * 0.2})`);
      bloom.addColorStop(1, `rgba(${r0},${g0},${b0},0)`);
      ctx.fillStyle = bloom;
      ctx.beginPath();
      ctx.arc(gx, gy, R * 1.7, 0, Math.PI * 2);
      ctx.fill();
      ctx.globalCompositeOperation = 'source-over';
    }
    ctx.restore();
  }

  /* how much of the disc the lids leave showing, 0 … 1 */
  private openness(e: EyeRig) {
    return Math.max(0, 1 - Math.max(0, e.lidTop) - Math.max(0, e.lidBottom));
  }

  /*
   * The lids: dark plates over the disc from above and below. The top
   * lid's edge tilts about its middle, its inner corner (toward the crest)
   * down for a positive angle; the bottom lid's edge can bow up into a
   * smile.
   */
  private drawLids(ctx: CanvasRenderingContext2D, e: EyeRig, side: number, R: number, r: number) {
    const span = R * 1.2;
    const yt = -r * 1.04 + Math.max(0, e.lidTop) * 2 * r * 1.04;
    const yb = r * 1.04 - Math.max(0, e.lidBottom) * 2 * r * 1.04;
    ctx.fillStyle = '#060504';
    if (e.lidTop > 0.001 || Math.abs(e.lidAngle) > 0.001) {
      /* inward is toward the crest: −x for the eye on the viewer's right */
      const slope = Math.tan(Math.max(-0.9, Math.min(0.9, e.lidAngle))) * -side;
      ctx.beginPath();
      ctx.moveTo(-span, -span);
      ctx.lineTo(span, -span);
      ctx.lineTo(span, yt + slope * span);
      ctx.lineTo(-span, yt - slope * span);
      ctx.closePath();
      ctx.fill();
    }
    if (e.lidBottom > 0.001 || e.lidCurve > 0.001) {
      const bow = Math.max(0, e.lidCurve) * r * 0.5;
      ctx.beginPath();
      ctx.moveTo(-span, span);
      ctx.lineTo(span, span);
      ctx.lineTo(span, yb);
      ctx.quadraticCurveTo(0, yb - bow * 2, -span, yb);
      ctx.closePath();
      ctx.fill();
    }
  }
}

export { TOP as FRAME_TOP, BOTTOM as FRAME_BOTTOM };
