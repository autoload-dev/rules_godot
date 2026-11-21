"""
Read the resource paths of a Godot 4.7.2+ PCK's directory.

A trimmed copy of rules_godot's PCK reader, so this module's tests carry their own.
"""

import struct
from pathlib import Path
from typing import IO, Any

_MAGIC = 0x43504447


def _exact(source: IO[bytes], size: int) -> bytes:
    value = source.read(size)
    if len(value) != size:
        raise ValueError("truncated PCK directory")
    return value


def _read(source: IO[bytes], fmt: str) -> tuple[Any, ...]:
    return struct.unpack(fmt, _exact(source, struct.calcsize(fmt)))


def _supported(header: tuple[Any, ...]) -> bool:
    """Whether a header is that of an unencrypted standalone Godot 4.7.2+ PCK v4."""
    magic, version, major, minor, patch, flags = header
    is_pck_v4 = magic == _MAGIC and version == 4
    is_godot_4 = major == 4 and (minor, patch) >= (7, 2)
    return is_pck_v4 and is_godot_4 and not flags & 5


def pck_paths(path: Path) -> list[str]:
    """Return the sorted resource paths of an unencrypted standalone PCK v4."""
    with path.open("rb") as source:
        if not _supported(_read(source, "<6I")):
            raise ValueError(
                "expected an unencrypted standalone Godot 4.7.2+ PCK v4 without sparse storage"
            )
        _read(source, "<Q")  # The base offset of the files' contents.
        (directory,) = _read(source, "<Q")
        source.seek(directory)
        (count,) = _read(source, "<I")
        paths = []
        for _ in range(count):
            (length,) = _read(source, "<I")
            paths.append(_exact(source, length).rstrip(b"\0").decode("utf-8"))
            # Offset, size, MD5 and flags of the file.
            _exact(source, 8 + 8 + 16 + 4)
    return sorted(paths)
