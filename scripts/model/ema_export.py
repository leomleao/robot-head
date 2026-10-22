import bpy, sys, os, math, json, bmesh
from mathutils import Vector
from mathutils.bvhtree import BVHTree
args = sys.argv[sys.argv.index('--') + 1:]
SRC, OUTJSON, P = args[0], args[1], json.loads(args[2])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.stl_import(filepath=SRC)
ob = bpy.context.selected_objects[0]
ob.rotation_euler = (0, 0, math.radians(90))
bpy.context.view_layer.objects.active = ob
bpy.ops.object.transform_apply(rotation=True)
vs = [v.co for v in ob.data.vertices]
mn = Vector([min(v[i] for v in vs) for i in range(3)]); mx = Vector([max(v[i] for v in vs) for i in range(3)])
# origin: the middle of the mouth line
mouth = mn.z + P['mouth']
ob.data.transform(__import__('mathutils').Matrix.Translation(Vector((-(mn.x + mx.x) / 2, -(mn.y + mx.y) / 2 - P.get('dy', 0), -mouth))))
ob.data.update()

def piece(lo, hi, name):
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True); bpy.context.view_layer.objects.active = ob
    bpy.ops.object.duplicate()
    d = bpy.context.selected_objects[0]; d.name = name
    bpy.ops.object.mode_set(mode='EDIT')
    bm = bmesh.from_edit_mesh(d.data)
    for z, keep_above in ((lo, True), (hi, False)):
        if z is None: continue
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        r = bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, z), plane_no=(0, 0, 1), clear_inner=keep_above, clear_outer=not keep_above)
        edges = [e for e in r['geom_cut'] if isinstance(e, bmesh.types.BMEdge)]
        if edges:
            try: bmesh.ops.holes_fill(bm, edges=edges, sides=0)
            except Exception as ex: print('fill failed', ex)
    bmesh.update_edit_mesh(d.data)
    bpy.ops.object.mode_set(mode='OBJECT')
    return d

scale = 0.6 / P['width']                  # head units per mm
cran = piece(0.0, None, 'head')
jaw = piece(-P['jaw'], 0.0, 'chin')
# the neck's rings reach up inside the band, and show below its shorter sides: drop them
if P.get('neckR'):
    bm2 = bmesh.new(); bm2.from_mesh(jaw.data)
    gone = [f for f in bm2.faces if math.hypot(f.calc_center_median().x, f.calc_center_median().y + P.get('neckDy', 0)) < P['neckR'] and f.calc_center_median().z < P['neckTop']]
    bmesh.ops.delete(bm2, geom=gone, context='FACES')
    bm2.to_mesh(jaw.data); jaw.data.update()
    print('neck faces dropped', len(gone))
ob.hide_set(True)

def to_ours(v): return (v.x * scale, -v.z * scale, -v.y * scale)

# eye bowls: where the face sits deeper than a round section of the cranium's width at that height
bm = bmesh.new(); bm.from_mesh(cran.data); tree = BVHTree.FromBMesh(bm)
def side(z):
    h = tree.ray_cast(Vector((50, 0, z)), Vector((-1, 0, 0)))
    return h[0].x if h[0] else 0
eyes = []
if P.get('eyes'):
    ex, ez, er = P['eyes']
    for s_ in (-1, 1):
        h = tree.ray_cast(Vector((s_ * ex, -50, ez + er * 1.15)), Vector((0, 1, 0)))
        eyes.append({'c': to_ours(Vector((s_ * ex, h[0].y, ez))), 'r': er * scale})
    print('EYES given', eyes)
step = 0.08
zs = [i * step for i in range(int(4 / step), int(18 / step))]
for s in ((-1, 1) if not P.get('eyes') else ()):
    pts = []
    for ix in range(int(1 / step), int(9 / step)):
        x = s * ix * step
        for z in zs:
            r = side(z)
            if abs(x) > r - 0.5: continue
            h = tree.ray_cast(Vector((x, -50, z)), Vector((0, 1, 0)))
            expect = -math.sqrt(max(0, r * r - x * x))
            if h[0] is None or h[0].y > expect + P.get('eyeDepth', 0.45):
                pts.append((x, z))
    cx = sum(p[0] for p in pts) / len(pts); cz = sum(p[1] for p in pts) / len(pts)
    rr = (len(pts) * step * step / math.pi) ** 0.5
    r = side(cz)
    ey = -math.sqrt(max(0, r * r - cx * cx))
    eyes.append({'c': to_ours(Vector((cx, ey, cz))), 'r': rr * scale})
    print('EYE', s, round(cx, 2), round(cz, 2), 'r', round(rr, 2), 'ours', [round(a, 4) for a in to_ours(Vector((cx, ey, cz)))], round(rr * scale, 4))

out = {'scale': scale, 'parts': {}}
for o, target in ((cran, P['headTris']), (jaw, P['chinTris'])):
    bpy.ops.object.select_all(action='DESELECT')
    o.select_set(True); bpy.context.view_layer.objects.active = o
    n0 = len(o.data.polygons)
    m = o.modifiers.new('dec', 'DECIMATE'); m.decimate_type = 'COLLAPSE'; m.ratio = min(1, target / n0); m.use_symmetry = True; m.symmetry_axis = 'X'
    o.modifiers.new('tri', 'TRIANGULATE')
    dg = bpy.context.evaluated_depsgraph_get()
    me = o.evaluated_get(dg).to_mesh()
    verts = [to_ours(v.co) for v in me.vertices]
    tris = [list(p.vertices) for p in me.polygons]
    # inside: a face whose outward rays mostly hit this same part again is enclosed
    # (the inside of the shell, the walls of the mouth and of the crest's slot)
    tb = BVHTree.FromPolygons([v.co.copy() for v in me.vertices], tris)
    dirs = []
    for p_ in me.polygons:
        n = p_.normal.normalized()
        a = n.orthogonal().normalized(); b = n.cross(a)
        hits = 0
        for k in range(7):
            ang = k * 2 * math.pi / 7
            d = (n + (a * math.cos(ang) + b * math.sin(ang)) * (0.0 if k == 0 else 0.6)).normalized()
            h = tb.ray_cast(p_.center + n * 0.02, d, P.get('insideReach', 30))
            if h[0] is not None: hits += 1
        # the caps across the cut at the mouth line are the dark of the mouth
        cap = abs(p_.center.z) < 0.08 and abs(n.z) > 0.9
        dirs.append(1 if hits >= 5 or cap else 0)
    print('inside', o.name, sum(dirs), '/', len(dirs))
    normals = [(p.normal.x, -p.normal.z, -p.normal.y) for p in me.polygons]
    out['parts'][o.name] = {'v': verts, 't': tris, 'n': normals, 'inside': dirs}
    zs2 = [v.co.z for v in me.vertices]
    print('PART', o.name, n0, '->', len(tris), 'z', round(min(zs2), 2), round(max(zs2), 2))
    o.evaluated_get(dg).to_mesh_clear()
out['parts']['head-fin'] = {'v': [], 't': [], 'n': []}
out['eyes'] = eyes
out['hinge'] = [-P['hingeZ'] * scale, -P['hingeY'] * scale]
json.dump(out, open(OUTJSON, 'w'))
print('WROTE', OUTJSON, 'scale', scale)
