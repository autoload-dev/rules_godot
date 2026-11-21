"""Run a declared project or PCK with isolated writable state; report its exit code."""

import argparse
import contextlib
import functools
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path, PurePosixPath
from typing import TextIO

from godot.private.project_config import compose_project, statement_groups
from tools.godot_staging import (
    NEW_SESSION,
    Original,
    apply_metadata,
    child_environment,
    copy_file,
    gd_string,
    resource_path,
    stage,
    stop_process_group,
    tree_entries,
    tree_files,
)
from tools.pck import add_pck_files, pck_file_contents


class ExecutionError(RuntimeError):
    """An execution failure with actionable diagnostics already captured."""


@functools.cache
def _runfiles_manifest(path: str) -> dict[str, str]:
    return dict(line.partition(" ")[::2] for line in Path(path).read_text().splitlines())


def _in_runfiles_directory(key: str) -> Path | None:
    root = os.environ.get("RUNFILES_DIR") or os.environ.get("TEST_SRCDIR")
    if root and (Path(root) / key).exists():
        return (Path(root) / key).resolve()
    return None


def _in_runfiles_manifest(key: str) -> Path | None:
    manifest = os.environ.get("RUNFILES_MANIFEST_FILE")
    if not manifest:
        return None
    entries = _runfiles_manifest(manifest)
    return Path(entries[key]).resolve() if key in entries else None


def _beside_program(key: str) -> Path | None:
    """A runfile in the .runfiles directory the running program lies in."""
    for parent in Path(sys.argv[0]).parents:
        if parent.name.endswith(".runfiles") and (parent / key).exists():
            return (parent / key).resolve()
    return None


def locate(key: str) -> Path:
    found = (
        _in_runfiles_directory(key) or _in_runfiles_manifest(key) or _beside_program(key)
    )
    if found is None:
        raise FileNotFoundError(f"Runfile {key} was not found")
    return found


# The autoload that records the errors Godot reports while the game runs.
_LOGGER = Path(__file__).parent / "run" / "errors.gd"
# The logger's name beside the project, where Godot reports errors of it.
_LOGGER_NAME = "rules_godot_errors.gd"
# A main scene replaces the project's; any other main runs with --script.
_SCENES = {".tscn", ".scn"}


@contextlib.contextmanager
def _interrupts_handled_by(handler: Callable[[int, object], None]) -> Iterator[None]:
    """Route SIGINT and SIGTERM to handler; signals reach only the main thread."""
    previous_handlers = {}
    try:
        if threading.current_thread() is threading.main_thread():
            for signum in (signal.SIGINT, signal.SIGTERM):
                previous_handlers[signum] = signal.signal(signum, handler)
        yield
    finally:
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)


def _stream(process: subprocess.Popen[str], sink: TextIO) -> None:
    """Print the process's output and write it to sink until the process exits."""
    assert process.stdout is not None
    for line in process.stdout:
        print(line, end="", flush=True)
        sink.write(line)
    process.wait()


def execute(
    command: list[str],
    root: Path,
    environment: dict[str, str],
    log: Path,
) -> int:
    """
    Stream output to the console and log; stop the engine process group on cancellation.

    Bazel's test timeout ends a test with SIGTERM, which stops Godot as well.

    Returns:
        Godot's exit code.
    """
    process = None
    interrupted_by = None

    def kill_process_group() -> None:
        # The engine may already have exited while a descendant still owns the
        # output pipe. Stop the group in either case.
        if process is not None:
            stop_process_group(process)

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted_by
        interrupted_by = interrupted_by or signal.Signals(signum).name
        kill_process_group()

    with log.open("w", encoding="utf-8") as sink, _interrupts_handled_by(interrupt):
        process = subprocess.Popen(
            command,
            cwd=root,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            start_new_session=NEW_SESSION,
        )
        # A signal can arrive while Popen is starting the isolated session.
        if interrupted_by:
            kill_process_group()
        try:
            _stream(process, sink)
        except BaseException:
            kill_process_group()
            process.wait()
            raise
    if interrupted_by:
        raise ExecutionError(f"Godot interrupted by {interrupted_by}")
    return process.returncode


def runfile_key(short_path: str, workspace: str) -> str:
    """The runfiles key of a Bazel short path; external repositories start with ../."""
    if short_path.startswith("../"):
        return short_path[3:]
    return workspace + "/" + short_path if workspace else short_path


def runfile_locator(workspace: str) -> Callable[[str], Path]:
    """Resolve a Bazel short path of the runfiles of a target in workspace."""

    def runfile(short_path: str) -> Path:
        return locate(runfile_key(short_path, workspace))

    return runfile


def _present_trees(keys: list[str], runfile: Callable[[str], Path]) -> list[str]:
    """
    Import results that exist in the runfiles.

    Bazel omits an empty tree artifact from runfiles; an import unit without
    importable files has an empty import result.
    """
    trees = []
    for key in keys:
        try:
            trees.append(str(runfile(key)))
        except FileNotFoundError:
            pass
    return trees


def import_results(
    project: dict, runfile: Callable[[str], Path]
) -> tuple[list[str], list[str]]:
    """
    A project's import results and its initialization, as present tree paths.

    The initialization carries Godot's global caches; staged after the imports, it
    replaces what Godot re-derived from them.
    """
    imports = [
        line
        for line in runfile(project["imports"]).read_text(encoding="utf-8").splitlines()
        if line
    ]
    return (
        _present_trees(imports, runfile),
        _present_trees([project["initialized"]], runfile),
    )


def tree_files_by_path(imports: list[str], initialized: list[str]) -> dict[str, Original]:
    """Import results, then Godot's caches, which replace what they re-derived."""
    generated: dict[str, Original] = {}
    for tree in imports:
        for path, original in tree_entries(Path(tree)):
            generated.setdefault(path, original)
    for tree in initialized:
        generated.update(tree_entries(Path(tree)))
    return generated


def generated_files(project: dict, runfile: Callable[[str], Path]) -> dict[str, Original]:
    """A project's import results, then Godot's caches, by resource path."""
    return tree_files_by_path(*import_results(project, runfile))


def _is_desktop_release_entry(section: str | None, key: str) -> bool:
    """Whether a descriptor key lists a desktop release library or dependency."""
    if section not in ("libraries", "dependencies"):
        return False
    return key.split(".")[0] in ("linux", "macos") and key.endswith(".release")


def with_editor_runtime_entries(descriptor: str) -> str:
    """
    Add an editor_runtime entry beside each desktop release entry of a pack's descriptor.

    The editor that runs a pack has the editor_runtime and debug feature tags, not
    release, so it loads a release pack's desktop libraries only under these entries.
    Export templates never have the tag.
    """
    groups = []
    for group, section, key in statement_groups(descriptor):
        groups.append(group)
        if key and _is_desktop_release_entry(section, key):
            separator = "" if group.endswith("\n") else "\n"
            value = group.split("=", 1)[1].lstrip()
            groups.append(
                f"{separator}{key.removesuffix('.release')}.editor_runtime={value}"
            )
    return "".join(groups)


def pack_descriptors(manifest: dict, runfile: Callable[[str], Path]) -> dict[str, bytes]:
    """Return the descriptors that replace those of the pack a pack run stages."""
    replaced = {
        path: runfile(key).read_bytes()
        for path, key in manifest.get("pack_descriptors", {}).items()
    }
    # Listed for a release pack of a desktop platform only.
    if manifest.get("release_descriptors"):
        # The pack names its files with or without res://; a replacement keeps its name.
        packed = {
            name.removeprefix("res://"): (name, text)
            for name, text in pck_file_contents(runfile(manifest["pack"]))[
                "extension_descriptors"
            ].items()
        }
        for path in manifest["release_descriptors"]:
            name, text = packed[path]
            replaced[name] = with_editor_runtime_entries(text).encode("utf-8")
    return replaced


def report(message: str) -> None:
    """Tell the user something, with main-repository labels as they write them."""
    print("rules_godot: " + message.replace("@@//", "//"), file=sys.stderr, flush=True)


def _resolved(paths: dict[str, str], runfile: Callable[[str], Path]) -> dict[str, str]:
    """Resource paths mapped to their resolved runfiles instead of runfile keys."""
    return {path: str(runfile(key)) for path, key in paths.items()}


def _add_run_settings(project: dict, root: Path) -> None:
    """
    Add the run's custom features and the project's settings from flags.

    Godot reads a source run's custom features from a root _custom_features key, as it
    reads an export's. Only the run adds them and the settings from flags, so views and
    packs share their configuration across variants and flag values.
    """
    if not (project.get("custom_features") or project.get("flag_settings")):
        return
    configuration = root / "project.godot"
    text = configuration.read_text(encoding="utf-8")
    if project.get("flag_settings"):
        text = compose_project(text, project["flag_settings"], {}, "")
    if project.get("custom_features"):
        features = json.dumps(",".join(project["custom_features"]))
        text = f"_custom_features={features}\n" + text
    configuration.unlink()
    configuration.write_text(text, encoding="utf-8")


def stage_project(project: dict, root: Path, runfile: Callable[[str], Path]) -> None:
    imports, initialized = import_results(project, runfile)
    # Resolve each individual runfile, including tree artifacts, before calling
    # the shared staging implementation; no checkout path is consulted.
    staged = set(
        stage(
            {
                "project_file": str(runfile(project["project_file"])),
                "member_resource_paths": _resolved(
                    project["member_resource_paths"], runfile
                ),
                "import_resource_paths": _resolved(
                    project["import_resource_paths"], runfile
                ),
                "imports": imports,
            },
            root,
            Path("/"),
        )
    )
    for tree in initialized:
        for relative, source in tree_files(Path(tree)):
            copy_file(source, root / resource_path(relative))
            staged.add(relative)
    _add_run_settings(project, root)
    # After the initialization, whose files would replace completed copies.
    if "metadata_index" in project:
        metadata = project["metadata_index"]
        index = json.loads(runfile(metadata["path"]).read_text(encoding="utf-8"))
        apply_metadata(root, index, metadata["assign"], staged)


# Bazel's test contract and the target's env reach the running project.
_TEST_ENVIRONMENT = (
    "TEST_SRCDIR",
    "RUNFILES_DIR",
    "RUNFILES_MANIFEST_FILE",
    "TEST_SHARD_INDEX",
    "TEST_TOTAL_SHARDS",
    "TEST_SHARD_STATUS_FILE",
    "TESTBRIDGE_TEST_ONLY",
    "XML_OUTPUT_FILE",
    "TEST_UNDECLARED_OUTPUTS_DIR",
    "TEST_TMPDIR",
    "TEST_PREMATURE_EXIT_FILE",
    "TEST_TARGET",
    "TEST_WORKSPACE",
)


def godot_environment(work: Path, env: dict[str, str]) -> dict[str, str]:
    """The isolated environment plus Bazel's test variables and the target's env."""
    environment = child_environment(work)
    environment.update(
        {name: os.environ[name] for name in _TEST_ENVIRONMENT if name in os.environ}
    )
    environment.update(env)
    return environment


def publish_reports(reports: Path) -> None:
    destination = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")
    if destination:
        shutil.copytree(reports, Path(destination) / "godot", dirs_exist_ok=True)


def register_logger(directory: Path, work: Path, errors: Path, stop: bool) -> None:
    """
    Add the error logger autoload through the override.cfg Godot reads in directory.

    Godot loads override.cfg after the project's settings, beside the main pack
    for a pack run and in the project for a source run, so neither the pack nor
    the project changes. An authored override.cfg keeps its other settings.
    """
    logger = work / _LOGGER_NAME
    shutil.copyfile(_LOGGER, logger)
    override = directory / "override.cfg"
    authored = override.read_text(encoding="utf-8") if override.exists() else ""
    override.write_text(
        compose_project(
            authored,
            {
                "rules_godot/run/errors": gd_string(str(errors)),
                "rules_godot/run/stop_on_error": "true" if stop else "false",
            },
            {"RulesGodotErrors": "*" + str(logger)},
            "",
        ),
        encoding="utf-8",
    )


def logger_failure(log: str) -> str:
    """
    Why the run logger did not start, from Godot's output.

    Args:
        log: What Godot printed.

    Returns:
        The error Godot reported for the logger, or the project setting that keeps
        Godot from reading override.cfg.
    """
    lines = log.splitlines()
    # Godot names the script on the error line or on the "at:" line after it.
    for line, following in zip(lines, lines[1:] + [""]):
        if (
            line.startswith(("SCRIPT ERROR:", "ERROR:"))
            and _LOGGER_NAME in line + following
        ):
            return f"Godot could not load it: {line.strip()}"
    return (
        "a project that sets application/config/disable_project_settings_override "
        'needs engine_errors = "report"'
    )


def recorded_errors(errors: Path) -> list[dict]:
    """The errors the logger recorded, in order."""
    return [
        json.loads(line)
        for line in errors.read_text(encoding="utf-8").splitlines()
        if line
    ]


def _exit_status(code: int) -> int:
    """Godot's exit code; a signal ending Godot maps to the shell's exit status."""
    return code if code >= 0 else 128 - code


def _stage_pack(manifest: dict, root: Path, runfile: Callable[[str], Path]) -> Path:
    """Stage a pack run's main pack and the extension files beside it."""
    pack = root / "main.pck"
    descriptors = pack_descriptors(manifest, runfile)
    if descriptors:
        add_pck_files(runfile(manifest["pack"]), pack, descriptors)
    else:
        shutil.copyfile(runfile(manifest["pack"]), pack)
    for path, key in manifest["extension_resource_paths"].items():
        copy_file(runfile(key), root / resource_path(path))
    return pack


def _stage_additional_packs(
    additional_packs: dict[str, str], root: Path, runfile: Callable[[str], Path]
) -> None:
    """Stage the packs the project loads itself, relative to its working directory."""
    for name, key in additional_packs.items():
        destination = root / resource_path(name)
        if destination.exists():
            raise ExecutionError(f"Additional pack {name} collides with a staged file")
        copy_file(runfile(key), destination)


def _main_arguments(main: str) -> list[str]:
    """Godot's arguments for the run's main: a scene replaces the project's main scene."""
    if not main:
        return []
    if PurePosixPath(main).suffix in _SCENES:
        return ["res://" + resource_path(main)]
    return ["--script", "res://" + resource_path(main)]


def _directories(work: Path) -> tuple[Path, Path]:
    """The staged project's directory and the reports directory of a run in work."""
    return work / "project", work / "reports"


def _staged_command(
    manifest: dict, work: Path, runfile: Callable[[str], Path]
) -> list[str]:
    """Stage the project or pack of a run in work and return Godot's command."""
    root, reports = _directories(work)
    # Required fields fail before anything is staged.
    main = manifest["main"]
    headless = manifest["headless"]
    additional_packs = manifest["additional_packs"]
    command = [
        str(runfile(manifest["editor"])),
        "--path",
        str(root),
        "--log-file",
        str(reports / "runtime-engine.log"),
    ]
    if headless:
        command.append("--headless")
    if "project" in manifest:
        stage_project(manifest["project"], root, runfile)
    else:
        command.extend(["--main-pack", str(_stage_pack(manifest, root, runfile))])
    _stage_additional_packs(additional_packs, root, runfile)
    return command + _main_arguments(main)


def _status_without_logger(code: int, log: Path, engine_errors: str) -> int:
    """
    The run's status when the logger never started.

    The logger creates its file when the game starts; a Godot that failed before has its
    own failure status.
    """
    if code == 0 and engine_errors == "fail":
        print(
            "rules_godot: the run logger did not start, so errors Godot reported were "
            "not recorded; "
            + logger_failure(log.read_text(encoding="utf-8", errors="replace")),
            file=sys.stderr,
        )
        return 1
    return _exit_status(code)


def _status_with_errors(code: int, recorded: list[dict], engine_errors: str) -> int:
    """The run's status after reporting the errors the logger recorded."""
    if not recorded:
        return _exit_status(code)
    first = recorded[0]
    print(
        f"rules_godot: Godot reported {len(recorded)} error(s) while the "
        f"game ran, first at {first['location']}: {first['text']}",
        file=sys.stderr,
    )
    if engine_errors == "fail":
        return code if code > 0 else 1
    return _exit_status(code)


def _run_in(work: Path, manifest: dict, extra: list[str], env: dict[str, str]) -> int:
    """Stage and run Godot in work; return the run's status."""
    engine_errors = manifest["engine_errors"]
    stop_on_error = manifest["stop_on_error"]
    environment = godot_environment(work, manifest["env"] | env)
    command = _staged_command(manifest, work, runfile_locator(manifest["workspace"]))
    root, reports = _directories(work)
    errors = reports / "errors.jsonl"
    register_logger(root, work, errors, stop_on_error and engine_errors == "fail")
    log = reports / "runtime.log"
    code = execute(command + extra, root, environment, log)
    if not errors.exists():
        return _status_without_logger(code, log, engine_errors)
    return _status_with_errors(code, recorded_errors(errors), engine_errors)


def _write_runner_report(reports: Path, failure: str | None, started: float) -> None:
    (reports / "runner.json").write_text(
        json.dumps(
            {"error": failure, "duration_seconds": time.monotonic() - started},
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def run(
    manifest: dict, extra: list[str] | None = None, env: dict[str, str] | None = None
) -> int:
    """
    Run Godot once; return its exit code, or raise on a runner failure.

    env adds to the environment the manifest gives Godot.
    """
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="godot-run-") as temporary:
        work = Path(temporary)
        root, reports = _directories(work)
        root.mkdir()
        reports.mkdir()
        failure = None
        try:
            return _run_in(work, manifest, extra or [], env or {})
        except KeyError as error:
            failure = f"Missing required run manifest field: {error.args[0]!r}"
            raise ExecutionError(failure) from error
        except (ExecutionError, OSError, ValueError) as error:
            failure = str(error)
            raise ExecutionError(failure) from error
        finally:
            # Preserve even failure diagnostics before deleting the work directory.
            _write_runner_report(reports, failure, started)
            publish_reports(reports)


def _env_pair(argv: list[str]) -> str | None:
    """The NAME=VALUE pair of a leading --env, if argv starts with one."""
    if argv[:1] != ["--env"] or len(argv) < 2:
        return None
    return argv[1] if "=" in argv[1] else None


def _leading_env(argv: list[str]) -> tuple[dict[str, str], list[str]]:
    """
    Split off the --env NAME=VALUE pairs that may precede the manifest.

    bazel run's application launcher passes them; everything after the manifest is
    Godot's, including its --.
    """
    env = {}
    while (pair := _env_pair(argv)) is not None:
        name, _, value = pair.partition("=")
        env[name] = value
        argv = argv[2:]
    return env, argv


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    env, argv = _leading_env(sys.argv[1:])
    args = parser.parse_args(argv[:2])
    extra = argv[2:]
    try:
        code = run(json.loads(args.manifest.read_text(encoding="utf-8")), extra, env)
    except (ExecutionError, OSError, ValueError) as error:
        print(f"rules_godot: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    raise SystemExit(code)


if __name__ == "__main__":
    main()
