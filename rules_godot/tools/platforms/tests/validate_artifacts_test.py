"""The packaging evidence validate_artifacts records from the smoke applications' artifacts."""

import datetime
import json
import tempfile
import unittest
import zipfile
from collections.abc import Sequence
from pathlib import Path
from unittest import mock

from tools.platforms import validate_artifacts

_DESCRIPTOR = 'ios.release = "res://bin/libcounter.a"'

# What each host tool prints, by the name of the command it runs.
_OUTPUTS = {
    "llvm-readelf": "1: 0000 FUNC GLOBAL native_counter_init",
    "aapt": "package: name='org.example'\nsdkVersion:'24'\nlocales: '--_--'",
    "java": "Verifies",
    "xcodebuild": "Xcode 27.0",
    "codesign": "",
    "dyld_info": "_native_counter_init",
    "file": "Mach-O 64-bit executable arm64",
}


class ValidateArtifactsTest(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve() / "rules_godot"
        self.root.mkdir()
        (self.root / ".bazelversion").write_text("9.3.0\n")
        self.ndk = self.root / "ndk"
        self.ndk.mkdir()
        (self.ndk / "source.properties").write_text("Pkg.Revision = 29.0\n")
        self.apk = self.root / "app.apk"
        self.write_apk("lib/arm64-v8a/libcounter.so")
        self.bundle = self.root / "static_app.app"
        self.app = self.root / "unpacked"
        self.app.mkdir()
        (self.app / "static_app.pck").write_bytes(b"ios-pack")
        self.descriptor = _DESCRIPTOR
        self.outputs = dict(_OUTPUTS)

    def write_apk(self, library: str) -> None:
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr(library, b"library")
            archive.writestr("lib/arm64-v8a/libgodot_android.so", b"engine")
            archive.writestr("assets/main.pck", b"android-pack")

    def pck_contents(self, data: bytes) -> dict:
        if data == b"ios-pack":
            return {"extension_descriptors": {"counter.gdextension": self.descriptor}}
        return {"files": ["res://main.tscn"]}

    def command(self, args: Sequence[object]) -> str:
        words = [str(arg) for arg in args]
        if words[:2] == ["/usr/bin/xcrun", "--sdk"]:
            return "27.0"
        name = Path(words[1] if words[0] == "/usr/bin/xcrun" else words[0]).name
        return self.outputs[name]

    def validate(self) -> dict:
        output = self.root / "evidence.json"
        argv = [
            "validate_artifacts",
            f"--root={self.root}",
            "--android-sdk=/sdk",
            f"--android-ndk={self.ndk}",
            "--android-api-level=36",
            "--java=/jdk/bin/java",
            "--build-tools=36.1.0",
            "--output=evidence.json",
        ]
        now = datetime.datetime(2026, 1, 2, 3, 4, 5, tzinfo=datetime.UTC)
        with (
            mock.patch("sys.argv", argv),
            mock.patch("sys.stdout"),
            mock.patch.object(
                validate_artifacts,
                "configured_output",
                side_effect=[self.apk, self.bundle],
            ),
            mock.patch.object(validate_artifacts, "command", self.command),
            mock.patch.object(validate_artifacts, "pck_contents", self.pck_contents),
            mock.patch.object(validate_artifacts, "digest", return_value="apk-digest"),
            mock.patch.object(
                validate_artifacts, "application_bundle", return_value=self.app
            ),
            mock.patch.object(
                validate_artifacts, "bundle_identity", return_value=("ios-digest", 42)
            ),
            mock.patch.object(validate_artifacts, "datetime") as clock,
        ):
            clock.now.return_value = now
            validate_artifacts.main()
        return json.loads(output.read_text())

    def test_evidence_names_the_artifacts_and_their_inspections(self) -> None:
        consumer = self.root.parent
        self.assertEqual(
            self.validate(),
            {
                "validated_at_utc": "2026-01-02T03:04:05+00:00",
                "device_execution": False,
                "toolchains": {
                    "bazel": "9.3.0",
                    "godot": "4.7.2.stable",
                    "android_sdk": "36",
                    "android_build_tools": "36.1.0",
                    "android_ndk": "Pkg.Revision = 29.0",
                    "java_build_runtime_and_language": "21",
                    "xcode": "Xcode 27.0",
                    "iphonesimulator_sdk": "27.0",
                },
                "build_commands": {
                    "android": (
                        f"cd {consumer} && ANDROID_HOME=/sdk ANDROID_NDK_HOME={self.ndk} "
                        "bazel build //e2e/rules_godot/smoke/android:app --config=android"
                    ),
                    "ios": (
                        f"cd {consumer} && bazel build "
                        "//e2e/rules_godot/smoke/ios:static_app --config=official"
                    ),
                    "macos": (
                        f"cd {consumer} && bazel build //e2e/rules_godot/smoke/macos:app "
                        "--@autoload_rules_godot//godot:macos_signing=adhoc"
                    ),
                },
                "android": {
                    "artifact": str(self.apk),
                    "sha256": "apk-digest",
                    "size_bytes": self.apk.stat().st_size,
                    "signature_verification": "Verifies",
                    "manifest_summary": [
                        "package: name='org.example'",
                        "sdkVersion:'24'",
                    ],
                    "native_libraries": [
                        "lib/arm64-v8a/libcounter.so",
                        "lib/arm64-v8a/libgodot_android.so",
                    ],
                    "gdextension_entry_exported": "native_counter_init",
                    "pck": {"files": ["res://main.tscn"]},
                },
                "ios": {
                    "artifact": str(self.bundle),
                    "sha256": "ios-digest",
                    "size_bytes": 42,
                    "signature_verification": "codesign --verify --deep --strict passed",
                    "cpu": "Mach-O 64-bit executable arm64",
                    "gdextension_entry_exported": "_native_counter_init",
                    "pck": {
                        "extension_descriptors": {"counter.gdextension": _DESCRIPTOR}
                    },
                    "official_template_caveat": (
                        "4.7.2 simulator archive is x86_64 despite arm64+x86_64 "
                        "XCFramework metadata"
                    ),
                },
            },
        )

    def test_missing_extension_code_is_an_error(self) -> None:
        self.write_apk("lib/arm64-v8a/libother.so")
        with self.assertRaisesRegex(ValueError, "no compiled extension library"):
            self.validate()
        self.write_apk("lib/arm64-v8a/libcounter.so")
        self.outputs["llvm-readelf"] = ""
        with self.assertRaisesRegex(ValueError, "Android extension entry is absent"):
            self.validate()
        self.outputs = dict(_OUTPUTS, dyld_info="")
        with self.assertRaisesRegex(ValueError, "iOS static extension entry is absent"):
            self.validate()
        self.outputs = dict(_OUTPUTS)
        self.descriptor = 'ios.release = ""'
        with self.assertRaisesRegex(ValueError, "nonempty static .a descriptor path"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
