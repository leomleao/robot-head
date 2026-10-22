import bpy, sys, os, math, json
from mathutils import Vector
sys.path.insert(0, os.path.dirname(__file__))
from common import *
args = sys.argv[sys.argv.index('--') + 1:]
D, OUT, P = args[0], args[1], json.loads(args[2])

def bbox(ob):
    vs = [ob.matrix_world @ v.co for v in ob.data.vertices]
    return Vector([min(v[i] for v in vs) for i in range(3)]), Vector([max(v[i] for v in vs) for i in range(3)])

bpy.ops.wm.read_factory_settings(use_empty=True)
head = load(D, 'head'); chin = load(D, 'chin'); fin = load(D, 'head-fin')
for ob in (head, chin, fin):
    bpy.context.view_layer.objects.active = ob
    ob.select_set(True)
    bpy.ops.object.origin_set(type='ORIGIN_GEOMETRY', center='BOUNDS')
    ob.select_set(False)
# the head: centred on x and y, bottom on z = 0
hmn, hmx = bbox(head)
head.location -= Vector(((hmn.x + hmx.x) / 2, (hmn.y + hmx.y) / 2, hmn.z))
bpy.context.view_layer.update()
hmn, hmx = bbox(head)
# the fin: in the slot, its top just proud of the dome
fin.location = Vector((0, 0, 0))
bpy.context.view_layer.update()
fmn, fmx = bbox(fin)
fin.location = Vector((-(fmn.x + fmx.x) / 2 + P['finX'], -(fmn.y + fmx.y) / 2 + P['finY'], hmx.z + P['finProud'] - fmx.z))
# the chin: turned upright, its pivots at the given point
chin.rotation_euler = (math.radians(90), 0, 0)
chin.location = Vector((0, 0, 0))
bpy.context.view_layer.update()
# the pivot pins: the vertices furthest out on x
vs = [chin.matrix_world @ v.co for v in chin.data.vertices]
xm = max(abs(v.x) for v in vs)
pins = [v for v in vs if abs(v.x) > xm - 3]
pc = Vector((0, sum(v.y for v in pins) / len(pins), sum(v.z for v in pins) / len(pins)))
chin.location = Vector((0, P['pivotY'], P['pivotZ'])) - pc
chin.rotation_euler.x += math.radians(P.get('jawOpen', 0))
head.color = (0.45, 0.43, 0.42, 1); chin.color = (0.5, 0.42, 0.4, 1); fin.color = (0.4, 0.45, 0.5, 1)
bpy.context.view_layer.update()
cmn, cmx = bbox(chin)
print('HEAD', tuple(round(a, 1) for a in hmn), tuple(round(a, 1) for a in hmx))
print('CHIN', tuple(round(a, 1) for a in cmn), tuple(round(a, 1) for a in cmx), 'pins at', tuple(round(a, 1) for a in pc))
sc = setup_render(320)
tgt = (0, 0, 30)
for v, loc in [('front', (0, -400, 0)), ('side', (400, 0, 0)), ('q', (230, -320, 60)), ('below', (120, -330, -170))]:
    shoot(sc, os.path.join(OUT, f'asm_{v}.png'), loc, target=tgt, scale=140)

# ── measure the eye holes: rays from the front, along +y ──
from mathutils.bvhtree import BVHTree
import bmesh
if P.get('measure'):
    dg = bpy.context.evaluated_depsgraph_get()
    bm = bmesh.new(); bm.from_object(head, dg); bm.transform(head.matrix_world)
    tree = BVHTree.FromBMesh(bm)
    deep = []
    step = 0.5
    for ix in range(int(-40 / step), int(40 / step)):
        for iz in range(int(30 / step), int(68 / step)):
            x, z = ix * step, iz * step
            hit = tree.ray_cast(Vector((x, -100, z)), Vector((0, 1, 0)))
            if hit[0] is None: continue
            y = hit[0].y
            # the surface near the eyes is at about y = -40; a hole shows the far wall
            deep.append((x, z, y))
    front = {}
    for x, z, y in deep: front[(x, z)] = y
    holes = [(x, z) for (x, z), y in front.items() if y > -20]
    for side in (-1, 1):
        pts = [(x, z) for x, z in holes if x * side > 3]
        if not pts: continue
        cx = sum(p[0] for p in pts) / len(pts); cz = sum(p[1] for p in pts) / len(pts)
        r = (len(pts) * step * step / math.pi) ** 0.5
        # the surface depth around the hole, and its normal, from neighbours
        ring = [front.get((round((cx + (r + 2) * math.cos(a)) / step) * step, round((cz + (r + 2) * math.sin(a)) / step) * step)) for a in [i * math.pi / 8 for i in range(16)]]
        ring = [v for v in ring if v is not None and v < -20]
        print('EYE', side, round(cx, 2), round(cz, 2), 'r', round(r, 2), 'surfaceY', round(sum(ring) / max(1, len(ring)), 2))
    # the front profile at the mouth line and at the eyes, for drawing on the surface
    for z in (1, 10, 20, 30, 40, 50, 60, 66, 70):
        row = []
        for x in range(-40, 41, 5):
            hit = tree.ray_cast(Vector((x, -100, z)), Vector((0, 1, 0)))
            row.append(round(hit[0].y, 1) if hit[0] else None)
        print('FRONT z', z, row)
