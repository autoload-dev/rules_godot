"""A godot_cc_extension's descriptor and shared library implement Godot's entry ABI."""

import ctypes
import os
import unittest
from pathlib import Path


class Initialization(ctypes.Structure):
    _fields_ = [
        ("minimum_initialization_level", ctypes.c_int),
        ("userdata", ctypes.c_void_p),
        ("initialize", ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int)),
        ("deinitialize", ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_int)),
    ]


FIXTURE = "godot/extension/tests/fixtures/c_abi"


def runfile(name: str) -> Path:
    """Return the one runfile of the C ABI fixture with this name."""
    root = Path(os.environ.get("TEST_SRCDIR", "."))
    found = list(root.glob(f"**/{FIXTURE}/{name}"))
    if len(found) != 1:
        raise AssertionError(f"expected one {name} in runfiles, got {found}")
    return found[0]


class CcExtensionAbiTest(unittest.TestCase):
    def test_descriptor_names_the_entry_symbol_and_host_libraries(self) -> None:
        descriptor = runfile("hello.gdextension").read_text()
        self.assertIn('entry_symbol = "rules_godot_library_init"', descriptor)
        self.assertIn('compatibility_minimum = "4.7.2"', descriptor)
        self.assertIn("res://native/bin/", descriptor)
        self.assertRegex(
            descriptor, r"(?m)^(macos|linux)\.(arm64|x86_64)\.(release|debug) = "
        )

    def test_entry_symbol_initializes_at_the_scene_level(self) -> None:
        library = ctypes.CDLL(str(runfile("hello.library.shared/libhello.so")))
        entry = library.rules_godot_library_init
        entry.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.POINTER(Initialization),
        ]
        entry.restype = ctypes.c_uint8
        initialization = Initialization()
        self.assertEqual(entry(None, None, ctypes.byref(initialization)), 1)
        self.assertEqual(initialization.minimum_initialization_level, 2)
        self.assertTrue(initialization.initialize)
        initialization.initialize(initialization.userdata, 2)
        initialization.deinitialize(initialization.userdata, 2)


if __name__ == "__main__":
    unittest.main()
