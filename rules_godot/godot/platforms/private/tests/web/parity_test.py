"""
Compare the ruleset's web export of a project with Godot's own export of it.

Godot's editor exports the project's files with the same template and export options. Both
exports have the same files; every file but the PCK and the page is the same, and the page
is the same once the PCK's size, which the export of each writes into it, agrees.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

# The pack's export options in the fixture's BUILD.bazel, as export_presets.cfg writes them.
_OPTIONS = {
    "html/canvas_resize_policy": "1",
    "html/focus_canvas_on_start": "false",
    "html/head_include": '"<meta name=\\"theme-color\\" content=\\"#242424\\">"',
}

_PCK_SIZE = re.compile(r'"index\.pck":\d+')

ARGS: argparse.Namespace


def _directory(paths: list[str], member: str) -> Path:
    """The directory among paths that holds member, or the one directory."""
    for path in map(Path, paths):
        if path.is_dir() and (path / member).exists():
            return path
        if path.name == member:
            return path.parent
    raise AssertionError(f"no {member} in {paths}")


def _godot_export(work: Path) -> Path:
    project = work / "project"
    project.mkdir()
    for source in ARGS.project:
        shutil.copy(source, project / Path(source).name)
    template = work / "template.zip"
    runtime = _directory(ARGS.runtime, "godot.wasm")
    with zipfile.ZipFile(template, "w") as archive:
        for file in sorted(runtime.iterdir()):
            archive.write(file, file.name)
    options = {
        "custom_template/debug": json.dumps(str(template)),
        "custom_template/release": json.dumps(str(template)),
    } | _OPTIONS
    (project / "export_presets.cfg").write_text(
        '[preset.0]\n\nname="Web"\nplatform="Web"\nrunnable=true\n'
        'export_filter="all_resources"\nexport_path="out/index.html"\n\n[preset.0.options]\n\n'
        + "".join(f"{key}={value}\n" for key, value in options.items())
    )
    out = work / "out"
    out.mkdir()
    environment = dict(
        os.environ, HOME=str(work), XDG_DATA_HOME=str(work), XDG_CONFIG_HOME=str(work)
    )
    for step in (["--import"], ["--export-release", "Web", str(out / "index.html")]):
        result = subprocess.run(
            [ARGS.editor, "--headless", "--path", str(project), *step],
            env=environment,
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"Godot's {step[0]} failed:\n{result.stdout}\n{result.stderr}"
            )
    return out


class WebExportParityTest(unittest.TestCase):
    def test_files_and_page_match_godots_export(self) -> None:
        ours = _directory(ARGS.app, "index.html")
        with tempfile.TemporaryDirectory() as work:
            theirs = _godot_export(Path(work))
            self.assertEqual(
                sorted(path.name for path in theirs.iterdir()),
                sorted(path.name for path in ours.iterdir()),
            )
            for path in sorted(theirs.iterdir()):
                if path.name in ("index.pck", "index.html"):
                    continue
                with self.subTest(file=path.name):
                    self.assertEqual(path.read_bytes(), (ours / path.name).read_bytes())
            size = f'"index.pck":{(ours / "index.pck").stat().st_size}'
            self.assertEqual(
                _PCK_SIZE.sub(size, (theirs / "index.html").read_text()),
                (ours / "index.html").read_text(),
            )


def main() -> None:
    global ARGS
    parser = argparse.ArgumentParser()
    for name in ("app", "runtime", "project"):
        parser.add_argument(f"--{name}", nargs="+", required=True)
    parser.add_argument("--editor", required=True)
    ARGS, rest = parser.parse_known_args()
    unittest.main(argv=[sys.argv[0], *rest])


if __name__ == "__main__":
    main()
