"""Provide cached, read-only workspace, Starlark and Bazel facts to convention rules."""

import io
import json
import os
import subprocess
import tokenize
import xml.etree.ElementTree as ET
from collections import defaultdict
from collections.abc import Iterable, Mapping
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from functools import cached_property
from pathlib import Path
from types import MappingProxyType
from typing import Protocol

from tools.tool_environment import nested_tool_environment

BUILD_FILES = frozenset({"BUILD", "BUILD.bazel"})


def nearest(path: Path, roots: Iterable[Path]) -> Path | None:
    """The deepest root that contains path: a nested root owns its files, not the outer one."""
    owners = [root for root in roots if path.is_relative_to(root)]
    return max(owners, key=lambda root: len(root.parts)) if owners else None


# The typed roots of a consumer module, below its module root: projects/ and addons/.
TYPED_ROOTS = frozenset({"projects", "addons"})
# The regression module and its smoke paths, laid out by the verification architecture.
REGRESSION_MODULE = Path("tests")
SMOKE_ROOT = "smoke"
ADDON_SCENARIO = "shared_addon"
# Packages of the regression module that are no scenario, such as its Bazel launcher link.
REGRESSION_TOOLING = frozenset({"tools"})


class EvidenceError(ValueError):
    """An evidence tool could not produce complete facts; the audit cannot pass."""


@dataclass(frozen=True)
class Location:
    path: str
    line: int


@dataclass(frozen=True)
class Module:
    path: Path
    builds: tuple[Path, ...]

    @cached_property
    def packages(self) -> tuple[str, ...]:
        """Package names relative to the module; its root package is ``""``."""
        return tuple(
            "" if package == "." else package
            for package in (
                build.parent.relative_to(self.path).as_posix() for build in self.builds
            )
        )


@dataclass(frozen=True)
class Call:
    location: Location
    kind: str
    attrs: frozenset[str]
    literal_name: str | None = None


@dataclass(frozen=True)
class StringLiteral:
    location: Location
    # Contents between the quotes; escapes stay undecoded.
    value: str


@dataclass(frozen=True)
class Target:
    label: str
    location: Location
    strings: Mapping[str, str]
    booleans: Mapping[str, bool]
    generator_location: Location | None
    kind: str
    labels: Mapping[str, str]
    label_lists: Mapping[str, tuple[str, ...]]
    label_keyed_strings: Mapping[str, Mapping[str, str]]
    outputs: tuple[str, ...]

    @property
    def origin(self) -> Location:
        """The authored call: a macro's caller, otherwise the rule's own location."""
        return self.generator_location or self.location

    def authored_inputs(self) -> frozenset[str]:
        """
        Labels in attributes the declaration chose.

        Implicit attributes come from the rule definition, and visibility grants
        access rather than consuming anything.
        """

        def authored(attribute: str) -> bool:
            return not attribute.startswith(("$", ":")) and attribute != "visibility"

        inputs = {value for name, value in self.labels.items() if authored(name)}
        for name, labels in self.label_lists.items():
            if authored(name):
                inputs.update(labels)
        for name, mapping in self.label_keyed_strings.items():
            if authored(name):
                inputs.update(mapping)
        return frozenset(inputs)


def evaluated_source_label(root: Path, module: Module, file: str) -> str:
    """Turn an evaluated source frame into its repository-qualified Starlark label."""
    if file.startswith(("@", "//")) and "//" in file:
        repository, _, relative = file.partition("//")
        if ":" in relative:
            return repository + "//" + relative
        directory, _, basename = relative.rpartition("/")
        return repository + "//" + directory + ":" + basename
    path = Path(file)
    main = root / module.path
    if path.is_absolute() and path.is_relative_to(main):
        path = path.relative_to(main)
    elif "/external/" in file or file.startswith("external/"):
        external = (
            file.split("/external/", 1)[1]
            if "/external/" in file
            else file.removeprefix("external/")
        )
        repository, separator, relative = external.partition("/")
        if not separator:
            raise EvidenceError("unresolved evaluated external source: " + file)
        directory, _, basename = relative.rpartition("/")
        return "@@" + repository + "//" + directory + ":" + basename
    elif path.is_absolute():
        resolved = path.resolve()
        if not resolved.is_relative_to(main.resolve()):
            raise EvidenceError("unresolved evaluated source repository: " + file)
        path = resolved.relative_to(main.resolve())
    directory = path.parent.as_posix()
    return "//" + ("" if directory == "." else directory) + ":" + path.name


def evaluated_frames(stack: Iterable[str]) -> tuple[tuple[str, str], ...]:
    """Retain named Starlark call frames supplied by Bazel, without source guessing."""
    result = []
    for frame in stack:
        file, _, _, function = frame.rsplit(":", 3)
        if file.endswith(".bzl") and function.strip() != "<toplevel>":
            result.append((file, function.strip()))
    return tuple(result)


@dataclass(frozen=True)
class SourceFile:
    label: str
    path: Path


@dataclass(frozen=True)
class GeneratedFile:
    label: str


Fact = Target | SourceFile | GeneratedFile


@dataclass(frozen=True)
class Declaration:
    call: Call
    targets: tuple[Target, ...]


class StarlarkTool(Protocol):
    def calls(self, module: Module) -> tuple[Call, ...]: ...

    def module_name(self, module: Module) -> str: ...


class BazelTool(Protocol):
    def rules(self, module: Module) -> tuple[Target, ...]: ...

    def inspect(self, module: Module, labels: tuple[str, ...]) -> Mapping[str, Fact]: ...

    def invocations(
        self, module: Module
    ) -> Mapping[str, tuple[tuple[str, str], ...]]: ...


class Workspace:
    def __init__(self, root: Path, files: tuple[str, ...]) -> None:
        self.root = root
        # Git also lists tracked files that were deleted from the working tree.
        self.files = tuple(sorted({name for name in files if (root / name).is_file()}))
        self._texts: dict[str, str] = {}
        self._strings: dict[str, tuple[StringLiteral, ...]] = {}
        self._typed_directories: dict[str, Mapping[Path, tuple[str, ...]]] = {}

    @cached_property
    def file_set(self) -> frozenset[str]:
        return frozenset(self.files)

    @cached_property
    def documents(self) -> tuple[str, ...]:
        """Markdown under docs/ and every README; AGENTS.md files instruct agents instead."""
        return tuple(
            name
            for name in self.files
            if Path(name).suffix == ".md"
            and (name.startswith("docs/") or Path(name).name.lower().startswith("readme"))
            and Path(name).name != "AGENTS.md"
        )

    @cached_property
    def godot_configurations(self) -> tuple[Path, ...]:
        """Every ``project.godot`` file."""
        return tuple(
            Path(name) for name in self.files if Path(name).name == "project.godot"
        )

    def has_build(self, directory: Path) -> bool:
        """Whether a BUILD file makes the directory a package."""
        return any((directory / name).as_posix() in self.file_set for name in BUILD_FILES)

    def typed_directory(self, path: Path) -> tuple[str, Path] | None:
        """
        Return the kind and root of the project or add-on directory
        ``<module>/<kind>/<name>/`` that path lies in; the root module has no typed roots,
        and the regression module's scenario packages are its projects.
        """
        module = self.owner(path.as_posix())
        if module == Path("."):
            return None
        parts = path.relative_to(module).parts
        if module == REGRESSION_MODULE:
            # The regression module's consumer scenarios: one project package per scenario and
            # per operating system below smoke/; the shared add-on scenario is an add-on.
            if parts[0] == SMOKE_ROOT and len(parts) > 2:
                return "projects", module / Path(*parts[:2])
            if parts[0] == ADDON_SCENARIO and len(parts) > 1:
                return "addons", module / ADDON_SCENARIO
            if (
                parts[0] not in REGRESSION_TOOLING | {SMOKE_ROOT, ADDON_SCENARIO}
                and len(parts) > 1
            ):
                return "projects", module / parts[0]
            return None
        if len(parts) > 2 and parts[0] in TYPED_ROOTS:
            return parts[0], module / Path(*parts[:2])
        return None

    def typed_directories(self, kind: str) -> Mapping[Path, tuple[str, ...]]:
        """Map each project or add-on directory ``<module>/<kind>/<name>`` to its files."""
        if kind not in self._typed_directories:
            members: dict[Path, list[str]] = defaultdict(list)
            for name in self.files:
                owner = self.typed_directory(Path(name))
                if owner is not None and owner[0] == kind:
                    members[owner[1]].append(name)
            self._typed_directories[kind] = MappingProxyType(
                {root: tuple(files) for root, files in sorted(members.items())}
            )
        return self._typed_directories[kind]

    def _roots(self, marker: str) -> tuple[Path, ...]:
        """Directories holding a file named marker, such as MODULE.bazel."""
        return tuple(
            Path(name).parent for name in self.files if Path(name).name == marker
        )

    @cached_property
    def module_paths(self) -> tuple[Path, ...]:
        return self._roots("MODULE.bazel")

    def owner(self, name: str) -> Path:
        """Return the nearest module directory, including nested standalone modules."""
        owner = nearest(Path(name), self.module_paths)
        if owner is None:
            raise EvidenceError(f"{name}: no owning MODULE.bazel")
        return owner

    @cached_property
    def repository_paths(self) -> tuple[Path, ...]:
        """Roots of repositories that are no module, such as local_repository fixtures."""
        return self._roots("REPO.bazel")

    @cached_property
    def modules(self) -> tuple[Module, ...]:
        """
        Resolve owned BUILD files against their nearest module without loading Bazel; a
        repository below a module that is no module itself belongs to none.
        """
        builds: dict[Path, list[Path]] = defaultdict(list)
        for name in self.files:
            if Path(name).name in BUILD_FILES:
                owner = self.owner(name)
                repository = nearest(Path(name), self.repository_paths)
                if repository is None or owner.is_relative_to(repository):
                    builds[owner].append(Path(name))
        return tuple(Module(path, tuple(files)) for path, files in sorted(builds.items()))

    def text(self, name: str) -> str:
        if name not in self._texts:
            try:
                self._texts[name] = (self.root / name).read_text()
            except (OSError, UnicodeDecodeError) as error:
                raise EvidenceError(f"{name}: cannot read: {error}") from error
        return self._texts[name]

    def strings(self, name: str) -> tuple[StringLiteral, ...]:
        """String literals of a Starlark file (BUILD, MODULE.bazel or .bzl)."""
        if name not in self._strings:
            self._strings[name] = string_literals(name, self.text(name))
        return self._strings[name]


def has_literal_name(source: str) -> bool:
    """
    Recognize one literal argument in Buildozer's already-parsed, formatted call.

    This only tokenizes delimiters and strings; it does not parse or evaluate
    Starlark. Buildozer supplies the decoded value, so Python's string semantics
    are never substituted for Starlark's.
    """
    try:
        tokens = [
            token
            for token in tokenize.generate_tokens(io.StringIO(source).readline)
            if token.type
            not in {
                tokenize.COMMENT,
                tokenize.NL,
                tokenize.NEWLINE,
                tokenize.ENDMARKER,
                tokenize.INDENT,
                tokenize.DEDENT,
            }
        ]
    except tokenize.TokenError as error:
        raise EvidenceError(f"cannot tokenize parsed call: {error}") from error
    depth = 0
    for index, token in enumerate(tokens):
        if token.string in {"(", "[", "{"}:
            depth += 1
        elif token.string in {")", "]", "}"}:
            depth -= 1
        elif (
            depth == 1
            and token.string == "name"
            and index > 0
            and tokens[index - 1].string in {"(", ","}
            and index + 3 < len(tokens)
            and tokens[index + 1].string == "="
        ):
            return tokens[index + 2].type == tokenize.STRING and tokens[
                index + 3
            ].string in {",", ")"}
    return False


def string_literals(name: str, text: str) -> tuple[StringLiteral, ...]:
    """
    List string literals in Starlark source without evaluating it.

    Comments are skipped by the tokenizer. Contents keep their escapes undecoded,
    so Python's string semantics are never substituted for Starlark's.
    """
    try:
        tokens = tuple(tokenize.generate_tokens(io.StringIO(text).readline))
    except tokenize.TokenError as error:
        raise EvidenceError(f"{name}: cannot tokenize: {error}") from error
    literals = []
    for token in tokens:
        if token.type != tokenize.STRING:
            continue
        body = token.string.lstrip("rRbBuU")
        quotes = 3 if body[:3] in {'"""', "'''"} else 1
        literals.append(
            StringLiteral(Location(name, token.start[0]), body[quotes:-quotes])
        )
    return tuple(literals)


def run_tool(command: list[str], cwd: Path) -> str:
    """Return a tool's output, or fail the audit with its diagnostics."""
    try:
        environment = (
            {"env": nested_tool_environment(os.environ)}
            if Path(command[0]).name == "bazel"
            else {}
        )
        return subprocess.run(
            command, cwd=cwd, capture_output=True, text=True, check=True, **environment
        ).stdout
    except subprocess.CalledProcessError as error:
        raise EvidenceError(
            f"{Path(command[0]).name} failed with exit status {error.returncode}\n"
            + (error.stderr or "")
        ) from error
    except OSError as error:
        raise EvidenceError(f"cannot run {command[0]}: {error}") from error


class Buildozer:
    def __init__(self, root: Path, executable: Path) -> None:
        self.root = root
        self.executable = executable
        self._calls: dict[Module, tuple[Call, ...]] = {}
        self._names: dict[Module, str] = {}

    def module_name(self, module: Module) -> str:
        """The name the module declares in its MODULE.bazel."""
        if module not in self._names:
            output = run_tool(
                [
                    str(self.executable),
                    "-output_json",
                    "print name",
                    str(self.root / module.path / "MODULE.bazel") + ":%module",
                ],
                self.root,
            )
            records = json.loads(output).get("records", [])
            if len(records) != 1:
                raise EvidenceError(f"{module.path}/MODULE.bazel: expected one module()")
            self._names[module] = records[0]["fields"][0]["text"]
        return self._names[module]

    def calls(self, module: Module) -> tuple[Call, ...]:
        """Read syntax through the pinned parser; never evaluate Starlark with Python."""
        if module in self._calls:
            return self._calls[module]
        output = run_tool(
            [
                str(self.executable),
                "-output_json",
                "-respect_bazelignore=false",
                "print kind attrs path startline name rule",
                *[str(self.root / build.parent) + ":*" for build in module.builds],
            ],
            self.root,
        )
        calls = []
        for record in json.loads(output).get("records", []):
            kind, attrs, path, line, name, source = record["fields"]
            calls.append(
                Call(
                    Location(
                        Path(path["text"]).relative_to(self.root).as_posix(),
                        line["number"],
                    ),
                    kind["text"],
                    frozenset(attrs.get("list", {}).get("strings", [])),
                    name.get("text", "") if has_literal_name(source["text"]) else None,
                )
            )
        self._calls[module] = tuple(calls)
        return self._calls[module]


def location(root: Path, base: Path, value: str) -> Location:
    """Resolve a ``path:line:column`` value; relative paths start at base."""
    path, line, _column = value.rsplit(":", 2)
    source = Path(path)
    if not source.is_absolute():
        source = base / source
    source = source.resolve()
    name = (
        source.relative_to(root).as_posix()
        if source.is_relative_to(root)
        else str(source)
    )
    return Location(name, int(line))


def repository_root(root: Path, module: Module, rule: ET.Element) -> Path:
    """
    Return the root of the repository declaring a rule.

    Bazel reports generator_location relative to that repository, which differs from
    the querying module for targets of other modules.
    """
    build = Path(rule.attrib["location"].rsplit(":", 2)[0])
    if not build.is_absolute():
        build = root / module.path / build
    repository = build.parent
    for _ in Path(rule.attrib["name"].partition("//")[2].partition(":")[0]).parts:
        repository = repository.parent
    return repository


def generator_location(
    root: Path, module: Module, rule: ET.Element, origin: str | None
) -> Location | None:
    """The authored macro call, or None where Bazel names no file (another module's macro)."""
    if not origin:
        return None
    resolved = location(root, repository_root(root, module, rule), origin)
    return resolved if (root / resolved.path).is_file() else None


def query_targets(root: Path, module: Module, query: ET.Element) -> tuple[Target, ...]:
    """Decode loading metadata without naming policy, exemptions or diagnostics."""
    targets = []
    for rule in query.findall("rule"):
        strings = {
            item.attrib["name"]: item.attrib.get("value", "")
            for item in rule.findall("string")
        }
        booleans = {
            item.attrib["name"]: item.attrib["value"] == "true"
            for item in rule.findall("boolean")
            if "value" in item.attrib
        }
        origin = strings.get("generator_location")
        labels = {
            item.attrib["name"]: item.attrib["value"]
            for item in rule.findall("label")
            if "value" in item.attrib
        }
        label_lists = {
            item.attrib["name"]: tuple(child.attrib["value"] for child in item)
            for item in rule.findall("list")
            if all(child.tag == "label" and "value" in child.attrib for child in item)
        }
        label_keyed_strings = {}
        for item in rule.findall("dict"):
            pairs = item.findall("pair")
            if len(pairs) == len(item) and all(
                len(pair) == 2
                and pair[0].tag == "label"
                and pair[1].tag == "string"
                and "value" in pair[0].attrib
                and "value" in pair[1].attrib
                for pair in pairs
            ):
                label_keyed_strings[item.attrib["name"]] = MappingProxyType(
                    {pair[0].attrib["value"]: pair[1].attrib["value"] for pair in pairs}
                )
        targets.append(
            Target(
                label=rule.attrib["name"],
                location=location(root, root / module.path, rule.attrib["location"]),
                strings=MappingProxyType(strings),
                booleans=MappingProxyType(booleans),
                generator_location=generator_location(root, module, rule, origin),
                kind=rule.attrib["class"],
                labels=MappingProxyType(labels),
                label_lists=MappingProxyType(label_lists),
                label_keyed_strings=MappingProxyType(label_keyed_strings),
                outputs=tuple(
                    item.attrib["name"] for item in rule.findall("rule-output")
                ),
            )
        )
    return tuple(targets)


class Bazel:
    def __init__(self, root: Path) -> None:
        self.root = root
        self._rules: dict[Module, tuple[Target, ...]] = {}
        self._facts: dict[Module, dict[str, Fact]] = {}
        self._invocations: dict[Module, Mapping[str, tuple[tuple[str, str], ...]]] = {}

    def query(self, module: Module, expression: str) -> ET.Element:
        """Run a loading query and return its XML with default attribute values."""
        output = run_tool(
            [
                "bazel",
                "query",
                expression,
                "--output=xml",
                "--xml:default_values",
                "--noshow_progress",
            ],
            self.root / module.path,
        )
        try:
            return ET.fromstring(output)
        except ET.ParseError as error:
            raise EvidenceError(f"cannot parse Bazel query output: {error}") from error

    def invocations(self, module: Module) -> Mapping[str, tuple[tuple[str, str], ...]]:
        """Evaluated source/function frames, including each outermost macro owner."""
        if module not in self._invocations:
            patterns = ["//" + package + ":all" for package in module.packages]
            output = run_tool(
                [
                    "bazel",
                    "query",
                    "kind(rule, set(" + " ".join(patterns) + "))",
                    "--output=streamed_jsonproto",
                    "--proto:instantiation_stack",
                    "--noshow_progress",
                ],
                self.root / module.path,
            )
            result = {}
            for line in output.splitlines():
                try:
                    value = json.loads(line)["rule"]
                    result[value["name"]] = evaluated_frames(
                        value.get("instantiationStack", [])
                    )
                except (ValueError, KeyError) as error:
                    raise EvidenceError(
                        f"invalid evaluated instantiation evidence: {error}"
                    ) from error
            self._invocations[module] = MappingProxyType(result)
        return self._invocations[module]

    def rules(self, module: Module) -> tuple[Target, ...]:
        if module in self._rules:
            return self._rules[module]
        patterns = ["//" + package + ":all" for package in module.packages]
        query = self.query(module, "kind(rule, set(" + " ".join(patterns) + "))")
        self._rules[module] = query_targets(self.root, module, query)
        self._facts.setdefault(module, {}).update(
            {target.label: target for target in self._rules[module]}
        )
        return self._rules[module]

    def inspect(self, module: Module, labels: tuple[str, ...]) -> Mapping[str, Fact]:
        """Resolve explicit labels, including external repositories, without analysis."""
        cache = self._facts.setdefault(module, {})
        missing = sorted(set(labels) - cache.keys())
        if missing:
            query = self.query(
                module, "set(" + " ".join(json.dumps(label) for label in missing) + ")"
            )
            cache.update(
                {
                    target.label: target
                    for target in query_targets(self.root, module, query)
                }
            )
            for source in query:
                label = source.attrib["name"]
                if source.tag == "source-file":
                    value = location(
                        self.root, self.root / module.path, source.attrib["location"]
                    )
                    cache[label] = SourceFile(label, (self.root / value.path).resolve())
                elif source.tag == "generated-file":
                    cache[label] = GeneratedFile(label)
            unresolved = set(missing) - cache.keys()
            if unresolved:
                raise EvidenceError(
                    "Bazel did not resolve labels: " + ", ".join(sorted(unresolved))
                )
        return MappingProxyType({label: cache[label] for label in labels})


class Context:
    def __init__(
        self, workspace: Workspace, starlark: StarlarkTool, bazel: BazelTool
    ) -> None:
        self.workspace = workspace
        self.starlark = starlark
        self.bazel = bazel
        self._declarations: dict[Module, tuple[Declaration, ...]] = {}

    @cached_property
    def local_repositories(self) -> frozenset[str]:
        """Names of the modules whose sources this workspace owns."""
        return frozenset(self.starlark.module_name(m) for m in self.workspace.modules)

    def is_local(self, label: str) -> bool:
        """Whether a label names a package of one of the workspace's own modules."""
        repository = label.partition("//")[0].lstrip("@")
        # A module's canonical repository name ends with "+"; extension repositories
        # contain further "+" separators and never match a module name.
        return repository == "" or repository.removesuffix("+") in self.local_repositories

    def sources(self, module: Module, labels: Iterable[str]) -> Mapping[str, Path]:
        """
        Map repository labels to the workspace path that defines them.

        A target maps to its authored call's BUILD file, a source file to its
        resolved path and a generated file to its place in the generating package.
        External labels and sources resolving outside the workspace are omitted:
        no workspace path owns them.
        """
        local = tuple(sorted({label for label in labels if self.is_local(label)}))
        facts = self.bazel.inspect(module, local) if local else {}
        root = self.workspace.root
        paths: dict[str, Path] = {}
        for label, fact in facts.items():
            if isinstance(fact, Target):
                paths[label] = Path(fact.origin.path)
            elif isinstance(fact, SourceFile) and fact.path.is_relative_to(root):
                paths[label] = fact.path.relative_to(root)
            elif isinstance(fact, GeneratedFile):
                paths[label] = self._package_path(module, label)
        return MappingProxyType(paths)

    @cached_property
    def _module_paths(self) -> Mapping[str, Path]:
        return MappingProxyType(
            {self.starlark.module_name(m): m.path for m in self.workspace.modules}
        )

    def _package_path(self, module: Module, label: str) -> Path:
        """Return the workspace path a local label names inside its package."""
        repository, _, rest = label.partition("//")
        name = repository.lstrip("@").removesuffix("+")
        package, _, target = rest.partition(":")
        base = module.path if not name else self._module_paths[name]
        return base / package / target

    def macro_owner(self, module: Module, declaration: Declaration) -> str | None:
        """Resolve the evaluated outer macro's physical source, never its name alone."""
        invocations = self.bazel.invocations(module)
        owners = set()
        for target in declaration.targets:
            frames = invocations.get(target.label, ())
            if not frames:
                if target.strings.get("generator_function"):
                    raise EvidenceError(
                        f"{target.label}: missing evaluated macro instantiation ownership"
                    )
                continue
            file, function = frames[0]
            label = evaluated_source_label(self.workspace.root, module, file)
            repository, _, relative = label.partition("//")
            name = repository.lstrip("@").removesuffix("+")
            base = module.path if not name else self._module_paths.get(name)
            if base is None:
                owners.add(label + "%" + function)
                continue
            path = base / relative.replace(":", "/")
            directory = path.parent.as_posix()
            owners.add(
                "//"
                + ("" if directory == "." else directory)
                + ":"
                + path.name
                + "%"
                + function
            )
        if len(owners) > 1:
            raise EvidenceError(
                f"{declaration.call.location}: ambiguous evaluated macro ownership: {sorted(owners)}"
            )
        return next(iter(owners), None)

    def declarations(self, module: Module) -> tuple[Declaration, ...]:
        """Join parsed source calls and evaluated targets, retaining macro fan-out."""
        if module not in self._declarations:
            # Modules are separate Bazel workspaces: load all of them concurrently,
            # since a rule which needs one module's declarations visits every module.
            modules = [m for m in self.workspace.modules if m not in self._declarations]
            if module not in modules:
                modules.append(module)
            with ThreadPoolExecutor() as pool:
                calls = {m: pool.submit(self.starlark.calls, m) for m in modules}
                rules = {m: pool.submit(self.bazel.rules, m) for m in modules}
                for m in modules:
                    self._declarations[m] = join(calls[m].result(), rules[m].result())
        return self._declarations[module]


def join(calls: tuple[Call, ...], rules: tuple[Target, ...]) -> tuple[Declaration, ...]:
    """Attach each evaluated target to the one authored BUILD call it came from."""
    by_location: dict[Location, list[Call]] = defaultdict(list)
    for call in calls:
        by_location[call.location].append(call)
    targets: dict[Location, list[Target]] = defaultdict(list)
    for target in rules:
        origin = target.origin
        # Macro implementation calls are generated, not authored BUILD declarations.
        if Path(origin.path).name not in BUILD_FILES:
            continue
        candidates = by_location.get(origin, [])
        if len(candidates) != 1:
            raise EvidenceError(
                f"{origin.path}:{origin.line}: expected one parsed declaration, found {len(candidates)}"
            )
        targets[origin].append(target)
    return tuple(
        Declaration(by_location[origin][0], tuple(items))
        for origin, items in targets.items()
    )
