"""RG007: Godot test operations and their generated helpers are test-only."""

from collections.abc import Iterable

from tools.conventions.context import Context
from tools.conventions.framework import Finding, RuleInfo

# gdunit_test is autoload_gdunit's test operation.
OPERATIONS = frozenset({"godot_test", "gdunit_test"})


class TestOnlyOperations:
    info = RuleInfo(
        "RG007",
        "Godot test operations and their helpers are test-only",
        "docs/public/conventions.md#rg007",
    )

    def evaluate(self, context: Context) -> Iterable[Finding]:
        for module in context.workspace.modules:
            for declaration in context.declarations(module):
                call = declaration.call
                operations = [
                    target
                    for target in declaration.targets
                    if target.strings.get("generator_function") in OPERATIONS
                ]
                if not operations:
                    if call.kind in OPERATIONS:
                        yield Finding(
                            call.location,
                            "cannot identify test operation from Bazel generator metadata",
                            "not_checked",
                        )
                    continue
                for target in declaration.targets:
                    if target not in operations:
                        yield Finding(
                            call.location,
                            f"cannot attribute {target.label} to a Godot test operation",
                            "not_checked",
                        )
                for target in operations:
                    value = target.booleans.get("testonly")
                    if value is None:
                        yield Finding(
                            call.location,
                            f"cannot determine effective testonly for {target.label}",
                            "not_checked",
                        )
                    elif not value:
                        yield Finding(
                            call.location,
                            f"{target.label} must be testonly; remove testonly = False "
                            "from the test operation",
                        )
