"""A release App Bundle packages its extension stripped; its debug symbols keep the DWARF."""

import argparse
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from godot.platforms.private.tests.library_composition.android_apps import (
    bundle_tool_arguments,
    debug_symbol_sections,
    universal_apk,
)


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    bundle_tool_arguments(parser)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--debug-symbols", type=Path, required=True)
    return parser.parse_args(sys.argv[1:])


class AndroidDebugSymbolsTest(unittest.TestCase):
    def test_debug_symbols_match_the_stripped_extension_with_dwarf(self) -> None:
        args = _arguments()
        with tempfile.TemporaryDirectory() as directory:
            manifest, universal = universal_apk(args, args.app, Path(directory))
            self.assertIn('package="org.example.rulesgodot"', manifest)
            with zipfile.ZipFile(universal) as apk:
                sections = debug_symbol_sections(apk, args.debug_symbols)
        self.assertIn("arm64-v8a/libhello.so", sections)
        for name, names in sections.items():
            with self.subTest(library=name):
                self.assertIn(".symtab", names)
                self.assertIn(".debug_info", names)


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1])
