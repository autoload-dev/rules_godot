"""Run a test launcher the way Bazel does, for the adapters' contract tests."""

import os
import subprocess
import tempfile
from pathlib import Path


def run(launcher: str, *arguments: str, **environment: str) -> tuple[int, str, Path]:
    """Run a test launcher like Bazel; return exit code, output and work dir."""
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
        [str(Path(launcher).absolute()), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
        timeout=200,
        check=False,
    )
    return process.returncode, process.stdout, work
