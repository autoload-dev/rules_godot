import contextlib
import hashlib
import io
import json
import struct
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import godot_actions, godot_export, godot_staging
from tools.godot_actions import (
    import_base,
    import_resources,
    importable_suffixes,
    importer_mismatches,
    initialize,
)
from tools.godot_export import (
    exclusive_export,
    export_lock,
    export_presets,
    validate_pck,
)
from tools.godot_staging import (
    IMPORT_ARCHIVE,
    add_resource_path_manifests,
    copy_file,
    executable,
    join_action,
    resource_path,
    run_action,
    same_content,
    stage,
    validate_staged_paths,
    write_archive,
)
from tools.mapped_paths import resolve_paths, resolver
from tools.node_ids import with_node_ids
from tools.pack_contents import content_selection, inspect_export
from tools.pck import add_pck_files, pck_contents, pck_file_contents


def pck_bytes(
    version: int = 4, engine: tuple[int, int, int] = (4, 7, 2), padding: int = 0
) -> bytes:
    """A PCK header with an empty directory at offset 40."""
    return struct.pack("<6IQQI", 0x43504447, version, *engine, 0, 0, 40, 0) + bytes(
        padding
    )


def write_pck(path: Path) -> Path:
    path.write_bytes(pck_bytes(padding=128))
    return path


class ActionTest(unittest.TestCase):
    def test_extensions_are_registered_before_cold_editor_start(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            (base / "extension").write_text(
                '[configuration]\nentry_symbol="example_init"\n'
            )
            root = base / "project"
            root.mkdir()
            stage(
                {
                    "project_file": "project.godot",
                    "member_resource_paths": {
                        "native/b.gdextension": "extension",
                        "native/a.gdextension": "extension",
                    },
                },
                root,
                base,
            )
            self.assertEqual(
                (root / ".godot/extension_list.cfg").read_text(),
                "res://native/a.gdextension\nres://native/b.gdextension\n",
            )

    def test_added_pck_files_replace_and_extend_godots_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            godot = base / "godot.pck"
            add_pck_files(
                write_pck(base / "empty.pck"),
                godot,
                {"a.txt": b"a", ".godot/extension_list.cfg": b"res://x.gdextension\n"},
            )
            files = {
                ".godot/extension_list.cfg": b"res://x.gdextension\nres://y.gdextension\n",
                "y.gdextension": b"[configuration]\n",
            }
            first, second = base / "first.pck", base / "second.pck"
            add_pck_files(godot, first, files)
            add_pck_files(godot, second, files)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            contents = pck_file_contents(first, include_paths=True)
            self.assertEqual(
                [".godot/extension_list.cfg", "a.txt", "y.gdextension"],
                contents["paths"],
            )
            self.assertEqual(
                ["res://x.gdextension", "res://y.gdextension"], contents["extension_list"]
            )
            self.assertEqual(
                {"y.gdextension": "[configuration]\n"}, contents["extension_descriptors"]
            )

    def test_staged_copies_keep_the_executable_bit(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            handler = root / "crash_handler"
            handler.write_bytes(b"handler")
            handler.chmod(0o555)
            notice = root / "notice.txt"
            notice.write_bytes(b"notice")
            copy_file(handler, root / "staged/crash_handler")
            copy_file(notice, root / "staged/notice.txt")
            self.assertTrue(executable(root / "staged/crash_handler"))
            self.assertFalse(executable(root / "staged/notice.txt"))
            member = tarfile.TarInfo("crash_handler")
            member.mode = 0o755
            self.assertTrue(executable((root / "unit.tar", member)))
            self.assertFalse(executable(b"bytes"))

    def test_resource_identities_reject_escaping_paths(self) -> None:
        for path in ["../x", "/x", "a/../b", "a//b", "res://x", "a\\b", ""]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                resource_path(path)
        self.assertEqual(resource_path("generated/a.tres"), "generated/a.tres")

    def test_staging_rejects_case_and_unicode_aliases_before_copying(self) -> None:
        for paths in [
            ("A.gd", "a.gd"),
            ("Assets/a.gd", "assets/b.gd"),
            ("a", "a/b"),
            ("caf\u00e9/a.gd", "cafe\u0301/b.gd"),
        ]:
            with (
                self.subTest(paths=paths),
                self.assertRaisesRegex(ValueError, "Conflicting"),
            ):
                validate_staged_paths({path: "input" for path in paths})
        validate_staged_paths({"a/a.gd": "one", "a/b.gd": "two"})

    def test_overlapping_imports_must_have_identical_content(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            for name, content in [("one", "a"), ("two", "b")]:
                (base / name / ".godot/imported").mkdir(parents=True)
                (base / name / ".godot/imported/x.ctex").write_text(content)
            root = base / "staged"
            root.mkdir()
            with self.assertRaisesRegex(ValueError, "Conflicting import results"):
                stage(
                    {
                        "project_file": "project.godot",
                        "member_resource_paths": {},
                        "imports": ["one", "two"],
                    },
                    root,
                    base,
                )

    def test_cached_import_cannot_replace_an_authored_uid(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            (base / "script.gd").write_text("extends Node\n")
            (base / "script.gd.uid").write_text("uid://authored\n")
            (base / "cached").mkdir()
            cached_uid = base / "cached/script.gd.uid"
            cached_uid.write_text("uid://generated\n")
            manifest = {
                "project_file": "project.godot",
                "member_resource_paths": {
                    "script.gd": "script.gd",
                    "script.gd.uid": "script.gd.uid",
                },
                "imports": ["cached"],
            }
            root = base / "staged"
            root.mkdir()
            with self.assertRaisesRegex(
                ValueError, "Cached import UID conflicts with authored sidecar"
            ):
                stage(manifest, root, base)
            cached_uid.write_text("uid://authored")
            stage(manifest, root, base)
            self.assertEqual("uid://authored", (root / "script.gd.uid").read_text())

    def test_cached_import_aliases_are_rejected_before_copying(self) -> None:
        aliases = [
            ("script.gd.UID", "script.gd.uid"),
            ("Assets/script.gd.uid", "assets/script.gd.uid"),
            ("caf\u00e9/script.gd.uid", "cafe\u0301/script.gd.uid"),
        ]
        for authored, cached in aliases:
            with (
                self.subTest(authored=authored, cached=cached),
                tempfile.TemporaryDirectory() as temp,
            ):
                base = Path(temp)
                (base / "project.godot").write_text("config_version=5\n")
                (base / "authored_uid").write_text("uid://authored\n")
                cached_uid = base / "cached" / cached
                cached_uid.parent.mkdir(parents=True)
                cached_uid.write_text("uid://generated\n")
                root = base / "staged"
                root.mkdir()
                manifest = {
                    "project_file": "project.godot",
                    "member_resource_paths": {authored: "authored_uid"},
                    "imports": ["cached"],
                }
                with self.assertRaisesRegex(
                    ValueError, "Conflicting portable Godot paths"
                ):
                    stage(manifest, root, base)
                self.assertEqual([], list(root.iterdir()))

    def test_cached_import_results_cannot_alias_each_other(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            for result, filename in [
                ("one", ".godot/imported/FILE.ctex"),
                ("two", ".godot/imported/file.ctex"),
            ]:
                cached = base / result / filename
                cached.parent.mkdir(parents=True)
                cached.write_text("payload")
            root = base / "staged"
            root.mkdir()
            with self.assertRaisesRegex(ValueError, "Conflicting portable Godot paths"):
                stage(
                    {
                        "project_file": "project.godot",
                        "member_resource_paths": {},
                        "imports": ["one", "two"],
                    },
                    root,
                    base,
                )
            self.assertEqual([], list(root.iterdir()))

    def test_cached_imports_can_enrich_the_same_authored_import_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            (base / "authored_import").write_text('[remap]\nimporter="texture"\n')
            enriched = (
                '[remap]\nimporter="texture"\npath="res://.godot/imported/image.ctex"\n'
            )
            for tree in ["one", "two"]:
                (base / tree).mkdir()
                (base / tree / "image.png.import").write_text(enriched)
            root = base / "staged"
            root.mkdir()
            stage(
                {
                    "project_file": "project.godot",
                    "member_resource_paths": {"image.png.import": "authored_import"},
                    "imports": ["one", "two"],
                },
                root,
                base,
            )
            self.assertEqual(enriched, (root / "image.png.import").read_text())

    def test_unit_archives_are_deterministic_and_staged_like_import_results(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            results = base / "results"
            (results / ".godot/imported").mkdir(parents=True)
            (results / ".godot/imported/icon.ctex").write_bytes(b"texture")
            (results / "icon.svg.import").write_text("[remap]\n")
            for name in ("one", "two"):
                (base / name).mkdir()
                write_archive(
                    results,
                    [".godot/imported/icon.ctex", "icon.svg.import"],
                    base / name / IMPORT_ARCHIVE,
                )
            self.assertEqual(
                (base / "one" / IMPORT_ARCHIVE).read_bytes(),
                (base / "two" / IMPORT_ARCHIVE).read_bytes(),
            )
            # A unit without importable files leaves an empty import result.
            (base / "empty").mkdir()
            root = base / "project"
            root.mkdir()
            stage(
                {
                    "project_file": "project.godot",
                    "member_resource_paths": {},
                    "imports": ["one", "empty"],
                },
                root,
                base,
            )
            self.assertEqual(
                (root / ".godot/imported/icon.ctex").read_bytes(), b"texture"
            )
            self.assertEqual((root / "icon.svg.import").read_text(), "[remap]\n")

    def test_archive_entries_must_be_regular_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            (base / "linked").mkdir()
            with tarfile.open(base / "linked" / IMPORT_ARCHIVE, "w") as stream:
                link = tarfile.TarInfo(".godot/imported/icon.ctex")
                link.type, link.linkname = tarfile.SYMTYPE, "/etc/passwd"
                stream.addfile(link)
            root = base / "project"
            root.mkdir()
            with self.assertRaisesRegex(ValueError, "Unexpected archive entry"):
                stage(
                    {
                        "project_file": "project.godot",
                        "member_resource_paths": {},
                        "imports": ["linked"],
                    },
                    root,
                    base,
                )

    def test_import_archives_only_what_godot_added_or_altered(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            results = base / "results"
            (results / ".godot/imported").mkdir(parents=True)
            names = ["rewritten", "altered", "untouched"]
            for name in names:
                (results / f".godot/imported/{name}.ctex").write_bytes(name.encode())
            (base / "dependency").mkdir()
            write_archive(
                results,
                [f".godot/imported/{name}.ctex" for name in names],
                base / "dependency" / IMPORT_ARCHIVE,
            )

            def editor(
                manifest: dict, execroot: Path, root: Path, work: Path, args: list[str]
            ) -> dict:
                imported = root / ".godot/imported"
                (imported / "rewritten.ctex").write_bytes(b"rewritten")
                (imported / "altered.ctex").write_bytes(b"reimported")
                (imported / "new.ctex").write_bytes(b"new")
                return {"facts": {"invalid": []}, "output": ""}

            output = base / "out" / IMPORT_ARCHIVE
            manifest = {
                "project_file": "project.godot",
                "member_resource_paths": {},
                "imports": ["dependency"],
                "outputs": [],
                "editor": "editor",
            }
            with mock.patch.object(godot_actions, "run_action", editor):
                import_resources(manifest, output, base)
            with tarfile.open(output) as stream:
                self.assertEqual(
                    [".godot/imported/altered.ctex", ".godot/imported/new.ctex"],
                    stream.getnames(),
                )

    def test_an_import_keeps_no_result_of_the_importers_it_stages(self) -> None:
        # FR-017, FR-020: the importer's own assets import with its add-on, not again in
        # every unit whose import stages the importer.
        self.assertEqual(
            ".godot/imported/icon.svg-"
            + hashlib.md5(b"res://addons/md/icon.svg").hexdigest()
            + ".",
            import_base("addons/md/icon.svg"),
        )
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")

            def editor(
                manifest: dict, execroot: Path, root: Path, work: Path, args: list[str]
            ) -> dict:
                (root / ".godot/imported").mkdir(parents=True)
                for path in ["notes.md", "addons/md/icon.svg"]:
                    for suffix in ["res", "md5"]:
                        (root / (import_base(path) + suffix)).write_bytes(b"x")
                return {"facts": {"invalid": []}, "output": ""}

            output = base / "out" / IMPORT_ARCHIVE
            manifest = {
                "project_file": "project.godot",
                "member_resource_paths": {},
                "imports": [],
                "outputs": ["notes.md"],
                "tools": ["addons/md/icon.svg", "addons/md/importer.gd"],
                "editor": "editor",
            }
            with mock.patch.object(godot_actions, "run_action", editor):
                import_resources(manifest, output, base)
            with tarfile.open(output) as stream:
                self.assertEqual(
                    [import_base("notes.md") + "md5", import_base("notes.md") + "res"],
                    stream.getnames(),
                )

    def test_the_importer_probe_enables_the_importers_it_stages(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            root = base / "project"
            root.mkdir()
            stage(
                {
                    "project_file": "project.godot",
                    "member_resource_paths": {},
                    "editor_plugins": ["res://addons/md/plugin.cfg"],
                },
                root,
                base,
            )
            self.assertIn(
                'enabled=PackedStringArray("res://addons/md/plugin.cfg")',
                (root / "project.godot").read_text(),
            )

    def test_an_import_sets_the_import_settings_of_the_importers_it_stages(self) -> None:
        # D26: the import settings of an importer reach only the processes staging it,
        # beside the plugins the staged project.godot already enables.
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text(
                'config_version=5\n\n[editor_plugins]\nenabled=PackedStringArray("res://addons/a/plugin.cfg")\n'
            )
            root = base / "project"
            root.mkdir()
            stage(
                {
                    "project_file": "project.godot",
                    "member_resource_paths": {},
                    "editor_plugins": ["res://addons/md/plugin.cfg"],
                    "settings": {"md_importer/heading": '"#"'},
                },
                root,
                base,
            )
            text = (root / "project.godot").read_text()
            self.assertIn('heading="#"', text)
            self.assertIn(
                'enabled=PackedStringArray("res://addons/a/plugin.cfg", "res://addons/md/plugin.cfg")',
                text,
            )

    def test_the_importer_probe_fails_on_a_suffix_the_declaration_lacks(self) -> None:
        # FR-018, US5 AS3: an importer for an undeclared suffix and a declared suffix
        # nothing converts each fail, naming the add-on and the suffix.
        importers = [
            {
                "label": "//addons:md",
                "suffixes": ["markdown", "md"],
                "scripts": ["res://addons/md/importer.gd"],
                "plugin": "res://addons/md/plugin.cfg",
                "native": False,
                "member_resource_paths": {},
            }
        ]
        records = {
            "--editor": {
                "facts": {
                    "suffixes": ["md", "png", "txt"],
                    "importers": [
                        {
                            "label": "//addons:md",
                            "suffixes": ["md", "TXT"],
                        }
                    ],
                }
            },
            "--script": {"facts": {"suffixes": ["png"]}},
        }
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            manifest = {
                "project_file": "project.godot",
                "member_resource_paths": {},
                "imports": [],
                "importers": importers,
                "editor": "editor",
            }

            def editor(
                manifest: dict, execroot: Path, root: Path, work: Path, args: list[str]
            ) -> dict:
                return records[args[0]]

            with mock.patch.object(godot_actions, "run_action", editor):
                with self.assertRaisesRegex(
                    RuntimeError,
                    "//addons:md registers an importer for the suffix 'txt'(.|\n)*"
                    "//addons:md declares the importer suffix 'markdown'",
                ):
                    importable_suffixes(manifest, base / "out", base)
                importers[0]["suffixes"] = ["md", "txt"]
                importable_suffixes(manifest, base / "out", base)
            self.assertEqual(
                ["md", "txt"], sorted(path.name for path in (base / "out").iterdir())
            )

    def test_extension_importers_are_the_suffixes_their_add_on_adds(self) -> None:
        # E10: Godot does not say which library registered an importer, so an add-on with
        # an extension contributes what the editor recognizes only with it staged; a
        # declared suffix Godot imports anyway cannot be told apart and is no mismatch.
        native = {
            "label": "//addons:native",
            "suffixes": ["png", "vox"],
            "native": True,
            "member_resource_paths": {"addons/native/native.gdextension": "x"},
        }
        self.assertEqual(
            [], importer_mismatches([native], {"//addons:native": {"vox"}}, {"png"})
        )
        self.assertEqual(
            [
                (
                    "//addons:native declares the importer suffix 'vox', "
                    "which none of its importers converts"
                )
            ],
            importer_mismatches([native], {}, {"png"}),
        )

    def test_an_import_fails_only_on_its_own_invalid_files(self) -> None:
        for invalid, fails in [(["other.png"], False), (["mine.png"], True)]:
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                (base / "project.godot").write_text("config_version=5\n")
                record = {"facts": {"invalid": invalid}, "output": "importer said no"}
                manifest = {
                    "project_file": "project.godot",
                    "member_resource_paths": {},
                    "imports": [],
                    "outputs": ["mine.png"],
                    "editor": "editor",
                }
                with mock.patch.object(godot_actions, "run_action", return_value=record):
                    if fails:
                        with self.assertRaisesRegex(
                            RuntimeError,
                            "could not import mine.png(.|\n)*importer said no",
                        ):
                            import_resources(
                                manifest, base / "out" / IMPORT_ARCHIVE, base
                            )
                    else:
                        import_resources(manifest, base / "out" / IMPORT_ARCHIVE, base)

    def test_initialize_accepts_a_project_without_resource_uids(self) -> None:
        # Godot writes no UID cache when no resource has a UID, as in an empty project.
        for written, fails in [
            ([".godot/global_script_class_cache.cfg"], False),
            ([".godot/uid_cache.bin"], True),
        ]:
            with self.subTest(written=written), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                (base / "project.godot").write_text("config_version=5\n")

                def editor(
                    manifest: dict,
                    execroot: Path,
                    root: Path,
                    work: Path,
                    args: list[str],
                    written: list[str] = written,
                ) -> dict:
                    for relative in written:
                        (root / relative).parent.mkdir(parents=True, exist_ok=True)
                        (root / relative).write_text("cache")
                    return {"facts": {"invalid": []}, "output": "", "stopped": False}

                manifest = {
                    "project_file": "project.godot",
                    "member_resource_paths": {},
                    "imports": [],
                    "editor": "editor",
                }
                output = base / "out"
                with mock.patch.object(godot_actions, "run_action", editor):
                    if fails:
                        with self.assertRaisesRegex(
                            RuntimeError, "global_script_class_cache.cfg"
                        ):
                            initialize(manifest, output, base)
                        continue
                    initialize(manifest, output, base)
                self.assertEqual(
                    [".godot/global_script_class_cache.cfg"],
                    [
                        path.relative_to(output).as_posix()
                        for path in output.rglob("*")
                        if path.is_file()
                    ],
                )

    def test_resource_path_manifests_merge_unless_they_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            for name, resource_paths in [
                ("one", {"a.gd": "x/a.gd"}),
                ("two", {"a.gd": "x/a.gd", "b.gd": "x/b.gd"}),
                ("other", {"a.gd": "y/a.gd"}),
            ]:
                (base / name).write_text(json.dumps(resource_paths))
            manifest = {"project_file": "project.godot"}
            add_resource_path_manifests(
                manifest, [base / "one", base / "two"], resolver([])
            )
            self.assertEqual(
                {"a.gd": "x/a.gd", "b.gd": "x/b.gd"}, manifest["member_resource_paths"]
            )
            with self.assertRaisesRegex(
                ValueError, "Conflicting staged sources for a.gd"
            ):
                add_resource_path_manifests(manifest, [base / "other"], resolver([]))

    def test_mapped_paths_resolve_to_the_root_of_the_staged_file(self) -> None:
        mapped = "bazel-out/cfg/bin/main/a.gd"
        manifest = {"files": {"a.gd": mapped, "b.gd": "main/b.gd"}, "list": [mapped]}
        # Path mapping staged the inputs at their mapped paths.
        self.assertEqual(
            manifest, resolve_paths(manifest, resolver(["bazel-out/cfg/bin"]))
        )
        self.assertEqual(
            {
                "files": {
                    "a.gd": "bazel-out/k8-fastbuild/bin/main/a.gd",
                    "b.gd": "main/b.gd",
                },
                "list": ["bazel-out/k8-fastbuild/bin/main/a.gd"],
            },
            resolve_paths(manifest, resolver(["bazel-out/k8-fastbuild/bin"])),
        )
        with tempfile.TemporaryDirectory() as temp, contextlib.chdir(temp):
            Path("bazel-out/one/bin/main").mkdir(parents=True)
            Path("bazel-out/two/bin/main").mkdir(parents=True)
            Path("bazel-out/two/bin/main/a.gd").touch()
            resolve = resolver(["bazel-out/one/bin", "bazel-out/two/bin"])
            self.assertEqual("bazel-out/two/bin/main/a.gd", resolve(mapped))
            Path("bazel-out/one/bin/main/a.gd").touch()
            with self.assertRaisesRegex(ValueError, "several configurations"):
                resolve(mapped)

    def test_export_preset_escapes_strings(self) -> None:
        preset = export_presets({"preset_platform": "Android", "features": ['a"b']})
        self.assertIn('platform="Android"', preset)
        self.assertIn(r"a\"b", preset)

    def test_export_selection_is_explicit_and_raw_files_are_included(self) -> None:
        preset = export_presets(
            {"preset_platform": "Linux", "preset_settings": {"script_export_mode": "2"}},
            ["native/b.so", "native/a.so"],
        )
        self.assertIn('include_filter="*"', preset)
        # Godot writes .uid files beside scripts; they leave with their source.
        self.assertIn(
            'exclude_filter="native/a.so,native/a.so.uid,native/b.so,native/b.so.uid"',
            preset,
        )
        self.assertIn("script_export_mode=2", preset)

    def test_export_options_follow_the_managed_ones(self) -> None:
        preset = export_presets(
            {
                "preset_platform": "Android",
                "preset_prelude": {"binary_format/architecture": '"arm64"'},
                "export_options": {
                    "texture_format/etc2_astc": "true",
                    "package/name": '"Demo"',
                },
            }
        )
        options = preset.split("[preset.0.options]\n", 1)[1].splitlines()
        self.assertEqual(
            [
                'binary_format/architecture="arm64"',
                'package/name="Demo"',
                "texture_format/etc2_astc=true",
            ],
            [line for line in options if line],
        )
        with self.assertRaises(ValueError):
            export_presets(
                {
                    "preset_platform": "Linux",
                    "export_options": {"x/y": 'load("res://a.gd")'},
                }
            )

    def test_prelude_is_sorted_before_authored_duplicates(self) -> None:
        preset = export_presets(
            {
                "preset_platform": "macOS",
                "preset_prelude": {
                    "binary_format/embed_pck": "false",
                    "binary_format/architecture": '"arm64"',
                },
                "export_options": {"binary_format/embed_pck": "true"},
            }
        )
        options = preset.split("[preset.0.options]\n", 1)[1].strip().splitlines()
        self.assertEqual(
            [
                'binary_format/architecture="arm64"',
                "binary_format/embed_pck=false",
                "binary_format/embed_pck=true",
            ],
            options,
        )

    def test_absent_prelude_has_no_platform_fallback(self) -> None:
        for prelude in [{}, {"preset_prelude": {}}]:
            self.assertNotIn(
                "binary_format/", export_presets({"preset_platform": "macOS", **prelude})
            )

    def test_prelude_literals_are_validated(self) -> None:
        with self.assertRaises(ValueError):
            export_presets(
                {
                    "preset_platform": "macOS",
                    "preset_prelude": {"x/y": 'load("res://a.gd")'},
                }
            )

    @unittest.skipUnless(sys.platform == "darwin", "macOS shares tmpproject.binary")
    def test_exports_lock_the_user_temporary_directory(self) -> None:
        lock = export_lock()
        if lock is None:
            self.fail("macOS exports must share a lock")
        with exclusive_export():
            self.assertTrue(lock.exists())

    def run_stub(
        self, behavior: dict, timeout: int = 300, grace: int = 20
    ) -> tuple[dict | None, str, str]:
        """
        Run an editor action with a stub editor; return its record or None, the
        error and stderr.

        The stub reads behavior from the staged project: the record it writes
        (or none), then whether it hangs and its exit status.
        """
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            editor = base / "editor"
            editor.write_text(
                f"#!{sys.executable}\n"
                "import json, pathlib, sys, time\n"
                "root = pathlib.Path(sys.argv[sys.argv.index('--path') + 1])\n"
                "behavior = json.loads((root / 'stub.json').read_text())\n"
                "action = json.loads((root / 'addons/rules_godot_action/action.json').read_text())\n"
                "if behavior.get('record'):\n"
                "    pathlib.Path(action['record']).write_text(json.dumps(behavior['record']))\n"
                "print('godot output')\n"
                "sys.stdout.flush()\n"
                "if behavior.get('hang'):\n"
                "    time.sleep(60)\n"
                "sys.exit(behavior.get('exit', 0))\n"
            )
            editor.chmod(0o755)
            work, root = base / "work", base / "work" / "project"
            root.mkdir(parents=True)
            (root / "project.godot").write_text("config_version=5\n")
            (root / "stub.json").write_text(json.dumps(behavior))
            join_action(root, work, "export")
            stderr = io.StringIO()
            with (
                mock.patch.object(godot_staging, "_ACTION_TIMEOUT_SECONDS", timeout),
                mock.patch.object(godot_staging, "_RECORD_GRACE_SECONDS", grace),
                contextlib.redirect_stderr(stderr),
            ):
                try:
                    record = run_action({"editor": str(editor)}, base, root, work, [])
                except RuntimeError as error:
                    return None, str(error), stderr.getvalue()
            return record, "", stderr.getvalue()

    def test_an_action_without_a_record_fails_with_godots_output(self) -> None:
        record, error, _ = self.run_stub({"exit": 0})
        self.assertIsNone(record)
        self.assertIn("ended without recording its export result", error)
        self.assertIn("godot output", error)

    def test_a_failure_record_fails_with_its_diagnostics(self) -> None:
        failure = {
            "operation": "export",
            "verdict": "failure",
            "diagnostics": ["Save PCK: Can't open file for writing"],
            "facts": {},
        }
        record, error, _ = self.run_stub({"record": failure, "exit": 1})
        self.assertIsNone(record)
        self.assertIn("Save PCK: Can't open file for writing", error)
        self.assertIn("godot output", error)

    def test_a_crash_after_a_success_record_is_a_note(self) -> None:
        success = {
            "operation": "export",
            "verdict": "success",
            "diagnostics": [],
            "facts": {},
        }
        record, error, stderr = self.run_stub({"record": success, "exit": 134})
        self.assertEqual(
            ("", success | {"output": "godot output\n", "stopped": False}),
            (error, record),
        )
        self.assertIn("ended with exit status 134 after a successful export", stderr)

    def test_godot_is_stopped_a_grace_period_after_its_record(self) -> None:
        success = {
            "operation": "export",
            "verdict": "success",
            "diagnostics": [],
            "facts": {},
        }
        record, error, stderr = self.run_stub({"record": success, "hang": True}, grace=1)
        self.assertEqual(
            ("", success | {"output": "godot output\n", "stopped": True}), (error, record)
        )
        self.assertIn("stopped Godot 1 seconds after its export result", stderr)

    def test_an_action_without_a_record_in_time_fails(self) -> None:
        record, error, _ = self.run_stub({"hang": True}, timeout=1)
        self.assertIsNone(record)
        self.assertIn("recorded no export result within 1 seconds", error)

    def test_the_action_plugin_joins_hidden_from_scans_and_exports(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            root = work / "project"
            root.mkdir()
            authored = '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/a/plugin.cfg")\n'
            (root / "project.godot").write_text(authored)
            join_action(root, work, "features", {"tags": ["mobile"]})
            directory = root / "addons/rules_godot_action"
            self.assertTrue((directory / ".gdignore").exists())
            self.assertEqual(authored, (work / "project.godot").read_text())
            self.assertIn(
                '"res://addons/a/plugin.cfg", "res://addons/rules_godot_action/plugin.cfg"',
                (root / "project.godot").read_text(),
            )
            action = json.loads((directory / "action.json").read_text())
            self.assertEqual(
                {
                    "operation": "features",
                    "tags": ["mobile"],
                    "record": str(work / "record.json"),
                    "project_file": str(work / "project.godot"),
                },
                action,
            )
            with self.assertRaisesRegex(ValueError, "reserved for rules_godot"):
                join_action(root, work, "features")

    def test_pack_exports_scenes_with_stable_node_ids(self) -> None:
        scene = '[gd_scene format=3]\n\n[node name="Main" type="Node"]\n'
        for assign, expected in [
            (True, with_node_ids(scene, "main.tscn")),
            (False, scene),
        ]:
            with self.subTest(assign=assign), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                (base / "project.godot").write_text("config_version=5\n")
                (base / "main.tscn").write_text(scene)
                (base / "content.json").write_text(
                    json.dumps({"resources": {"main.tscn": "main.tscn"}})
                )
                (base / "index.json").write_text(
                    json.dumps({"node_ids": {"main.tscn": {"issues": ["Main"]}}})
                )
                exported: list[str] = []

                def editor(
                    manifest: dict,
                    execroot: Path,
                    root: Path,
                    work: Path,
                    args: list[str],
                    exported: list[str] = exported,
                ) -> dict:
                    if "--export-pack" in args:
                        exported.append((root / "main.tscn").read_text())
                        write_pck(Path(args[-1]))
                    return {}

                manifest = {
                    "project_file": "project.godot",
                    "content": "content.json",
                    "member_resource_paths": {"main.tscn": "main.tscn"},
                    "editor": "editor",
                    "version": "4.7.2",
                    "preset_platform": "Linux",
                    "variant": "release",
                    "owner": "//game:pack",
                    "metadata_index": {
                        "path": "index.json",
                        "assign": ["node_ids"] if assign else [],
                    },
                }
                with (
                    mock.patch.object(godot_export, "run_action", editor),
                    mock.patch.object(godot_export, "export_presets", return_value=""),
                    mock.patch.object(godot_export, "write_report"),
                ):
                    godot_export.pack(manifest, base / "out.pck", base / "r.json", base)
                self.assertEqual([expected], exported)
                self.assertEqual(scene, (base / "main.tscn").read_text())

    def test_staging_points_references_at_the_files_uids(self) -> None:
        scene = (
            "[gd_scene format=3]\n\n"
            '[ext_resource type="Script" uid="uid://stale" path="res://main.gd" id="1"]\n'
        )
        expected = scene.replace("uid://stale", "uid://main")
        for assign, staged_scene in [(["resource_uids"], expected), ([], scene)]:
            with self.subTest(assign=assign), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                (base / "project.godot").write_text("config_version=5\n")
                (base / "main.tscn").write_text(scene)
                (base / "main.gd").write_text("extends Node\n")
                (base / "main.gd.uid").write_text("uid://main\n")
                root = base / "project"
                root.mkdir()
                (base / "index.json").write_text(
                    json.dumps(
                        {
                            "resource_uids": {
                                "main.tscn": {"uids": {"main.gd": "uid://main"}}
                            }
                        }
                    )
                )
                originals = stage(
                    {
                        "project_file": "project.godot",
                        "member_resource_paths": {
                            path: path for path in ["main.tscn", "main.gd", "main.gd.uid"]
                        },
                        "metadata_index": {"path": "index.json", "assign": assign},
                    },
                    root,
                    base,
                )
                self.assertEqual(staged_scene, (root / "main.tscn").read_text())
                self.assertEqual(scene, (base / "main.tscn").read_text())
                # Godot's import scan compares against these; the update is not its output.
                self.assertTrue(same_content(root / "main.tscn", originals["main.tscn"]))

    def test_pack_starts_the_editor_once_for_its_export(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            (base / "content.json").write_text(json.dumps({"resources": {}}))
            launches: list[list[str]] = []

            def editor(
                manifest: dict, execroot: Path, root: Path, work: Path, args: list[str]
            ) -> dict:
                launches.append(args)
                if "--export-pack" in args:
                    write_pck(Path(args[-1]))
                return {}

            manifest = {
                "project_file": "project.godot",
                "content": "content.json",
                "member_resource_paths": {},
                "editor": "editor",
                "version": "4.7.2",
                "preset_platform": "Linux",
                "variant": "release",
                "owner": "//game:pack",
            }
            with (
                mock.patch.object(godot_export, "run_action", editor),
                mock.patch.object(godot_export, "export_presets", return_value=""),
            ):
                godot_export.pack(manifest, base / "out.pck", base / "report.json", base)
            self.assertEqual(
                [["--export-pack", "Bazel", str(base / "out.pck")]], launches
            )

    def test_a_pack_fails_when_its_export_meets_an_unknown_class(self) -> None:
        # D28: exporting without the extension of a class drops its values from the
        # converted scenes and resources while the export still succeeds; Godot's only
        # report is this message, as printed by Godot 4.7.2 in that export.
        output = (
            "Godot Engine v4.7.2.stable.official.ed1daf0bf\n"
            "ERROR: Cannot get class 'ProbeNode'.\n"
            "   at: _instantiate_internal (core/object/class_db.cpp:587)\n"
            "ERROR: Cannot get class 'ProbeData'.\n"
            "   at: _instantiate_internal (core/object/class_db.cpp:587)\n"
            "[ DONE ] savepack\n"
        )
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "project.godot").write_text("config_version=5\n")
            (base / "content.json").write_text(json.dumps({"resources": {}}))

            def editor(
                manifest: dict, execroot: Path, root: Path, work: Path, args: list[str]
            ) -> dict:
                write_pck(Path(args[-1]))
                return {"output": output}

            manifest = {
                "project_file": "project.godot",
                "content": "content.json",
                "member_resource_paths": {},
                "editor": "editor",
                "version": "4.7.2",
                "preset_platform": "Linux",
                "variant": "release",
                "owner": "//game:pack",
            }
            with (
                mock.patch.object(godot_export, "run_action", editor),
                mock.patch.object(godot_export, "export_presets", return_value=""),
                self.assertRaisesRegex(
                    RuntimeError,
                    "//game:pack: Godot did not know the class ProbeData, ProbeNode "
                    "during the export(.|\n)*a library for the platform that runs "
                    "the export",
                ),
            ):
                godot_export.pack(manifest, base / "out.pck", base / "report.json", base)

    def test_exports_exclude_every_staged_path_outside_the_content(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            (base / "content.json").write_text(
                json.dumps({"pack": "//:base", "resources": {"main.gd": "a"}})
            )
            manifest = {
                "content": "content.json",
                "member_resource_paths": {"main.gd": "a", "dlc/level.gd": "b"},
                "import_resource_paths": {"model.bin": "c"},
            }
            self.assertEqual(
                ({"main.gd"}, {"dlc/level.gd", "model.bin"}),
                content_selection(manifest, base),
            )
        with self.assertRaisesRegex(ValueError, "literal export filter"):
            export_presets({"preset_platform": "Linux"}, ["levels/[1].json"])

    def test_generated_uid_of_an_excluded_script_is_a_leak(self) -> None:
        with self.assertRaisesRegex(
            RuntimeError, "excluded resources in the PCK: dlc.gd.uid"
        ):
            inspect_export(
                {
                    "paths": ["res://main.gd", "res://dlc.gd.uid"],
                    "file_count": 2,
                },
                {"main.gd"},
                {"dlc.gd"},
            )
        report = inspect_export(
            {"paths": ["res://main.gd", "res://main.gd.uid"], "file_count": 2},
            {"main.gd"},
            {"dlc.gd"},
        )
        self.assertEqual(["main.gd"], report["selected_paths"])

    def test_declared_sidecars_are_never_missing_and_have_no_sidecars(self) -> None:
        # Godot writes no sidecar beside a sidecar, and packs sidecars as its own
        # UID and import tables, never as resources.
        report = inspect_export(
            {"paths": ["res://main.gd", "res://dlc.gd.uid.uid"], "file_count": 2},
            {"main.gd", "main.gd.uid", "icon.png.import"},
            {"dlc.gd.uid"},
        )
        self.assertEqual(
            ["icon.png.import", "main.gd", "main.gd.uid"], report["selected_paths"]
        )

    def test_files_godot_ignores_are_never_missing(self) -> None:
        # Godot exports nothing below a directory that holds a .gdignore.
        report = inspect_export(
            {"paths": ["res://main.gd"], "file_count": 1},
            {"main.gd", "template/.gdignore", "template/css/style.css"},
            set(),
            {"template/.gdignore", "template/css/style.css"},
        )
        self.assertEqual(
            ["main.gd", "template/.gdignore", "template/css/style.css"],
            report["selected_paths"],
        )
        with self.assertRaisesRegex(
            RuntimeError, "omitted declared resources.*style.css"
        ):
            inspect_export(
                {"paths": ["res://main.gd"], "file_count": 1},
                {"main.gd", "template/css/style.css"},
                set(),
            )

    def test_zero_exit_bogus_export_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            pck = Path(temp) / "main.pck"
            pck.write_bytes(struct.pack("<II", 0, 2) + bytes(128))
            with self.assertRaisesRegex(RuntimeError, r"valid Godot 4\.7\.2\+ PCK v4"):
                validate_pck(pck)

    def test_only_modern_pack_format_and_engine_versions_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            pck = Path(temp) / "main.pck"
            for version in (2, 3, 5):
                pck.write_bytes(pck_bytes(version=version, padding=128))
                with (
                    self.subTest(format=version),
                    self.assertRaisesRegex(RuntimeError, "PCK v4"),
                ):
                    validate_pck(pck)
            for engine in [(4, 5, 1), (4, 7, 1), (5, 0, 0)]:
                pck.write_bytes(pck_bytes(engine=engine, padding=128))
                with (
                    self.subTest(engine=engine),
                    self.assertRaisesRegex(RuntimeError, "PCK v4"),
                ):
                    validate_pck(pck)
            for engine in [(4, 7, 2), (4, 7, 10), (4, 8, 0)]:
                pck.write_bytes(pck_bytes(engine=engine, padding=128))
                self.assertEqual(0, validate_pck(pck)["file_count"])

    def test_mobile_pack_inspector_rejects_legacy_engines_and_formats(self) -> None:
        self.assertEqual(pck_contents(pck_bytes())["godot_version"], "4.7.2")
        for data in [
            pck_bytes(version=2),
            pck_bytes(version=3),
            pck_bytes(engine=(4, 7, 1)),
        ]:
            with self.assertRaisesRegex(ValueError, "PCK v4"):
                pck_contents(data)


if __name__ == "__main__":
    unittest.main()
