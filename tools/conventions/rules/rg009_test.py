"""Application/add-on type follows location identically in examples and tests."""

import unittest

from tools.conventions.rules.rg009 import TypedRootLayout
from tools.conventions.test_support import RepositoryTest


class TypedRootLayoutTest(RepositoryTest):
    def setUp(self) -> None:
        super().setUp()
        self.write_consumer_modules()

    def evaluate(self, *names: str) -> list[str]:
        for name in names:
            self.write(name, "")
        context = self.context()
        return [item.message for item in TypedRootLayout().evaluate(context)]

    def test_all_four_typed_roots_and_operating_system_project_contexts_are_allowed(
        self,
    ) -> None:
        self.assertEqual(
            [],
            self.evaluate(
                "examples/projects/game/BUILD.bazel",
                "examples/projects/game/project.godot",
                "tests/mobile/BUILD.bazel",
                "tests/mobile/android/project.godot",
                "examples/addons/widget/demo/project.godot",
                "examples/addons/widget/tests/project.godot",
                "tests/shared_addon/demo/project.godot",
                "tests/shared_addon/tests/project.godot",
            ),
        )

    def test_legacy_groups_unit_packages_and_unnamed_roots_are_rejected(self) -> None:
        findings = self.evaluate(
            "examples/games/game/project.godot",
            "examples/projects/project.godot",
            "tests/project.godot",
            "tests/smoke/project.godot",
        )
        self.assertEqual(len(findings), 4)
        self.assertTrue(
            all(
                "named project or add-on below projects/ or addons/" in item
                for item in findings
            )
        )

    def test_an_add_on_modules_test_fixtures_may_live_in_its_tests(self) -> None:
        findings = self.evaluate(
            "addons/runner/MODULE.bazel",
            "addons/runner/examples/MODULE.bazel",
            "addons/runner/examples/tests/fixtures/suites/project.godot",
            "addons/runner/examples/fixtures/project.godot",
        )
        self.assertEqual(len(findings), 1)

    def test_a_nested_module_is_not_an_exemption_for_project_placement(self) -> None:
        self.assertEqual(
            len(
                self.evaluate(
                    "consumers/demo/MODULE.bazel",
                    "consumers/demo/android/project.godot",
                )
            ),
            1,
        )

    def test_project_needs_configuration_and_own_build(self) -> None:
        findings = self.evaluate(
            "tests/raw_library/native.cc", "examples/projects/app/project.godot"
        )
        self.assertEqual(len(findings), 3)
        self.assertTrue(
            any("must contain a Godot configuration" in item for item in findings)
        )
        self.assertTrue(any("must own a BUILD file" in item for item in findings))

    def test_extension_fixture_inputs_and_generated_templates_do_not_define_projects(
        self,
    ) -> None:
        self.assertEqual(
            [],
            self.evaluate(
                "tests/tools/c_abi/native.cc",
                "tests/tools/resources/project.godot.tpl",
                "tests/parser_test.py",
                "godot/private/default_project.godot",
            ),
        )


if __name__ == "__main__":
    unittest.main()
