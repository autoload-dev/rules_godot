"""Adapter tests follow Bazel's test encyclopedia with a fake adapter."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PASSING, FAILING, ERROR, NONE = sys.argv[1:5]
sys.argv = sys.argv[:1]


def run(launcher: str, **environment: str) -> tuple[int, str]:
    """Run a test launcher like Bazel; return its exit code and output."""
    work = Path(tempfile.mkdtemp())
    env: dict[str, str] = {
        **os.environ,
        "XML_OUTPUT_FILE": str(work / "test.xml"),
        "TEST_UNDECLARED_OUTPUTS_DIR": str(work / "outputs"),
        **environment,
    }
    for name in ["TEST_TOTAL_SHARDS", "TEST_SHARD_INDEX", "TESTBRIDGE_TEST_ONLY"]:
        if name not in environment:
            env.pop(name, None)
    process = subprocess.run(
        [str(Path(launcher).absolute())],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
        timeout=200,
        check=False,
    )
    return process.returncode, process.stdout


def ran(output: str) -> list[str]:
    """The cases the fake adapter ran, in order."""
    return [
        line.split()[1]
        for line in output.splitlines()
        if line.startswith("fake_adapter: res://")
    ]


class AdapterTest(unittest.TestCase):
    def test_runs_the_listed_cases_in_path_order(self) -> None:
        code, output = run(PASSING)
        self.assertEqual(code, 0, output)
        self.assertEqual(
            ran(output),
            [
                "res://first_case.txt",
                "res://second/second_case.txt",
                "res://third_case.txt",
            ],
            output,
        )

    def test_shards_split_the_cases_round_robin(self) -> None:
        # The listed file that is no case takes no place in the round-robin.
        for index, expected in enumerate(
            [
                ["res://first_case.txt", "res://third_case.txt"],
                ["res://second/second_case.txt"],
            ]
        ):
            with self.subTest(index=index):
                status = Path(tempfile.mkdtemp()) / "shard"
                code, output = run(
                    PASSING,
                    TEST_TOTAL_SHARDS="2",
                    TEST_SHARD_INDEX=str(index),
                    TEST_SHARD_STATUS_FILE=str(status),
                )
                self.assertEqual(code, 0, output)
                self.assertEqual(ran(output), expected, output)
                self.assertTrue(status.exists())

    def test_a_shard_without_cases_passes(self) -> None:
        code, output = run(
            PASSING,
            TEST_TOTAL_SHARDS="4",
            TEST_SHARD_INDEX="3",
            TEST_SHARD_STATUS_FILE=str(Path(tempfile.mkdtemp()) / "shard"),
        )
        self.assertEqual(code, 0, output)
        self.assertEqual(ran(output), [], output)

    def test_test_filter_selects_cases_by_path(self) -> None:
        code, output = run(PASSING, TESTBRIDGE_TEST_ONLY="second")
        self.assertEqual(code, 0, output)
        self.assertEqual(ran(output), ["res://second/second_case.txt"], output)
        # A filter matching no case selects nothing to run, as an empty shard does.
        for only in ["no_such_case", "notes"]:
            with self.subTest(only=only):
                code, output = run(PASSING, TESTBRIDGE_TEST_ONLY=only)
                self.assertEqual(code, 0, output)
                self.assertIn("matches no case", output)

    def test_the_exit_code_alone_decides(self) -> None:
        code, output = run(FAILING)
        self.assertNotEqual(code, 0, output)
        # The engine error the case reports fails no test.
        code, output = run(ERROR)
        self.assertEqual(code, 0, output)
        self.assertIn("a deliberate engine error", output)

    def test_a_test_without_cases_fails(self) -> None:
        code, output = run(NONE)
        self.assertNotEqual(code, 0, output)
        self.assertIn("the test lists no case", output)


if __name__ == "__main__":
    unittest.main()
