import bpy, os, math
from mathutils import Vector, Euler

def load(D, n):
    bpy.ops.wm.stl_import(filepath=os.path.join(D, n + '.stl'))
    ob = bpy.context.selected_objects[0]
    ob.name = n
    return ob

def setup_render(size=360):
    sc = bpy.context.scene
    sc.render.engine = 'BLENDER_WORKBENCH'
    sc.display.shading.light = 'STUDIO'
    sc.display.shading.color_type = 'OBJECT'
    sc.render.resolution_x = sc.render.resolution_y = size
    return sc

def shoot(sc, path, loc, target=(0, 0, 0), scale=150):
    cam = sc.camera
    if cam is None:
        cd = bpy.data.cameras.new('c'); cd.type = 'ORTHO'
        cam = bpy.data.objects.new('c', cd); sc.collection.objects.link(cam); sc.camera = cam
    cam.data.ortho_scale = scale
    cam.location = Vector(loc) + Vector(target)
    d = Vector(target) - cam.location
    cam.rotation_euler = d.to_track_quat('-Z', 'Z' if abs(d.normalized().z) > 0.99 else 'Y').to_euler() if abs(d.normalized().z) <= 0.99 else d.to_track_quat('-Z', 'Y').to_euler()
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
