"""Tests of the web launcher with a stand-in browser that plays the page's part."""

import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import launch_web
from launch_common import LaunchError, parse_options

# A stand-in for a Chromium browser: it loads the page it is given, checks the launcher's
# hook, and posts the engine's events out of order, as concurrent requests may arrive.
_BROWSER = """#!{python}
import json, sys, urllib.request
url = sys.argv[-1]
page = urllib.request.urlopen(url).read().decode()
assert "window.__rulesGodot(GODOT_CONFIG)" in page, page
assert '"args": ["--headless", "level=3"]' in page, page
origin = url.rsplit("/", 1)[0]
assert urllib.request.urlopen(origin + "/__rules_godot/hook.js").read()
def post(events):
    request = urllib.request.Request(origin + "/__rules_godot/events", json.dumps(events).encode())
    urllib.request.urlopen(request).read()
post([{{"seq": 2, "kind": "exit", "code": 42}}])
post([{{"seq": 0, "kind": "stdout", "text": "first"}}, {{"seq": 1, "kind": "stderr", "text": "second"}}])
"""

_PAGE = """<html><script src="index.js"></script>
<script>const engine = new Engine(GODOT_CONFIG);</script></html>
"""


class BrowsersTest(unittest.TestCase):
    def test_chromium_browsers_come_first(self) -> None:
        paths = {"firefox": "/usr/bin/firefox", "chromium": "/usr/bin/chromium"}
        found = launch_web.browsers(which=paths.get, applications=(), system="Linux")
        self.assertEqual(["Chromium", "Firefox"], [browser.name for browser in found])

    def test_headless_without_chromium_names_what_it_looked_for(self) -> None:
        firefox = launch_web.Browser("Firefox", "/usr/bin/firefox", False)
        with self.assertRaisesRegex(
            LaunchError,
            "No Chromium browser found on this host for --headless. Looked for: Google Chrome, Chromium, Microsoft Edge, chrome-headless-shell",
        ):
            launch_web.choose_browser(None, True, [firefox])

    def test_without_device_a_visible_run_takes_the_system_browser(self) -> None:
        self.assertIsNone(launch_web.choose_browser(None, False, []))

    def test_device_names_a_browser_or_its_path(self) -> None:
        chromium = launch_web.Browser("Chromium", "/usr/bin/chromium", True)
        self.assertEqual(
            chromium, launch_web.choose_browser("chromium", False, [chromium])
        )
        self.assertEqual(
            "/opt/edge/msedge",
            launch_web.choose_browser("/opt/edge/msedge", True, []).path,
        )
        with self.assertRaisesRegex(LaunchError, "no browser safari on this host"):
            launch_web.choose_browser("safari", False, [chromium])

    def test_headless_chromium_renders_in_software(self) -> None:
        chromium = launch_web.Browser("Chromium", "/usr/bin/chromium", True)
        command = launch_web.browser_command(
            chromium, "http://127.0.0.1:8060/index.html", "/tmp/p", True
        )
        self.assertIn("--use-angle=swiftshader", command)
        self.assertIn("--user-data-dir=/tmp/p", command)
        self.assertEqual("http://127.0.0.1:8060/index.html", command[-1])


class PageTest(unittest.TestCase):
    def test_hook_wraps_the_engine_configuration(self) -> None:
        page = launch_web.instrumented_page(_PAGE, ["--headless"])
        self.assertIn('<script src="/__rules_godot/hook.js"></script>', page)
        self.assertIn("new Engine(window.__rulesGodot(GODOT_CONFIG))", page)

    def test_a_page_without_godots_markers_is_served_as_it_is(self) -> None:
        self.assertIsNone(launch_web.instrumented_page("<html></html>", []))

    def test_events_print_in_the_pages_order(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        run = launch_web.Run(out, err)
        run.add([{"seq": 1, "kind": "stdout", "text": "two"}])
        run.add(
            [
                {"seq": 0, "kind": "stdout", "text": "one"},
                {"seq": 2, "kind": "exit", "code": 3},
            ]
        )
        self.assertEqual("one\ntwo\n", out.getvalue())
        self.assertEqual(3, run.exit["code"])


class LaunchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, True)
        site = self.directory / "site"
        site.mkdir()
        (site / "index.html").write_text(_PAGE)
        (self.directory / "hook.js").write_text("// hook")
        browser = self.directory / "chrome-headless-shell"
        browser.write_text(_BROWSER.format(python=sys.executable))
        browser.chmod(browser.stat().st_mode | stat.S_IXUSR)
        self.browser = browser
        self.manifest = {
            "site": "site",
            "entry_point": "index.html",
            "hook": "hook.js",
            "headers": {},
        }

    def test_exits_with_the_applications_code_after_its_log(self) -> None:
        options = parse_options(
            ["--headless", f"--device={self.browser}", "--port=0", "--", "level=3"],
            "web",
            launch_web.OPTIONS,
        )
        out = io.StringIO()
        with (
            mock.patch.object(sys, "stdout", out),
            mock.patch.object(launch_web, "browsers", return_value=[]),
        ):
            code = launch_web.launch(
                self.manifest, options, lambda path: str(self.directory / path)
            )
        self.assertEqual(42, code)
        self.assertEqual("first\n", out.getvalue())

    def test_fresh_and_env_do_not_apply(self) -> None:
        for option in ("--fresh", "--env=A=B", "--detach"):
            with self.subTest(option=option), self.assertRaises(LaunchError):
                parse_options([option], "web", launch_web.OPTIONS)


if __name__ == "__main__":
    os.environ.pop("BROWSER", None)
    unittest.main()
