"""Tool regressions for parser boundaries, evaluated source locations, loading failures and caching."""

import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Literal
from unittest.mock import patch

from tools.conventions.context import (
    Bazel,
    Buildozer,
    Call,
    Context,
    EvidenceError,
    GeneratedFile,
    Location,
    SourceFile,
    Workspace,
    evaluated_source_label,
    has_literal_name,
    query_targets,
    string_literals,
)
from tools.conventions.test_support import Record, RepositoryTest, query_xml

BUILDOZER = Path(sys.argv.pop(1)).resolve()


class ContextTest(RepositoryTest):
    def test_imported_absolute_source_is_local_but_same_named_foreign_source_is_not(
        self,
    ) -> None:
        self.write("consumer/MODULE.bazel", "")
        self.write("consumer/BUILD.bazel", "")
        self.write("godot/app.bzl", "")
        call = Call(
            Location("consumer/BUILD.bazel", 1), "godot_app", frozenset({"name"}), "app"
        )
        records: list[Record] = [
            {
                "name": "//:app",
                "path": "consumer/BUILD.bazel",
                "strings": {"generator_function": "godot_app"},
            }
        ]
        context = self.context((call,), records)
        module = next(
            module
            for module in context.workspace.modules
            if module.path == Path("consumer")
        )
        declaration = context.declarations(module)[0]
        with tempfile.TemporaryDirectory() as temporary:
            external = Path(temporary) / "external"
            external.mkdir()
            (external / "main+").symlink_to(self.root, target_is_directory=True)
            imported = external / "main+/godot/app.bzl"
            self.tools.owners["//:app"] = ((str(imported), "godot_app"),)
            self.assertEqual(
                "//godot:app.bzl%godot_app", context.macro_owner(module, declaration)
            )
            (external / "foreign+").symlink_to(self.root, target_is_directory=True)
            self.tools.owners["//:app"] = (
                (str(external / "foreign+/godot/app.bzl"), "godot_app"),
            )
            self.assertEqual(
                "@@foreign+//godot:app.bzl%godot_app",
                context.macro_owner(module, declaration),
            )
        self.tools.owners["//:app"] = (("godot/app.bzl", "godot_app"),)
        self.assertEqual(
            "//consumer/godot:app.bzl%godot_app", context.macro_owner(module, declaration)
        )

    def test_evaluated_source_frames_become_repository_labels(self) -> None:
        module = self.context().workspace.modules[0]
        self.assertEqual(
            "//godot:app.bzl", evaluated_source_label(self.root, module, "godot/app.bzl")
        )

    def test_missing_and_ambiguous_evaluated_macro_owners_fail_closed(self) -> None:
        call = Call(Location("BUILD.bazel", 1), "godot_app", frozenset({"name"}), "app")
        records: list[Record] = [
            {
                "name": "//:app",
                "path": "BUILD.bazel",
                "strings": {"generator_function": "godot_app"},
                "owner": "//godot:app.bzl%godot_app",
            }
        ]
        context = self.context((call,), records)
        module = context.workspace.modules[0]
        declaration = context.declarations(module)[0]
        self.tools.owners = {}
        with self.assertRaisesRegex(EvidenceError, "missing evaluated macro"):
            context.macro_owner(module, declaration)
        records.append(
            {
                "name": "//:app.helper",
                "path": "BUILD.bazel",
                "strings": {"generator_function": "godot_app"},
                "owner": "//godot/other:app.bzl%godot_app",
            }
        )
        context = self.context((call,), records)
        module = context.workspace.modules[0]
        with self.assertRaisesRegex(EvidenceError, "ambiguous evaluated macro"):
            context.macro_owner(module, context.declarations(module)[0])

    def test_evaluated_instantiation_frames_preserve_defining_file_and_function(
        self,
    ) -> None:
        module = self.context().workspace.modules[0]
        evaluated = '{"rule":{"name":"//:app","instantiationStack":["BUILD.bazel:1:1: <toplevel>","godot/app.bzl:2:1: godot_app","godot/private/backend.bzl:3:1: helper"]}}'
        with patch("tools.conventions.context.run_tool", return_value=evaluated) as query:
            frames = Bazel(self.root).invocations(module)
        self.assertEqual(
            (("godot/app.bzl", "godot_app"), ("godot/private/backend.bzl", "helper")),
            frames["//:app"],
        )
        self.assertIn("--proto:instantiation_stack", query.call_args.args[0])

    def test_label_and_resource_membership_metadata_are_preserved(self) -> None:
        records: list[Record] = [
            {
                "name": "//:resources",
                "path": "BUILD.bazel",
                "kind": "godot_resources",
                "labels": {"project_file": "//:project.godot"},
                "label_lists": {"srcs": ["//:main/game.gd"], "deps": ["//:shared"]},
                "label_keyed_strings": {
                    "resource_paths": {"//:asset": "images/icon.svg"}
                },
                "outputs": ["//:generated.gd"],
            }
        ]
        target = query_targets(
            self.root, self.workspace().modules[0], query_xml(self.root, records)
        )[0]
        self.assertEqual("godot_resources", target.kind)
        self.assertEqual("//:project.godot", target.labels["project_file"])
        self.assertEqual(("//:main/game.gd",), target.label_lists["srcs"])
        self.assertEqual(
            {"//:asset": "images/icon.svg"}, target.label_keyed_strings["resource_paths"]
        )
        self.assertEqual(("//:generated.gd",), target.outputs)

    def test_generator_location_is_relative_to_the_declaring_repository(self) -> None:
        self.write("consumer/MODULE.bazel", "")
        self.write("consumer/BUILD.bazel", "")
        self.write("lib/fixtures/BUILD.bazel", "")
        consumer = next(
            module
            for module in self.workspace().modules
            if module.path == Path("consumer")
        )
        records: list[Record] = [
            {
                "name": "@root_module//lib/fixtures:helper",
                "path": "lib/fixtures/BUILD.bazel",
                "line": 4,
                "strings": {"generator_location": "lib/fixtures/BUILD.bazel:3:1"},
            }
        ]
        target = query_targets(self.root, consumer, query_xml(self.root, records))[0]
        self.assertEqual(Location("lib/fixtures/BUILD.bazel", 3), target.origin)

    def test_unresolvable_generator_location_takes_the_rule_location(self) -> None:
        self.write("consumer/MODULE.bazel", "")
        self.write("consumer/addon/BUILD.bazel", "")
        consumer = next(
            module
            for module in self.workspace().modules
            if module.path == Path("consumer")
        )
        records: list[Record] = [
            {
                "name": "//addon:addon",
                "path": "consumer/addon/BUILD.bazel",
                "line": 10,
                # What Bazel reports for a symbolic macro another module defines.
                "strings": {
                    "generator_location": "checkout/consumer/addon/BUILD.bazel:10:12"
                },
            }
        ]
        target = query_targets(self.root, consumer, query_xml(self.root, records))[0]
        self.assertEqual(Location("consumer/addon/BUILD.bazel", 10), target.origin)

    def test_module_local_labels_include_workspace_modules_only(self) -> None:
        self.write("consumer/MODULE.bazel", "")
        self.write("consumer/BUILD.bazel", "")
        context = self.context()
        self.assertEqual(frozenset({"main", "consumer"}), context.local_repositories)
        for label in ("//:a", "@//:a", "@consumer//:a", "@@consumer+//:a"):
            self.assertTrue(context.is_local(label), label)
        for label in ("@engine//:a", "@@+extension+consumer//:a"):
            self.assertFalse(context.is_local(label), label)

    def test_inspection_resolves_physical_source_owners_and_reuses_facts(self) -> None:
        self.write("application/project.godot", "")
        (self.root / "linked_repository").symlink_to(
            self.root / "application", target_is_directory=True
        )
        xml = '<query><source-file name="@local//:project.godot" location="linked_repository/project.godot:1:1"/><generated-file name="//:generated.gd"/></query>'
        tool = Bazel(self.root)
        module = self.workspace().modules[0]
        with patch("tools.conventions.context.run_tool", return_value=xml) as query:
            result = tool.inspect(module, ("@local//:project.godot", "//:generated.gd"))
            cached = tool.inspect(module, ("@local//:project.godot",))
        self.assertEqual(1, query.call_count)
        self.assertEqual(
            SourceFile("@local//:project.godot", self.root / "application/project.godot"),
            result["@local//:project.godot"],
        )
        self.assertIs(result["@local//:project.godot"], cached["@local//:project.godot"])
        self.assertIsInstance(result["//:generated.gd"], GeneratedFile)

    def test_incomplete_inspection_response_cannot_pass_as_no_sources(self) -> None:
        with (
            patch("tools.conventions.context.run_tool", return_value="<query/>"),
            self.assertRaisesRegex(EvidenceError, "did not resolve"),
        ):
            Bazel(self.root).inspect(self.workspace().modules[0], ("//:missing",))

    def test_configurable_boolean_without_a_scalar_value_remains_unknown(self) -> None:
        xml = '<query><rule class="filegroup" name="//:main" location="BUILD.bazel:1:1"><boolean name="known" value="true"/><boolean name="selected"/></rule></query>'
        target = query_targets(
            self.root, self.workspace().modules[0], ET.fromstring(xml)
        )[0]
        self.assertEqual({"known": True}, target.booleans)

    def test_parser_handles_comments_strings_nested_names_and_comprehensions(
        self,
    ) -> None:
        source = """
# fake(name = "bad-name")
package(default_visibility = ["//visibility:public"])
exports_files(["Bad-Source.json"])
custom(
    name = r"good_name",
    data = {"name": "bad-name"},
    text = "nested(name = 'bad-name')",
)
custom(name = "computed" + "_name")
[custom(name = name) for name in ["one", "two"]]
"""
        self.write("BUILD.bazel", source)
        tool = Buildozer(self.root, BUILDOZER)
        calls = tool.calls(self.workspace().modules[0])
        self.assertEqual(
            ["good_name", None, None],
            [call.literal_name for call in calls if call.kind == "custom"],
        )
        self.assertTrue(
            all("name" in call.attrs for call in calls if call.kind == "custom")
        )
        self.assertEqual(source, (self.root / "BUILD.bazel").read_text())

    def test_workspace_resolves_existing_files_to_their_nearest_module(self) -> None:
        for name in ("examples/MODULE.bazel", "examples/demo/BUILD", "README.md"):
            self.write(name, "")
        workspace = Workspace(
            self.root,
            (
                "MODULE.bazel",
                "BUILD.bazel",
                "examples/MODULE.bazel",
                "examples/demo/BUILD",
                "README.md",
                "deleted/BUILD.bazel",
            ),
        )
        self.assertNotIn("deleted/BUILD.bazel", workspace.files)
        self.assertEqual(Path("examples"), workspace.owner("examples/demo/README.md"))
        self.assertEqual(Path("."), workspace.owner("README.md"))
        self.assertEqual(
            [("",), ("demo",)], [module.packages for module in workspace.modules]
        )

    def test_repository_fixtures_belong_to_no_module(self) -> None:
        for name in ("fixtures/repo/REPO.bazel", "fixtures/repo/data/BUILD.bazel"):
            self.write(name, "")
        workspace = Workspace(
            self.root,
            (
                "MODULE.bazel",
                "BUILD.bazel",
                "fixtures/repo/REPO.bazel",
                "fixtures/repo/data/BUILD.bazel",
            ),
        )
        self.assertEqual([("",)], [module.packages for module in workspace.modules])

    def test_string_literals_skip_comments_and_keep_escapes(self) -> None:
        source = """# "comment"
load("//a:b.bzl", 'c')
text = r\"\"\"multi
line\"\"\"
escaped = "a\\"b"
"""
        self.assertEqual(
            [(2, "//a:b.bzl"), (2, "c"), (3, "multi\nline"), (5, 'a\\"b')],
            [
                (item.location.line, item.value)
                for item in string_literals("BUILD.bazel", source)
            ],
        )

    def test_literal_detection_does_not_evaluate_starlark(self) -> None:
        for source in (
            'target(name = "simple")',
            'target(name = r"raw")',
            'target(name = """multi\nline""")',
            'target(\n# name = computed\nname = "good", data = {"name": "bad"})',
        ):
            self.assertTrue(has_literal_name(source), source)
        for source in (
            'helper(data = {"name": "bad"})',
            'target(name = "computed" + suffix)',
            "target(name = name)",
            'target(**{"name": "hidden"})',
        ):
            self.assertFalse(has_literal_name(source), source)

    def test_missing_or_ambiguous_source_evidence_stops_the_audit(self) -> None:
        for calls in (
            (),
            (
                Call(Location("BUILD.bazel", 1), "a", frozenset()),
                Call(Location("BUILD.bazel", 1), "b", frozenset()),
            ),
        ):
            context = self.context(calls, [{"name": "//:target", "path": "BUILD.bazel"}])
            with self.assertRaisesRegex(ValueError, "expected one parsed declaration"):
                context.declarations(context.workspace.modules[0])

    def test_declarations_preserve_fanout_and_share_the_tool_snapshot(self) -> None:
        call = Call(Location("BUILD.bazel", 1), "custom", frozenset({"name"}), "main")
        context = self.context(
            (call,),
            [
                {"name": "//:main", "path": "BUILD.bazel"},
                {
                    "name": "//:main_helper",
                    "path": "BUILD.bazel",
                    "strings": {"generator_location": "BUILD.bazel:1:1"},
                },
            ],
        )
        module = context.workspace.modules[0]
        first = context.declarations(module)
        self.assertIs(first, context.declarations(module))
        self.assertEqual(2, len(first[0].targets))
        self.assertEqual((1, 1), (self.tools.call_requests, self.tools.rule_requests))

    def test_typed_directories_are_measured_from_the_owning_module(self) -> None:
        for name in (
            "examples/MODULE.bazel",
            "tests/MODULE.bazel",
            "consumers/demo/MODULE.bazel",
        ):
            self.write(name, "")
        workspace = self.workspace()
        self.assertEqual(
            ("projects", Path("examples/projects/x")),
            workspace.typed_directory(Path("examples/projects/x/BUILD.bazel")),
        )
        self.assertEqual(
            ("projects", Path("tests/y")),
            workspace.typed_directory(Path("tests/y/tests/android/BUILD.bazel")),
        )
        self.assertEqual(
            ("projects", Path("tests/smoke/linux")),
            workspace.typed_directory(Path("tests/smoke/linux/main/main.gd")),
        )
        self.assertEqual(
            ("addons", Path("tests/shared_addon")),
            workspace.typed_directory(Path("tests/shared_addon/demo/BUILD.bazel")),
        )
        self.assertEqual(
            ("addons", Path("consumers/demo/addons/z")),
            workspace.typed_directory(Path("consumers/demo/addons/z/BUILD.bazel")),
        )
        for name in (
            "godot/private/tests/BUILD.bazel",
            "tests/tools/x/BUILD.bazel",
            "tests/smoke/BUILD.bazel",
            "tests/BUILD.bazel",
            "projects/root/BUILD.bazel",
        ):
            with self.subTest(name=name):
                self.assertIsNone(workspace.typed_directory(Path(name)))

    def test_tools_visit_each_owning_module_once(self) -> None:
        files = (
            "MODULE.bazel",
            "BUILD.bazel",
            "examples/MODULE.bazel",
            "examples/BUILD.bazel",
            "tests/MODULE.bazel",
            "tests/BUILD.bazel",
        )
        for name in files:
            self.write(
                name,
                'filegroup(name = "valid")\n' if Path(name).name == "BUILD.bazel" else "",
            )
        process_run = subprocess.run
        queries: list[Path] = []
        parses: list[str] = []

        def dispatch(
            command: list[str],
            *,
            cwd: Path,
            capture_output: bool,
            text: Literal[True],
            check: bool,
            env: dict[str, str] | None = None,
        ) -> subprocess.CompletedProcess[str]:
            if command[0] != "bazel":
                parses.append(command[-1])
                return process_run(
                    command,
                    cwd=cwd,
                    capture_output=capture_output,
                    text=text,
                    check=check,
                )
            module = cwd.relative_to(self.root)
            self.assertIn("--xml:default_values", command)
            queries.append(module)
            xml = ET.tostring(
                query_xml(
                    self.root,
                    [{"name": "//:valid", "path": (module / "BUILD.bazel").as_posix()}],
                ),
                encoding="unicode",
            )
            return subprocess.CompletedProcess(command, 0, xml, "")

        context = Context(
            self.workspace(files), Buildozer(self.root, BUILDOZER), Bazel(self.root)
        )
        with patch("tools.conventions.context.subprocess.run", side_effect=dispatch):
            for module in context.workspace.modules:
                context.declarations(module)
                context.declarations(module)
                context.starlark.calls(module)
                context.bazel.rules(module)
        self.assertEqual({Path("."), Path("examples"), Path("tests")}, set(queries))
        self.assertEqual(3, len(queries))
        self.assertEqual(3, len(parses))

    def test_failed_query_is_not_an_empty_successful_result(self) -> None:
        with (
            patch(
                "tools.conventions.context.subprocess.run",
                side_effect=subprocess.CalledProcessError(
                    7, "bazel query", stderr="loading failed"
                ),
            ),
            self.assertRaisesRegex(EvidenceError, "exit status 7\nloading failed"),
        ):
            Bazel(self.root).rules(self.workspace().modules[0])


if __name__ == "__main__":
    unittest.main()
