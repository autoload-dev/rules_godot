"""Multi-ABI App Bundles carry the platform libraries their project and application select."""

import argparse
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from godot.platforms.private.tests.library_composition.android_apps import (
    apk_classes,
    bundle_tool_arguments,
    universal_apk,
)


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    bundle_tool_arguments(parser)
    parser.add_argument("--app", type=Path, required=True)
    return parser.parse_args(sys.argv[1:])


class AndroidBundlesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        args = _arguments()
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        work = Path(directory.name)
        (work / "app").mkdir()
        cls.manifest, universal = universal_apk(args, args.app, work / "app")
        with zipfile.ZipFile(universal) as apk:
            cls.names = set(apk.namelist())
            cls.pck = apk.getinfo("assets/main.pck")
            cls.classes = apk_classes(apk)

    def test_base_manifest_names_the_application_and_godots_activity(self) -> None:
        self.assertIn('package="org.example.rulesgodot"', self.manifest)
        self.assertIn("com.godot.game.GodotApp", self.manifest)

    def test_universal_apk_stores_the_pack_with_the_export_command_line(self) -> None:
        self.assertEqual(self.pck.compress_type, zipfile.ZIP_STORED)
        self.assertIn("assets/_cl_", self.names)

    def test_every_abi_gets_the_engine_and_the_extension(self) -> None:
        for library in (
            "lib/arm64-v8a/libgodot_android.so",
            "lib/arm64-v8a/libhello.so",
            "lib/x86_64/libgodot_android.so",
            "lib/x86_64/libhello.so",
        ):
            self.assertIn(library, self.names)

    def test_project_libraries_reach_the_dex_files(self) -> None:
        for name in (
            # Godot's template activity and the edge-to-edge support it calls.
            "androidx.activity.EdgeToEdge",
            "com.godot.game.GodotApp",
            "org.example.addon.Addon",
            "org.example.plugin.Plugin",
            # The shell library's dex reaches the APK through the runtime bridge.
            "org.godotengine.godot.Godot",
        ):
            self.assertIn(name, self.classes)

    def test_project_libraries_reach_the_manifest(self) -> None:
        for entry in (
            # Launchers start Godot's template activity through its alias.
            "com.godot.game.GodotAppLauncher",
            "org.example.addon.NAME",
            # The plugin AAR keeps its uses-permission entries.
            "android.permission.VIBRATE",
            # From the editor that exported the pack.
            "org.godotengine.editor.version",
            "4.7.2.stable",
        ):
            self.assertIn(entry, self.manifest)


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1])
