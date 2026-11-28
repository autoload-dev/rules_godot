"""
Write Godot's web export of a pack from a web template, as EditorExportPlatformWeb does.

export_project names every file after the page: the template's files, with godot
replaced by the page's name, the PCK, the boot splash and the page's icons. It fills
the HTML shell's $GODOT_* placeholders line by line from the export options and project
settings (_fix_html). This tool does the same with what Godot decided for the pack's
export, the facts, and the images Godot rendered for it. The directory and a
deterministic ZIP of it are the outputs.

Sections: Page, Files.
"""

import argparse
import json
import shutil
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from tools.platforms.shell_common import Facts, color_html
from tools.platforms.zip_archive import write_zip

# The page's name, which names every file: static hosts and itch.io open index.html.
NAME = "index"

# The template's files only a progressive web app ships.
_PWA_FILES = ("godot.service.worker.js", "godot.offline.html")

# ==== Page ====================================================================


def godot_json(value: Any) -> str:
    """Return value as Godot's JSON.stringify writes it: sorted keys, no spaces."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _godot_bool(value: object) -> str:
    """Return a bool as Godot's String(Variant) writes it."""
    return "true" if value else "false"


def page_config(facts: Facts, file_sizes: Mapping[str, int]) -> dict[str, Any]:
    """Return the Engine configuration _fix_html writes into the page."""
    return {
        "canvasResizePolicy": facts.option("html/canvas_resize_policy"),
        "experimentalVK": facts.option("html/experimental_virtual_keyboard"),
        "focusCanvas": facts.option("html/focus_canvas_on_start"),
        "gdextensionLibs": [],
        "executable": NAME,
        # An export without debug flags passes the engine no arguments.
        "args": [],
        "fileSizes": dict(file_sizes),
        "ensureCrossOriginIsolationHeaders": facts.option(
            "progressive_web_app/ensure_cross_origin_isolation_headers"
        ),
        "godotPoolSize": facts.option("threads/godot_pool_size"),
        "emscriptenPoolSize": facts.option("threads/emscripten_pool_size"),
    }


def _head_include(facts: Facts) -> str:
    head = ""
    if facts.option("html/export_icon"):
        head += (
            f'<link id="-gd-engine-icon" rel="icon" type="image/png" href="{NAME}.icon.png" />\n'
            f'<link rel="apple-touch-icon" href="{NAME}.apple-touch-icon.png"/>\n'
        )
    return head + str(facts.option("html/head_include") or "")


def _splash_classes(facts: Facts) -> str:
    # A stretch mode other than disabled (0) shows the splash at full size.
    stretch = facts.setting("application/boot_splash/stretch_mode")
    return " ".join(
        [
            "show-image--"
            + _godot_bool(facts.setting("application/boot_splash/show_image")),
            "fullsize--" + _godot_bool(stretch != 0),
            "use-filter--"
            + _godot_bool(facts.setting("application/boot_splash/use_filter")),
        ]
    )


def page(shell: str, facts: Facts, file_sizes: Mapping[str, int]) -> str:
    """
    Return the HTML shell with its placeholders filled, as _fix_html fills them.

    Godot replaces every placeholder in each line, in the order it inserted them into its
    hash map, and ends every line, the last one included, with a newline. That order
    replaces $GODOT_SPLASH_COLOR before $GODOT_SPLASH, which starts it.
    """
    replacements = {
        "$GODOT_URL": NAME + ".js",
        "$GODOT_PROJECT_NAME": str(facts.setting("application/config/name") or ""),
        "$GODOT_HEAD_INCLUDE": _head_include(facts),
        "$GODOT_CONFIG": godot_json(page_config(facts, file_sizes)),
        "$GODOT_SPLASH_COLOR": "#"
        + color_html(facts.setting("application/boot_splash/bg_color")),
        "$GODOT_SPLASH_CLASSES": _splash_classes(facts),
        "$GODOT_SPLASH": NAME + ".png",
        "$GODOT_THREADS_ENABLED": _godot_bool(facts.option("variant/thread_support")),
    }
    lines = []
    for line in shell.split("\n"):
        for key, value in replacements.items():
            line = line.replace(key, value)
        lines.append(line + "\n")
    return "".join(lines)


# ==== Files ===================================================================


def copy_template(runtime: Path, site: Path) -> None:
    """Copy the template's files, renamed after the page, as _extract_template does."""
    for source in sorted(runtime.iterdir()):
        if source.name in _PWA_FILES or not source.name.startswith("godot."):
            continue
        shutil.copyfile(source, site / source.name.replace("godot", NAME, 1))


def copy_images(images: Path, site: Path, facts: Facts) -> None:
    """Copy the boot splash and, where the page shows them, its icons."""
    shutil.copyfile(images / "splash.png", site / f"{NAME}.png")
    if facts.option("html/export_icon"):
        shutil.copyfile(images / "icon.png", site / f"{NAME}.icon.png")
        shutil.copyfile(
            images / "apple-touch-icon.png", site / f"{NAME}.apple-touch-icon.png"
        )


def _renderer_note(facts: Facts) -> None:
    method = facts.setting("rendering/renderer/rendering_method")
    if method not in (None, "gl_compatibility"):
        print(
            f"note: the project selects the {method} renderer; the web runs the "
            "Compatibility renderer (rendering/renderer/rendering_method.web)",
            file=sys.stderr,
        )


def export(args: argparse.Namespace) -> None:
    facts = Facts(json.loads(args.facts.read_text(encoding="utf-8")))
    site: Path = args.output
    site.mkdir(parents=True, exist_ok=True)
    copy_template(args.runtime, site)
    shutil.copyfile(args.pack, site / f"{NAME}.pck")
    file_sizes = {
        f"{NAME}.pck": (site / f"{NAME}.pck").stat().st_size,
        f"{NAME}.wasm": (site / f"{NAME}.wasm").stat().st_size,
    }
    shell = (args.shell or args.runtime / "godot.html").read_text(encoding="utf-8")
    (site / f"{NAME}.html").write_text(page(shell, facts, file_sizes), encoding="utf-8")
    copy_images(args.images, site, facts)
    _renderer_note(facts)
    write_zip(
        args.archive,
        {path.name: path for path in sorted(site.iterdir())},
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--runtime", type=Path, required=True, help="the template's directory"
    )
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--facts", type=Path, required=True)
    parser.add_argument(
        "--images", type=Path, required=True, help="the images Godot rendered"
    )
    parser.add_argument("--shell", type=Path, help="the pack's own HTML shell")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    export(parser.parse_args())


if __name__ == "__main__":
    main()
