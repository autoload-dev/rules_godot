"""Tests of the Firebase configuration generator."""

import json
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import google_services

TESTDATA = Path(__file__).parent / "testdata"
TOOLS = "{http://schemas.android.com/tools}"


def _config() -> dict:
    return json.loads((TESTDATA / "google-services.json").read_text())


class AndroidValuesTest(unittest.TestCase):
    def test_writes_the_values_of_the_matching_client(self) -> None:
        self.assertEqual(
            google_services.android_values(_config(), "org.example.game"),
            {
                "gcm_defaultSenderId": "123456789012",
                "project_id": "example-game",
                "firebase_database_url": "https://example-game-default-rtdb.firebaseio.com",
                "google_storage_bucket": "example-game.appspot.com",
                "google_app_id": "1:123456789012:android:aaaaaaaaaaaaaaaa",
                "default_web_client_id": "123456789012-web.apps.googleusercontent.com",
                "google_api_key": "AIzaFakeKeyForTests000000000000000000",
                "google_crash_reporting_api_key": "AIzaFakeKeyForTests000000000000000000",
            },
        )

    def test_picks_a_second_client_and_omits_a_missing_web_client(self) -> None:
        values = google_services.android_values(_config(), "org.example.game.dev")
        self.assertEqual(
            values["google_app_id"], "1:123456789012:android:bbbbbbbbbbbbbbbb"
        )
        self.assertNotIn("default_web_client_id", values)

    def test_names_the_known_clients_when_none_matches(self) -> None:
        with self.assertRaisesRegex(
            google_services.ConfigError, "org.example.game, org.example.game.dev"
        ):
            google_services.android_values(_config(), "org.example.other")

    def test_requires_the_project_number(self) -> None:
        config = _config()
        del config["project_info"]["project_number"]
        with self.assertRaisesRegex(google_services.ConfigError, "gcm_defaultSenderId"):
            google_services.android_values(config, "org.example.game")


class AndroidResourceXmlTest(unittest.TestCase):
    def test_keeps_sorted_untranslatable_strings(self) -> None:
        root = ET.fromstring(google_services.android_resource_xml({"b": "2", "a": "1"}))
        self.assertEqual(root.get(TOOLS + "keep"), "@string/a,@string/b")
        self.assertEqual(
            [(s.get("name"), s.get("translatable"), s.text) for s in root],
            [
                ("a", "false", "1"),
                ("b", "false", "2"),
            ],
        )

    def test_escapes_xml_and_android_syntax(self) -> None:
        root = ET.fromstring(google_services.android_resource_xml({"x": "@a&b'c\"d<e"}))
        self.assertEqual(root[0].text, "\\@a&b\\'c\\\"d<e")


class IosPlistTest(unittest.TestCase):
    def _run(self, application_id: str) -> tuple[int, bool]:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / google_services.PLIST_NAME
            code = google_services.main(
                [
                    "ios",
                    "--config",
                    str(TESTDATA / "GoogleService-Info.plist"),
                    "--application-id",
                    application_id,
                    "--output",
                    str(output),
                ]
            )
            return code, output.exists()

    def test_copies_the_plist_of_the_bundle_identifier(self) -> None:
        self.assertEqual(self._run("org.example.game"), (0, True))

    def test_rejects_another_bundle_identifier(self) -> None:
        self.assertEqual(self._run("org.example.other"), (1, False))


class AndroidCommandTest(unittest.TestCase):
    def test_writes_a_resource_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "google_services.xml"
            code = google_services.main(
                [
                    "android",
                    "--config",
                    str(TESTDATA / "google-services.json"),
                    "--application-id",
                    "org.example.game",
                    "--output",
                    str(output),
                ]
            )
            self.assertEqual(code, 0)
            names = [s.get("name") for s in ET.parse(output).getroot()]
            self.assertIn("google_app_id", names)


if __name__ == "__main__":
    unittest.main()
