"""Turn Firebase app configuration files into the platform resources of one application.

``android`` does what the ``com.google.gms.google-services`` Gradle plugin does for one
variant: it picks the client of the application ID from ``google-services.json`` and writes
its values as Android string resources. ``ios`` checks ``GoogleService-Info.plist`` against
the bundle identifier and copies it under the name the Firebase SDK looks up.
"""

import argparse
import json
import plistlib
import shutil
import sys
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape

# The values without which FirebaseApp.configure() raises on iOS.
REQUIRED_PLIST_KEYS = ("GOOGLE_APP_ID", "GCM_SENDER_ID")

# client_type of the OAuth client the plugin writes as default_web_client_id.
WEB_CLIENT_TYPE = 3

PLIST_NAME = "GoogleService-Info.plist"


class ConfigError(Exception):
    """A configuration file that does not fit the application."""


def android_values(config: dict[str, Any], application_id: str) -> dict[str, str]:
    """
    Return the string resources the Gradle plugin writes for ``application_id``.

    Args:
        config: The parsed ``google-services.json``.
        application_id: The Android application ID of the app.

    Returns:
        A dict from resource name to value.

    Raises:
        ConfigError: When no client matches or a required value is missing.
    """
    project = config.get("project_info", {})
    client = _client(config, application_id)
    values: dict[str, str] = {}
    _put(values, "gcm_defaultSenderId", project.get("project_number"), required=True)
    _put(values, "project_id", project.get("project_id"))
    _put(values, "firebase_database_url", project.get("firebase_url"))
    _put(values, "google_storage_bucket", project.get("storage_bucket"))
    _put(
        values,
        "google_app_id",
        client.get("client_info", {}).get("mobilesdk_app_id"),
        required=True,
    )
    web_clients = [
        oauth
        for oauth in client.get("oauth_client", [])
        if oauth.get("client_type") == WEB_CLIENT_TYPE
    ]
    if web_clients:
        _put(values, "default_web_client_id", web_clients[0].get("client_id"))
    api_keys = client.get("api_key", [])
    if api_keys:
        _put(values, "google_api_key", api_keys[0].get("current_key"))
        _put(values, "google_crash_reporting_api_key", api_keys[0].get("current_key"))
    return values


def _package_name(client: dict[str, Any]) -> str | None:
    return (
        client.get("client_info", {}).get("android_client_info", {}).get("package_name")
    )


def _client(config: dict[str, Any], application_id: str) -> dict[str, Any]:
    clients = config.get("client", [])
    # The first client of a package wins, as in the Gradle plugin.
    by_package = {
        package: client
        for client in reversed(clients)
        if (package := _package_name(client)) is not None
    }
    if application_id in by_package:
        return by_package[application_id]
    clients_text = ", ".join(sorted(by_package)) or "no Android clients"
    raise ConfigError(
        f"No client for application ID {application_id!r} in google-services.json; it has "
        f"{clients_text}. Register the app in the Firebase console or download the file of "
        "the right project."
    )


def _put(
    values: dict[str, str], name: str, value: object, *, required: bool = False
) -> None:
    if value is None or value == "":
        if required:
            raise ConfigError(f"google-services.json has no value for {name}")
        return
    values[name] = str(value)


def android_resource_xml(values: dict[str, str]) -> str:
    """
    Return a ``res/values`` file of ``values``.

    The SDK looks the strings up by name at run time, so ``tools:keep`` protects them from
    resource shrinking; ``translatable="false"`` keeps lint quiet as the plugin does.
    """
    names = sorted(values)
    kept = ",".join("@string/" + name for name in names)
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="{kept}">',
    ]
    lines += [
        f'    <string name="{name}" translatable="false">'
        f"{_android_string(values[name])}</string>"
        for name in names
    ]
    lines.append("</resources>")
    return "\n".join(lines) + "\n"


def _android_string(value: str) -> str:
    """Escape ``value`` for XML and for Android's string resource syntax."""
    text = escape(value).replace("\\", "\\\\").replace("'", "\\'").replace('"', '\\"')
    if text[:1] in ("@", "?"):
        text = "\\" + text
    return text


def check_ios_plist(plist: dict[str, Any], application_id: str) -> None:
    """
    Check that ``plist`` belongs to ``application_id``.

    Raises:
        ConfigError: When the bundle identifier is different or a required value is missing.
    """
    bundle_id = plist.get("BUNDLE_ID")
    if bundle_id != application_id:
        raise ConfigError(
            f"{PLIST_NAME} is for bundle identifier {bundle_id!r}, not {application_id!r}; "
            "download the file of the app registered with this identifier."
        )
    for key in REQUIRED_PLIST_KEYS:
        if not plist.get(key):
            raise ConfigError(f"{PLIST_NAME} has no {key}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    android = commands.add_parser(
        "android", help="Write the string resources of google-services.json."
    )
    android.add_argument("--config", type=Path, required=True)
    android.add_argument("--application-id", required=True)
    android.add_argument("--output", type=Path, required=True)
    ios = commands.add_parser("ios", help="Check and copy GoogleService-Info.plist.")
    ios.add_argument("--config", type=Path, required=True)
    ios.add_argument("--application-id", required=True)
    ios.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "android":
            config = json.loads(args.config.read_text(encoding="utf-8"))
            args.output.write_text(
                android_resource_xml(android_values(config, args.application_id)),
                encoding="utf-8",
            )
        else:
            with args.config.open("rb") as stream:
                check_ios_plist(plistlib.load(stream), args.application_id)
            shutil.copyfile(args.config, args.output)
    except ConfigError as error:
        print(f"{args.config}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
