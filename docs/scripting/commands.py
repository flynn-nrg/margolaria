# commands.py: an example startup script for Margolaria (docs/SCRIPTING.md).
#
# Copy it into ~/Library/Application Support/Margolaria/Scripts (Scripts >
# Open Scripts Folder), then choose Scripts > Reload Startup Scripts, or
# restart Margolaria. Its two commands appear in the Scripts menu and in
# the command palette (⌘K). A startup script has no document: it only
# registers the commands, which run on the front window's document when
# chosen.

import margolaria


@margolaria.command("Add Brick Material")
def add_brick_material():
    # One undo step, "Undo Add Brick Material".
    shader = margolaria.add_node("ND_standard_surface_surfaceshader", name="brick_shader")
    material = margolaria.add_node("ND_surfacematerial", name="brick")
    margolaria.set_value(shader, "base_color", (0.6, 0.25, 0.15))
    margolaria.set_value(shader, "specular_roughness", 0.6)
    margolaria.connect(material, "surfaceshader", shader)
    margolaria.select(material)


@margolaria.command("Print Issues")
def print_issues():
    # Only reads: no undo step. What it prints appears in the Console tab.
    issues = margolaria.issues()
    print(f"{len(issues)} issue{'' if len(issues) == 1 else 's'}")
    for issue in issues:
        print(f"  {issue.severity}: {issue.path or 'document'}: {issue.message}")
