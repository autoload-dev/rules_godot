"""
Representative configurations of each public API, keyed by API identity.

A key may append `#variant` for further configurations of the same API. Fields:
target, the fixture root; lane, the CI lane whose contract check runs the case
(default `host`); module, the Bazel module to run in (default the root module);
options; conditions, the contract availabilities the configuration activates;
forwarded_groups, when the root forwards an upstream target's output groups;
host_replacements, string substitutions per host operating system. Repository APIs
list documented entrypoints instead of a target, each with its fixture labels.
"""

_FIXTURES = "//godot/tests/api_contracts:"
_EXPORT_PLATFORM = "--platforms=@autoload_rules_godot//godot/platforms:"

# The application of the platform tests, one declaration for every operating system.
_SELECTED_APP = "//godot/platforms/private/tests/app_platform_selection/fixtures/app_selecting_platform_libraries:app"

# The root module registers the Android SDK and NDK toolchains only where a case asks.
_ANDROID_SDK_TOOLCHAINS = [
    "--extra_toolchains=@androidsdk//:all",
    "--extra_toolchains=@android_toolchains//:all",
]

_VARIANTS = ["debug", "release"]
_HUB_EDITORS = ["linux_arm64", "linux_x86_64", "macos_arm64", "macos_x86_64"]

# The Linux template and Android shell CPUs of Godot's official builds.
_TEMPLATE_CPUS = ["arm32", "arm64", "x86_32", "x86_64"]

def _hub_entrypoints(runtimes, extra = {}):
    """Entrypoint cases of a godot_engines hub: its editors plus the given runtime rows."""
    rows = {
        "@{repository}//toolchains:editor_{platform}_{cpu}": [
            "@godot//toolchains:editor_" + slot
            for slot in _HUB_EDITORS
        ],
        "@{repository}//toolchains:editor_{platform}_{cpu}.toolchain": [
            "@godot//toolchains:editor_%s.toolchain" % slot
            for slot in _HUB_EDITORS
        ],
    }
    for pattern, slots in runtimes.items():
        rows["@{repository}//toolchains:runtime_" + pattern] = [
            "@godot//toolchains:runtime_" + slot
            for slot in slots
        ]
        rows["@{repository}//toolchains:runtime_%s.toolchain" % pattern] = [
            "@godot//toolchains:runtime_%s.toolchain" % slot
            for slot in slots
        ]
    return rows | extra

_ANDROID_TOOLCHAINS = "@android_toolchains//:"
_NDK_TARGET_SYSTEMS = [
    "aarch64-linux-android",
    "arm-linux-androideabi",
    "i686-linux-android",
    "x86_64-linux-android",
]

API_CASES = {
    "//godot:defs.bzl%godot_resources": {"target": _FIXTURES + "resources"},
    "//godot:defs.bzl%godot_addon": {"target": _FIXTURES + "addon"},
    "//godot:defs.bzl%godot_project": {"target": _FIXTURES + "project"},
    "//godot:defs.bzl%godot_pack": {"target": _FIXTURES + "pack"},
    "//godot:defs.bzl%godot_pack#reachable": {"target": _FIXTURES + "reachable_pack", "conditions": ["filtered"]},
    "//godot:defs.bzl%godot_pack#required": {"target": _FIXTURES + "required_pack", "conditions": ["filtered"]},
    "//godot:defs.bzl%godot_run": {"target": _FIXTURES + "run"},
    "//godot:defs.bzl%godot_test": {"target": _FIXTURES + "game_test"},
    "//godot:defs.bzl%godot_editor": {"target": _FIXTURES + "editor"},
    "//godot:defs.bzl%godot_metadata_sync": {"target": _FIXTURES + "metadata"},
    "//godot/extension:defs.bzl%godot_extension": {"target": _FIXTURES + "extension"},
    # Extensions forward CcInfo for the static libraries iOS links.
    "//godot/extension:defs.bzl%godot_extension#cc": {
        "lane": "ios",
        "target": _FIXTURES + "imported_cc",
        "conditions": ["when_cc"],
        "options": [_EXPORT_PLATFORM + "ios_sim_x86_64"],
    },
    "//godot/extension:defs.bzl%godot_cc_extension": {"target": "//godot/extension/tests/fixtures/c_abi:hello"},
    "//godot/extension:defs.bzl%godot_cc_extension#cc": {
        "lane": "ios",
        "target": "//godot/extension/tests/fixtures/c_abi:hello",
        "conditions": ["when_cc"],
        "options": [_EXPORT_PLATFORM + "ios_sim_x86_64"],
    },
    "//godot/engine:defs.bzl%godot_editor_component": {"target": _FIXTURES + "editor_component"},
    "//godot/engine:defs.bzl%godot_runtime_component": {"target": _FIXTURES + "runtime_component"},
    "//godot/engine:defs.bzl%godot_editor_component#engine": {
        "target": _FIXTURES + "editor_component_named",
        "conditions": ["engine named"],
    },
    "//godot/engine:defs.bzl%godot_runtime_component#engine": {
        "target": _FIXTURES + "runtime_component_named",
        "conditions": ["engine named"],
    },
    "//godot/platforms:defs.bzl%godot_export_platform": {"target": "//godot/platforms:linux_x86_64"},
    "//godot:app.bzl%godot_app": {
        "lane": "host",
        "target": _SELECTED_APP,
        "conditions": ["desktop"],
        "options": [_EXPORT_PLATFORM + "macos_arm64"],
        "host_replacements": {"linux": {"macos_arm64": "linux_x86_64"}},
    },
    "//godot:app.bzl%godot_app#editor": {
        "lane": "host",
        "target": _SELECTED_APP,
        "conditions": ["editor"],
        "options": ["--@autoload_rules_godot//godot:variant=editor"],
    },
    "//godot:app.bzl%godot_app#apk": {
        "lane": "android",
        "target": _SELECTED_APP,
        "conditions": ["apk"],
        "options": [_EXPORT_PLATFORM + "android_arm64"] + _ANDROID_SDK_TOOLCHAINS,
        "forwarded_groups": True,
    },
    "//godot:app.bzl%godot_app#aab": {
        "lane": "android",
        "target": _SELECTED_APP,
        "conditions": ["aab"],
        "options": [_EXPORT_PLATFORM + "android_arm64", "--@autoload_rules_godot//godot:android_format=aab"] + _ANDROID_SDK_TOOLCHAINS,
    },
    "//godot:app.bzl%godot_app#ios": {
        "lane": "ios",
        "target": _SELECTED_APP,
        "conditions": ["ios"],
        "options": [_EXPORT_PLATFORM + "ios_sim_x86_64"],
        "forwarded_groups": True,
    },
    "//godot/extension:repositories.bzl%godot_cpp_bindings": {
        "entrypoints": {
            "@{repository}//:godot_cpp": ["@godot_cpp//:godot_cpp"],
            "@{repository}//:{api_path}": ["@godot_cpp//:gdextension/extension_api-4-7.json"],
            "@{repository}//:LICENSE.md": ["@godot_cpp//:LICENSE.md"],
        },
    },
    "//godot:extensions.bzl%godot_engines": {
        "lane": "host",
        "conditions": ["desktop"],
        "entrypoints": _hub_entrypoints({
            "linux_{cpu}_{variant}": ["linux_" + cpu + "_" + v for cpu in _TEMPLATE_CPUS for v in _VARIANTS],
            "macos_{cpu}_{variant}": ["macos_" + cpu + "_" + v for cpu in ["arm64", "x86_64"] for v in _VARIANTS],
        }),
    },
    "//godot:extensions.bzl%godot_engines#android": {
        "lane": "android",
        "module": "tests",
        "conditions": ["android_shell"],
        "entrypoints": _hub_entrypoints(
            # The hub builds the debug runtimes the official release lacks from its sources.
            {"android_{cpu}_{variant}": [
                "android_%s_release" % cpu
                for cpu in _TEMPLATE_CPUS
            ] + ["android_%s_debug" % cpu for cpu in ["arm64", "x86_64"]]},
            {
                "@{repository}//android:{variant}": ["@godot//android:" + v for v in _VARIANTS],
                "@{repository}//android:plugin_api": ["@godot//android:plugin_api"],
            },
        ),
        "options": ["--config=android", _EXPORT_PLATFORM + "android_arm64"],
    },
    # The source tag's archive is fetched only by the source-engine lane.
    "//godot:extensions.bzl%godot_engines#source": {
        "lane": "source-engine",
        "conditions": ["source"],
        "entrypoints": _hub_entrypoints({}, {
            "@{repository}//:source.json": ["@godot_sources//:source.json"],
            "@{repository}//:{archive}": ["@godot_sources//:source.tar.gz"],
        }),
    },
    "//godot:extensions.bzl%godot_engines#ios": {
        "lane": "ios",
        "module": "tests",
        "conditions": ["ios"],
        "entrypoints": _hub_entrypoints({
            "ios_{cpu}_{environment}_{variant}": [
                slot + "_" + v
                # The hub builds the arm64 Simulator runtimes from the release's sources.
                for slot in ["ios_arm64_device", "ios_arm64_simulator", "ios_x86_64_simulator"]
                for v in _VARIANTS
            ],
        }),
        "options": [_EXPORT_PLATFORM + "ios_sim_x86_64"],
    },
    "//godot:extensions.bzl%godot_android_toolchains": {
        "lane": "android",
        "module": "tests",
        "conditions": [],
        "entrypoints": {
            _ANDROID_TOOLCHAINS + "ndk_{target_system}": [
                _ANDROID_TOOLCHAINS + "ndk_" + system
                for system in _NDK_TARGET_SYSTEMS
            ],
            _ANDROID_TOOLCHAINS + "ndk_linux_x86_64_{target_system}": [
                _ANDROID_TOOLCHAINS + "ndk_linux_x86_64_" + system
                for system in _NDK_TARGET_SYSTEMS
            ],
            _ANDROID_TOOLCHAINS + "sdk_linux_x86_64": [
                _ANDROID_TOOLCHAINS + "sdk_linux_x86_64",
            ],
            _ANDROID_TOOLCHAINS + "android_linux_x86_64": [
                _ANDROID_TOOLCHAINS + "android_linux_x86_64",
            ],
            _ANDROID_TOOLCHAINS + "aapt": [
                _ANDROID_TOOLCHAINS + "aapt",
            ],
            _ANDROID_TOOLCHAINS + "aapt2": [
                _ANDROID_TOOLCHAINS + "aapt2",
            ],
        },
        "options": ["--config=android"],
    },
}

# Behavior tests demonstrating why each API's public companions or repository
# entrypoints are separate targets; the checker requires one per API with them. An entry
# is a root-module label or a dict with target and module, as cases name their module.
BEHAVIOR_TESTS = {
    "//godot:app.bzl%godot_app": ["//godot/private/config/tests:test_debug_symbols_need_no_signing_identity"],
    "//godot:defs.bzl%godot_addon": ["//godot/private/tests:test_tests_reach_editor_parts_through_the_editor_target"],
    "//godot:defs.bzl%godot_project": [
        "//godot/private/tests:test_named_addon_is_in_every_operation",
        "//godot/private/tests:test_named_addons_import_their_parts",
    ],
    "//godot:defs.bzl%godot_metadata_sync": [
        "//godot/private/tests/editor_view:editor_view_writes_edits_back_test",
    ],
    "//godot/extension:repositories.bzl%godot_cpp_bindings": [_FIXTURES + "repository_cpp"],
    "//godot:extensions.bzl%godot_engines": [_FIXTURES + "repository_hub"],
    "//godot:extensions.bzl%godot_android_toolchains": [
        "//godot/platforms/private/tests:test_linux_executor_uses_linux_android_tools",
    ],
    "//godot/engine:defs.bzl%godot_editor_component": ["//godot/engine/private/tests:test_editor_resolves_on_execution_platform"],
    "//godot/engine:defs.bzl%godot_runtime_component": ["//godot/engine/private/tests:test_desktop_release_resolves_template_payload"],
}
