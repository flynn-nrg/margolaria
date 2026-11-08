# list_materials.py: spike M6a (docs/spikes/M6a-python.md).
#
# Run with File > Run Script… on any document: prints Python's and
# MaterialX's versions and the document's materials, with their shaders.
# Changes nothing, so it adds no undo step (since M6b).

import sys

import MaterialX as mx
import margolaria

doc = margolaria.document()
print(f"Python {sys.version.split()[0]}, MaterialX {mx.__version__}")
materials = doc.getMaterialNodes()
print(f"{len(materials)} material{'' if len(materials) == 1 else 's'}:")
for material in materials:
    shaders = [shader.getCategory() for shader in mx.getShaderNodes(material)]
    print(f"  {material.getName()}: {', '.join(shaders) or 'no shader'}")
