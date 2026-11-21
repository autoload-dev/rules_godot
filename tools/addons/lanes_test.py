"""Every add-on module's lanes run the same commands in its examples."""

import unittest
from pathlib import Path

from tools.addons.lanes import command
from tools.addons.modules import AddonModule


def module(*projects: str) -> AddonModule:
    return AddonModule(Path("addons/widget"), "autoload_widget", "0.1.0", "", projects)


class LanesTest(unittest.TestCase):
    def test_host_tests_the_module_and_every_example_target_but_the_apps(self) -> None:
        self.assertEqual(
            command("host", module("demo", "store")),
            [
                "bazel",
                "test",
                "--",
                "@autoload_widget//...",
                "//...",
                "-//projects/demo:app",
                "-//projects/store:app",
            ],
        )

    def test_mobile_lanes_build_each_example_app(self) -> None:
        self.assertEqual(
            command("ios", module("demo")),
            ["bazel", "build", "--config=ios_sim", "//projects/demo:app"],
        )
        self.assertEqual(command("android", module("demo"))[2], "--config=android")

    def test_a_module_without_example_projects_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            command("host", module())


if __name__ == "__main__":
    unittest.main()
