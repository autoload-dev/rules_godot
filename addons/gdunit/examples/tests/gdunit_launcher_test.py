"""gdunit_test launchers follow Bazel's test encyclopedia in real GdUnit runs."""

import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from tests.contract import run

PASSING, FAILURE, EMPTY, SKIPPED, ORPHAN = sys.argv[1:6]
sys.argv = sys.argv[:1]


def suites(work: Path) -> set[str]:
    return {
        suite.get("name", "")
        for suite in ET.parse(work / "test.xml").getroot().iter("testsuite")
    }


class GdUnitLauncherTest(unittest.TestCase):
    def test_reports_and_logs_reach_bazel(self) -> None:
        code, output, work = run(PASSING)
        self.assertEqual(code, 0, output)
        self.assertEqual(
            suites(work), {"PassingTest", "StringTest", "GeneratedTest"}, output
        )
        self.assertTrue(list((work / "outputs/gdunit").rglob("results.xml")))
        self.assertTrue((work / "outputs/godot/runtime.log").exists())

    def test_shards_split_suites_round_robin(self) -> None:
        # Suites run in path order: passing/GeneratedTest.gd, passing/PassingTest.gd,
        # passing/suites/. The sidecar and the helper script listed between them are
        # no suites, so they take no place in the round-robin.
        for index, expected in enumerate(
            [{"GeneratedTest", "StringTest"}, {"PassingTest"}]
        ):
            with self.subTest(index=index):
                status = Path(tempfile.mkdtemp()) / "shard"
                code, output, work = run(
                    PASSING,
                    TEST_TOTAL_SHARDS="2",
                    TEST_SHARD_INDEX=str(index),
                    TEST_SHARD_STATUS_FILE=str(status),
                )
                self.assertEqual(code, 0, output)
                self.assertEqual(suites(work), expected, output)
                self.assertTrue(status.exists())

    def test_a_shard_without_suites_passes(self) -> None:
        code, output, _ = run(
            PASSING,
            TEST_TOTAL_SHARDS="4",
            TEST_SHARD_INDEX="3",
            TEST_SHARD_STATUS_FILE=str(Path(tempfile.mkdtemp()) / "shard"),
        )
        self.assertEqual(code, 0, output)
        self.assertIn("no suites in this shard", output)

    def test_test_filter_selects_suites(self) -> None:
        code, output, work = run(PASSING, TESTBRIDGE_TEST_ONLY="StringTest")
        self.assertEqual(code, 0, output)
        self.assertEqual(suites(work), {"StringTest"}, output)
        # A filter matching no suite selects nothing to run, as an empty shard does.
        for only in ["NoSuchTest", "Totals"]:
            with self.subTest(only=only):
                code, output, _ = run(PASSING, TESTBRIDGE_TEST_ONLY=only)
                self.assertEqual(code, 0, output)
                self.assertIn("matches no suite", output)

    def test_arguments_after_the_separator_reach_gdunit(self) -> None:
        code, output, _ = run(PASSING, "--", "--no-such-gdunit-option")
        self.assertNotEqual(code, 0, output)
        self.assertIn("--no-such-gdunit-option", output)

    def test_failures_and_empty_runs_fail(self) -> None:
        for fixture, diagnostics in [
            (FAILURE, ["1 failed"]),
            (EMPTY, ["executed no test", "wrote no JUnit report"]),
            (SKIPPED, ["executed no test"]),
        ]:
            with self.subTest(fixture=fixture):
                code, output, _ = run(fixture)
                self.assertNotEqual(code, 0, output)
                self.assertTrue(
                    any(diagnostic in output for diagnostic in diagnostics), output
                )

    def test_orphan_nodes_pass_with_a_warning_naming_the_test(self) -> None:
        # GdUnit's command line exits with its warning code 101 for orphan nodes.
        code, output, _ = run(ORPHAN)
        self.assertEqual(code, 0, output)
        self.assertIn("possible orphan nodes", output)
        self.assertRegex(output, r"OrphanTest\.gd > test_leaves_an_orphan_node: [1-9]")

    def test_a_failed_assertion_keeps_its_details(self) -> None:
        code, output, work = run(FAILURE)
        self.assertNotEqual(code, 0, output)
        report = ET.parse(work / "test.xml")
        cases = [
            case
            for case in report.getroot().iter("testcase")
            if case.get("name") == "test_deliberate_failure"
        ]
        self.assertEqual(len(cases), 1, output)
        self.assertEqual(cases[0].get("classname"), "FailingTest")
        failure = cases[0].find("failure")
        if failure is None:
            self.fail(f"The assertion did not fail: {output}")
        details = "".join(failure.itertext())
        self.assertRegex(details, r"Expecting:\s+5\s+but was\s+4(?:\s|$)")


if __name__ == "__main__":
    unittest.main()
