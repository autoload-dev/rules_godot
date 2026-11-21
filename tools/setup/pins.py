"""
Require the pins that the root module and its consumer modules share to agree.

Each module declares its own dependencies, as a consumer of rules_godot does, so Bazel
cannot see that they drift apart. This check reads every MODULE.bazel with Python's
ast and compares each pin that two or more modules declare.
"""

import sys
from collections import Counter
from collections.abc import Iterator
from pathlib import Path
from typing import Any

from tools.setup.modules import declarations, literals, module_paths

ARCHIVE = ("sha256", "urls")
# The attributes compared for each kind of declaration: a function, a repository rule or
# an `<extension>.<tag>`. Tags of other extensions are no pins.
ATTRIBUTES = {
    "bazel_dep": ("version",),
    "http_archive": ARCHIVE,
    "http_file": ARCHIVE,
    "godot_cpp_bindings": ("api_path",),
    "android_sdk_repository_extension.configure": ("api_level", "build_tools_version"),
    "godot_android_toolchains.configure": ("ndk_api_level",),
    "godot_engines.prebuilt": ("version",),
    "godot_engines.source": ("version", "sha256", "urls", "strip_prefix"),
}
MAVEN = "maven.install"
# Each consumer module overrides the ruleset with its checkout, so its version is no pin.
# An add-on module declares the release it needs instead.
UNPINNED = {"bazel_dep:autoload_rules_godot"}
# Deliberate drifts: module -> keys, such as "addons/<name>": {"bazel_dep:<module>"}, with
# the reason beside the entry. Remove an entry once its reason no longer holds.
EXCEPTIONS: dict[str, set[str]] = {
    # Firebase's Kotlin Multiplatform artifacts (androidx.datastore) need rules_jvm_external
    # 7.2 with the gradle resolver; the ruleset's modules stay on 6.10 until they move too.
    "addons/firebase": {"bazel_dep:rules_jvm_external"},
    "addons/firebase/examples": {"bazel_dep:rules_jvm_external"},
}


def _key(kind: str, name: str | None, attribute: str) -> str:
    if kind == "bazel_dep":
        return f"bazel_dep:{name}"
    if name is None:
        return f"{kind}:{attribute}"
    return f"{kind}:{name}.{attribute}"


def module_pins(source: str) -> dict[str, Any]:
    """Pins of one MODULE.bazel by `kind:name` key, such as `bazel_dep:rules_android`."""
    pins: dict[str, Any] = {}
    for declaration in declarations(source):
        kind = declaration.kind
        values = literals(declaration.keywords)
        name = values.get("name")
        if kind == MAVEN:
            # Maven coordinates group:artifact[:packaging[:classifier]]:version.
            for coordinate in values.get("artifacts", []):
                artifact, _, version = coordinate.rpartition(":")
                pins[f"{MAVEN}:{name}:{artifact}"] = version
        for attribute in ATTRIBUTES.get(kind, ()):
            if attribute in values:
                pins[_key(kind, name, attribute)] = values[attribute]
    return pins


def _format(value: Any) -> str:
    return ", ".join(value) if isinstance(value, list) else str(value)


def _shared_pins(root: Path, module: str) -> Iterator[tuple[str, str, Any]]:
    """The pins of one module that other modules must agree on, with their file."""
    path = root / module
    locations = {
        "MODULE.bazel": module_pins((path / "MODULE.bazel").read_text()),
        ".bazelversion": {"bazelversion": (path / ".bazelversion").read_text().strip()},
    }
    skipped = UNPINNED | EXCEPTIONS.get(module, set())
    for file, pins in locations.items():
        location = (Path(module) / file).as_posix()
        for key, value in pins.items():
            if key not in skipped:
                yield key, location, value


def drifts(root: Path) -> list[str]:
    """One line per module whose shared pin differs from the most common value."""
    declared: dict[str, dict[str, tuple[str, Any]]] = {}
    for module in module_paths(root):
        for key, location, value in _shared_pins(root, module):
            declared.setdefault(key, {})[module] = (location, value)
    lines = []
    for key, modules in declared.items():
        if len(modules) < 2:
            continue
        counts = Counter(repr(value) for _, value in modules.values())
        if len(counts) == 1:
            continue
        reference = counts.most_common(1)[0][0]
        location, value = [
            entry for entry in modules.values() if repr(entry[1]) == reference
        ][-1]
        for other, actual in modules.values():
            if repr(actual) != reference:
                lines.append(
                    f"{other}: {key} is {_format(actual)}, {location} has {_format(value)}"
                )
    return lines


def main(argv: list[str]) -> int:
    root = Path(argv[0]) if argv else Path(__file__).resolve().parents[2]
    lines = drifts(root)
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
