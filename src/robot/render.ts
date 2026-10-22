/* Drawing the robot's head on a 2D canvas. Every frame its meshes are
   turned about the middle of the head, projected, sorted back to front by
   quad and filled with their lighting; then the face goes on top: dark
   sockets, the glow inside them cut by the lids, and a bloom that spills
   onto the shell. A soft shadow on the floor sits under it. */

import { HEAD, HEAD_BOTTOM, HEAD_SIDE, HEAD_TOP, JAW_PANEL, MAT, craniumFront, robotMeshes, rotation, shapeJaw, type Mesh, type V3 } from './geometry';
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
    shell: { albedo: a, f0: 0.02, metal: 0.2, spec: 0.06, shininess: 10, rim: 0.35, sheen: 0.22, flat: 0.45 },
    dark: { albedo: [a[0] * 0.32, a[1] * 0.32, a[2] * 0.32], f0: 0.03, metal: 0.3, spec: 0.06, shininess: 12, rim: 0.3, flat: 0.4 },
    inside: { albedo: [0.006, 0.005, 0.004], f0: 0.02, metal: 0, spec: 0, shininess: 8, rim: 0, sheen: 0.15 },
  };
}

export interface RobotPose {
  yaw: number;
  pitch: number;
  roll: number;
  /* the head's drift, sideways and up, in head units */
  x: number;
  lift: number;
}

export const REST_POSE: RobotPose = { yaw: 0, pitch: 0, roll: 0, x: 0, lift: 0 };

export interface RenderOptions {
  shadow: boolean;
}

const smooth = (a: number, b: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

/* ── framing ─────────────────────────────────────────────────────────── */

/* the head at rest fills the box but for this inset, as a share of it */
const BOX_INSET = 0.05;
/* room past the head for motion, in head units: a nod or tilt, the bob, the
   glow, and the floor's shadow below */
const REACH = { up: 0.12, side: 0.1, shadow: 0.14 };
/* how far below the chin the floor is */
const FLOOR = 0.07;

/**
 * Where the head sits, in CSS px. The element is a `box` × `box` square
 * with the head at rest centred in it and filling it; the canvas reaches
 * past it by `pad*` on each side. `cx`, `cy` place the middle of the mouth line (the model's
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
  const tall = HEAD_BOTTOM - HEAD_TOP, wide = 2 * HEAD_SIDE;
  const inner = box * (1 - 2 * BOX_INSET);
  const unit = Math.min(inner / tall, inner / wide);
  /* the resting head, centred in the box */
  const above = (box - tall * unit) / 2;
  const originY = above - HEAD_TOP * unit;
  const padTop = Math.ceil(Math.max(0, REACH.up * unit - above) + 1);
  const padBottom = Math.ceil(Math.max(0, (FLOOR + REACH.shadow) * unit - above) + 1);
  const padSide = Math.ceil(Math.max(0, REACH.side * unit - (box - wide * unit) / 2) + 1);
  return { box, padTop, padBottom, padSide, unit, cx: padSide + box / 2, cy: padTop + originY };
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
  /* how far the jaw hangs below the cranium at rest: the dark slit of the mouth */
  drop = 0;
  set(pose: RobotPose, face: FaceRig, cx: number, cy: number, U: number) {
    rotation(pose.yaw + face.yaw, pose.pitch + face.pitch, pose.roll + face.roll, this.R);
    /* the jaw swings down and back about its hinge */
    const th = Math.max(0, face.jawOpen) * 0.5;
    const c = Math.cos(th), s = Math.sin(th);
    this.J[0] = 1; this.J[4] = c; this.J[5] = s; this.J[7] = -s; this.J[8] = c;
    this.cx = cx; this.cy = cy; this.U = U;
    this.dx = pose.x; this.dy = -pose.lift;
    /* about 3% of the head's width, and never under two and a half pixels, so a small head keeps its mouth */
    this.drop = Math.max(0.018, 2.5 / U);
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
    this.head(x, HEAD.hingeY + J[4] * hy + J[5] * hz + this.drop, HEAD.hingeZ + J[7] * hy + J[8] * hz, out, o);
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

/* the colour of every inside surface, and of the mouth's dark */
const INSIDE = '#0c090a';
/* the iris's blades, and the lines between them */
const IRIS = '#1c1517';
const IRIS_LINE = '#3d3335';
/* the outline's colour */
const INK = '#140f12';

/* how far forward the crest's quads sort (a sum over four corners) */
const CREST_BIAS = 0.1;

/* the face round each eye faces a little out and up from the round of the head */
const EYE_NORMAL_R: V3 = (() => {
  const l = Math.hypot(0.3, 0.16, 1);
  return [0.3 / l, -0.16 / l, 1 / l];
})();
const EYE_NORMAL_L: V3 = [-EYE_NORMAL_R[0], EYE_NORMAL_R[1], EYE_NORMAL_R[2]];

/* the grime: a little darker toward the bottom of each part */
const grimeOf = (y: number) => 1 - 0.14 * smooth(-0.35, 0.3, y);

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
  private proj: Projected[] = [];
  private zs = new Float32Array(0);
  private order = new Uint32Array(0);
  private owner = new Uint16Array(0);
  private jawPos: Float32Array | null = null;
  private x = new HeadXform();
  private nrm: V3 = [0, 0, 0];
  private col: V3 = [0, 0, 0];
  private pt = new Float32Array(9);
  private layer: HTMLCanvasElement | null = null;
  private ink: HTMLCanvasElement | null = null;

  /* an offscreen canvas the size of the frame's */
  private surface(c: HTMLCanvasElement | null, w: number, h: number) {
    if (!c) c = document.createElement('canvas');
    if (c.width !== w || c.height !== h) {
      c.width = w;
      c.height = h;
    }
    return c;
  }

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

  /** Draw a frame; `frame` is in CSS px, the canvas in device px (`dpr` per CSS px). */
  draw(ctx: CanvasRenderingContext2D, frame: Frame, dpr: number, pose: RobotPose, face: FaceRig, pal: Palette, opts: RenderOptions) {
    this.setup();
    const W = ctx.canvas.width, H = ctx.canvas.height;
    const U = frame.unit * dpr;
    const cx = frame.cx * dpr, cy = frame.cy * dpr;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, W, H);

    const X = this.x;
    X.set(pose, face, cx, cy, U);

    /* the floor's shadow, smaller and fainter the higher the head floats */
    if (opts.shadow) {
      const up = Math.max(0, pose.lift);
      const rx = HEAD.r * 1.15 * (1 - up * 0.9) * U;
      ctx.save();
      ctx.translate(cx + pose.x * U, cy + (HEAD_BOTTOM + FLOOR) * U);
      ctx.scale(1, 0.16);
      const a = 0.5 * Math.max(0, 1 - up * 1.6);
      const g = ctx.createRadialGradient(0, 0, 0, 0, 0, rx);
      g.addColorStop(0, `rgba(0,0,0,${a})`);
      g.addColorStop(0.55, `rgba(0,0,0,${a * 0.45})`);
      g.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(0, 0, rx, 0, Math.PI * 2);
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

    /* the head goes on its own layer, so its silhouette can be inked */
    this.layer = this.surface(this.layer, W, H);
    const out = ctx;
    ctx = this.layer.getContext('2d')!;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, W, H);

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
    this.drawSeams(ctx, U);

    /* the ink: the head's silhouette in a dark line, as drawn in the film */
    this.ink = this.surface(this.ink, W, H);
    const ink = this.ink.getContext('2d')!;
    ink.globalCompositeOperation = 'copy';
    ink.drawImage(this.layer, 0, 0);
    ink.globalCompositeOperation = 'source-in';
    ink.fillStyle = INK;
    ink.fillRect(0, 0, W, H);
    ink.globalCompositeOperation = 'source-over';
    const w = Math.max(1, U * 0.008);
    for (let k = 0; k < 8; k++) {
      const a = (k / 8) * Math.PI * 2;
      out.drawImage(this.ink, Math.cos(a) * w, Math.sin(a) * w);
    }
    out.drawImage(this.layer, 0, 0);
    ctx = out;

    this.drawEye(ctx, face.right, face, -1, pal);
    this.drawEye(ctx, face.left, face, 1, pal);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
  }

  private fillQuad(ctx: CanvasRenderingContext2D, p: Projected, q: number, pal: Palette) {
    const { quads, normals, ys, mats } = p.mesh;
    const N = this.nrm;
    if (p.jaw) this.x.jawNormal(normals[q * 3], normals[q * 3 + 1], normals[q * 3 + 2], N);
    else this.x.normal(normals[q * 3], normals[q * 3 + 1], normals[q * 3 + 2], N);
    /* the inside of the head and the mouth: unlit, a cavity rather than a surface */
    let s = INSIDE;
    if (mats[q] !== MAT.inside) {
      const mat = mats[q] === MAT.dark ? pal.dark : pal.shell;
      const col = radiance(mat, N[0], N[1], N[2], this.col);
      const g = grimeOf(ys[q]);
      col[0] *= g; col[1] *= g; col[2] *= g;
      s = css(col);
    }
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

  /* the dark inside of the mouth */
  private drawMouth(ctx: CanvasRenderingContext2D, face: FaceRig, pal: Palette) {
    void pal;
    const X = this.x, pt = this.pt;
    /* a dark plate just behind the face, from the mouth line down into the jaw */
    ctx.beginPath();
    const steps = 12;
    for (let i = 0; i <= steps; i++) {
      const x = -HEAD.r * 0.85 + (i / steps) * HEAD.r * 1.7;
      X.head(x, -0.02, craniumFront(x * 0.98, -0.01).z - 0.01, pt, 0);
      if (i) ctx.lineTo(pt[0], pt[1]);
      else ctx.moveTo(pt[0], pt[1]);
    }
    for (let i = steps; i >= 0; i--) {
      const x = -HEAD.r * 0.85 + (i / steps) * HEAD.r * 1.7;
      X.head(x, 0.1, craniumFront(x * 0.98, -0.01).z - 0.05, pt, 0);
      ctx.lineTo(pt[0], pt[1]);
    }
    ctx.closePath();
    /* and a wall across the middle of the head, so a turned head shows dark between the cranium and the jaw's arms */
    for (const [x, y] of [[-0.24, -0.03], [0.24, -0.03], [0.24, 0.1], [-0.24, 0.1]] as const) {
      X.head(x, y, -0.06, pt, 0);
      if (x < 0 && y < 0) ctx.moveTo(pt[0], pt[1]);
      else ctx.lineTo(pt[0], pt[1]);
    }
    ctx.closePath();
    ctx.fillStyle = INSIDE;
    ctx.fill();
  }

  /* ink along the edges of the jaw's flat front panel, as the film draws its facets */
  private drawSeams(ctx: CanvasRenderingContext2D, U: number) {
    const X = this.x, pt = this.pt, N = this.nrm;
    X.jawNormal(0, 0, 1, N);
    if (N[2] < 0.05 || !JAW_PANEL.x) return;
    ctx.lineCap = 'round';
    ctx.lineWidth = Math.max(1, U * 0.007);
    ctx.strokeStyle = INK;
    ctx.globalAlpha = Math.min(1, N[2] * 2.5);
    for (const s of [-1, 1]) {
      /* only the edge whose far facet still faces us: the near one turns away when the head turns */
      const x = s * JAW_PANEL.x;
      ctx.beginPath();
      X.jaw(x, JAW_PANEL.top + 0.004, JAW_PANEL.z, pt, 0); ctx.moveTo(pt[0], pt[1]);
      X.jaw(x, JAW_PANEL.bottom - 0.004, JAW_PANEL.z, pt, 0); ctx.lineTo(pt[0], pt[1]);
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }

  /*
   * One eye, drawn in its own patch of the face: the patch's tangent plane
   * is mapped to the screen, so everything inside is drawn in head units
   * centred on the socket. `side` is −1 for the eye on the viewer's left.
   */
  private drawEye(ctx: CanvasRenderingContext2D, e: EyeRig, face: FaceRig, side: number, pal: Palette) {
    const X = this.x, pt = this.pt;
    void X;
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
    const gx = e.gazeX * travel, gy = e.gazeY * travel + R * 0.08;
    const bright = Math.max(0, e.glow);
    const open = this.openness(e);
    ctx.save();
    ctx.beginPath();
    ctx.arc(0, 0, R * 0.985, 0, Math.PI * 2);
    ctx.clip();
    if (open > 0.001 && bright > 0.001) {
      /* the disc: hot white at the core, the colour toward its edge */
      const iris = Math.min(1, Math.max(0, e.pupil));
      const core = (k: number) => `rgb(${Math.round(r0 + (255 - r0) * k)},${Math.round(g0 + (255 - g0) * k)},${Math.round(b0 + (255 - b0) * k)})`;
      /* a small white core, a little low in the disc, falling off evenly to
         a warm rim at about half the brightness; a small head gets a wider
         core so its eyes still pop */
      const corePart = 0.14 + 0.2 * (1 - smooth(6, 20, r * X.U));
      const grad = ctx.createRadialGradient(gx, gy + r * 0.1, 0, gx, gy, r);
      const rim = (k: number) => `rgb(${Math.round(r0 * k)},${Math.round(g0 * k * 0.9)},${Math.round(b0 * k * 0.82)})`;
      grad.addColorStop(0, core(0.95));
      grad.addColorStop(corePart, core(0.7));
      grad.addColorStop(0.55, rim(0.86));
      grad.addColorStop(0.95, rim(0.6));
      grad.addColorStop(1, rim(0.54));
      ctx.globalAlpha = Math.min(1, bright);
      glowPath(ctx, gx, gy, r, e.shape);
      ctx.fillStyle = grad;
      ctx.fill();
      /*
       * The iris, for anger and defence: a camera's aperture closing over the
       * glow. A dark disc of blades whose edges run on past each corner of a
       * five-sided opening; the opening narrows to a pinpoint as `pupil`
       * goes to 1, the blades turning as it closes, and the light shows
       * through it.
       */
      if (iris > 0.01) {
        ctx.globalAlpha = Math.min(1, iris * 4);
        ctx.beginPath();
        ctx.arc(gx, gy, r * 1.03, 0, Math.PI * 2);
        ctx.fillStyle = IRIS;
        ctx.fill();
        const ap = r * (0.92 - 0.8 * iris);
        const turn = iris * 0.9;
        const vx = new Float32Array(5), vy = new Float32Array(5);
        for (let i = 0; i < 5; i++) {
          const a = turn - Math.PI / 2 + (i / 5) * Math.PI * 2;
          vx[i] = gx + Math.cos(a) * ap;
          vy[i] = gy + Math.sin(a) * ap;
        }
        ctx.globalAlpha = Math.min(1, bright);
        const hot = ctx.createRadialGradient(gx, gy, 0, gx, gy, ap);
        hot.addColorStop(0, core(0.55));
        hot.addColorStop(0.5, `rgb(${r0},${g0},${b0})`);
        hot.addColorStop(1, rim(0.8));
        ctx.beginPath();
        for (let i = 0; i < 5; i++) {
          if (i) ctx.lineTo(vx[i], vy[i]);
          else ctx.moveTo(vx[i], vy[i]);
        }
        ctx.closePath();
        ctx.fillStyle = hot;
        ctx.fill();
        /* the blades' edges: each side of the opening carried on to the rim */
        ctx.globalAlpha = Math.min(1, iris * 4);
        ctx.strokeStyle = IRIS_LINE;
        ctx.lineWidth = r * 0.035;
        ctx.beginPath();
        for (let i = 0; i < 5; i++) {
          const j = (i + 4) % 5;
          const dx = vx[i] - vx[j], dy = vy[i] - vy[j];
          const l = Math.hypot(dx, dy) || 1;
          /* how far along that line the disc's edge is */
          const px = vx[i] - gx, py = vy[i] - gy;
          const b = (px * dx + py * dy) / l;
          const reach = -b + Math.sqrt(Math.max(0, b * b - (px * px + py * py) + r * r));
          ctx.moveTo(vx[i], vy[i]);
          ctx.lineTo(vx[i] + (dx / l) * reach, vy[i] + (dy / l) * reach);
        }
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
    }
    this.drawLids(ctx, e, side, R, r);
    ctx.restore();

    /* the bloom: the glow lighting the air and the shell round the socket */
    if (open > 0.001 && bright > 0.001) {
      ctx.globalCompositeOperation = 'lighter';
      const a = 0.3 * Math.min(1.4, bright) * Math.min(1, open * 1.6) * (1 - Math.min(1, e.pupil) * 0.6) * (0.6 + 0.4 * facing);
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

