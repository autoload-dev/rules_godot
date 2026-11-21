"""
Staging and editor runs shared by the Godot project actions and exports.

Neither tool's own code or data is an input of the other's actions, so a change
to one reruns only that tool's actions.
"""

import argparse
import contextlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
from collections.abc import Callable, Collection, Iterable, Iterator, Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import IO

from godot.private.project_config import (
    compose_project,
    enable_plugins,
    enabled_plugins,
)
from tools.godot_files import is_uid_sidecar
from tools.mapped_paths import add_root_arguments, resolve_paths, resolver
from tools.node_ids import with_node_ids
from tools.pck import EXTENSION_LIST
from tools.resource_graph import portable_identity, validate_identities
from tools.resource_uids import with_resource_uids


def _is_resource_path(value: str) -> bool:
    """Whether value is a relative POSIX path of plain components and printable text."""
    if not value or PurePosixPath(value).is_absolute():
        return False
    if "\\" in value or ":" in value:
        return False
    if any(ord(c) < 32 for c in value):
        return False
    return not any(x in ("", ".", "..") for x in value.split("/"))


def resource_path(value: str) -> str:
    if not _is_resource_path(value):
        raise ValueError(f"Invalid resource path: {value!r}")
    return value


def validate_staged_paths(resource_paths: dict[str, str]) -> None:
    """Detect portable-path collisions before a case-insensitive copy can lose data."""
    prefixes: dict[str, str] = {}
    files = {portable_identity(path): path for path in resource_paths}
    for path in resource_paths:
        _check_prefixes(path, files, prefixes)


def _check_prefixes(path: str, files: dict[str, str], prefixes: dict[str, str]) -> None:
    """
    Check each prefix of path against the prefixes seen so far and the files.

    A prefix may have one spelling, and only the path itself may be a file.
    """
    parts = resource_path(path).split("/")
    for index in range(1, len(parts) + 1):
        prefix = "/".join(parts[:index])
        identity = portable_identity(prefix)
        previous = prefixes.setdefault(identity, prefix)
        if previous != prefix:
            raise ValueError(
                f"Conflicting portable Godot paths: {previous!r} and {prefix!r}"
            )
        if index < len(parts) and identity in files:
            raise ValueError(
                f"Conflicting Godot file/directory paths: {files[identity]!r} and {path!r}"
            )


def copy_file(source: Path, destination: Path) -> None:
    """Copy source's bytes to destination; an executable source stays executable."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    if executable(source):
        destination.chmod(destination.stat().st_mode | 0o111)


# Where a staged file's bytes came from: a file, an archive member or content.
Original = Path | tuple[Path, tarfile.TarInfo] | bytes


def executable(original: Original) -> bool:
    """Whether original is an executable file, such as an extension's crash handler."""
    if isinstance(original, bytes):
        return False
    if isinstance(original, Path):
        return os.access(original, os.X_OK)
    return bool(original[1].mode & 0o111)


@contextlib.contextmanager
def open_original(original: Original) -> Iterator[IO[bytes]]:
    if isinstance(original, bytes):
        yield io.BytesIO(original)
    elif isinstance(original, Path):
        with original.open("rb") as data:
            yield data
    else:
        archive, member = original
        # Unit archives are uncompressed; "r:" skips probing for compression.
        with tarfile.open(archive, "r:") as stream:
            data = stream.extractfile(member)
            if data is None:
                raise ValueError(f"Archive entry {member.name!r} is not a file")
            yield data


def same_content(path: Path, original: Original) -> bool:
    """Whether path still holds the original bytes, compared in chunks."""
    with path.open("rb") as current, open_original(original) as expected:
        while True:
            chunk = current.read(1 << 20)
            if chunk != expected.read(1 << 20):
                return False
            if not chunk:
                return True


# An import unit's result: one archive, or nothing when the unit had no file
# that an importer handles.
IMPORT_ARCHIVE = "import.tar"


def tree_files(tree_root: Path) -> list[tuple[str, Path]]:
    return [
        (source.relative_to(tree_root).as_posix(), source)
        for source in sorted(tree_root.rglob("*"))
        if source.is_file()
    ]


def tree_entries(tree_root: Path) -> Sequence[tuple[str, Original]]:
    """List an import result's files, from its archive or its tree, without extracting."""
    archive = tree_root / IMPORT_ARCHIVE
    if not archive.is_file():
        return tree_files(tree_root)
    with tarfile.open(archive, "r:") as stream:
        members = stream.getmembers()
    for member in members:
        if not member.isreg():
            raise ValueError(f"Unexpected archive entry {member.name!r} in {archive}")
    return [(member.name, (archive, member)) for member in members]


def add_resource_path_manifests(
    manifest: dict, paths: list[Path], resolve: Callable[[str], str]
) -> None:
    """Merge resource path manifests of more paths to stage into the manifest's members."""
    resource_paths = manifest.setdefault("member_resource_paths", {})
    for path in paths:
        staged = json.loads(path.read_text(encoding="utf-8"))
        for relative, source in resolve_paths(staged, resolve).items():
            if resource_paths.setdefault(relative, source) != source:
                raise ValueError("Conflicting staged sources for " + relative)


def write_archive(root: Path, paths: list[str], archive: Path) -> None:
    """Archive files deterministically so equal results have equal bytes."""
    write_originals({relative: root / relative for relative in paths}, archive)


def _size(original: Original) -> int:
    if isinstance(original, bytes):
        return len(original)
    if isinstance(original, Path):
        return original.stat().st_size
    return original[1].size


def write_originals(files: Mapping[str, Original], archive: Path) -> None:
    """Archive files by path from where their bytes come, as write_archive does."""
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "w", format=tarfile.PAX_FORMAT) as stream:
        for relative in sorted(files):
            info = tarfile.TarInfo(relative)
            info.size, info.mode, info.mtime, info.uid, info.gid = (
                _size(files[relative]),
                0o644,
                0,
                0,
                0,
            )
            with open_original(files[relative]) as data:
                stream.addfile(info, data)


def read_original(original: Original) -> bytes:
    """Return the bytes of a staged file's original."""
    with open_original(original) as data:
        return data.read()


def _source_paths(manifest: dict) -> dict[str, str]:
    """The import inputs overlaid by the members, which must not stage other files there."""
    resource_paths = dict(manifest.get("import_resource_paths", {}))
    for path, source in manifest["member_resource_paths"].items():
        if resource_paths.setdefault(path, source) != source:
            raise ValueError("Import input conflicts with project member: " + path)
    return resource_paths


def _check_import_uid(
    relative: str, original: Original, resource_paths: dict[str, str], execroot: Path
) -> None:
    """Fail for a cached UID sidecar that differs from an authored one at its path."""
    if not is_uid_sidecar(relative) or relative not in resource_paths:
        return
    authored = (execroot / resource_paths[relative]).read_text(encoding="utf-8").strip()
    if authored != read_original(original).decode("utf-8").strip():
        raise ValueError("Cached import UID conflicts with authored sidecar: " + relative)


def _metadata_completions(
    metadata: dict, execroot: Path, files: dict[str, Original]
) -> dict[str, Original]:
    """The staged text files the metadata index completes, as bytes."""
    index = json.loads((execroot / metadata["path"]).read_text(encoding="utf-8"))
    texts = completed_texts(
        index,
        metadata["assign"],
        files,
        lambda path: read_original(files[path]).decode("utf-8"),
    )
    return {path: text.encode("utf-8") for path, text in texts.items()}


def _merged_import_results(
    imported_files: list[tuple[str, Original, str]],
    resource_paths: dict[str, str],
    execroot: Path,
) -> dict[str, Original]:
    """
    The import results by resource path; equal results of several units merge.

    An import result may differ neither from another unit's nor, for a UID sidecar, from
    the authored one.
    """
    merged: dict[str, Original] = {}
    for relative, original, _ in imported_files:
        _check_import_uid(relative, original, resource_paths, execroot)
        if relative not in merged:
            merged[relative] = original
        elif read_original(merged[relative]) != read_original(original):
            raise ValueError(
                f"Conflicting import results for {PurePosixPath(relative).name}"
            )
    return merged


def staged_files(manifest: dict, execroot: Path) -> dict[str, Original]:
    """
    Return the files the project stages, project.godot aside: where each one's bytes come from.

    The members and import inputs, overlaid by the import results, then the extension list and
    the text files the metadata index completes, as bytes. Conflicting paths, import results
    or UIDs fail here, so every operation staging the project rejects the same inputs.
    """
    resource_paths = _source_paths(manifest)
    imported_files = [
        (relative, original, tree)
        for tree in manifest.get("imports", [])
        for relative, original in tree_entries(execroot / tree)
    ]
    # Validate the complete namespace once. Cached sidecars and generated files must not
    # alias authored paths or another import result.
    validate_staged_paths(
        resource_paths | {relative: tree for relative, _, tree in imported_files}
    )
    validate_identities(
        {path: execroot / source for path, source in resource_paths.items()}
    )
    files: dict[str, Original] = {
        relative: execroot / source for relative, source in resource_paths.items()
    }
    files |= _merged_import_results(imported_files, resource_paths, execroot)
    # Load extensions before the file scan so imports and exported scripts
    # see the same registered classes, including on a cold build.
    content = extension_list(resource_paths)
    if content:
        files[EXTENSION_LIST] = content
    if "metadata_index" in manifest:
        files.update(_metadata_completions(manifest["metadata_index"], execroot, files))
    return files


def stage(manifest: dict, root: Path, execroot: Path) -> dict[str, Original]:
    """
    Stage the project; return where each staged file's bytes came from.

    Its editor plugins, such as the importers an import stages, are enabled
    in the staged project.godot, which also takes its settings, such as the import
    settings of those importers. Godot's scans compare against the originals, which hold
    the metadata completions as the staged files do.
    """
    originals: dict[str, Original] = {
        "project.godot": execroot / manifest["project_file"],
        **staged_files(manifest, execroot),
    }
    for relative, original in originals.items():
        destination = root / resource_path(relative)
        if isinstance(original, Path):
            copy_file(original, destination)
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        with open_original(original) as data, destination.open("wb") as copy:
            shutil.copyfileobj(data, copy)
        if executable(original):
            destination.chmod(destination.stat().st_mode | 0o111)
    _configure(root, manifest.get("editor_plugins", []), manifest.get("settings", {}))
    return originals


# How each kind of metadata completes a text file from its metadata index entry.
COMPLETIONS = {
    "node_ids": lambda text, path, _: with_node_ids(text, path),
    "resource_uids": lambda text, path, entry: with_resource_uids(
        text, path, entry["uids"]
    ),
}


def completed_texts(
    index: dict, kinds: Iterable[str], staged: Collection[str], read: Callable[[str], str]
) -> dict[str, str]:
    """
    Return the staged text files the metadata kinds of the index change, completed.

    Args:
        index: The metadata index.
        kinds: The kinds of metadata to complete, keys of COMPLETIONS.
        staged: The staged resource paths; the index may name others.
        read: Returns a staged file's text by its resource path.
    """
    texts: dict[str, str] = {}
    authored: dict[str, str] = {}
    for kind in kinds:
        for path, entry in index[kind].items():
            if path not in staged:
                continue
            if path not in texts:
                texts[path] = authored[path] = read(path)
            texts[path] = COMPLETIONS[kind](texts[path], path, entry)
    return {path: text for path, text in texts.items() if text != authored[path]}


def apply_metadata(
    root: Path, index: dict, kinds: Iterable[str], staged: Collection[str]
) -> dict[str, bytes]:
    """
    Complete the staged text files with the metadata kinds the index lists for them.

    Returns:
        The updated files' bytes by resource path; their sources keep theirs.
    """
    texts = completed_texts(
        index,
        kinds,
        staged,
        lambda path: (root / resource_path(path)).read_text(encoding="utf-8", newline=""),
    )
    for path, text in texts.items():
        (root / resource_path(path)).write_text(text, encoding="utf-8", newline="")
    return {path: text.encode("utf-8") for path, text in texts.items()}


def extension_list(paths: Iterable[str]) -> bytes:
    """EXTENSION_LIST's content for the .gdextension files among paths; empty for none."""
    extensions = sorted(path for path in paths if path.endswith(".gdextension"))
    return "".join("res://" + path + "\n" for path in extensions).encode("utf-8")


@contextlib.contextmanager
def staged_project(
    manifest: dict, execroot: Path, prefix: str
) -> Iterator[tuple[Path, Path, dict[str, Original]]]:
    """Yield (work, root, originals): a temporary work directory with the staged project."""
    with tempfile.TemporaryDirectory(prefix=prefix) as temporary:
        work = Path(temporary)
        root = work / "project"
        root.mkdir()
        originals = stage(manifest, root, execroot)
        yield work, root, originals


def gd_string(value: str) -> str:
    """A Godot string literal of value."""
    return json.dumps(value, ensure_ascii=False)


# Godot runs in its own process group, so stopping it reaches its descendants.
NEW_SESSION = os.name != "nt"


def stop_process_group(process: subprocess.Popen) -> None:
    """Stop a process started with NEW_SESSION and its descendants, if still running."""
    try:
        if NEW_SESSION:
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
    except ProcessLookupError:
        pass


def child_environment(directory: Path) -> dict[str, str]:
    result = {
        k: os.environ[k]
        for k in ("PATH", "SYSTEMROOT", "DEVELOPER_DIR", "SDKROOT")
        if k in os.environ
    }
    for key, leaf in {
        "HOME": "home",
        "TMPDIR": "tmp",
        "XDG_DATA_HOME": "data",
        "XDG_CONFIG_HOME": "config",
        "XDG_CACHE_HOME": "cache",
    }.items():
        path = directory / leaf
        path.mkdir(parents=True, exist_ok=True)
        result[key] = str(path)
    result.update(
        LANG="en_US.UTF-8",
        LC_ALL="en_US.UTF-8",
        TZ="UTC",
        GODOT_SILENCE_ROOT_WARNING="1",
    )
    return result


# rules_godot's action plugin, staged into every view an editor action runs on.
_ACTION = Path(__file__).parent / "action"
ACTION_DIRECTORY = "addons/rules_godot_action"
# Godot's own result of an action, written by the action plugin.
_RECORD = "record.json"
# An editor action's bound, and how long Godot may take to exit after its record.
_ACTION_TIMEOUT_SECONDS = 300
_RECORD_GRACE_SECONDS = 20


def join_action(
    root: Path,
    work: Path,
    operation: str,
    parameters: Mapping[str, object] | None = None,
) -> None:
    """
    Stage the action plugin for an operation and enable it in the staged project.

    Its directory holds a .gdignore file, so Godot loads the plugin but never
    scans, imports or exports its files. An export packs the project.godot from
    before the join.

    Args:
        root: The staged project.
        work: The action's work directory, which receives the record.
        operation: What the plugin records, see tools/action/plugin.gd.
        parameters: More fields of the plugin's action.json.
    """
    directory = root / ACTION_DIRECTORY
    if directory.exists():
        raise ValueError(f"res://{ACTION_DIRECTORY} is reserved for rules_godot")
    shutil.copytree(_ACTION, directory)
    (directory / ".gdignore").touch()
    project = root / "project.godot"
    authored = work / "project.godot"
    shutil.copyfile(project, authored)
    (directory / "action.json").write_text(
        json.dumps(
            {
                **(parameters or {}),
                "operation": operation,
                "record": str(work / _RECORD),
                "project_file": str(authored),
            }
        ),
        encoding="utf-8",
    )
    _configure(root, [f"res://{ACTION_DIRECTORY}/plugin.cfg"], {})


def _configure(root: Path, plugins: Iterable[str], settings: Mapping[str, str]) -> None:
    """Enable editor plugins and set settings, such as importers' import settings, in the staged project.godot."""
    if not plugins and not settings:
        return
    project = root / "project.godot"
    text = project.read_text(encoding="utf-8")
    plugins = [*plugins, *enabled_plugins(text)]
    if settings:
        text = compose_project(text, dict(settings), {}, "")
    project.write_text(enable_plugins(text, plugins), encoding="utf-8")


def _status(returncode: int) -> str:
    return f"signal {-returncode}" if returncode < 0 else f"exit status {returncode}"


def _await_record(
    process: subprocess.Popen[bytes], record: Path, log: Path, operation: str
) -> bool:
    """
    Wait for Godot's record, then a grace period for Godot to exit.

    Returns:
        Whether Godot was still running after the grace period and is to be stopped.
    """
    deadline = time.monotonic() + _ACTION_TIMEOUT_SECONDS
    while not record.exists() and process.poll() is None:
        if time.monotonic() > deadline:
            stop_process_group(process)
            process.wait()
            raise RuntimeError(
                f"Godot recorded no {operation} result within "
                f"{_ACTION_TIMEOUT_SECONDS} seconds:\n"
                + log.read_text(encoding="utf-8", errors="replace")
            )
        time.sleep(0.05)
    if not record.exists():
        return False
    try:
        process.wait(timeout=_RECORD_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        return True
    return False


def _successful_record(
    record: Path, output: str, operation: str, returncode: int
) -> dict:
    """The action plugin's record; fail when Godot wrote none or a failed one."""
    if not record.exists():
        raise RuntimeError(
            f"Godot ended without recording its {operation} result "
            f"({_status(returncode)}):\n{output}"
        )
    result = json.loads(record.read_text(encoding="utf-8"))
    if result["verdict"] != "success":
        raise RuntimeError(
            f"Godot recorded a failed {operation}:\n"
            + "\n".join(result["diagnostics"])
            + f"\nGodot's output:\n{output}"
        )
    return result


def _note_ending(stopped: bool, returncode: int, operation: str) -> None:
    """Note a Godot that was stopped or failed after a successful record."""
    if stopped:
        print(
            f"rules_godot: note: stopped Godot {_RECORD_GRACE_SECONDS} seconds "
            f"after its {operation} result",
            file=sys.stderr,
        )
    elif returncode:
        print(
            f"rules_godot: note: Godot ended with {_status(returncode)} "
            f"after a successful {operation}",
            file=sys.stderr,
        )


def run_action(
    manifest: dict, execroot: Path, root: Path, work: Path, args: list[str]
) -> dict:
    """
    Run the manifest's editor on the staged project; return the action's record.

    The record the action plugin writes decides, not Godot's output or exit
    status: Godot is stopped a grace period after its record, and an exit
    after a successful record is only a note. The caller checks the action's
    declared outputs.
    """
    operation = json.loads(
        (root / ACTION_DIRECTORY / "action.json").read_text(encoding="utf-8")
    )["operation"]
    record = work / _RECORD
    record.unlink(missing_ok=True)
    log = work / "godot.out"
    command = [
        str((execroot / manifest["editor"]).resolve()),
        "--headless",
        "--path",
        str(root),
        "--log-file",
        str(work / "godot.log"),
        *args,
    ]
    with log.open("wb") as sink:
        process = subprocess.Popen(
            command,
            cwd=root,
            env=child_environment(work),
            stdout=sink,
            stderr=subprocess.STDOUT,
            start_new_session=NEW_SESSION,
        )
        try:
            stopped = _await_record(process, record, log, operation)
        finally:
            stop_process_group(process)
            process.wait()
    output = log.read_text(encoding="utf-8", errors="replace")
    result = _successful_record(record, output, operation, process.returncode)
    result["output"] = output
    result["stopped"] = stopped
    _note_ending(stopped, process.returncode, operation)
    return result


def add_manifest_arguments(parser: argparse.ArgumentParser) -> None:
    """Add the manifest, output and staging arguments every action takes."""
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--resource-path-manifest",
        dest="resource_path_manifests",
        action="append",
        default=[],
        type=Path,
        help="Resource path manifest of more paths to stage.",
    )
    parser.add_argument(
        "--import",
        dest="imports",
        action="append",
        default=[],
        help="Import result to stage, in order.",
    )
    parser.add_argument(
        "--editor", help="The editor executable, for actions that run it."
    )
    add_root_arguments(parser)


def load_manifest(args: argparse.Namespace) -> dict:
    """Read the action manifest and add the staged imports and resource paths."""
    resolve = resolver(args.roots)
    manifest = resolve_paths(
        json.loads(args.manifest.read_text(encoding="utf-8")), resolve
    )
    manifest["imports"] = args.imports
    if args.editor:
        manifest["editor"] = args.editor
    add_resource_path_manifests(manifest, args.resource_path_manifests, resolve)
    return manifest
