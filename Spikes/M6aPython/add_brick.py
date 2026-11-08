# add_brick.py: spike M6a (docs/spikes/M6a-python.md).
#
# Run with File > Run Script…: adds a brick-red material to the document,
# an open_pbr_surface whose roughness reads a checkerboard tiled 8×8. It
# appears in the graph and the viewport, and Edit > Undo "Run add_brick.py"
# takes all of it back in one step.

import MaterialX as mx
import margolaria

doc = margolaria.document()

name = doc.createValidChildName("brick")
shader = doc.addNode("open_pbr_surface", name + "_surface", mx.SURFACE_SHADER_TYPE_STRING)
shader.setInputValue("base_color", mx.Color3(0.55, 0.22, 0.13))

checker = doc.addNode("checkerboard", name + "_checker", "color3")
checker.setInputValue("uvtiling", mx.Vector2(8.0, 8.0))
roughness = doc.addNode("extract", name + "_roughness", "float")
roughness.setConnectedNode("in", checker)
shader.setConnectedNode("specular_roughness", roughness)

material = doc.addMaterialNode(name, shader)
print(f"Added {material.getName()}.")
