"""Desktop bundle layouts, deterministic archives and bundle path handling."""

import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

from tools.platforms import package_desktop
from tools.platforms.native_fixtures import elf


class PackageDesktopTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.runtime = self.root / "runtime"
        self.runtime.write_text("#!/bin/sh\nprintf '%s\\n' runtime-ok\n")
        self.pack = self.root / "game.pck"
        self.pack.write_bytes(b"GDPCfixture")
        self.infoplist = self.root / "Info.plist"
        self.infoplist.write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": "Game",
                    "CFBundleIdentifier": "org.example.game",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "4",
                }
            )
        )

    def package(
        self, operating_system: str, folder: str, **overrides: object
    ) -> argparse.Namespace:
        args = argparse.Namespace(
            operating_system=operating_system,
            runtime=str(self.runtime),
            cpu=None,
            pack=str(self.pack),
            output=str(self.root / folder),
            archive=str(self.root / (folder + ".archive")),
            app_name="Game",
            infoplist_base=str(self.infoplist),
            icons=None,
            manifest=None,
            resources=None,
        )
        for key, value in overrides.items():
            setattr(args, key, value)
        package_desktop.package(args)
        return args

    def test_macos_bundle_takes_the_rendered_icon_and_generated_metadata(self) -> None:
        icons = self.root / "icons"
        icons.mkdir()
        (icons / "icon.icns").write_bytes(b"icns")
        args = self.package("macos", "Icon.app", icons=str(icons))
        root = Path(args.output)
        info = plistlib.loads((root / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIconFile"], "icon.icns")
        self.assertEqual(info["CFBundleVersion"], "4")
        # The packager owns the executable's name.
        self.assertEqual(info["CFBundleExecutable"], "Game")
        self.assertEqual((root / "Contents/Resources/icon.icns").read_bytes(), b"icns")

    def test_macos_bundle_takes_resource_directories(self) -> None:
        localizations = self.root / "localizations"
        (localizations / "de.lproj").mkdir(parents=True)
        (localizations / "de.lproj/InfoPlist.strings").write_text("de")
        catalog = self.root / "catalog"
        catalog.mkdir()
        (catalog / "Assets.car").write_bytes(b"car")
        args = self.package(
            "macos", "Resources.app", resources=[str(localizations), str(catalog)]
        )
        resources = Path(args.output) / "Contents/Resources"
        self.assertEqual((resources / "de.lproj/InfoPlist.strings").read_text(), "de")
        self.assertEqual((resources / "Assets.car").read_bytes(), b"car")

    def test_macos_bundle_without_icon(self) -> None:
        args = self.package("macos", "Plain.app", icons=str(self.root / "missing"))
        info = plistlib.loads((Path(args.output) / "Contents/Info.plist").read_bytes())
        self.assertNotIn("CFBundleIconFile", info)

    def test_linux_can_execute_and_preserves_pack(self) -> None:
        args = self.package("linux", "Game.bundle")
        self.assertEqual(
            subprocess.check_output([str(Path(args.output) / "Game")]), b"runtime-ok\n"
        )
        with tarfile.open(args.archive) as archive:
            binary = archive.getmember("Game.bundle/Game")
            self.assertEqual(binary.mode, 0o755)
            self.assertEqual((binary.uid, binary.gid, binary.mtime), (0, 0, 0))
            pack = archive.extractfile("Game.bundle/Game.pck")
            assert pack is not None
            self.assertEqual(pack.read(), b"GDPCfixture")

    def test_macos_bundle_layout(self) -> None:
        args = self.package("macos", "Game.app")
        root = Path(args.output)
        info = plistlib.loads((root / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "org.example.game")
        self.assertEqual(info["CFBundleExecutable"], "Game")
        self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")
        self.assertEqual(info["CFBundleVersion"], "4")
        self.assertEqual(
            (root / "Contents/Resources/Game.pck").read_bytes(), b"GDPCfixture"
        )
        with zipfile.ZipFile(args.archive) as archive:
            entry = archive.getinfo("Game.app/Contents/MacOS/Game")
            self.assertEqual((entry.external_attr >> 16) & 0o777, 0o755)
            self.assertEqual(entry.date_time, (1980, 1, 1, 0, 0, 0))

    def test_archive_is_reproducible_across_source_mtime_changes(self) -> None:
        for operating_system, folder in [("linux", "Game.bundle"), ("macos", "Game.app")]:
            args = self.package(operating_system, folder)
            before = hashlib.sha256(Path(args.archive).read_bytes()).hexdigest()
            # Rebuild the same logical layout at another physical location.
            output = self.root / "second" / folder
            output.parent.mkdir(exist_ok=True)
            os.utime(self.runtime, (12345678, 12345678))
            args.output = str(output)
            args.archive += ".second"
            package_desktop.package(args)
            self.assertEqual(
                before, hashlib.sha256(Path(args.archive).read_bytes()).hexdigest()
            )

    def test_extension_libraries_and_collision(self) -> None:
        library = self.root / "libgame.so"
        library.write_bytes(b"native")
        manifest = self.root / "manifest.json"
        manifest.write_text(
            json.dumps([{"source": str(library), "destination": "native/libgame.so"}])
        )
        args = self.package("linux", "valid", manifest=str(manifest))
        self.assertEqual(
            (Path(args.output) / "native/libgame.so").read_bytes(), b"native"
        )
        manifest.write_text(
            json.dumps([{"source": str(library), "destination": "Game.pck"}])
        )
        with self.assertRaisesRegex(ValueError, "duplicate bundle destination"):
            self.package("linux", "collision", manifest=str(manifest))

    def test_extension_data_keeps_its_mode(self) -> None:
        handler = self.root / "crash_handler"
        handler.write_bytes(b"handler")
        handler.chmod(0o555)
        notice = self.root / "notice.txt"
        notice.write_bytes(b"notice")
        # Bazel marks every output executable: a generated descriptor keeps no mode.
        descriptor = self.root / "extension.gdextension"
        descriptor.write_bytes(b"[configuration]\n")
        descriptor.chmod(0o555)
        manifest = self.root / "data.json"
        manifest.write_text(
            json.dumps(
                [
                    {
                        "source": str(handler),
                        "destination": "crash_handler",
                        "keep_mode": True,
                    },
                    {
                        "source": str(notice),
                        "destination": "notice.txt",
                        "keep_mode": True,
                    },
                    {
                        "source": str(descriptor),
                        "destination": "extension.gdextension",
                    },
                ]
            )
        )
        args = self.package("linux", "Data.bundle", manifest=str(manifest))
        with tarfile.open(args.archive) as archive:
            self.assertEqual(archive.getmember("Data.bundle/crash_handler").mode, 0o755)
            self.assertEqual(archive.getmember("Data.bundle/notice.txt").mode, 0o644)
            self.assertEqual(
                archive.getmember("Data.bundle/extension.gdextension").mode, 0o644
            )

    def test_cpu_error_keeps_extension_context(self) -> None:
        library = self.root / "libwrong.so"
        library.write_bytes(elf(cpu="x86_64"))
        manifest = self.root / "wrong.json"
        manifest.write_text(
            json.dumps(
                [
                    {
                        "source": str(library),
                        "destination": "native/libwrong.so",
                        "context": "native/game.gdextension: linux arm64 none release",
                    }
                ]
            )
        )
        with self.assertRaisesRegex(
            ValueError,
            r"native/game.gdextension: linux arm64 none release.*libwrong.so.*CPU.*supply",
        ):
            self.package("linux", "wrong_cpu", manifest=str(manifest), cpu="arm64")

    def test_rejects_paths_outside_bundle(self) -> None:
        for destination in [
            "../escape",
            "/absolute",
            "native/../../escape",
            "native\\escape",
        ]:
            with self.subTest(destination=destination), self.assertRaises(ValueError):
                package_desktop.relative_path(destination)


if __name__ == "__main__":
    unittest.main()
