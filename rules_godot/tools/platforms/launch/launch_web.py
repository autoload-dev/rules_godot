"""
Serve a web application on this host, open it in a browser and exit with its exit code.

The server serves the application's directory on 127.0.0.1 and inserts a script into its
page that sends the engine's log and exit code back, without the DevTools protocol. The
browser is the host's: the system's default, the one --device names, or with --headless a
Chromium browser without a window. Nothing is downloaded.

Sections: Browsers, Page, Server, Launch.
"""

from __future__ import annotations

import dataclasses
import functools
import http.server
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

import launch_common

OPTIONS = frozenset({"device", "list_devices", "headless", "port"})

# Godot's port for "Run in browser"; the next free one when it is taken.
DEFAULT_PORT = 8060
_PORTS_TRIED = 20

# What the launcher exits with when the page shows Godot's notice instead of the engine.
PAGE_FAILED = 126

# ==== Browsers ================================================================


@dataclasses.dataclass(frozen=True)
class Browser:
    """A browser of this host: its name, its executable and whether it is a Chromium."""

    name: str
    path: str
    chromium: bool


_MACOS_APPLICATIONS = (
    ("Google Chrome", "Google Chrome.app/Contents/MacOS/Google Chrome", True),
    ("Chromium", "Chromium.app/Contents/MacOS/Chromium", True),
    ("Microsoft Edge", "Microsoft Edge.app/Contents/MacOS/Microsoft Edge", True),
    ("Firefox", "Firefox.app/Contents/MacOS/firefox", False),
)

_COMMANDS = (
    ("Google Chrome", ("google-chrome", "google-chrome-stable"), True),
    ("Chromium", ("chromium", "chromium-browser"), True),
    ("Microsoft Edge", ("microsoft-edge", "microsoft-edge-stable"), True),
    ("chrome-headless-shell", ("chrome-headless-shell",), True),
    ("Firefox", ("firefox",), False),
)

HEADLESS_CANDIDATES = "Google Chrome, Chromium, Microsoft Edge, chrome-headless-shell"


def _first_existing(directories: Sequence[Path], relative: str) -> Path | None:
    return next(
        (
            directory / relative
            for directory in directories
            if (directory / relative).exists()
        ),
        None,
    )


def _first_command(
    which: Callable[[str], str | None], commands: Sequence[str]
) -> str | None:
    return next((path for path in map(which, commands) if path), None)


def browsers(
    which: Callable[[str], str | None] = shutil.which,
    applications: Sequence[Path] = (Path("/Applications"), Path.home() / "Applications"),
    system: str = platform.system(),
) -> list[Browser]:
    """Return the browsers found on this host, Chromium browsers first."""
    candidates: list[Browser] = []
    for name, relative, chromium in _MACOS_APPLICATIONS if system == "Darwin" else ():
        path = _first_existing(applications, relative)
        candidates += [Browser(name, str(path), chromium)] if path else []
    for name, commands, chromium in _COMMANDS:
        command = _first_command(which, commands)
        candidates += [Browser(name, command, chromium)] if command else []
    # The first of each name: an application before a command of the same browser.
    found = {browser.name: browser for browser in reversed(candidates)}
    return sorted(
        found.values(),
        key=lambda browser: (not browser.chromium, candidates.index(browser)),
    )


def _named_browser(device: str, found: Sequence[Browser]) -> Browser:
    """The browser --device names: a path, or the name of a browser found on this host."""
    if os.path.sep in device or os.path.exists(device):
        name = os.path.basename(device).lower()
        return Browser(device, device, "firefox" not in name and "safari" not in name)
    names = device.lower()
    for browser in found:
        if names in (browser.name.lower(), Path(browser.path).name.lower()):
            return browser
    raise launch_common.LaunchError(
        f"no browser {device} on this host; --list-devices lists those it has, or name a "
        "browser's executable with --device=<path>"
    )


def _first_chromium(found: Sequence[Browser]) -> Browser:
    chromium = next((browser for browser in found if browser.chromium), None)
    if chromium is None:
        raise launch_common.LaunchError(
            f"No Chromium browser found on this host for --headless. Looked for: {HEADLESS_CANDIDATES}. "
            "Install one, or name its path with --device=<path>."
        )
    return chromium


def choose_browser(
    device: str | None, headless: bool, found: Sequence[Browser]
) -> Browser | None:
    """
    Return the browser that --device names, the first Chromium for --headless, or None.

    None stands for the system's default browser.

    Raises:
        LaunchError: No browser fits, or --headless names one that is no Chromium.
    """
    browser = _named_browser(device, found) if device else None
    if not headless:
        return browser
    browser = browser or _first_chromium(found)
    if not browser.chromium:
        raise launch_common.LaunchError(
            f"--headless needs a Chromium browser, not {browser.name}"
        )
    return browser


# Flags for a browser the launcher starts: no first-run dialogs, and no throttling of a
# page whose window is hidden. Without a GPU, WebGL 2 needs SwiftShader: Godot's page checks
# for it before the engine starts.
_COMMON_FLAGS = (
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-timer-throttling",
    "--disable-renderer-backgrounding",
    "--disable-backgrounding-occluded-windows",
    "--autoplay-policy=no-user-gesture-required",
    # The fresh profile stores nothing worth protecting: no keychain prompt on macOS, no
    # keyring on Linux.
    "--use-mock-keychain",
    "--password-store=basic",
)
_HEADLESS_FLAGS = (
    "--headless=new",
    # Chromium's own sandbox cannot start under a Bazel test's sandbox or in a container,
    # and the page is the application's own, served from this host.
    "--no-sandbox",
    "--disable-gpu",
    "--use-angle=swiftshader",
    "--enable-unsafe-swiftshader",
)


def browser_command(
    browser: Browser, url: str, profile: str, headless: bool
) -> list[str]:
    """Return the command that opens url in a browser the launcher starts."""
    if not browser.chromium:
        return [browser.path, "--new-instance", "--profile", profile, url]
    flags = list(_COMMON_FLAGS) + (list(_HEADLESS_FLAGS) if headless else [])
    return [browser.path, *flags, "--user-data-dir=" + profile, url]


# ==== Page ====================================================================

_ENGINE_SCRIPT = '<script src="index.js"></script>'
_ENGINE = "new Engine(GODOT_CONFIG)"
_HOOK_PATH = "/__rules_godot/hook.js"


def instrumented_page(page: str, args: Sequence[str]) -> str | None:
    """Return the page with the launcher's hook, or None for a page without Godot's markers."""
    if _ENGINE_SCRIPT not in page or _ENGINE not in page:
        return None
    hook = (
        f"{_ENGINE_SCRIPT}\n<script>window.__RULES_GODOT__ = {json.dumps({'args': list(args)})};</script>\n"
        f'<script src="{_HOOK_PATH}"></script>'
    )
    return page.replace(_ENGINE_SCRIPT, hook, 1).replace(
        _ENGINE, "new Engine(window.__rulesGodot(GODOT_CONFIG))", 1
    )


class Run:
    """The events of one page load, printed in the order the page sent them."""

    def __init__(self, out: Any = None, err: Any = None) -> None:
        self.condition = threading.Condition()
        self.events: dict[int, dict[str, Any]] = {}
        self.printed = 0
        self.exit: dict[str, Any] | None = None
        self.notice: str | None = None
        # The streams at the time of the run, not of the import.
        self._out = out or sys.stdout
        self._err = err or sys.stderr

    def add(self, events: Sequence[Mapping[str, Any]]) -> None:
        with self.condition:
            for event in events:
                self.events[event["seq"]] = dict(event)
            while self.printed in self.events:
                self._show(self.events[self.printed])
                self.printed += 1
            self.condition.notify_all()

    def _show(self, event: Mapping[str, Any]) -> None:
        kind = event["kind"]
        if kind in ("stdout", "stderr"):
            stream = self._out if kind == "stdout" else self._err
            stream.write(str(event["text"]).rstrip("\n") + "\n")
            stream.flush()
        elif kind == "exit":
            self.exit = dict(event)
        elif kind == "notice" and str(event.get("text", "")).strip():
            self.notice = str(event["text"]).strip()
        elif kind == "page-error":
            launch_common.log("page error: " + str(event.get("text", "")))


# ==== Server ==================================================================


@dataclasses.dataclass(frozen=True)
class Site:
    """What the server serves: the application's directory, its page with the hook, the hook."""

    directory: Path
    page: str | None
    hook: bytes
    headers: Mapping[str, str]


def _handler(site: Site, run: Run) -> Any:
    class Handler(http.server.SimpleHTTPRequestHandler):
        extensions_map = {
            **http.server.SimpleHTTPRequestHandler.extensions_map,
            ".js": "text/javascript",
            ".wasm": "application/wasm",
            ".pck": "application/octet-stream",
        }

        def log_message(self, *_args: object) -> None:
            pass

        def end_headers(self) -> None:
            self.send_header("Cache-Control", "no-store")
            for name, value in site.headers.items():
                self.send_header(name, value)
            super().end_headers()

        def _send(self, body: bytes, content_type: str) -> None:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            path = self.path.split("?", 1)[0]
            if path == _HOOK_PATH:
                return self._send(site.hook, "text/javascript")
            if site.page is not None and path in ("/", "/index.html"):
                return self._send(site.page.encode("utf-8"), "text/html; charset=utf-8")
            return super().do_GET()

        def do_POST(self) -> None:
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.send_response(204)
            self.end_headers()
            if self.path == "/__rules_godot/events":
                run.add(json.loads(body))

    return functools.partial(Handler, directory=str(site.directory))


def serve(handler: Any, port: int) -> http.server.ThreadingHTTPServer:
    """Start serving on 127.0.0.1 at port or, when it is taken, the next free one."""
    http.server.ThreadingHTTPServer.request_queue_size = 128
    for candidate in range(port, port + _PORTS_TRIED):
        try:
            server = http.server.ThreadingHTTPServer(("127.0.0.1", candidate), handler)
        except OSError:
            continue
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server
    raise launch_common.LaunchError(
        f"no free port among {port} to {port + _PORTS_TRIED - 1}"
    )


# ==== Launch ==================================================================


def _wait_for(run: Run, done: Callable[[], bool], seconds: float) -> None:
    """Wait, holding the run's condition, until done or the time is up."""
    deadline = time.monotonic() + seconds
    while not done() and time.monotonic() < deadline:
        run.condition.wait(0.05)


def _browser_failure(browser: subprocess.Popen, log: Path) -> launch_common.LaunchError:
    output = log.read_text(errors="replace").strip().splitlines()[-20:]
    return launch_common.LaunchError(
        f"the browser exited with code {browser.returncode} before the application did:\n"
        + "\n".join(output)
    )


def _wait(run: Run, browser: subprocess.Popen | None, browser_log: Path) -> int:
    """Wait for the application's exit code, or the page's notice, and return the code."""
    with run.condition:
        while run.exit is None:
            if run.notice is not None:
                # The page also shows a notice when the engine exits with an error code,
                # just before it reports the exit.
                _wait_for(run, lambda: run.exit is not None, 2)
                if run.exit is None:
                    launch_common.log("the page stopped with: " + run.notice)
                    return PAGE_FAILED
            elif browser is not None and browser.poll() is not None:
                raise _browser_failure(browser, browser_log)
            else:
                run.condition.wait(0.1)
        # Lines the page sent before its exit may still be in flight.
        exit_event = run.exit
        _wait_for(run, lambda: run.printed > exit_event["seq"], 5)
        return int(exit_event["code"])


def _list(found: Sequence[Browser]) -> int:
    for browser in found:
        note = "" if browser.chromium else "\t(no --headless)"
        print(f"{browser.name}\t{browser.path}{note}")
    return 0


def _site(
    manifest: Mapping[str, Any],
    options: launch_common.Options,
    runfile: Callable[[str], str],
) -> Site:
    directory = Path(runfile(manifest["site"]))
    args = (["--headless"] if options.headless else []) + list(options.godot_args)
    page = instrumented_page(
        (directory / manifest["entry_point"]).read_text(encoding="utf-8"), args
    )
    if page is None:
        launch_common.log(
            "the page has no Godot engine script to report through, so the launcher shows no log "
            "and waits for Ctrl-C"
        )
    hook = Path(runfile(manifest["hook"])).read_bytes()
    return Site(directory, page, hook, manifest.get("headers", {}))


def _open(
    browser: Browser | None, url: str, profile: str, headless: bool
) -> subprocess.Popen | None:
    """Open url in the system's default browser, or start the browser and return its process."""
    if browser is None:
        webbrowser.open(url)
        return None
    with (Path(profile) / "browser.log").open("w") as log:
        return subprocess.Popen(
            browser_command(browser, url, profile, headless),
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )


def launch(
    manifest: Mapping[str, Any],
    options: launch_common.Options,
    runfile: Callable[[str], str],
) -> int:
    found = browsers()
    if options.list_devices:
        return _list(found)
    browser = choose_browser(options.device, options.headless, found)
    site = _site(manifest, options, runfile)
    run = Run()
    server = serve(
        _handler(site, run), DEFAULT_PORT if options.port is None else options.port
    )
    url = f"http://127.0.0.1:{server.server_address[1]}/{manifest['entry_point']}"
    launch_common.log(f"serving {site.directory} at {url}")
    # Chromium keeps a socket in its profile, whose path must stay short: a test's TMPDIR
    # is too long for it.
    profile = tempfile.mkdtemp(
        prefix="rules_godot_browser_", dir="/tmp" if os.path.isdir("/tmp") else None
    )
    process = None
    try:
        process = _open(browser, url, profile, options.headless)
        if site.page is None:
            threading.Event().wait()
        return _wait(run, process, Path(profile) / "browser.log")
    finally:
        if process is not None:
            launch_common.end(process, group=True)
        server.shutdown()
        shutil.rmtree(profile, ignore_errors=True)
