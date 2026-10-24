// The Iron Giant's shaders, as MSL source compiled at runtime (see PLAN.md §2
// for why). Everything here mirrors src/robot/render.ts and light.ts: the
// head's meshes lit per triangle, the ink outline, the floor's shadow, and
// each eye drawn analytically in its patch of the face.
//
// Colours are written sRGB-encoded (the TS's 2.2 curve) into a plain unorm
// target and blended there, as Canvas2D does, with premultiplied alpha.

enum Shaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// ── shared ─────────────────────────────────────────────────────────────

static float smooth01(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// the ACES-like curve, then the 2.2 encoding
static float display1(float x) {
    float t = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
    return pow(clamp(t, 0.0, 1.0), 1.0 / 2.2);
}
static float3 display3(float3 c) { return float3(display1(c.r), display1(c.g), display1(c.b)); }

// src over dst, premultiplied; `c` straight, `a` its coverage × alpha
static float4 over(float4 dst, float3 c, float a) {
    return float4(c * a, a) + dst * (1.0 - a);
}

// coverage of a shape from its signed distance (negative inside) and a pixel's size
static float cover(float sd, float px) {
    return clamp(0.5 - sd / px, 0.0, 1.0);
}

static float2 toClip(float2 px, float2 viewport) {
    return float2(px.x / viewport.x * 2.0 - 1.0, 1.0 - px.y / viewport.y * 2.0);
}

// ── the head ───────────────────────────────────────────────────────────

struct HeadUniforms {
    float4 r0, r1, r2;   // the rotation's rows
    float4 view;         // viewport w, h; centre x, y (px)
    float4 head;         // px per unit, drift x, drift y, pivot
    float4 jaw;          // cos, sin of the swing, drop, smile
    float4 hinge;        // hinge y, z, the jaw's top, 1 for the jaw
};

struct Material {
    float4 albedoF0;     // linear albedo, f0
    float4 p;            // metal, spec, shininess, rim
    float4 q;            // sheen, flat
};

struct Lighting {
    Material shell;
    Material dark;
    float4 inside;       // the cavity's colour, encoded
};

struct MeshVertex {
    packed_float3 pos;
    packed_float3 nrm;
    float grimeY;
    float material;
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float grimeY [[flat]];
    float material [[flat]];
};

// how far the jaw's top edge bends at a rest vertex: for a smile its middle
// sinks while the corners stay at the mouth line; for a frown the corners sink
static float smileOffset(float3 v, float smile, float jawTop) {
    if (abs(smile) < 1e-3 || v.z < 0.05) return 0.0;
    float near = 1.0 - clamp((v.y - jawTop) / 0.1, 0.0, 1.0);
    if (near <= 0.0) return 0.0;
    float across = min(1.0, abs(v.x) / 0.3);
    float front = min(1.0, v.z / 0.18);
    float shape = smile > 0.0 ? 1.0 - across * across : across * across;
    return abs(smile) * 0.075 * shape * near * front;
}

vertex MeshOut mesh_vertex(uint vid [[vertex_id]],
                           const device MeshVertex *verts [[buffer(0)]],
                           constant HeadUniforms &U [[buffer(1)]]) {
    MeshVertex v = verts[vid];
    float3 p = float3(v.pos);
    float3 n = float3(v.nrm);
    if (U.hinge.w > 0.5) {
        // the jaw: bend its top edge, then swing it down and back about its hinge
        p.y += smileOffset(p, U.jaw.w, U.hinge.z);
        float c = U.jaw.x, s = U.jaw.y;
        float hy = p.y - U.hinge.x, hz = p.z - U.hinge.y;
        p = float3(p.x, U.hinge.x + c * hy + s * hz + U.jaw.z, U.hinge.y - s * hy + c * hz);
        n = float3(n.x, c * n.y + s * n.z, -s * n.y + c * n.z);
    }
    // turn about the pivot, then drift
    float pivot = U.head.w;
    float3 q = float3(p.x, p.y - pivot, p.z);
    float3 w = float3(dot(U.r0.xyz, q), dot(U.r1.xyz, q) + pivot, dot(U.r2.xyz, q));
    float3 wn = float3(dot(U.r0.xyz, n), dot(U.r1.xyz, n), dot(U.r2.xyz, n));
    float2 px = U.view.zw + (w.xy + U.head.yz) * U.head.x;

    MeshOut o;
    o.position = float4(toClip(px, U.view.xy), 0.5 - w.z * 0.25, 1.0);
    // a face turned away is dropped, as the TS does: all three corners share the normal
    if (wn.z < -0.04) o.position = float4(2.0, 2.0, 2.0, 1.0);
    o.normal = wn;
    o.grimeY = v.grimeY;
    o.material = v.material;
    return o;
}

// the studio seen in a reflection along r
static float environment(float3 r, float3 key) {
    float up = -r.y;
    float horizon = 0.05 + 0.12 * smooth01(-0.25, 0.3, up);
    float softbox = 1.1 * smooth01(0.42, 0.78, up) * smooth01(-0.9, -0.2, r.z - 0.6 * abs(r.x));
    float window = 2.6 * smooth01(0.86, 0.97, dot(r, key));
    float strip = 0.5 * smooth01(0.6, 0.85, -r.x) * smooth01(-0.35, 0.05, up) * (1.0 - smooth01(0.2, 0.5, up));
    return horizon + softbox + window + strip;
}

static float3 radiance(Material m, float3 n) {
    const float3 KEY = normalize(float3(-0.5, -0.78, 0.62));
    const float3 FILL = normalize(float3(0.85, 0.15, 0.5));
    const float3 BACK = normalize(float3(0.55, -0.55, -0.62));
    const float3 HALF = normalize(float3(KEY.x, KEY.y, KEY.z + 1.0));
    float3 albedo = m.albedoF0.xyz;
    float f0 = m.albedoF0.w, metal = m.p.x, spec = m.p.y, shininess = m.p.z, rimK = m.p.w;
    float sheen = m.q.x, flatness = m.q.y;

    float ndl = dot(n, KEY);
    // a little wrap so the terminator is soft, like a moulded part
    float key = max(0.0, (ndl + 0.12) / 1.12);
    float fill = max(0.0, dot(n, FILL));
    float sky = 0.5 - 0.5 * n.y;
    float ndv = max(0.0, n.z);
    float fres = f0 + (1.0 - f0) * pow(1.0 - ndv, 5.0);
    // reflection of the view ray
    float3 r = float3(2.0 * ndv * n.x, 2.0 * ndv * n.y, 2.0 * ndv * n.z - 1.0);
    float env = environment(r, KEY) * fres * sheen;
    float sp = spec * pow(max(0.0, dot(n, HALF)), shininess);
    float b = max(0.0, dot(n, BACK));
    float rim = rimK * b * b * pow(1.0 - ndv, 1.6);
    float lit = 0.05 + 0.1 * sky + 1.25 * key + 0.16 * fill;
    float diffuse = lit + flatness * (0.62 - lit);
    float3 tint = 1.0 - metal + metal * albedo * 2.2;
    // the rim is a cool back light
    const float3 RIM_TINT = float3(0.62, 0.78, 1.0);
    return albedo * diffuse * (1.0 - fres * 0.6) + (env + sp) * tint + rim * RIM_TINT * (0.35 + albedo);
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]], constant Lighting &L [[buffer(0)]]) {
    // the inside of the head and the mouth: unlit, a cavity rather than a surface
    if (in.material > 1.5) return float4(L.inside.rgb, 1.0);
    Material m = in.material > 0.5 ? L.dark : L.shell;
    float3 c = radiance(m, normalize(in.normal));
    // grime toward the bottom, in the TS's six steps
    float ig = round(smooth01(-0.35, 0.3, in.grimeY) * 5.0);
    c *= 1.0 - 0.14 * (ig / 5.0);
    return float4(display3(c), 1.0);
}

// ── flat shapes in the head pass: the mouth's dark, the jaw's seams ────

struct FlatVertex {
    packed_float3 pos;
};

struct FlatOut {
    float4 position [[position]];
};

// the mouth plate and the inner wall, in model space through the head's turn
vertex FlatOut plate_vertex(uint vid [[vertex_id]],
                            const device FlatVertex *verts [[buffer(0)]],
                            constant HeadUniforms &U [[buffer(1)]]) {
    float3 p = float3(verts[vid].pos);
    float pivot = U.head.w;
    float3 q = float3(p.x, p.y - pivot, p.z);
    float3 w = float3(dot(U.r0.xyz, q), dot(U.r1.xyz, q) + pivot, dot(U.r2.xyz, q));
    FlatOut o;
    o.position = float4(toClip(U.view.zw + (w.xy + U.head.yz) * U.head.x, U.view.xy), 0.0, 1.0);
    return o;
}

fragment float4 plate_fragment(FlatOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return color;
}

// a line with round caps in screen px: the jaw panel's seams
struct LineUniforms {
    float4 ends;         // a.xy, b.xy (px)
    float4 style;        // width, alpha, viewport w, h
    float4 color;
};

struct LineOut {
    float4 position [[position]];
    float2 px;
};

vertex LineOut line_vertex(uint vid [[vertex_id]], constant LineUniforms &L [[buffer(0)]]) {
    float2 a = L.ends.xy, b = L.ends.zw;
    float2 d = b - a;
    float len = length(d);
    float2 t = len > 1e-4 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-t.y, t.x);
    float h = L.style.x * 0.5 + 1.0;
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 p = (corner.x < 0.0 ? a - t * h : b + t * h) + nrm * h * corner.y;
    LineOut o;
    o.position = float4(toClip(p, L.style.zw), 0.0, 1.0);
    o.px = p;
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]], constant LineUniforms &L [[buffer(0)]]) {
    float2 a = L.ends.xy, b = L.ends.zw;
    float2 pa = in.px - a, ba = b - a;
    float k = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    float sd = length(pa - ba * k) - L.style.x * 0.5;
    float a1 = cover(sd, 1.0) * L.style.y;
    return float4(L.color.rgb * a1, a1);
}

// ── the canvas: shadow, ink and head, then the eyes ────────────────────

struct QuadOut {
    float4 position [[position]];
    float2 local;
};

// a quad from a centre and two axes in px; `local` spans −1 … 1
struct QuadUniforms {
    float4 centerAxisX;  // centre px, x axis px
    float4 axisYView;    // y axis px, viewport w, h
};

vertex QuadOut quad_vertex(uint vid [[vertex_id]], constant QuadUniforms &Q [[buffer(0)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 p = Q.centerAxisX.xy + Q.centerAxisX.zw * corner.x + Q.axisYView.xy * corner.y;
    QuadOut o;
    o.position = float4(toClip(p, Q.axisYView.zw), 0.0, 1.0);
    o.local = corner;
    return o;
}

// the floor's shadow: a soft ellipse; `local` is already scaled to the ellipse
fragment float4 shadow_fragment(QuadOut in [[stage_in]], constant float4 &S [[buffer(0)]]) {
    float t = length(in.local);
    float a = S.x;
    float alpha = t < 0.55 ? mix(a, a * 0.45, t / 0.55) : mix(a * 0.45, 0.0, clamp((t - 0.55) / 0.45, 0.0, 1.0));
    return float4(0.0, 0.0, 0.0, alpha);
}

struct FullOut {
    float4 position [[position]];
};

vertex FullOut full_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

// the ink: the head's silhouette grown by `w` px in a dark line (eight
// offset copies laid over each other, as the TS does), under the head
struct InkUniforms {
    float4 ink;          // colour, width px
};

fragment float4 composite_fragment(FullOut in [[stage_in]],
                                   texture2d<float> head [[texture(0)]],
                                   constant InkUniforms &I [[buffer(0)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_zero, coord::pixel);
    float2 p = in.position.xy;
    float4 h = head.sample(lin, p);
    float w = I.ink.w;
    float clear = 1.0;
    for (int k = 0; k < 8; k++) {
        float a = float(k) / 8.0 * 2.0 * M_PI_F;
        clear *= 1.0 - head.sample(lin, p - float2(cos(a), sin(a)) * w).a;
    }
    float inkA = 1.0 - clear;
    float4 ink = float4(I.ink.rgb * inkA, inkA);
    return h + ink * (1.0 - h.a);
}

// ── the eyes ───────────────────────────────────────────────────────────

struct EyeUniforms {
    float4 axes;         // the face plane's x and y axes on screen, px per head unit
    float4 origin;       // the socket's centre px, the quad's half size (head units), socket radius R
    float4 glow;         // gaze x, y, glow radius r, shape (0 disc … 1 pentagon)
    float4 light;        // alpha min(1, bright), iris, the core's share, 1 when the glow shows
    float4 color;        // glow colour (0–1), bloom alpha
    float4 lids;         // yt, yb, slope, bow
    float4 lidColor;     // colour, span
    float4 seam;         // y, width, alpha, flags: 1 top lid, 2 bottom lid, 4 seam
    float4 seamColor;    // colour, the iris's aperture radius
    float4 iris;         // the aperture's turn, viewport w, h
};

static float pentagonRadius(float2 d) {
    // the radius of a regular pentagon, point up, with circumradius 1, toward d
    const float seg = 2.0 * M_PI_F / 5.0;
    float a = atan2(d.y, d.x);
    float k = fmod(fmod(a + M_PI_F / 2.0, seg) + seg, seg) - M_PI_F / 5.0;
    return cos(M_PI_F / 5.0) / cos(k);
}

// the two-point conical gradient Canvas2D draws from a point (r0 = 0) to a circle
static float conicalT(float2 p, float2 c0, float2 c1, float r1) {
    float2 q = p - c0, d = c1 - c0;
    float a = dot(d, d) - r1 * r1;
    float qd = dot(q, d);
    if (abs(a) < 1e-9) return dot(q, q) / max(2.0 * qd, 1e-9);
    return (qd - sqrt(max(0.0, qd * qd - a * dot(q, q)))) / a;
}

static float3 stops5(float t, float3 c0, float t1, float3 c1, float t2, float3 c2, float t3, float3 c3, float3 c4) {
    t = clamp(t, 0.0, 1.0);
    if (t < t1) return mix(c0, c1, t / t1);
    if (t < t2) return mix(c1, c2, (t - t1) / (t2 - t1));
    if (t < t3) return mix(c2, c3, (t - t2) / (t3 - t2));
    return mix(c3, c4, (t - t3) / (1.0 - t3));
}

static float segmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float k = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-12), 0.0, 1.0);
    return length(pa - ba * k);
}

vertex QuadOut eye_vertex(uint vid [[vertex_id]], constant EyeUniforms &E [[buffer(0)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 local = corner * E.origin.z;
    float2 p = E.origin.xy + E.axes.xy * local.x + E.axes.zw * local.y;
    QuadOut o;
    o.position = float4(toClip(p, E.iris.yz), 0.0, 1.0);
    o.local = local;
    return o;
}

fragment float4 eye_fragment(QuadOut in [[stage_in]], constant EyeUniforms &E [[buffer(0)]]) {
    const float3 SOCKET = float3(6.0, 5.0, 4.0) / 255.0;
    const float3 IRIS = float3(35.0, 27.0, 29.0) / 255.0;
    const float3 IRIS_LINE = float3(90.0, 75.0, 78.0) / 255.0;

    float2 p = in.local;
    // one pixel, in head units
    float px = max(length(float2(dfdx(p.x), dfdy(p.x))), length(float2(dfdx(p.y), dfdy(p.y))));
    px = max(px, 1e-6);
    float R = E.origin.w;
    float2 g = E.glow.xy;
    float r = E.glow.z;
    float3 col = E.color.rgb;

    // the socket
    float4 out = over(float4(0.0), SOCKET, cover(length(p - float2(0.003, 0.004)) - R, px));

    // inside the socket's rim: the glow, the iris, the lids
    float4 inner = float4(0.0);
    if (E.light.w > 0.5) {
        // the disc: hot white at the core, the colour toward its edge
        float3 core95 = col + (1.0 - col) * 0.95, core70 = col + (1.0 - col) * 0.7;
        float3 rimTint = float3(1.0, 0.9, 0.82);
        float3 rim86 = col * 0.86 * rimTint, rim60 = col * 0.6 * rimTint, rim54 = col * 0.54 * rimTint;
        float2 d = p - g;
        float radius = r * (1.0 + (pentagonRadius(d) * 0.92 - 1.0) * E.glow.w);
        float t = conicalT(p, g + float2(0.0, r * 0.1), g, r);
        float corePart = E.light.z;
        float3 gc = stops5(t, core95, corePart, core70, 0.55, rim86, 0.95, rim60, rim54);
        inner = over(inner, gc, cover(length(d) - radius, px) * E.light.x);

        // the iris: a camera's aperture closing over the glow
        float iris = E.light.y;
        if (iris > 0.01) {
            float ia = min(1.0, iris * 4.0);
            inner = over(inner, IRIS, cover(length(d) - r * 1.03, px) * ia);
            float ap = E.seamColor.w, turn = E.iris.x;
            float2 v[5];
            for (int i = 0; i < 5; i++) {
                float a = turn - M_PI_F / 2.0 + float(i) / 5.0 * 2.0 * M_PI_F;
                v[i] = g + float2(cos(a), sin(a)) * ap;
            }
            // inside the pentagon: the largest signed distance to its edges
            float sd = -1e9;
            for (int i = 0; i < 5; i++) {
                float2 a = v[(i + 4) % 5], b = v[i];
                float2 e = normalize(b - a);
                float2 nrm = float2(e.y, -e.x);
                // outward is away from the centre
                if (dot(nrm, (a + b) * 0.5 - g) < 0.0) nrm = -nrm;
                sd = max(sd, dot(p - a, nrm));
            }
            float3 hot = stops5(length(d) / ap, col + (1.0 - col) * 0.55, 0.25, col + (1.0 - col) * 0.275, 0.5, col, 0.75, mix(col, col * 0.8 * rimTint, 0.5), col * 0.8 * rimTint);
            inner = over(inner, hot, cover(sd, px) * E.light.x);
            // the blades' edges: each side of the opening carried on to the rim
            float line = 1e9;
            for (int i = 0; i < 5; i++) {
                float2 a = v[(i + 4) % 5], b = v[i];
                float2 e = b - a;
                float l = max(length(e), 1e-9);
                float2 u = e / l;
                float2 pv = b - g;
                float bb = dot(pv, u);
                float reach = -bb + sqrt(max(0.0, bb * bb - dot(pv, pv) + r * r));
                line = min(line, segmentDistance(p, b, b + u * reach));
            }
            inner = over(inner, IRIS_LINE, cover(line - r * 0.0175, px) * ia);
        }
    }

    // the lids: dark plates over the disc from above and below
    float flags = E.seam.w;
    float3 lid = E.lidColor.rgb;
    float yt = E.lids.x, yb = E.lids.y, slope = E.lids.z, bow = E.lids.w, span = E.lidColor.w;
    if (fmod(flags, 2.0) >= 1.0) {
        float sd = (p.y - (yt + slope * p.x)) / sqrt(1.0 + slope * slope);
        inner = over(inner, lid, cover(sd, px));
    }
    if (fmod(flags, 4.0) >= 2.0) {
        float k = p.x / span;
        float edge = yb - bow * (1.0 - k * k);
        float slopeB = 2.0 * bow * p.x / (span * span);
        float sd = (edge - p.y) / sqrt(1.0 + slopeB * slopeB);
        inner = over(inner, lid, cover(sd, px));
    }
    if (flags >= 4.0) {
        // the seam between the shut lids
        float sd = abs(p.y - E.seam.x) - E.seam.y * 0.5;
        inner = over(inner, E.seamColor.rgb, cover(sd, px) * E.seam.z);
    }
    float clip = cover(length(p) - R * 0.985, px);
    return inner * clip + out * (1.0 - inner.a * clip);
}

// the bloom: the glow lighting the air and the shell round the socket, added
fragment float4 bloom_fragment(QuadOut in [[stage_in]], constant EyeUniforms &E [[buffer(0)]]) {
    float2 p = in.local;
    float R = E.origin.w, r = E.glow.z;
    float d = length(p - E.glow.xy);
    float inner = r * 0.6, outer = R * 1.7;
    if (d > outer) return float4(0.0);
    float t = clamp((d - inner) / (outer - inner), 0.0, 1.0);
    float a = E.color.w;
    float alpha = t < 0.4 ? mix(a, a * 0.2, t / 0.4) : mix(a * 0.2, 0.0, (t - 0.4) / 0.6);
    return float4(E.color.rgb * alpha, alpha);
}
"""#
}
