"""
Write Godot's web export of a pack from a web template, as EditorExportPlatformWeb does.

export_project names every file after the page: the template's files, with godot
replaced by the page's name, the PCK, the boot splash and the page's icons. It fills
the HTML shell's $GODOT_* placeholders line by line from the export options and project
settings (_fix_html). This tool does the same with what Godot decided for the pack's
export, the facts, and the images Godot rendered for it. The directory and a
deterministic ZIP of it are the outputs.

A progressive web app adds the service worker, the offline page, the web manifest and its
icons, as _build_pwa writes them. The service worker's cache version is a digest of the
files it caches rather than Godot's export time, so it changes exactly when they do.

Sections: Page, Progressive web app, Files.
"""

import argparse
import hashlib
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


def replace_lines(text: str, replacements: Mapping[str, str]) -> str:
    """Replace placeholders in each line as _replace_strings does: in order, every line ended."""
    lines = []
    for line in text.split("\n"):
        for key, value in replacements.items():
            line = line.replace(key, value)
        lines.append(line + "\n")
    return "".join(lines)


def _read(path: Path) -> str:
    # Godot reads and writes these files' bytes: no newline translation either way.
    with path.open(encoding="utf-8", newline="") as source:
        return source.read()


def _write(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="") as destination:
        destination.write(text)


def godot_json(value: Any) -> str:
    """Return value as Godot's JSON.stringify writes it: sorted keys, no spaces."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _godot_bool(value: object) -> str:
    """Return a bool as Godot's String(Variant) writes it."""
    return "true" if value else "false"


def is_pwa(facts: Facts) -> bool:
    return bool(facts.option("progressive_web_app/enabled"))


def page_config(facts: Facts, file_sizes: Mapping[str, int]) -> dict[str, Any]:
    """Return the Engine configuration _fix_html writes into the page."""
    worker = {"serviceWorker": f"{NAME}.service.worker.js"} if is_pwa(facts) else {}
    return worker | {
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
    if is_pwa(facts):
        head += f'<link rel="manifest" href="{NAME}.manifest.json">\n'
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
    return replace_lines(shell, replacements)


# ==== Progressive web app =====================================================

# Godot's choices of progressive_web_app/display and orientation, by index.
_DISPLAYS = ("fullscreen", "standalone", "minimal-ui", "browser")
_ORIENTATIONS = ("any", "landscape", "portrait")
_ICON_SIZES = (144, 180, 512)


def _project_name(facts: Facts) -> str:
    return str(facts.setting("application/config/name") or "") or "Godot Game"


def _cached_files(facts: Facts) -> tuple[list[str], list[str]]:
    """The files the service worker caches on install, and those it caches on demand."""
    icons = (
        [f"{NAME}.icon.png", f"{NAME}.apple-touch-icon.png"]
        if facts.option("html/export_icon")
        else []
    )
    installed = [f"{NAME}.html", f"{NAME}.js", f"{NAME}.offline.html", *icons]
    installed += [f"{NAME}.audio.worklet.js", f"{NAME}.audio.position.worklet.js"]
    return installed, [f"{NAME}.wasm", f"{NAME}.pck"]


def _cache_version(site: Path, files: list[str]) -> str:
    """A digest of the cached files, in Godot's place for the export's time."""
    digest = hashlib.sha256()
    for name in files:
        digest.update(name.encode() + b"\0" + (site / name).read_bytes())
    return digest.hexdigest()[:20]


def service_worker(template: str, facts: Facts, site: Path) -> str:
    """Return Godot's service worker with its placeholders filled, as _build_pwa does."""
    installed, on_demand = _cached_files(facts)
    replacements = {
        "___GODOT_VERSION___": _cache_version(site, installed + on_demand),
        "___GODOT_NAME___": _project_name(facts)[:16],
        "___GODOT_OFFLINE_PAGE___": f"{NAME}.offline.html",
        "___GODOT_ENSURE_CROSSORIGIN_ISOLATION_HEADERS___": _godot_bool(
            facts.option("progressive_web_app/ensure_cross_origin_isolation_headers")
        ),
        "___GODOT_CACHE___": godot_json(installed),
        "___GODOT_OPT_CACHE___": godot_json(on_demand),
    }
    return replace_lines(template, replacements)


def manifest(facts: Facts) -> str:
    """Return the web manifest _build_pwa writes."""
    display = min(
        max(int(facts.option("progressive_web_app/display")), 0), len(_DISPLAYS) - 1
    )
    orientation = min(
        max(int(facts.option("progressive_web_app/orientation")), 0),
        len(_ORIENTATIONS) - 1,
    )
    return godot_json(
        {
            "name": _project_name(facts),
            "start_url": f"./{NAME}.html",
            "display": _DISPLAYS[display],
            "orientation": _ORIENTATIONS[orientation],
            "background_color": "#"
            + color_html(facts.option("progressive_web_app/background_color")),
            "icons": [
                {
                    "sizes": f"{size}x{size}",
                    "type": "image/png",
                    "src": f"{NAME}.{size}x{size}.png",
                }
                for size in _ICON_SIZES
            ],
        }
    )


def write_pwa(args: argparse.Namespace, facts: Facts, site: Path) -> None:
    """Write the progressive web app's files beside the page."""
    for size in _ICON_SIZES:
        shutil.copyfile(
            args.images / f"pwa_{size}.png", site / f"{NAME}.{size}x{size}.png"
        )
    if args.offline_page:
        shutil.copyfile(args.offline_page, site / f"{NAME}.offline.html")
    template = _read(args.runtime / "godot.service.worker.js")
    _write(site / f"{NAME}.service.worker.js", service_worker(template, facts, site))
    (site / f"{NAME}.manifest.json").write_bytes(manifest(facts).encode("utf-8"))


def _hosting_note(facts: Facts) -> None:
    if not facts.option("variant/thread_support"):
        return
    supplied = is_pwa(facts) and facts.option(
        "progressive_web_app/ensure_cross_origin_isolation_headers"
    )
    print(
        "note: the application runs threads, so its host must make it cross-origin isolated: "
        + (
            "its service worker supplies the headers where the host sets none"
            if supplied
            else "serve it with Cross-Origin-Opener-Policy: same-origin and "
            "Cross-Origin-Embedder-Policy: require-corp, or enable "
            "progressive_web_app/ensure_cross_origin_isolation_headers"
        ),
        file=sys.stderr,
    )


# ==== Files ===================================================================


def copy_template(runtime: Path, site: Path, pwa: bool) -> None:
    """Copy the template's files, renamed after the page, as _extract_template does."""
    skipped = () if pwa else _PWA_FILES
    for source in sorted(runtime.glob("godot.*")):
        if source.name not in skipped:
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
    copy_template(args.runtime, site, is_pwa(facts))
    shutil.copyfile(args.pack, site / f"{NAME}.pck")
    file_sizes = {
        f"{NAME}.pck": (site / f"{NAME}.pck").stat().st_size,
        f"{NAME}.wasm": (site / f"{NAME}.wasm").stat().st_size,
    }
    shell = _read(args.shell or args.runtime / "godot.html")
    _write(site / f"{NAME}.html", page(shell, facts, file_sizes))
    copy_images(args.images, site, facts)
    if is_pwa(facts):
        write_pwa(args, facts, site)
    _renderer_note(facts)
    _hosting_note(facts)
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
    parser.add_argument("--offline-page", type=Path, help="the pack's own offline page")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    export(parser.parse_args())


if __name__ == "__main__":
    main()
