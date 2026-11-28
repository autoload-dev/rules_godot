"""Record artifact-level mobile packaging evidence without claiming device runs."""

import argparse
import json
import os
import re
import shlex
import subprocess
import tempfile
import zipfile
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

from tools.digest import digest
from tools.pack.pck import pck_contents
from tools.platforms.apple_bundle import application_bundle, bundle_identity

# The consumer scenarios' smoke applications whose artifacts this check validates, in the
# repository's root module, and the godot-cpp extension each one packages.
ANDROID_APP = "//e2e/rules_godot/smoke/android:app"
# The iOS application that links the extension statically, whose executable exports its
# entry symbol; the smoke's other iOS application embeds the extension as a framework.
IOS_APP = "//e2e/rules_godot/smoke/ios:static_app"
# Its bundle, executable and pack, named after the target.
IOS_EXECUTABLE = "static_app"
MACOS_APP = "//e2e/rules_godot/smoke/macos:app"
ANDROID_LIBRARY = "lib/arm64-v8a/libcounter.so"
ENTRY_SYMBOL = "native_counter_init"


def command(args: Iterable[object]) -> str:
    return subprocess.check_output(
        [str(arg) for arg in args], stderr=subprocess.STDOUT, text=True
    ).strip()


def configured_output(module: Path, target: str, config: str, suffix: str) -> Path:
    """Locate a built artifact without following the last build's bazel-bin link."""
    bazel = shlex.split(os.environ.get("BAZEL", "bazel"))

    def query(*arguments: str) -> str:
        return subprocess.check_output(
            [*bazel, *arguments, f"--config={config}"], cwd=module, text=True
        ).strip()

    execution_root = Path(query("info", "execution_root"))
    outputs = query("cquery", target, "--output=files").splitlines()
    matches = [execution_root / path for path in outputs if path.endswith(suffix)]
    if len(matches) != 1 or not matches[0].exists():
        raise ValueError(f"Build {target} --config={config} before inspecting it")
    return matches[0]


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(os.environ.get("BUILD_WORKSPACE_DIRECTORY", ".")),
    )
    parser.add_argument("--android-sdk", type=Path, required=True)
    parser.add_argument("--android-ndk", type=Path, required=True)
    # The API level the root module configures for its SDK, which the repository's tooling
    # reads from its MODULE.bazel (tools/android/requirements.py).
    parser.add_argument("--android-api-level", required=True)
    parser.add_argument("--java", type=Path, required=True)
    parser.add_argument("--build-tools", required=True)
    parser.add_argument("--output", type=Path, help="Write the result to this path")
    return parser


def _toolchains(args: argparse.Namespace, root: Path) -> dict[str, str]:
    """Return the versions of the toolchains that built and inspect the artifacts."""
    return {
        "bazel": (root / ".bazelversion").read_text().strip(),
        "godot": "4.7.2.stable",
        "android_sdk": args.android_api_level,
        "android_build_tools": args.build_tools,
        "android_ndk": (args.android_ndk / "source.properties").read_text().strip(),
        "java_build_runtime_and_language": "21",
        "xcode": command(["/usr/bin/xcodebuild", "-version"]),
        "iphonesimulator_sdk": command(
            ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]
        ),
    }


def _build_commands(args: argparse.Namespace, consumer: Path) -> dict[str, str]:
    """Return the commands that build the artifacts in the root module."""
    return {
        "android": (
            f"cd {shlex.quote(str(consumer))} && "
            f"ANDROID_HOME={shlex.quote(str(args.android_sdk))} "
            f"ANDROID_NDK_HOME={shlex.quote(str(args.android_ndk))} "
            f"bazel build {ANDROID_APP} --config=android"
        ),
        "ios": (
            f"cd {shlex.quote(str(consumer))} && bazel build {IOS_APP} --config=official"
        ),
        "macos": (
            f"cd {shlex.quote(str(consumer))} && bazel build {MACOS_APP} "
            "--@autoload_rules_godot//godot:macos_signing=adhoc"
        ),
    }


# The lines of aapt's badging that summarize the APK's manifest.
_MANIFEST_SUMMARY = (
    "package:",
    "sdkVersion:",
    "targetSdkVersion:",
    "launchable-activity:",
    "native-code:",
)


def _android_evidence(apk: Path, args: argparse.Namespace, temporary: Path) -> dict:
    """Return what the APK's signature, manifest, libraries and pack show."""
    android_tools = args.android_sdk / "build-tools" / args.build_tools
    with zipfile.ZipFile(apk) as archive:
        native_paths = sorted(
            path
            for path in archive.namelist()
            if path.startswith("lib/") and path.endswith(".so")
        )
        if ANDROID_LIBRARY not in native_paths:
            raise ValueError("Android artifact has no compiled extension library")
        library = temporary / Path(ANDROID_LIBRARY).name
        library.write_bytes(archive.read(ANDROID_LIBRARY))
        readelf = (
            args.android_ndk / "toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf"
        )
        symbols = command([readelf, "--dyn-syms", "--wide", library])
        if ENTRY_SYMBOL not in symbols:
            raise ValueError("Android extension entry is absent from dynamic symbols")
        badging = command([android_tools / "aapt", "dump", "badging", apk])
        return {
            "artifact": str(apk),
            "sha256": digest(apk),
            "size_bytes": apk.stat().st_size,
            "signature_verification": command(
                [
                    args.java,
                    "-jar",
                    android_tools / "lib/apksigner.jar",
                    "verify",
                    "--verbose",
                    apk,
                ]
            ),
            "manifest_summary": [
                line
                for line in badging.splitlines()
                if line.startswith(_MANIFEST_SUMMARY)
            ],
            "native_libraries": native_paths,
            "gdextension_entry_exported": ENTRY_SYMBOL,
            "pck": pck_contents(archive.read("assets/main.pck")),
        }


def _ios_evidence(bundle: Path, temporary: Path) -> dict:
    """Return what the iOS bundle's signature, executable and pack show."""
    app = application_bundle(bundle, temporary / "ios")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    executable = app / IOS_EXECUTABLE
    exported = command(["/usr/bin/xcrun", "dyld_info", "-exports", executable])
    if f"_{ENTRY_SYMBOL}" not in exported:
        raise ValueError("iOS static extension entry is absent from Mach-O exports")
    pack = pck_contents((app / f"{IOS_EXECUTABLE}.pck").read_bytes())
    descriptor = "\n".join(pack["extension_descriptors"].values())
    if not re.search(r'ios[^=]*=\s*"res://[^"\n]+\.a"', descriptor):
        raise ValueError("iOS pack must retain a nonempty static .a descriptor path")
    sha256, size = bundle_identity(bundle)
    return {
        "artifact": str(bundle),
        "sha256": sha256,
        "size_bytes": size,
        "signature_verification": "codesign --verify --deep --strict passed",
        "cpu": command(["/usr/bin/file", "-b", executable]),
        "gdextension_entry_exported": f"_{ENTRY_SYMBOL}",
        "pck": pack,
        "official_template_caveat": "4.7.2 simulator archive is x86_64 despite arm64+x86_64 XCFramework metadata",
    }


def main() -> None:
    args = _parser().parse_args()
    root = args.root.resolve()
    # The repository's root module, which holds the scenarios.
    consumer = root.parent
    apk = configured_output(consumer, ANDROID_APP, "android", "/app.apk")
    # A Simulator build keeps the application a directory.
    bundle = configured_output(consumer, IOS_APP, "official", f"/{IOS_EXECUTABLE}.app")
    evidence = {
        "validated_at_utc": datetime.now(UTC).isoformat(),
        "device_execution": False,
        "toolchains": _toolchains(args, root),
        "build_commands": _build_commands(args, consumer),
    }
    with tempfile.TemporaryDirectory() as temporary:
        evidence["android"] = _android_evidence(apk, args, Path(temporary))
        evidence["ios"] = _ios_evidence(bundle, Path(temporary))
    result = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    if args.output:
        output = args.output if args.output.is_absolute() else root / args.output
        output.write_text(result)
    print(result, end="")


if __name__ == "__main__":
    main()
