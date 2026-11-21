"""Exercise the actual hk path policy without executing any selected commands."""

import ast
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from collections.abc import Iterator
from pathlib import Path

from tools.ci.verification import PROFILE_LANES, lane_plan

ROOT = Path(__file__).resolve().parents[2]
CASES = ROOT / "godot/tests/api_contracts/cases.bzl"
# hk itself rather than mise's shim, which finds no hk outside this checkout's mise.toml,
# such as in the temporary checkouts of the add-on cases.
HK = (
    subprocess.run(
        ["mise", "which", "hk"], cwd=ROOT, capture_output=True, text=True, check=False
    ).stdout.strip()
    or "hk"
)
# Add-on modules by directory, with their addon.pkl.
ADDON_MODULES = {
    "widget": 'lanes = List("host", "android", "ios")\nhosts = List("linux", "macos")\n',
    "gadget": 'lanes = List("host")\nhosts = List("macos")\n',
}


def regression_contract_packages() -> Iterator[tuple[str, str]]:
    """
    The package of each contract case or behavior test in tests/, with its lane's task.

    Behavior tests name no lane: a consumer module's resolve in the host lane.
    """
    source = "\n".join(
        line for line in CASES.read_text().splitlines() if not line.startswith("load(")
    )
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, ast.Dict):
            continue
        fields: dict[str, str] = {}
        for key, value in zip(node.keys, node.values, strict=True):
            match key, value:
                case ast.Constant(value=str(name)), ast.Constant(value=str(text)):
                    fields[name] = text
        target = fields.get("target", "")
        # Repository entrypoints are declared by tests/MODULE.bazel, not a package.
        if fields.get("module") != "tests" or not target.startswith("//"):
            continue
        package = target.removeprefix("//").partition(":")[0]
        lane = fields.get("lane", "host")
        yield f"tests/{package}/BUILD.bazel", f"contracts:{lane}"


# The examples whose suites run on the host.
HOST_EXAMPLES = {
    "test:example:sqlite",
    "test:example:platform_paths",
    "test:example:lichtpost",
    "test:example:app_auth",
    "test:example:dart",
}


class SelectionTest(unittest.TestCase):
    def plan(self, *files: str, profiles: tuple[str, ...] = (), cwd: Path = ROOT) -> dict:
        command = [HK]
        for profile in profiles:
            command.extend(["--profile", profile])
        command.extend(["check", "--plan", "--json", *files])
        result = subprocess.run(
            command,
            cwd=cwd,
            env={
                **os.environ,
                "HK_PROFILE": "",
                "HK_SKIP_STEPS": "",
                "HK_SKIP_HOOKS": "",
            },
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)

    def test_shared_example_dependencies_select_all_example_suites(self) -> None:
        lanes = lane_plan(self.plan("examples/deps/BUILD.bazel", profiles=PROFILE_LANES))
        self.assertEqual(set(lanes["host"]), HOST_EXAMPLES)

    def test_gdunit_test_changes_select_its_consumers(self) -> None:
        lanes = lane_plan(self.plan("addons/gdunit/defs.bzl", profiles=PROFILE_LANES))
        self.assertEqual(
            set(lanes["host"]),
            HOST_EXAMPLES | {"test:regressions", "host:addon:gdunit"},
        )
        self.assertEqual(lanes["android"] + lanes["ios"], [])

    def test_gdunit_own_tests_select_only_its_lane(self) -> None:
        lanes = lane_plan(
            self.plan(
                "addons/gdunit/examples/tests/gdunit_launcher_test.py",
                profiles=PROFILE_LANES,
            )
        )
        self.assertEqual(lanes["host"], ["host:addon:gdunit"])

    def test_petri_selects_its_source_engine_suite_and_no_host_example(self) -> None:
        for path in (
            "examples/projects/petri/engine/modules/reaction_diffusion/gray_scott_field.cpp",
            "examples/projects/petri/main/dish/dish.gd",
            "examples/engines/godot_petri.lock.json",
        ):
            with self.subTest(path=path):
                lanes = lane_plan(self.plan(path, profiles=PROFILE_LANES))
                self.assertEqual(lanes["source-engine"], ["test:example:petri"])
                self.assertEqual(lanes["host"], [])

    def test_sqlite_dependency_selects_only_its_host_example(self) -> None:
        lanes = lane_plan(
            self.plan("examples/deps/sqlite.BUILD.bazel", profiles=PROFILE_LANES)
        )
        self.assertEqual(lanes["host"], ["test:example:sqlite"])

    def test_dart_sdk_build_selects_only_its_host_example(self) -> None:
        for path in (
            "examples/deps/dart_sdk.BUILD.bazel",
            "examples/deps/dart_sdk.patch",
        ):
            with self.subTest(path=path):
                lanes = lane_plan(self.plan(path, profiles=PROFILE_LANES))
                self.assertEqual(lanes["host"], ["test:example:dart"])

    def test_documentation_only_changes_do_not_select_code_or_lane_work(self) -> None:
        for path in (
            "docs/public/versions.md",
            "docs/public/engine.md",
            "examples/addons/platform_paths/README.md",
        ):
            with self.subTest(path=path):
                lanes = lane_plan(self.plan(path, profiles=PROFILE_LANES))
                self.assertEqual(lanes["quality"], ["conventions:docs"])
                self.assertFalse(
                    any(tasks for name, tasks in lanes.items() if name != "quality")
                )

    def test_mixed_changes_select_complementary_rules_locally_and_in_ci(self) -> None:
        for profiles in ((), PROFILE_LANES):
            with self.subTest(profiles=profiles):
                plan = self.plan("README.md", "BUILD.bazel", profiles=profiles)
                conventions = [
                    step["name"]
                    for step in plan["steps"]
                    if step["status"] == "included"
                    and step["name"].startswith("conventions")
                ]
                self.assertEqual(conventions, ["conventions:code", "conventions:docs"])
                self.assertEqual(
                    [
                        task
                        for task in lane_plan(plan)["quality"]
                        if task.startswith("conventions")
                    ],
                    conventions,
                )

    def test_common_content_tool_selects_the_acceptance_of_every_lane(self) -> None:
        lanes = lane_plan(self.plan("tools/common_content.py", profiles=PROFILE_LANES))
        self.assertIn("test:bazel", lanes["host"])
        self.assertIn("contracts:host", lanes["host"])
        self.assertEqual(set(lanes["android"]), {"android", "contracts:android"})
        self.assertEqual(set(lanes["ios"]), {"ios", "contracts:ios"})

    def test_mobile_smoke_scenario_selects_its_lane(self) -> None:
        lanes = lane_plan(
            self.plan("tests/smoke/android/main/main.gd", profiles=PROFILE_LANES)
        )
        self.assertIn("test:regressions", lanes["host"])
        # The scenario hosts no contract case.
        self.assertEqual(lanes["android"], ["android"])
        self.assertEqual(lanes["ios"], [])

    def test_private_test_rules_select_the_consumers_and_contracts(self) -> None:
        lanes = lane_plan(
            self.plan("godot/private/testing/ios_app_test.bzl", profiles=PROFILE_LANES)
        )
        # The ruleset's own artifact test rules are ruleset code: they select the
        # consumers and every lane's contracts.
        self.assertIn("test:regressions", lanes["host"])
        self.assertEqual(lanes["android"], ["contracts:android", "android"])
        self.assertEqual(lanes["ios"], ["contracts:ios", "ios"])

    def test_source_engine_white_box_tests_select_the_source_engine_lane(
        self,
    ) -> None:
        lanes = lane_plan(
            self.plan(
                "godot/platforms/private/tests/engine_probe/BUILD.bazel",
                profiles=PROFILE_LANES,
            )
        )
        self.assertEqual(lanes["host"], ["test:bazel"])
        self.assertEqual(lanes["source-engine"], ["source-engine"])

    def test_rule_changes_select_white_box_tests_and_the_regression_module(self) -> None:
        lanes = lane_plan(self.plan("godot/defs.bzl", profiles=PROFILE_LANES))
        self.assertIn("test:bazel", lanes["host"])
        self.assertIn("test:regressions", lanes["host"])

    def test_regression_project_changes_select_only_the_regression_module(self) -> None:
        lanes = lane_plan(
            self.plan(
                "tests/script_run/BUILD.bazel",
                profiles=PROFILE_LANES,
            )
        )
        self.assertIn("test:regressions", lanes["host"])
        self.assertNotIn("test:bazel", lanes["host"])

    def test_white_box_tests_select_only_the_ruleset_tests(self) -> None:
        lanes = lane_plan(
            self.plan("godot/private/tests/versions_tests.bzl", profiles=PROFILE_LANES)
        )
        self.assertIn("test:bazel", lanes["host"])
        self.assertNotIn("test:regressions", lanes["host"])
        self.assertNotIn("contracts:host", lanes["host"])
        self.assertEqual(lanes["android"], [])
        self.assertEqual(lanes["ios"], [])

    def addon_plan(self, *files: str) -> dict[str, list[str]]:
        """Plan in a checkout of hk.pkl with two add-on modules, one of them macOS only."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            shutil.copyfile(ROOT / "hk.pkl", root / "hk.pkl")
            for module, addon in ADDON_MODULES.items():
                (root / "addons" / module).mkdir(parents=True)
                (root / "addons" / module / "addon.pkl").write_text(addon)
            for name in files:
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                (root / name).touch()
            return lane_plan(self.plan(*files, profiles=PROFILE_LANES, cwd=root))

    def test_an_add_on_module_selects_only_its_own_lanes(self) -> None:
        lanes = self.addon_plan("addons/widget/widget/native/widget.cc")
        self.assertEqual(lanes["host"], ["host:addon:widget"])
        self.assertEqual(lanes["android"], ["android:addon:widget"])
        self.assertEqual(lanes["ios"], ["ios:addon:widget"])

    def test_an_add_on_module_names_the_hosts_and_lanes_it_is_limited_to(self) -> None:
        lanes = self.addon_plan("addons/gadget/README.txt")
        self.assertEqual(lanes["host"], ["host:addon:gadget@macos"])
        self.assertEqual(lanes["android"] + lanes["ios"], [])

    def test_shared_add_on_settings_select_every_module_and_the_self_test(self) -> None:
        lanes = self.addon_plan("addons/module.bazelrc")
        self.assertEqual(
            lanes["host"],
            ["host:addon:gadget@macos", "host:addon:widget", "host:addon-template@linux"],
        )

    def test_rule_changes_do_not_select_the_add_on_modules(self) -> None:
        lanes = self.addon_plan("godot/defs.bzl")
        self.assertFalse(
            any(":addon" in task for tasks in lanes.values() for task in tasks)
        )

    def test_the_generator_selects_its_self_test_in_every_lane(self) -> None:
        lanes = lane_plan(self.plan("tools/addons/new.py", profiles=PROFILE_LANES))
        self.assertIn("host:addon-template@linux", lanes["host"])
        self.assertIn("android:addon-template", lanes["android"])
        self.assertIn("ios:addon-template", lanes["ios"])

    def test_the_add_on_tools_own_tests_build_no_module(self) -> None:
        lanes = lane_plan(
            self.plan("tools/addons/generated_test.py", profiles=PROFILE_LANES)
        )
        self.assertFalse(
            any(":addon" in task for tasks in lanes.values() for task in tasks)
        )

    def test_default_check_does_not_build_examples(self) -> None:
        lanes = lane_plan(self.plan("examples/deps/BUILD.bazel"))
        self.assertFalse(
            any(lanes[name] for name in ("host", "source-engine", "android", "ios"))
        )

    def test_api_contract_inputs_select_registration_and_every_lane_contract(
        self,
    ) -> None:
        for path in (
            "tools/docs/output_contracts.py",
            "tools/conventions/context.py",
            "godot/tests/api_contracts/cases.bzl",
            "godot/tests/api_contracts/repositories/templates_fixture.py",
        ):
            with self.subTest(path=path):
                lanes = lane_plan(self.plan(path, profiles=PROFILE_LANES))
                self.assertEqual(lanes["docs"], ["docs"])
                self.assertIn("contracts:host", lanes["host"])
                self.assertNotIn("test:regressions", lanes["host"])
                self.assertEqual(lanes["source-engine"], ["contracts:source-engine"])
                self.assertEqual(lanes["android"], ["contracts:android"])
                self.assertEqual(lanes["ios"], ["contracts:ios"])

    def test_regression_packages_of_contract_cases_select_their_lane(self) -> None:
        # Today the consumer module hosts only repository entrypoint cases, which name no
        # package; a case or behavior test that targets one must select its lane.
        for path, task in sorted(set(regression_contract_packages())):
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file())
                lanes = lane_plan(self.plan(path, profiles=PROFILE_LANES))
                self.assertIn(task, [name for tasks in lanes.values() for name in tasks])

    def test_build_tool_environment_selects_contracts_and_the_tools_using_it(
        self,
    ) -> None:
        lanes = lane_plan(self.plan("tools/tool_environment.py", profiles=PROFILE_LANES))
        self.assertIn("contracts:host", lanes["host"])
        self.assertIn("test:gdextension", lanes["host"])
        self.assertEqual(lanes["android"], ["contracts:android", "android"])

    def test_contract_sources_also_select_the_non_host_lanes(self) -> None:
        for path in ("godot/app.bzl", "godot/extension/godot_cpp.BUILD.tpl"):
            with self.subTest(path=path):
                lanes = lane_plan(self.plan(path, profiles=PROFILE_LANES))
                self.assertEqual(lanes["docs"], ["docs"])
                self.assertIn("contracts:host", lanes["host"])
                self.assertIn("contracts:android", lanes["android"])
                self.assertIn("android", lanes["android"])
                self.assertIn("contracts:ios", lanes["ios"])

    def test_local_api_docs_selection_does_not_request_lane_work(self) -> None:
        lanes = lane_plan(self.plan("tools/docs/output_contracts.py"))
        self.assertEqual(lanes["docs"], ["docs"])
        self.assertFalse(any(lanes[name] for name in ("host", "android", "ios")))


if __name__ == "__main__":
    unittest.main()
