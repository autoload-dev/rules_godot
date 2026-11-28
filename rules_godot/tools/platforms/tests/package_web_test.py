"""Tests of the web packager over a stand-in template, pack and facts."""

import json
import shutil
import tempfile
import unittest
import zipfile
from argparse import Namespace
from pathlib import Path

from tools.platforms import package_web
from tools.platforms.shell_common import Facts

_SHELL = """<title>$GODOT_PROJECT_NAME</title>
$GODOT_HEAD_INCLUDE
<body style="background:$GODOT_SPLASH_COLOR" class="$GODOT_SPLASH_CLASSES"><img src="$GODOT_SPLASH">
<script src="$GODOT_URL"></script>
<script>const GODOT_CONFIG = $GODOT_CONFIG; const threads = $GODOT_THREADS_ENABLED;</script>
"""

_FACTS = {
    "options": {
        "html/canvas_resize_policy": 1,
        "html/experimental_virtual_keyboard": False,
        "html/focus_canvas_on_start": False,
        "html/export_icon": True,
        "html/head_include": '<meta name="theme-color" content="#242424">',
        "progressive_web_app/ensure_cross_origin_isolation_headers": True,
        "threads/godot_pool_size": 4,
        "threads/emscripten_pool_size": 8,
        "variant/thread_support": False,
    },
    "settings": {
        "application/config/name": "Game",
        "application/boot_splash/bg_color": [0.2, 0.4, 0.6, 1.0],
        "application/boot_splash/show_image": True,
        "application/boot_splash/stretch_mode": 1,
        "application/boot_splash/use_filter": False,
    },
    "versions": {},
    "name_translations": {},
}


class PageTest(unittest.TestCase):
    def test_placeholders_follow_the_export_as_godot_fills_them(self) -> None:
        page = package_web.page(_SHELL, Facts(_FACTS), {"index.pck": 3, "index.wasm": 5})
        self.assertIn("<title>Game</title>", page)
        self.assertIn(
            'href="index.icon.png" />\n<link rel="apple-touch-icon" href="index.apple-touch-icon.png"/>\n<meta name="theme-color"',
            page,
        )
        self.assertIn(
            'background:#336699" class="show-image--true fullsize--true use-filter--false"><img src="index.png">',
            page,
        )
        self.assertIn(
            'const GODOT_CONFIG = {"args":[],"canvasResizePolicy":1,"emscriptenPoolSize":8,'
            '"ensureCrossOriginIsolationHeaders":true,"executable":"index","experimentalVK":false,'
            '"fileSizes":{"index.pck":3,"index.wasm":5},"focusCanvas":false,"gdextensionLibs":[],'
            '"godotPoolSize":4}; const threads = false;',
            page,
        )

    def test_every_line_ends_with_a_newline_as_godots_replacement_writes_it(self) -> None:
        self.assertEqual("a\nb\n\n", package_web.page("a\nb\n", Facts(_FACTS), {}))


class ExportTest(unittest.TestCase):
    def test_files_are_named_after_the_page(self) -> None:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        runtime = root / "template"
        runtime.mkdir()
        for name in [
            "godot.js",
            "godot.wasm",
            "godot.audio.worklet.js",
            "godot.service.worker.js",
            "godot.offline.html",
        ]:
            (runtime / name).write_text(name)
        (runtime / "godot.html").write_text(_SHELL)
        images = root / "images"
        images.mkdir()
        for name in ["icon.png", "apple-touch-icon.png", "splash.png"]:
            (images / name).write_text(name)
        (root / "pack.pck").write_text("pck")
        (root / "facts.json").write_text(json.dumps(_FACTS))
        package_web.export(
            Namespace(
                runtime=runtime,
                pack=root / "pack.pck",
                facts=root / "facts.json",
                images=images,
                shell=None,
                output=root / "site",
                archive=root / "site.zip",
            )
        )
        names = sorted(path.name for path in (root / "site").iterdir())
        self.assertEqual(
            [
                "index.apple-touch-icon.png",
                "index.audio.worklet.js",
                "index.html",
                "index.icon.png",
                "index.js",
                "index.pck",
                "index.png",
                "index.wasm",
            ],
            names,
        )
        self.assertEqual(names, sorted(zipfile.ZipFile(root / "site.zip").namelist()))


if __name__ == "__main__":
    unittest.main()
