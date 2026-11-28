"""
An application carries its platform's backend and libraries.

The application of one declaration contains the selected operating system's add-on
libraries and resources only, the engine and extension libraries of its CPUs, and the
feature tags of its environment.
"""

import argparse
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

from godot.platforms.private.tests.dex import defined_classes
from tools.pack.pck import pck_member, project_features, project_setting_keys
from tools.platforms.apple_bundle import bundle_files
from tools.platforms.native_symbols import require_slices

# The application's delivered artifact for each operating system.
PUBLISHED = {
    "android": {"app.apk", "app_unsigned.aab"},
    # Development builds keep the bundle a directory; distribution archives it.
    "ios": {"app.app", "app.ipa"},
    "macos": {"app.zip"},
    "linux": {"app.tar.gz"},
}

# Each operating system's add-on library places its own resource at a resource path of the
# project.
ADDON_RESOURCES = {
    "android": "main/libraries/android_addon.gd",
    "ios": "main/libraries/ios_addon.gd",
}


def packs(packed: bytes, path: str) -> bool:
    """Whether the PCK contains a file at the resource path."""
    try:
        pck_member(packed, path)
    except KeyError:
        return False
    return True


def read_files(path: Path, operating_system: str) -> dict[str, bytes]:
    """The files of an application archive or bundle by their path in it."""
    if path.name.endswith(".tar.gz"):
        files = {}
        with tarfile.open(path) as source:
            for member in source.getmembers():
                if member.isfile():
                    stream = source.extractfile(member)
                    assert stream is not None
                    files[member.name] = stream.read()
        return files
    if operating_system == "ios":
        return bundle_files(path)
    with zipfile.ZipFile(path) as source:
        return {
            name: source.read(name)
            for name in source.namelist()
            if not name.endswith("/")
        }


def require_symbols(image: Path, cpus: set[str], flags: str, wanted: list[str]) -> None:
    """Require every CPU slice of a Mach-O image to list the wanted symbols under nm flags."""
    for cpu in sorted(cpus):
        symbols = subprocess.check_output(
            ["/usr/bin/nm", "-arch", cpu, flags, str(image)], text=True
        )
        missing = [symbol for symbol in wanted if symbol not in symbols]
        assert not missing, (cpu, image.name, missing)


def inspect_pack(packed: bytes, operating_system: str, environment: str) -> None:
    settings = pck_member(packed, "project.binary")
    runtime_custom = project_features(settings)
    # Godot applies the .simulator override at runtime when the feature is present.
    assert "application/config/description.simulator" in project_setting_keys(settings)
    assert ("simulator" in runtime_custom) == (environment == "simulator"), runtime_custom
    assert not runtime_custom & {"arm64", "x86_64"}, runtime_custom
    for owner, resource in ADDON_RESOURCES.items():
        assert packs(packed, resource) == (owner == operating_system), (owner, resource)


def inspect_sdk_versions(aapt: str, path: Path) -> None:
    manifest = subprocess.check_output([aapt, "dump", "badging", str(path)], text=True)
    minimum = re.search(r"^sdkVersion:'(\d+)'", manifest, re.MULTILINE)
    target = re.search(r"^targetSdkVersion:'(\d+)'", manifest, re.MULTILINE)
    assert minimum and target, manifest
    assert (minimum[1], target[1]) == ("24", "36"), manifest


def abi_directories(names: list[str], library: str) -> set[str]:
    """Return the ABI directories that package a library."""
    return {name.split("/")[-2] for name in names if name.endswith("/" + library)}


def inspect_android(
    files: dict[str, bytes], path: Path, cpus: set[str], aapt: str
) -> None:
    # sdk_bundle_test checks the AAB manifest with bundletool.
    if path.suffix == ".apk":
        inspect_sdk_versions(aapt, path)
    classes = set().union(
        *(defined_classes(data) for name, data in files.items() if name.endswith(".dex"))
    )
    assert "org.example.addon.Addon" in classes, (
        "Selected project Java dependency missing"
    )
    assert "org.example.plugin.Plugin" in classes, "Selected project AAR missing"
    assert "androidx.core.splashscreen.SplashScreen" in classes, (
        "The internally provisioned splash screen is missing"
    )
    names = list(files)
    abis = {"arm64-v8a" if cpu == "arm64" else "x86_64" for cpu in cpus}
    extension = [name for name in names if name.endswith("/libhello.so")]
    assert abi_directories(names, "libhello.so") == abis, extension
    engine_libraries = [name for name in names if name.endswith("/libgodot_android.so")]
    assert abi_directories(names, "libgodot_android.so") == abis, engine_libraries
    for name in engine_libraries:
        require_slices(
            files[name],
            {"arm64" if name.split("/")[-2] == "arm64-v8a" else "x86_64"},
            "elf",
            name,
        )


def inspect_ios_info(info: dict, environment: str) -> None:
    assert info.get("GCSupportsControllerUserInteraction") is True, info
    assert info["CFBundleIdentifier"] == "org.example.contract", info
    assert info["CFBundleExecutable"] == "app", info
    assert info["MinimumOSVersion"] == "15.0" and info["UIDeviceFamily"] == [
        1,
        2,
    ], info
    assert info["CFBundleSupportedPlatforms"] == [
        "iPhoneOS" if environment == "device" else "iPhoneSimulator"
    ], info


def inspect_ios(files: dict[str, bytes], cpus: set[str], environment: str) -> None:
    names = list(files)
    plist_name = next(name for name in names if name.endswith(".app/Info.plist"))
    info = plistlib.loads(files[plist_name])
    assert any(name.endswith("/addon_notice.txt") for name in names), names
    assert not any(name.endswith((".dex", ".aar")) for name in names), names
    inspect_ios_info(info, environment)
    bundle = plist_name.removesuffix("Info.plist")
    binary = bundle + info["CFBundleExecutable"]
    # The add-on's libraries link into the executable; the extension's library is
    # its own framework, which exports the entry symbol.
    framework = bundle + "Frameworks/hello.framework/hello"
    # Symbols each image defines, and the external ones only for the framework:
    # Godot looks up the exported entry.
    expected = {
        binary: (
            "-U",
            ["rules_godot_example_controllers", "rules_godot_example_swift"],
        ),
        framework: ("-gU", ["rules_godot_library_init"]),
    }
    with tempfile.TemporaryDirectory(prefix="godot-app-contents-") as directory:
        for name, (flags, wanted) in expected.items():
            data = files[name]
            require_slices(data, cpus, "ios_" + environment, name)
            image = Path(directory) / Path(name).name
            image.write_bytes(data)
            require_symbols(image, cpus, flags, wanted)


def inspect_desktop(
    files: dict[str, bytes], packed: bytes, cpus: set[str], operating_system: str
) -> None:
    names = list(files)
    binary = next(name for name in names if name.endswith("/app"))
    require_slices(
        files[binary],
        cpus,
        "macos" if operating_system == "macos" else "elf",
        binary,
    )
    descriptor = pck_member(packed, "native/hello.gdextension").decode()
    assert operating_system + "." in descriptor, descriptor
    assert any(name.endswith("/libhello.so") for name in names), names
    assert not any(name.endswith((".dex", ".aar")) for name in names), names


def inspect(args: argparse.Namespace) -> None:
    operating_system = args.operating_system
    cpus = set(args.cpus.split(","))
    environment = args.environment
    (path,) = [
        Path(output)
        for output in args.outputs
        if Path(output).name in PUBLISHED[operating_system]
    ]
    files = read_files(path, operating_system)
    assert files, "Application archive is empty"
    names = list(files)
    packed = files[next(name for name in names if name.endswith(".pck"))]
    inspect_pack(packed, operating_system, environment)
    if operating_system != "ios":
        assert not any(name.endswith("/addon_notice.txt") for name in names), names
    if operating_system == "android":
        inspect_android(files, path, cpus, args.aapt)
    elif operating_system == "ios":
        inspect_ios(files, cpus, environment)
    else:
        inspect_desktop(files, packed, cpus, operating_system)


class SelectedAppTest(unittest.TestCase):
    def test_application_contains_its_platform_selection(self) -> None:
        parser = argparse.ArgumentParser()
        parser.add_argument(
            "--operating-system", choices=sorted(PUBLISHED), required=True
        )
        parser.add_argument("--cpus", required=True)
        parser.add_argument("--environment", default="none")
        parser.add_argument("--aapt")
        parser.add_argument("outputs", nargs="+")
        inspect(parser.parse_args(sys.argv[1:]))


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1])
