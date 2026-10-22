import bpy, sys, os, math, json, bmesh
from mathutils.bvhtree import BVHTree
from mathutils import Vector
args = sys.argv[sys.argv.index('--') + 1:]
D, OUTJSON, P = args[0], args[1], json.loads(args[2])
sys.argv = [sys.argv[0], '--', D, os.path.dirname(OUTJSON), json.dumps({**P, 'measure': 0})]
exec(open(os.path.join(os.path.dirname(__file__), 'assemble.py')).read().split('sc = setup_render(320)')[0])

S = 0.6 / 84.8          # head units per mm: the cranium is 0.6 wide
def to_ours(v):         # blender: x right, y back, z up → ours: x right, y down, z toward the viewer
    return (v.x * S, -v.z * S, -v.y * S)

out = {'scale': S, 'parts': {}}
_dg = bpy.context.evaluated_depsgraph_get()
_bm = bmesh.new(); _bm.from_object(head, _dg); _bm.transform(head.matrix_world)
TREE = BVHTree.FromBMesh(_bm)
for ob, target in [(head, P['headTris']), (chin, P['chinTris']), (fin, P['finTris'])]:
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True); bpy.context.view_layer.objects.active = ob
    n0 = len(ob.data.polygons)
    m = ob.modifiers.new('dec', 'DECIMATE'); m.decimate_type = 'COLLAPSE'
    m.ratio = min(1, target / n0); m.use_symmetry = True; m.symmetry_axis = 'X'
    m2 = ob.modifiers.new('tri', 'TRIANGULATE')
    dg = bpy.context.evaluated_depsgraph_get()
    me = ob.evaluated_get(dg).to_mesh()
    mw = ob.matrix_world
    nm = mw.to_3x3().inverted().transposed()
    verts = [to_ours(mw @ v.co) for v in me.vertices]
    tris, normals = [], []
    for p in me.polygons:
        tris.append(list(p.vertices))
        n = (nm @ p.normal).normalized()
        normals.append((n.x, -n.z, -n.y))
    out['parts'][ob.name] = {'v': verts, 't': tris, 'n': normals}
    print('PART', ob.name, n0, '->', len(tris), 'tris,', len(verts), 'verts')
    ob.evaluated_get(dg).to_mesh_clear()
# the eyes: where the face sits deeper than the head's round, a bowl round each hole
prof = [(1, 42.3), (40, 42.3), (50, 36.7), (60, 30.7), (66, 24.9), (70, 18.8), (73.7, 0)]
def radius(z):
    for (z0, r0), (z1, r1) in zip(prof, prof[1:]):
        if z <= z1: return r0 + (z - z0) / (z1 - z0) * (r1 - r0)
    return 0
eyes = []
step = 0.4
for side in (-1, 1):
    pts = []
    for ix in range(int(3 / step), int(40 / step)):
        x = side * ix * step
        for iz in range(int(25 / step), int(68 / step)):
            z = iz * step
            r = radius(z)
            if abs(x) > r - 2: continue
            hit = TREE.ray_cast(Vector((x, -100, z)), Vector((0, 1, 0)))
            expect = -math.sqrt(max(0, r * r - x * x))
            if hit[0] is None or hit[0].y > expect + 2.5:
                pts.append((x, z))
    cx = sum(p[0] for p in pts) / len(pts); cz = sum(p[1] for p in pts) / len(pts)
    rr = (len(pts) * step * step / math.pi) ** 0.5
    ez = -math.sqrt(max(0, radius(cz) ** 2 - cx * cx))
    eyes.append({'c': to_ours(Vector((cx, ez, cz))), 'r': rr * S})
    print('EYE', side, 'centre mm', round(cx, 2), round(cz, 2), 'bowl r', round(rr, 2), '-> ours', [round(a, 4) for a in to_ours(Vector((cx, ez, cz)))], 'r', round(rr * S, 4))
out['eyes'] = eyes
# the jaw's hinge, in our units
out['hinge'] = [-(P['pivotZ']) * S, -(P['pivotY']) * S]
json.dump(out, open(OUTJSON, 'w'))
print('WROTE', OUTJSON)
