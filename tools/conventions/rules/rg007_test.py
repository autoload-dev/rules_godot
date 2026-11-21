"""RG007 regressions for effective flags, generated helpers and production inputs."""

import unittest

from tools.conventions.context import Call, Location
from tools.conventions.rules.rg007 import TestOnlyOperations
from tools.conventions.test_support import Record, RepositoryTest


class TestOnlyOperationsTest(RepositoryTest):
    def test_true_defaults_satisfy_the_rule_without_a_literal_attribute(self) -> None:
        for operation in ("godot_test", "gdunit_test"):
            call = Call(Location("BUILD.bazel", 1), operation, frozenset({"name"}))
            records: list[Record] = [
                {
                    "name": "//:test",
                    "path": "BUILD.bazel",
                    "strings": {"generator_function": operation},
                    "booleans": {"testonly": True},
                }
            ]
            self.assertEqual(
                [], list(TestOnlyOperations().evaluate(self.context((call,), records)))
            )

    def test_true_test_target_does_not_hide_false_generated_helpers(self) -> None:
        call = Call(Location("BUILD.bazel", 1), "renamed_test", frozenset({"name"}))
        records: list[Record] = [
            {
                "name": "//:tests",
                "path": "BUILD.bazel",
                "strings": {"generator_function": "gdunit_test"},
                "booleans": {"testonly": True},
            },
            {
                "name": "//:tests.case_list",
                "path": "BUILD.bazel",
                "strings": {"generator_function": "gdunit_test"},
                "booleans": {"testonly": False},
            },
            {
                "name": "//:tests.view",
                "path": "BUILD.bazel",
                "strings": {"generator_function": "gdunit_test"},
                "booleans": {"testonly": False},
            },
        ]
        findings = list(TestOnlyOperations().evaluate(self.context((call,), records)))
        self.assertEqual(2, len(findings))
        self.assertTrue(all(item.status == "violation" for item in findings))
        self.assertIn("//:tests.case_list", findings[0].message)
        self.assertIn("//:tests.view", findings[1].message)

    def test_explicit_false_test_target_is_a_violation(self) -> None:
        call = Call(
            Location("BUILD.bazel", 1), "godot_test", frozenset({"name", "testonly"})
        )
        records: list[Record] = [
            {
                "name": "//:test",
                "path": "BUILD.bazel",
                "strings": {"generator_function": "godot_test"},
                "booleans": {"testonly": False},
            }
        ]
        findings = list(TestOnlyOperations().evaluate(self.context((call,), records)))
        self.assertEqual(["violation"], [item.status for item in findings])

    def test_shared_runtime_inputs_and_unrelated_macros_remain_production_eligible(
        self,
    ) -> None:
        calls = (
            Call(Location("BUILD.bazel", 1), "godot_resources", frozenset({"name"})),
            Call(Location("BUILD.bazel", 2), "custom_test", frozenset({"name"})),
            Call(Location("BUILD.bazel", 3), "godot_test", frozenset({"name"})),
        )
        records: list[Record] = [
            {
                "name": "//:runtime",
                "path": "BUILD.bazel",
                "booleans": {"testonly": False},
            },
            {
                "name": "//:custom",
                "path": "BUILD.bazel",
                "line": 2,
                "strings": {"generator_function": "custom_test"},
                "booleans": {"testonly": False},
            },
            {
                "name": "//:test",
                "path": "BUILD.bazel",
                "line": 3,
                "strings": {"generator_function": "godot_test"},
                "booleans": {"testonly": True},
            },
        ]
        self.assertEqual(
            [], list(TestOnlyOperations().evaluate(self.context(calls, records)))
        )

    def test_missing_flag_or_generator_evidence_remains_not_checked(self) -> None:
        for strings in ({"generator_function": "godot_test"}, {}):
            call = Call(Location("BUILD.bazel", 1), "godot_test", frozenset({"name"}))
            records: list[Record] = [
                {"name": "//:test", "path": "BUILD.bazel", "strings": strings}
            ]
            findings = list(TestOnlyOperations().evaluate(self.context((call,), records)))
            self.assertEqual(["not_checked"], [item.status for item in findings])

    def test_mixed_wrapper_outputs_need_proven_test_ownership(self) -> None:
        call = Call(Location("BUILD.bazel", 1), "mixed_wrapper", frozenset({"name"}))
        records: list[Record] = [
            {
                "name": "//:check",
                "path": "BUILD.bazel",
                "strings": {"generator_function": "godot_test"},
                "booleans": {"testonly": True},
            },
            {
                "name": "//:runtime",
                "path": "BUILD.bazel",
                "strings": {"generator_function": "mixed_wrapper"},
                "booleans": {"testonly": False},
            },
        ]
        findings = list(TestOnlyOperations().evaluate(self.context((call,), records)))
        self.assertEqual(["not_checked"], [item.status for item in findings])
        self.assertIn("//:runtime", findings[0].message)


if __name__ == "__main__":
    unittest.main()
