"""The web application starts in a headless Chromium browser, logs and exits with its code."""

import os
import subprocess
import sys
import unittest

from python.runfiles import runfiles


LAUNCHER = ""


class WebSmokeTest(unittest.TestCase):
    def test_app_exits_with_its_code_after_its_log(self) -> None:
        launcher = runfiles.Create().Rlocation(LAUNCHER)
        # Port 0: any free port, so parallel tests do not wait for each other's.
        result = subprocess.run(
            [launcher, "--headless", "--port=0"],
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
            env=dict(os.environ),
        )
        self.assertEqual(7, result.returncode, result.stdout + result.stderr)
        self.assertIn("web smoke started on Web", result.stdout)
        self.assertIn("web smoke quits", result.stdout)
        self.assertLess(result.stdout.index("started"), result.stdout.index("quits"))


if __name__ == "__main__":
    LAUNCHER = sys.argv.pop(1)
    unittest.main()
