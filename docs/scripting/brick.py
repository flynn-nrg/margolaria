# brick.py: an example for Margolaria's scripting (docs/SCRIPTING.md).
#
# Run with File > Run Script… on any document. Builds a brick material from
# nothing: a standard_surface whose base colour reads an image, and whose
# roughness is set with MaterialX's own API. Two undo steps: "Run brick.py"
# (the material), then "Tint Bricks" (a block of its own). The material is
# selected on the canvas at the end, and the issues are printed: in a saved
# document, a warning that the image (brick.png, beside the file) isn't
# there; none in a new one, whose images have no folder to be found in.

import MaterialX as mx
import margolaria

# The editor's edits: nodes from their nodedefs, with the editor's checks.
shader = margolaria.add_node("ND_standard_surface_surfaceshader", name="brick_shader")
material = margolaria.add_node("ND_surfacematerial", name="brick")
texture = margolaria.add_node("ND_image_color3", name="brick_color")
margolaria.set_value(texture, "file", "brick.png")
margolaria.connect(shader, "base_color", texture)
margolaria.connect(material, "surfaceshader", shader)

# MaterialX's API, on the same document.
doc = margolaria.document()
doc.getNode(shader).setInputValue("specular_roughness", 0.7)

# A step of its own, undone before the material.
with margolaria.edit("Tint Bricks"):
    tint = margolaria.add_node("ND_multiply_color3", name="brick_tint")
    margolaria.connect(tint, "in1", texture)
    margolaria.set_value(tint, "in2", mx.Color3(1.0, 0.85, 0.8))
    margolaria.connect(shader, "base_color", tint)

# Refused edits raise margolaria.EditRefused, and change nothing.
try:
    margolaria.connect(shader, "base", texture)
except margolaria.EditRefused as refusal:
    print("Refused, as expected:", refusal)

margolaria.select(material)
for issue in margolaria.issues():
    print(f"{issue.severity}: {issue.path}: {issue.message}")
