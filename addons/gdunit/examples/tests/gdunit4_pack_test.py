"""Check what a pack with GdUnit4 leaves out: its editor scenes and its report templates."""

import sys
import unittest
from pathlib import Path

from tests.pck import pck_paths

PACK = Path(sys.argv[1])
sys.argv = sys.argv[:1]

# Godot instantiates scenes while packing; these create GdUnit's singletons.
EDITOR_SCENES = [
    "addons/gdUnit4/src/network/GdUnitServer.tscn",
    "addons/gdUnit4/src/ui/GdUnitConsole.tscn",
    "addons/gdUnit4/src/ui/GdUnitInspector.tscn",
]
# Their directory holds a .gdignore; GdUnit reads them through FileAccess.
TEMPLATES = "addons/gdUnit4/src/reporters/html/template/"


class GdUnit4PackTest(unittest.TestCase):
    def test_pack_holds_the_runtime_part_without_editor_scenes_or_templates(self) -> None:
        paths = pck_paths(PACK)
        script = "addons/gdUnit4/src/GdUnitTestSuite.gd"
        # Godot's export packs a script as tokens with a remap, a written pack as text.
        self.assertTrue({script, script + ".remap"} & set(paths), paths)
        for prefix in [*EDITOR_SCENES, TEMPLATES]:
            with self.subTest(prefix=prefix):
                self.assertEqual(
                    [path for path in paths if path.startswith(prefix)], [], paths
                )


if __name__ == "__main__":
    unittest.main()
