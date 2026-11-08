"""Rebuild the original website artwork: blender -b -t 4 --python scripts/website/render-usb.py"""
import bpy, math
from pathlib import Path
from mathutils import Vector
ROOT = Path(__file__).resolve().parents[2]
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
def material(name, color, metal=0, rough=.4):
    m=bpy.data.materials.new(name); m.diffuse_color=(*color,1); m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF'); p.inputs['Base Color'].default_value=(*color,1); p.inputs['Metallic'].default_value=metal; p.inputs['Roughness'].default_value=rough
    return m
orange=material('Burnt orange anodized shell',(.84,.18,.055),.35,.3)
silver=material('Brushed aluminum',(.58,.64,.7),.85,.27)
dark=material('Connector recess',(.028,.035,.045),.25)
ink=material('Warm white engraving',(.94,.88,.75))
gold=material('Contacts',(.8,.49,.12),.75)
def box(name, loc, scale, mat, bevel=.08):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc); o=bpy.context.object; o.name=name; o.dimensions=scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    o.data.materials.append(mat)
    if bevel:
        b=o.modifiers.new('Machined rounded edges','BEVEL'); b.width=bevel; b.segments=6
        o.modifiers.new('Weighted normals','WEIGHTED_NORMAL')
    return o
box('USB body',(0,-.45,0),(1.7,3.1,.52),orange,.22)
box('End seam',(0,-1.85,0),(1.5,.06,.36),dark,.02)
box('USB A connector',(0,1.65,0),(1.24,1.35,.4),silver,.06)
for x in [-.34,.34]: box('Connector retention hole',(x,1.65,.205),(.27,.32,.014),dark,.025)
box('Connector front opening',(0,2.327,0),(.99,.014,.22),dark,.015)
for x in [-.33,-.11,.11,.33]: box('Gold contact',(x,2.34,-.045),(.1,.025,.05),gold,.005)
def label(text,loc,size,mat):
    bpy.ops.object.text_add(location=loc); o=bpy.context.object; o.data.body=text; o.data.size=size; o.data.extrude=.001; o.data.materials.append(mat); return o
label('rufus',( -.59,-.15,.268),.38,ink)
label('4mac',(-.57,-.49,.268),.24,ink)
label('BOOT / CREATE',(-.57,-1.48,.267),.10,ink)
# A subtle engraved status bar.
box('LED recess',(.53,.55,.265),(.19,.055,.013),dark,.02)
box('LED',(.53,.55,.28),(.09,.025,.01),ink,.008)
world=bpy.context.scene.world; world.use_nodes=True; world.node_tree.nodes['Background'].inputs[0].default_value=(.5,.56,.65,1); world.node_tree.nodes['Background'].inputs[1].default_value=.5
def area(name,loc,power,size,color):
    bpy.ops.object.light_add(type='AREA', location=loc); o=bpy.context.object; o.name=name; o.data.energy=power; o.data.shape='DISK'; o.data.size=size; o.data.color=color; o.rotation_euler=(Vector((0,0,0))-o.location).to_track_quat('-Z','Y').to_euler()
area('Large softbox',(-3,-4,7),650,5,(1,.91,.82)); area('Cool rim',(4,3,5),850,4,(.78,.87,1)); area('Front fill',(1,-5,2),160,3,(1,.65,.4))
bpy.ops.object.camera_add(location=(5,-7,9)); camera=bpy.context.object; camera.rotation_euler=(Vector((0,.2,0))-camera.location).to_track_quat('-Z','Y').to_euler(); camera.data.type='ORTHO'; camera.data.ortho_scale=6.1
scene=bpy.context.scene; scene.camera=camera; scene.render.engine='CYCLES'; scene.cycles.samples=64; scene.cycles.use_denoising=True
scene.render.resolution_x=1200; scene.render.resolution_y=1200; scene.render.resolution_percentage=100; scene.render.film_transparent=True
scene.render.image_settings.file_format='PNG'; scene.render.filepath=str(ROOT/'website/assets/usb-render.png')
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'scripts/website/usb-scene.blend'))
bpy.ops.render.render(write_still=True)
