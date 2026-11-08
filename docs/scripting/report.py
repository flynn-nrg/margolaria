# report.py: an example for Margolaria's scripting (docs/SCRIPTING.md).
#
# Run with File > Run Script… on any document: prints its materials with
# their shaders, the working space, the selection and the issues. Changes
# nothing, so it adds no undo step, and the document isn't marked edited.

import MaterialX as mx
import margolaria

doc = margolaria.document()
materials = doc.getMaterialNodes()
print(f"{len(materials)} material{'' if len(materials) == 1 else 's'}, in {margolaria.working_space()}:")
for material in materials:
    shaders = [shader.getCategory() for shader in mx.getShaderNodes(material)]
    print(f"  {material.getName()}: {', '.join(shaders) or 'no shader'}")
print("Selected:", ", ".join(margolaria.selection()) or "nothing")
issues = margolaria.issues()
print(f"{len(issues)} issue{'' if len(issues) == 1 else 's'}")
for issue in issues:
    print(f"  {issue.severity}: {issue.path or 'document'}: {issue.message}")
