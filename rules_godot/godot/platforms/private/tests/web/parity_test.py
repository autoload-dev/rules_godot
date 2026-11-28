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

# The line of the service worker that holds its cache version, which Godot takes from the
# export's time and the ruleset from the files the worker caches.
_CACHE_VERSION = re.compile(r"^const CACHE_VERSION = .*$", re.MULTILINE)

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


def _template(work: Path) -> Path:
    """Zip the runtime's template of the case, as Godot's export takes a custom template."""
    kind = "web_release" if ARGS.threads else "web_nothreads_release"
    runtime = next(
        path.parent
        for path in map(Path, ARGS.runtime)
        if path.name == "godot.wasm" and path.parent.name == kind
    )
    template = work / "template.zip"
    with zipfile.ZipFile(template, "w") as archive:
        for file in sorted(runtime.iterdir()):
            archive.write(file, file.name)
    return template


def _run_editor(project: Path, work: Path, step: list[str]) -> None:
    environment = dict(
        os.environ, HOME=str(work), XDG_DATA_HOME=str(work), XDG_CONFIG_HOME=str(work)
    )
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


def _godot_export(work: Path) -> Path:
    project = work / "project"
    project.mkdir()
    for source in ARGS.project:
        shutil.copy(source, project / Path(source).name)
    template = _template(work)
    options = {
        "custom_template/debug": json.dumps(str(template)),
        "custom_template/release": json.dumps(str(template)),
    } | json.loads(os.environ["PARITY_EXPORT_OPTIONS"])
    (project / "export_presets.cfg").write_text(
        '[preset.0]\n\nname="Web"\nplatform="Web"\nrunnable=true\n'
        'export_filter="all_resources"\nexport_path="out/index.html"\n\n[preset.0.options]\n\n'
        + "".join(f"{key}={value}\n" for key, value in options.items())
    )
    out = work / "out"
    out.mkdir()
    for step in (["--import"], ["--export-release", "Web", str(out / "index.html")]):
        _run_editor(project, work, step)
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
                if path.name in ("index.pck", "index.html", "index.service.worker.js"):
                    continue
                with self.subTest(file=path.name):
                    self.assertEqual(path.read_bytes(), (ours / path.name).read_bytes())
            worker = theirs / "index.service.worker.js"
            if worker.exists():
                theirs_worker = _CACHE_VERSION.sub("", worker.read_text())
                ours_worker = _CACHE_VERSION.sub("", (ours / worker.name).read_text())
                self.assertEqual(theirs_worker, ours_worker)
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
    parser.add_argument("--threads", action=argparse.BooleanOptionalAction, default=False)
    ARGS, rest = parser.parse_known_args()
    unittest.main(argv=[sys.argv[0], *rest])


if __name__ == "__main__":
    main()
