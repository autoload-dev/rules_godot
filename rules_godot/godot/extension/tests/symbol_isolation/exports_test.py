"""Each godot_cc_extension shared library exports only its entry symbol."""

import os
import struct
import unittest
from pathlib import Path

from tools.platforms.native_symbols import (
    elf_sections,
    macho_load_commands,
    native_format,
)

FIXTURE = "godot/extension/tests/symbol_isolation"
PROBES = ["Alpha", "Beta"]


# The ELF symbol bindings that export a symbol: global, weak and GNU unique.
ELF_EXPORTING_BINDINGS = (1, 2, 10)


def elf_exported(info: int, other: int, section: int) -> bool:
    """Whether an ELF symbol is defined, binds to export and has default visibility."""
    return bool(section) and info >> 4 in ELF_EXPORTING_BINDINGS and other & 3 == 0


def elf_exports(data: bytes) -> set[str]:
    """Return the defined, default-visibility global, weak and GNU unique symbols of a 64-bit ELF file."""
    sections = elf_sections(data)
    table, strings = sections[".dynsym"], bytes(sections[".dynstr"])
    exports = set()
    for offset in range(0, len(table), 24):
        name, info, other, section = struct.unpack_from("<IBBH", table, offset)
        if elf_exported(info, other, section):
            exports.add(strings[name : strings.index(b"\0", name)].decode())
    return exports


# Bits of a Mach-O symbol's n_type. MACHO_EXTERNAL marks an external symbol. Any bit of
# MACHO_HIDDEN marks a private external or a debug entry. A symbol defined in a section has
# every bit of MACHO_DEFINED_IN_SECTION set.
MACHO_EXTERNAL = 0x01
MACHO_HIDDEN = 0xF0
MACHO_DEFINED_IN_SECTION = 0x0E


def macho_exported(kind: int) -> bool:
    """Whether a Mach-O symbol is exported: external, not hidden and defined in a section."""
    return (
        bool(kind & MACHO_EXTERNAL)
        and not kind & MACHO_HIDDEN
        and kind & MACHO_DEFINED_IN_SECTION == MACHO_DEFINED_IN_SECTION
    )


def symbol_table_exports(data: bytes, position: int) -> set[str]:
    """Return the exported symbols of the LC_SYMTAB load command at position, as C names."""
    symbols, count, strings, _ = struct.unpack_from("<IIII", data, position + 8)
    exports = set()
    for index in range(count):
        name, kind = struct.unpack_from("<IB", data, symbols + index * 16)
        if macho_exported(kind):
            end = data.index(b"\0", strings + name)
            exports.add(data[strings + name : end].decode().removeprefix("_"))
    return exports


def macho_exports(data: bytes) -> set[str]:
    """Return the defined external symbols of a thin 64-bit Mach-O file, as C names."""
    symbol_table = 0x2
    return set().union(
        *(
            symbol_table_exports(data, position)
            for command, position, _ in macho_load_commands(data)
            if command == symbol_table
        )
    )


def exports(path: Path) -> set[str]:
    data = path.read_bytes()
    return elf_exports(data) if native_format(path) == "elf" else macho_exports(data)


class ExportsTest(unittest.TestCase):
    def test_libraries_export_only_their_entry_symbol(self) -> None:
        root = Path(os.environ["TEST_SRCDIR"]) / os.environ["TEST_WORKSPACE"] / FIXTURE
        for probe in PROBES:
            with self.subTest(probe=probe):
                name = probe.lower()
                library = root / f"{name}.library.shared" / f"lib{name}.so"
                self.assertEqual({f"{probe}_probe_init"}, exports(library))


if __name__ == "__main__":
    unittest.main()
