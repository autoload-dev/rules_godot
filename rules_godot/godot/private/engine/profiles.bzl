"""
What rules_godot mirrors of Godot's exporters, by engine version.

Godot itself reports what it decides for an export: the export's feature tags,
the values and defaults of the export options and the project settings with the
export's feature overrides (see the pack's shell assets). A profile holds the
rest: the owned export options and the tables and constants Godot's
exporters use to write shell files, such as Android categories or iOS icon sizes.
Rules pass a profile to the build tools as data, so a newer Godot
version changes one profile, not the code that writes shell files.

Sections: Godot 4.7, Export options, Export hooks, Godot 4.8, Android shell, Runtime
profile, Build profile, Profile lookup.
"""

load("//godot/private:versions.bzl", "godot_series", "require_supported_source_version")

visibility(["//godot/..."])

# ==== Godot 4.7 ===============================================================

_LEFT = "UIInterfaceOrientationLandscapeLeft"

_RIGHT = "UIInterfaceOrientationLandscapeRight"

_UP = "UIInterfaceOrientationPortrait"

_DOWN = "UIInterfaceOrientationPortraitUpsideDown"

_ALL = [_LEFT, _RIGHT, _UP, _DOWN]

# Godot 4.7, from its Android, iOS (Apple embedded) and macOS exporters.
_GODOT_4_7 = {
    # Godot's default application icon and boot splash, beside this file.
    "assets": {
        "icon": "godot_4_7_icon.png",
        "splash": "godot_4_7_splash.png",
    },
    "android": {
        # The version options, whose value Godot's get_version reports.
        "version_options": ["version/name"],
        # package/app_category, by index; the index after the last is Undefined.
        "app_categories": [
            "accessibility",
            "audio",
            "game",
            "image",
            "maps",
            "news",
            "productivity",
            "social",
            "video",
        ],
        "game_category": 2,
        # Google Play's largest versionCode.
        "max_version_code": 2100000000,
        # The SDK versions when gradle_build/min_sdk and target_sdk are empty.
        "min_sdk": "24",
        "target_sdk": "36",
        # Godot's ScreenOrientation, in the order of display/window/handheld/orientation.
        "orientations": [
            "landscape",
            "portrait",
            "reverseLandscape",
            "reversePortrait",
            "userLandscape",
            "userPortrait",
            "fullUser",
        ],
        "launcher_categories": [
            ["package/show_in_app_library", "LAUNCHER"],
            ["package/show_in_android_tv", "LEANBACK_LAUNCHER"],
            ["package/show_as_launcher_app", "HOME"],
        ],
        "screen_sizes": ["small", "normal", "large", "xlarge"],
        # Permissions that make Godot request legacy external storage.
        "storage_permissions": [
            "android.permission.READ_EXTERNAL_STORAGE",
            "android.permission.WRITE_EXTERNAL_STORAGE",
        ],
        # Declared permissions Godot limits with android:maxSdkVersion, some only beside
        # another declared permission.
        "max_sdk_permissions": {
            "android.permission.WRITE_EXTERNAL_STORAGE": {"max_sdk": "29"},
            "android.permission.READ_EXTERNAL_STORAGE": {
                "max_sdk": "29",
                "requires": "android.permission.MANAGE_EXTERNAL_STORAGE",
            },
        },
        # Godot's template activity: its copy beside this file, its path in Godot's
        # platform/android and whether it reads the BuildConfig of Godot's Gradle build.
        "template_activity": {
            "path": "android/godot_4_7/GodotApp.java",
            "upstream": "java/app/src/main/java/com/godot/game/GodotApp.java",
            "build_config": True,
        },
        # The configuration changes the exporter's activity element lets it handle.
        "config_changes": [
            "layoutDirection",
            "locale",
            "orientation",
            "keyboardHidden",
            "screenSize",
            "smallestScreenSize",
            "density",
            "keyboard",
            "navigation",
            "screenLayout",
            "uiMode",
        ],
        # The command line flags of Godot's Android export, in its order.
        "command_line": {
            "xr_off": ["--xr_mode_regular", "--xr-mode", "off"],
            "flags": [
                ["screen/immersive_mode", "--fullscreen"],
                ["screen/edge_to_edge", "--edge_to_edge"],
            ],
            "background_color": "--background_color",
            "late_flags": [
                ["splash_screen/disable_godot_boot_splash", "--disable_godot_splash"],
                ["graphics/opengl_debug", "--debug_opengl"],
            ],
        },
        # Godot requests Vulkan for these rendering methods on this driver.
        "vulkan": {
            "rendering_methods": ["forward_plus", "mobile"],
            "driver": "vulkan",
            "version": "0x401000",
        },
        # Android ABIs by Godot's feature tag.
        "abis": {
            "arm32": "armeabi-v7a",
            "arm64": "arm64-v8a",
            "x86_32": "x86",
            "x86_64": "x86_64",
        },
        # Launcher icons: the directory of each density with the size of the
        # regular icon and of the adaptive icon layers.
        "icon_densities": [
            ["mipmap-xxxhdpi-v4", 192, 432],
            ["mipmap-xxhdpi-v4", 144, 324],
            ["mipmap-xhdpi-v4", 96, 216],
            ["mipmap-hdpi-v4", 72, 162],
            ["mipmap-mdpi-v4", 48, 108],
            ["mipmap", 192, 432],
        ],
    },
    "ios": {
        "version_options": ["application/short_version", "application/version"],
        # The CPUs of the exporter's architectures/* options. A Simulator
        # export of another CPU lacks its feature tag, so the rules add it
        # for the export and remove it from the packed settings (tools/pack/pck.py).
        # Temporary exception: drop both once Godot's iOS exporter registers every
        # Simulator CPU.
        "cpus": ["arm64"],
        # The privacy manifest declares the required-reason APIs.
        "declares_accessed_apis": True,
        # App icons: option, file name, pixels, scale and size in points.
        "icons": [
            ["icons/settings_58x58", "Icon-58", 58, "2x", "29x29"],
            ["icons/settings_87x87", "Icon-87", 87, "3x", "29x29"],
            ["icons/notification_40x40", "Icon-40", 40, "2x", "20x20"],
            ["icons/notification_60x60", "Icon-60", 60, "3x", "20x20"],
            ["icons/notification_76x76", "Icon-76", 76, "2x", "38x38"],
            ["icons/notification_114x114", "Icon-114", 114, "3x", "38x38"],
            ["icons/spotlight_80x80", "Icon-80", 80, "2x", "40x40"],
            ["icons/spotlight_120x120", "Icon-120", 120, "3x", "40x40"],
            ["icons/iphone_120x120", "Icon-120-1", 120, "2x", "60x60"],
            ["icons/iphone_180x180", "Icon-180", 180, "3x", "60x60"],
            ["icons/ipad_167x167", "Icon-167", 167, "2x", "83.5x83.5"],
            ["icons/ipad_152x152", "Icon-152", 152, "2x", "76x76"],
            ["icons/ios_128x128", "Icon-128", 128, "2x", "64x64"],
            ["icons/ios_192x192", "Icon-192", 192, "3x", "64x64"],
            ["icons/ios_136x136", "Icon-136", 136, "2x", "68x68"],
            ["icons/app_store_1024x1024", "Icon-1024", 1024, "1x", "1024x1024"],
        ],
        # The icon of every size without its own option, and the opaque one.
        "base_icon": "icons/icon_1024x1024",
        "opaque_icon": "icons/app_store_1024x1024",
        "orientations": [[_LEFT], [_UP], [_RIGHT], [_DOWN], [_LEFT, _RIGHT], [_UP, _DOWN], _ALL],
        "ipad_orientations": [
            [_RIGHT],
            [_UP],
            [_LEFT],
            [_DOWN],
            [_LEFT, _RIGHT],
            [_UP, _DOWN],
            _ALL,
        ],
        "capabilities": [
            ["capabilities/access_wifi", "wifi"],
            ["capabilities/performance_gaming_tier", "iphone-performance-gaming-tier"],
        ],
        # Godot requires an A12 for these mobile rendering methods and hides the
        # option there.
        "a12": {
            "option": "capabilities/performance_a12",
            "capability": "iphone-ipad-minimum-performance-a12",
            "rendering_methods": ["forward_plus", "mobile"],
        },
        "usage_descriptions": [
            ["privacy/camera_usage_description", "NSCameraUsageDescription"],
            ["privacy/microphone_usage_description", "NSMicrophoneUsageDescription"],
            ["privacy/photolibrary_usage_description", "NSPhotoLibraryUsageDescription"],
        ],
    },
    "macos": {
        "version_options": ["application/short_version", "application/version"],
        "declares_accessed_apis": False,
        "usage_descriptions": [
            ["privacy/microphone_usage_description", "NSMicrophoneUsageDescription"],
            ["privacy/camera_usage_description", "NSCameraUsageDescription"],
            ["privacy/location_usage_description", "NSLocationUsageDescription"],
            ["privacy/address_book_usage_description", "NSContactsUsageDescription"],
            ["privacy/calendar_usage_description", "NSCalendarsUsageDescription"],
            ["privacy/photos_library_usage_description", "NSPhotoLibraryUsageDescription"],
            ["privacy/desktop_folder_usage_description", "NSDesktopFolderUsageDescription"],
            [
                "privacy/documents_folder_usage_description",
                "NSDocumentsFolderUsageDescription",
            ],
            [
                "privacy/downloads_folder_usage_description",
                "NSDownloadsFolderUsageDescription",
            ],
            [
                "privacy/network_volumes_usage_description",
                "NSNetworkVolumesUsageDescription",
            ],
            [
                "privacy/removable_volumes_usage_description",
                "NSRemovableVolumesUsageDescription",
            ],
        ],
        # The sizes of the images of an .icns file.
        "icon_sizes": [16, 32, 64, 128, 256, 512, 1024],
    },
    # The privacy manifest of Godot's Apple exports.
    "privacy": {
        # Required-reason APIs of privacy/<name>_access_reasons and the reasons
        # of each flag bit.
        "accessed_apis": [
            ["file_timestamp", "FileTimestamp", ["DDA9.1", "C617.1", "3B52.1"]],
            ["system_boot_time", "SystemBootTime", ["35F9.1", "8FFB.1", "3D61.1"]],
            ["disk_space", "DiskSpace", ["E174.1", "85F4.1", "7D9E.1", "B728.1"]],
            ["active_keyboard", "ActiveKeyboards", ["3EC4.1", "54BD.1"]],
            ["user_defaults", "UserDefaults", ["1C8F.1", "AC6B.1", "CA92.1"]],
        ],
        # privacy/collected_data/<name>/* options and Apple's data type of each.
        "collected_data": [
            ["name", "Name"],
            ["email_address", "EmailAddress"],
            ["phone_number", "PhoneNumber"],
            ["physical_address", "PhysicalAddress"],
            ["other_contact_info", "OtherUserContactInfo"],
            ["health", "Health"],
            ["fitness", "Fitness"],
            ["payment_info", "PaymentInfo"],
            ["credit_info", "CreditInfo"],
            ["other_financial_info", "OtherFinancialInfo"],
            ["precise_location", "PreciseLocation"],
            ["coarse_location", "CoarseLocation"],
            ["sensitive_info", "SensitiveInfo"],
            ["contacts", "Contacts"],
            ["emails_or_text_messages", "EmailsOrTextMessages"],
            ["photos_or_videos", "PhotosorVideos"],
            ["audio_data", "AudioData"],
            ["gameplay_content", "GameplayContent"],
            ["customer_support", "CustomerSupport"],
            ["other_user_content", "OtherUserContent"],
            ["browsing_history", "BrowsingHistory"],
            ["search_history", "SearchHistory"],
            ["user_id", "UserID"],
            ["device_id", "DeviceID"],
            ["purchase_history", "PurchaseHistory"],
            ["product_interaction", "ProductInteraction"],
            ["advertising_data", "AdvertisingData"],
            ["other_usage_data", "OtherUsageData"],
            ["crash_data", "CrashData"],
            ["performance_data", "PerformanceData"],
            ["other_diagnostic_data", "OtherDiagnosticData"],
            ["environment_scanning", "EnvironmentScanning"],
            ["hands", "Hands"],
            ["head", "Head"],
            ["other_data_types", "OtherDataTypes"],
        ],
        # Flag bits of privacy/collected_data/<name>/collection_purposes.
        "purposes": [
            "Analytics",
            "AppFunctionality",
            "DeveloperAdvertising",
            "ThirdPartyAdvertising",
            "ProductPersonalization",
            "Other",
        ],
    },
}

# ==== Export options ==========================================================

# One row owns the value, applicability and authoring policy together. CPU
# rows reuse exporter maps above; Android SDK fallbacks stay in the Android shell policy.
def _owned(key, owner, derive, placement, when, authored, **operands):
    return dict(
        key = key,
        owner = owner,
        derive = derive,
        placement = placement,
        when = when,
        authored = authored,
        **operands
    )

def _cpu_rows(suffixes):
    return [
        _owned(
            "architectures/" + suffix,
            "export_platform",
            derive = "cpu_member",
            placement = "preset",
            when = "always",
            authored = "reject",
            cpu = cpu,
        )
        for cpu, suffix in suffixes.items()
    ]

_DESKTOP_ARCHITECTURE = _owned(
    "binary_format/architecture",
    "export_platform",
    derive = "first_cpu",
    placement = "prelude",
    when = "always",
    authored = "reject",
)

_NO_EMBEDDED_PACK = _owned(
    "binary_format/embed_pck",
    "output-layout",
    derive = "constant",
    placement = "prelude",
    when = "always",
    authored = "reject",
    value = False,
)

_BUNDLE_IDENTIFIER = _owned(
    "application/bundle_identifier",
    "identity",
    derive = "application_value",
    placement = "pack",
    when = "application_identity",
    authored = "match",
    source = "application_id",
)

def _macos_owned_options():
    return [
        _DESKTOP_ARCHITECTURE,
        # Godot stores this unregistered value; a plugin can register it and
        # an authored value then overrides the prelude.
        _NO_EMBEDDED_PACK | {
            "authored": "live",
            "exception": "Retain the observable unregistered prefix and registered-plugin override; remove only with behavior-equivalence evidence or separately approved behavior change.",
        },
        _BUNDLE_IDENTIFIER,
    ] + [
        _owned(
            "application/min_macos_version_" + cpu,
            "macos-deployment",
            derive = "application_value",
            placement = "pack",
            when = "macos_application",
            authored = "match",
            source = "macos_minimum_os_version",
        )
        for cpu in ["arm64", "x86_64"]
    ]

def _android_owned_options(profile):
    return _cpu_rows(profile["android"]["abis"]) + [
        _BUNDLE_IDENTIFIER | {"key": "package/unique_name"},
    ] + [
        _owned(
            "gradle_build/%s_sdk" % sdk,
            "android-sdk",
            derive = "android_sdk",
            placement = "pack",
            when = "android_application",
            authored = "reject",
            sdk = sdk,
        )
        for sdk in ["min", "target"]
    ]

def _ios_owned_options(profile):
    return _cpu_rows({cpu: cpu for cpu in profile["ios"]["cpus"]}) + [
        _BUNDLE_IDENTIFIER,
        _owned(
            "application/min_ios_version",
            "ios-deployment",
            derive = "application_value",
            placement = "pack",
            when = "ios_application",
            authored = "match",
            source = "ios_minimum_os_version",
        ),
        _owned(
            "application/targeted_device_family",
            "ios-deployment",
            derive = "application_enum",
            placement = "pack",
            when = "ios_application",
            authored = "match",
            source = "ios_families",
            choices = {"iphone": 0, "ipad": 1, "ipad,iphone": 2},
        ),
    ]

def _web_owned_options():
    """
    Return the web export's owned options.

    Its variant follows the export platform and the pack's extensions.
    """
    return [
        _owned(
            "variant/thread_support",
            "export_platform",
            derive = "web_threads",
            placement = "preset",
            when = "always",
            authored = "reject",
        ),
        _owned(
            "variant/extensions_support",
            "web-extensions",
            derive = "constant",
            placement = "preset",
            when = "always",
            authored = "reject",
            value = False,
        ),
    ]

def _owned_options(profile):
    return {
        "linux": [_DESKTOP_ARCHITECTURE, _NO_EMBEDDED_PACK],
        "macos": _macos_owned_options(),
        "android": _android_owned_options(profile),
        "ios": _ios_owned_options(profile),
        "web": _web_owned_options(),
    }

_GODOT_4_7["owned_export_options"] = _owned_options(_GODOT_4_7)

# Export options a pack must not author, by exporter, with the owner ID of what
# replaces them: option_owners names a Bazel equivalent; other owners have no
# supported workflow. Rejections of owned options come from owned_export_options;
# identity/deployment mirrors may be authored when they agree. Godot's probe
# reports which options an exporter registers, with their types and defaults; the
# reviewed per-option inventory of a version and how to compare a new one are in
# docs/internal/export-option-inventory.md.
_REJECTED_OPTIONS_4_7 = {
    "web": {
        "custom_template/debug": "engine",
        "custom_template/release": "engine",
    },
    "linux": {
        "custom_template/debug": "engine",
        "custom_template/release": "engine",
        "debug/export_console_wrapper": "output-layout",
        "shader_baker/enabled": "shader-baking",
        "ssh_remote_deploy/cleanup_script": "remote-deployment",
        "ssh_remote_deploy/enabled": "remote-deployment",
        "ssh_remote_deploy/extra_args_scp": "remote-deployment",
        "ssh_remote_deploy/extra_args_ssh": "remote-deployment",
        "ssh_remote_deploy/host": "remote-deployment",
        "ssh_remote_deploy/port": "remote-deployment",
        "ssh_remote_deploy/run_script": "remote-deployment",
    },
    "macos": {
        "application/export_angle": "angle-export",
        "codesign/apple_team_id": "macos-signing",
        "codesign/certificate_file": "macos-export-signing",
        "codesign/certificate_password": "macos-export-signing",
        "codesign/codesign": "macos-signing",
        "codesign/custom_options": "macos-signing",
        "codesign/entitlements/additional": "macos-signing",
        "codesign/entitlements/address_book": "macos-signing",
        "codesign/entitlements/allow_dyld_environment_variables": "macos-signing",
        "codesign/entitlements/allow_jit_code_execution": "macos-signing",
        "codesign/entitlements/allow_unsigned_executable_memory": "macos-signing",
        "codesign/entitlements/app_sandbox/device_bluetooth": "macos-signing",
        "codesign/entitlements/app_sandbox/device_usb": "macos-signing",
        "codesign/entitlements/app_sandbox/enabled": "macos-signing",
        "codesign/entitlements/app_sandbox/files_downloads": "macos-signing",
        "codesign/entitlements/app_sandbox/files_movies": "macos-signing",
        "codesign/entitlements/app_sandbox/files_music": "macos-signing",
        "codesign/entitlements/app_sandbox/files_pictures": "macos-signing",
        "codesign/entitlements/app_sandbox/files_user_selected": "macos-signing",
        "codesign/entitlements/app_sandbox/helper_executables": "macos-signing",
        "codesign/entitlements/app_sandbox/network_client": "macos-signing",
        "codesign/entitlements/app_sandbox/network_server": "macos-signing",
        "codesign/entitlements/apple_events": "macos-signing",
        "codesign/entitlements/audio_input": "macos-signing",
        "codesign/entitlements/calendars": "macos-signing",
        "codesign/entitlements/camera": "macos-signing",
        "codesign/entitlements/custom_file": "macos-signing",
        "codesign/entitlements/debugging": "macos-signing",
        "codesign/entitlements/disable_library_validation": "macos-signing",
        "codesign/entitlements/location": "macos-signing",
        "codesign/entitlements/photos_library": "macos-signing",
        "codesign/identity": "macos-signing",
        "codesign/installer_identity": "macos-export-signing",
        "codesign/provisioning_profile": "macos-export-signing",
        "custom_template/debug": "engine",
        "custom_template/release": "engine",
        "debug/export_console_wrapper": "output-layout",
        "export/distribution_type": "xcode-export",
        "notarization/api_key": "notarization",
        "notarization/api_key_id": "notarization",
        "notarization/api_uuid": "notarization",
        "notarization/apple_id_name": "notarization",
        "notarization/apple_id_password": "notarization",
        "notarization/notarization": "notarization",
        "shader_baker/enabled": "shader-baking",
        "ssh_remote_deploy/cleanup_script": "remote-deployment",
        "ssh_remote_deploy/enabled": "remote-deployment",
        "ssh_remote_deploy/extra_args_scp": "remote-deployment",
        "ssh_remote_deploy/extra_args_ssh": "remote-deployment",
        "ssh_remote_deploy/host": "remote-deployment",
        "ssh_remote_deploy/port": "remote-deployment",
        "ssh_remote_deploy/run_script": "remote-deployment",
        "xcode/platform_build": "xcode-export",
        "xcode/sdk_build": "xcode-export",
        "xcode/sdk_name": "xcode-export",
        "xcode/sdk_version": "xcode-export",
        "xcode/xcode_build": "xcode-export",
        "xcode/xcode_version": "xcode-export",
    },
    "android": {
        "custom_template/debug": "engine",
        "custom_template/release": "engine",
        "gradle_build/android_source_template": "gradle",
        "gradle_build/compress_native_libraries": "android-compression",
        "gradle_build/export_format": "android-format",
        "gradle_build/gradle_build_directory": "gradle",
        "gradle_build/use_gradle_build": "gradle",
        "keystore/debug": "android-signing",
        "keystore/debug_password": "android-signing",
        "keystore/debug_user": "android-signing",
        "keystore/release": "android-signing",
        "keystore/release_password": "android-signing",
        "keystore/release_user": "android-signing",
        "package/signed": "android-signing",
        "shader_baker/enabled": "shader-baking",
        "xr_features/xr_mode": "xr",
    },
    "ios": {
        "application/app_store_team_id": "ios-signing",
        "application/code_sign_identity_debug": "ios-signing",
        "application/code_sign_identity_release": "ios-signing",
        "application/delete_old_export_files_unconditionally": "xcode-export",
        "application/export_method_debug": "xcode-export",
        "application/export_method_release": "xcode-export",
        "application/export_project_only": "xcode-export",
        "application/provisioning_profile_specifier_debug": "ios-signing",
        "application/provisioning_profile_specifier_release": "ios-signing",
        "application/provisioning_profile_uuid_debug": "ios-signing",
        "application/provisioning_profile_uuid_release": "ios-signing",
        "application/signature": "ios-signature",
        "custom_template/debug": "engine",
        "custom_template/release": "engine",
        "entitlements/additional": "ios-signing",
        "entitlements/game_center": "ios-signing",
        "entitlements/increased_memory_limit": "ios-signing",
        "entitlements/push_notifications": "ios-signing",
        "modules/camera": "ios-camera-module",
        "shader_baker/enabled": "shader-baking",
        "storyboard/image_scale_mode": "ios-launch-scale",
    },
}

_GODOT_4_7["rejected_export_options"] = _REJECTED_OPTIONS_4_7

# Registered options that Godot's reflection hides and build tools read; the probe
# asks for them by name, as it does for every option a pack authors.
_GODOT_4_7["hidden_export_options"] = {
    "ios": ["capabilities/performance_a12"],
    # Listed only with thread support, but always written into the web page.
    "web": ["threads/emscripten_pool_size", "threads/godot_pool_size"],
}

_GODOT_4_7["option_owners"] = {
    "export_platform": "select a godot_export_platform with --platforms",
    "identity": "godot_app.application_id",
    "macos-deployment": "godot_app.macos_minimum_os_version",
    "ios-deployment": "godot_app.ios_minimum_os_version / ios_families",
    "engine": "the runtime toolchain; register a godot_runtime_component for the slot",
    "android-sdk": "godot_app.android_min_sdk_version / android_target_sdk_version",
    "android-format": "--@autoload_rules_godot//godot:android_format",
    "android-signing": "godot_app.android_debug_key; AAB signing stays external",
    "ios-signing": "godot_app.ios_provisioning_profile / ios_entitlements",
    "macos-signing": "the optional godot_app signing operation",
    "output-layout": "the godot_app target name and Bazel's output layout",
    "android-compression": "rules_android's packaging of JNI libraries",
    "web-extensions": "the extensions of the application's packs: an application with web extensions takes the template that loads them",
}

# ==== Export hooks ============================================================

def _hook(kind, disposition, operating_systems = [], counterpart = None, aliases = []):
    """
    Classify an export hook.

    Args:
        kind: virtual, method or descriptor.
        disposition: pack (Godot's pack export applies it), counterpart (a Bazel
            declaration carries it) or none (no counterpart exists).
        operating_systems: Where the contribution matters; empty for pack.
        counterpart: The kind of Bazel declaration that carries it.
        aliases: Further method names Godot binds to the same method.

    Returns:
        The hook's row, which JSON encodes.
    """
    return {
        "kind": kind,
        "disposition": disposition,
        "operating_systems": operating_systems,
        "counterpart": counterpart,
        "aliases": aliases,
    }

_PACK_HOOK = _hook("virtual", "pack")

# EditorExportPlugin hooks of the minor: its virtuals and the bound methods that add files,
# libraries or native settings to an export, as editor/export/editor_export_plugin.h and
# .cpp declare them, and the legacy plugin descriptors. One row per hook, keyed by its
# canonical name or, for descriptors, the kind of file.
# docs/internal/export-plugin-hook-inventory.md cites their consumers; a pinned source that
# declares other names fails
# //godot/private/engine/tests:pinned_godot_sources_declare_the_reviewed_export_hooks_test.
_EXPORT_HOOKS_4_7 = {
    name: _PACK_HOOK
    for name in [
        "_begin_customize_resources",
        "_begin_customize_scenes",
        "_customize_resource",
        "_customize_scene",
        "_end_customize_resources",
        "_end_customize_scenes",
        "_export_begin",
        "_export_end",
        "_export_file",
        "_get_customization_configuration_hash",
        "_get_export_features",
        "_get_export_option_visibility",
        "_get_export_option_warning",
        "_get_export_options",
        "_get_export_options_overrides",
        "_get_name",
        "_should_update_export_options",
        "_supports_platform",
    ]
} | {
    "add_file": _hook("method", "pack"),
    "skip": _hook("method", "pack"),
    "add_shared_object": _hook("method", "counterpart", ["android", "ios", "linux", "macos"], "extension_library"),
    "_get_android_libraries": _hook("virtual", "counterpart", ["android"], "android_library"),
    "_get_android_dependencies": _hook("virtual", "counterpart", ["android"], "maven_artifact"),
    "_get_android_dependencies_maven_repos": _hook("virtual", "counterpart", ["android"], "maven_repository"),
    "_get_android_manifest_element_contents": _hook("virtual", "counterpart", ["android"], "library_manifest"),
    "_get_android_manifest_application_element_contents": _hook("virtual", "counterpart", ["android"], "library_manifest"),
    "_get_android_manifest_activity_element_contents": _hook("virtual", "counterpart", ["android"], "library_manifest"),
    "_update_android_prebuilt_manifest": _hook("virtual", "none", ["android"]),
    "_end_generate_apple_embedded_project": _hook("virtual", "none", ["ios"]),
    "add_apple_embedded_platform_framework": _hook("method", "counterpart", ["ios"], "apple_framework", ["add_ios_framework"]),
    "add_apple_embedded_platform_embedded_framework": _hook("method", "counterpart", ["ios"], "apple_framework", ["add_ios_embedded_framework"]),
    "add_apple_embedded_platform_project_static_lib": _hook("method", "counterpart", ["ios"], "static_library", ["add_ios_project_static_lib"]),
    "add_apple_embedded_platform_plist_content": _hook("method", "counterpart", ["ios"], "infoplist", ["add_ios_plist_content"]),
    "add_apple_embedded_platform_linker_flags": _hook("method", "counterpart", ["ios"], "linkopts", ["add_ios_linker_flags"]),
    "add_apple_embedded_platform_bundle_file": _hook("method", "counterpart", ["ios"], "bundle_resource", ["add_ios_bundle_file"]),
    "add_apple_embedded_platform_cpp_code": _hook("method", "counterpart", ["ios"], "native_source", ["add_ios_cpp_code"]),
    "add_macos_plugin_file": _hook("method", "none", ["macos"]),
    "gdap": _hook("descriptor", "counterpart", ["android"], "android_library"),
    "gdip": _hook("descriptor", "counterpart", ["ios"], "static_library"),
}

_GODOT_4_7["export_hooks"] = _EXPORT_HOOKS_4_7

# ==== Godot 4.8 ===============================================================

# Live 4.8-beta1 inventory comparison: the retained per-minor tables are unchanged;
# only these three registered options differ from the bounded 4.7.2 inventory.
# Defaults and actual types are still read from the configured editor's probe.
_REJECTED_OPTIONS_4_8 = {operating_system: dict(options) for operating_system, options in _REJECTED_OPTIONS_4_7.items()}

_REJECTED_OPTIONS_4_8["android"]["gradle_build/minification"] = "gradle"

_REJECTED_OPTIONS_4_8["linux"]["debug/export_debug_symbols"] = "native-debug-symbols"

_REJECTED_OPTIONS_4_8["macos"]["debug/export_debug_symbols"] = "native-debug-symbols"

_GODOT_4_8 = dict(_GODOT_4_7)

_GODOT_4_8["rejected_export_options"] = _REJECTED_OPTIONS_4_8

# Godot 4.8 moves the template activity into the template's data library, whose
# manifest adds font configuration changes.
_GODOT_4_8["android"] = _GODOT_4_7["android"] | {
    "template_activity": {
        "path": "android/godot_4_8/GodotApp.java",
        "upstream": "java/app/dataLib/src/main/java/com/godot/game/GodotApp.java",
        "build_config": False,
    },
    "config_changes": _GODOT_4_7["android"]["config_changes"] + [
        "fontScale",
        "fontWeightAdjustment",
    ],
}

_GODOT_4_8["option_owners"] = _GODOT_4_7["option_owners"] | {
    "native-debug-symbols": "native toolchain symbol/strip settings and the app's debug_symbols output group",
}

# Godot 4.8 adds Swift package references to the Xcode project of its iOS export.
_GODOT_4_8["export_hooks"] = _EXPORT_HOOKS_4_7 | {
    "add_apple_embedded_platform_spm_package": _hook("method", "counterpart", ["ios"], "swift_package"),
}

# ==== Android shell ===========================================================

# Godot's Android shell library, a Java/Kotlin library
# (platform/android/java/lib/build.gradle and app/config.gradle). The Maven coordinates
# are rules_godot's contribution to the shared maven repository in MODULE.bazel; their
# labels are the shell library's direct dependencies.
_ANDROID_SHELL = {
    "library": "platform/android/java/lib",
    "package": "org.godotengine.godot",
    "min_sdk": 24,
    "java_level": "17",
    # The manifest placeholder Gradle fills with the library version name.
    "version_placeholder": "${godotLibraryVersion}",
    "deps": [
        "@maven//:androidx_annotation_annotation_jvm",
        "@maven//:androidx_documentfile_documentfile",
        "@maven//:androidx_fragment_fragment",
        "@maven//:org_jetbrains_annotations",
        "@maven//:org_jetbrains_kotlin_kotlin_stdlib",
    ],
    # Godot's Maven graph, the minimums of the shell library's and the template activity's
    # Maven dependencies; a file of //godot/private/engine:android_maven_graphs.
    "maven_graph": "android/maven_graph_install.json",
}

_GODOT_4_7["android_shell"] = _ANDROID_SHELL

_GODOT_4_8["android_shell"] = _ANDROID_SHELL

# Every supported minor shares one shell library; godot_android_runtime's shell AAR names
# no version.
ANDROID_SHELL_DEPS = _ANDROID_SHELL["deps"]

# ==== Runtime profile =========================================================

# What godot_runtime_profile keeps in a profile it derives from Godot's detection.
_RUNTIME_PROFILE = {
    # Classes the engine instantiates itself, or that scripts and importers reach by name,
    # whichever the project's files name. Godot's detection reads files, so it lists them
    # for a project that never names them, and a runtime without them stops at start.
    "keep_classes": [
        "CryptoKey",
        "DPITexture",
        "GLTFDocumentExtension",
        "Gradient",
        "GradientTexture2D",
        "Image",
        "ImageTexture",
        "Script",
        "Shader",
        "ViewportTexture",
        "World2D",
        "World3D",
        "X509Certificate",
    ],
}

_GODOT_4_7["runtime_profile"] = _RUNTIME_PROFILE

_GODOT_4_8["runtime_profile"] = _RUNTIME_PROFILE

# ==== Build profile ===========================================================

# How a source recipe reads a build profile's disabled_build_options for its version.
_GODOT_4_7["build_profile"] = {
    # The 4.7 editor writes these renderer switches, which no 4.7 SCons option reads
    # (editor/settings/editor_build_profile.cpp: "There's no scons option to disable
    # rendering device"); 4.8 adds them as options. A recipe leaves them out.
    "editor_only_options": ["forward_mobile_renderer", "forward_plus_renderer", "rendering_device"],
    "implied_options": [{
        # Temporary exception: in 4.7.0 to 4.7.2, gridmap does not compile with
        # disable_physics_3d (modules/gridmap/grid_map.cpp), which Godot's 4.7 branch fixes
        # after 4.7.2 (godotengine/godot#122593). Remove it once the catalogue's 4.7
        # release contains the fix.
        "versions": ["4.7.0", "4.7.1", "4.7.2"],
        "option": "disable_physics_3d",
        "implies": {"module_gridmap_enabled": False},
    }],
}

_GODOT_4_8["build_profile"] = {
    "editor_only_options": [],
    "implied_options": [],
}

# ==== Profile lookup ==========================================================

_PROFILES = {
    "4.7": _GODOT_4_7,
    "4.8": _GODOT_4_8,
}

def engine_profile(version):
    """
    Return the profile of Godot's exporters for an engine version.

    Args:
        version: Canonical engine version, such as 4.7.2, 4.8.0-beta1 or a source's 4.7.3-rc.

    Returns:
        A dict of the exporters' tables and constants, which JSON encodes.
    """

    # Source-built editors may name an unnumbered prerelease, such as 4.7.3-rc.
    require_supported_source_version(version)
    series = godot_series(version)
    if series not in _PROFILES:
        fail("rules_godot has no engine profile for Godot %s" % series)
    return _PROFILES[series]
