"""Public symbolic app analysis contracts; synthetic engines are never executed."""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("//godot:app.bzl", "godot_app")
load("//godot:providers.bzl", "GodotDesktopAppInfo")
load("//godot/extension:defs.bzl", "godot_extension")
load("//godot/private:providers.bzl", "GodotRuntimeInfo")
load("//godot/private/config:settings.bzl", "CPUS", "ENVIRONMENT", "EXPORT_PLATFORM", "OPERATING_SYSTEM", "PLATFORM_SLICES")
load("//godot/private/tests:toolchains.bzl", "own_toolchains")

visibility("private")

def _runtime_impl(ctx):
    executable = ctx.actions.declare_file(ctx.label.name + ".runtime")
    ctx.actions.write(executable, "analysis-only engine fixture", is_executable = True)
    return [
        DefaultInfo(files = depset([executable])),
        # iOS applications link the runtime; an empty CcInfo stands in for it.
        CcInfo(),
        GodotRuntimeInfo(
            executable = executable,
            files = depset([executable]),
            platform = ctx.attr.platform,
            cpu = "arm64",
            environment = ctx.attr.environment,
            facts_source = "declared",
            origin = str(ctx.label),
            version = "4.7.2",
            variant = ctx.attr.variant,
            bundle_files = {},
            debug_symbols = None,
            minimum_os = ctx.attr.minimum_os,
        ),
    ]

runtime_fixture = rule(
    implementation = _runtime_impl,
    attrs = {
        "platform": attr.string(),
        "environment": attr.string(doc = "device or simulator for an iOS runtime."),
        "variant": attr.string(default = "release"),
        "minimum_os": attr.string(doc = "The deployment target the runtime declares, as a source recipe does."),
    },
)

_SMALL = {"size": "small"}

# The checks that need a macOS host, for its runtime slots or its Apple aspects.
_MACOS_HOST = _SMALL | {"target_compatible_with": ["@platforms//os:macos"]}

_DEBUG_SIMULATOR = {
    "//command_line_option:platforms": str(Label("//godot/platforms:ios_sim_arm64")),
    str(Label("//godot:variant")): "debug",
}

# Runtimes that declare Godot's deployment targets, as source recipes do.
_FLOOR_ENGINES = own_toolchains(["//godot/private/config/tests/engines/floor:all"])

def _expect_failure(env, target, message):
    env.expect.that_target(target).failures().contains_predicate(matching.contains(message))

def _analyzes(env, target):
    """The target under test analyzes; the test asserts nothing else."""
    _ = (env, target)  # @unused

def _test_desktop_app_exposes_archive_launcher_and_runtime_component(name):
    analysis_test(
        name = name,
        target = ":app",
        impl = _desktop_app_exposes_archive_launcher_and_runtime_component,
        attr_values = _SMALL,
    )

def _desktop_app_exposes_archive_launcher_and_runtime_component(env, app):
    env.expect.that_bool(
        GodotDesktopAppInfo in app,
        expr = "Public app must retain the providers of the selected application backend",
    ).equals(True)
    if GodotDesktopAppInfo in app:
        desktop_app = app[GodotDesktopAppInfo]
        expected = "app.zip" if desktop_app.operating_system == "macos" else "app.tar.gz"
        env.expect.that_str(desktop_app.archive.basename).equals(expected)
        env.expect.that_str(app[DefaultInfo].files_to_run.executable.basename).equals("app.run")

        # The app names the runtime component it packages, for diagnostics.
        env.expect.that_bool(
            desktop_app.runtime_component != None,
            expr = "the app must name its runtime component",
        ).equals(True)
        if desktop_app.runtime_component:
            env.expect.that_str(desktop_app.runtime_component.role).equals("runtime")
            env.expect.that_str(desktop_app.runtime_component.platform).equals(desktop_app.operating_system)

def _test_simulator_app_links_runtime_component_of_its_platform_slice(name):
    """An app links the iOS runtime component its simulator platform slice resolves through the runtime bridge."""
    godot_app(
        name = name + "_app",
        application_id = "org.example.runtimebridge",
        pack = ":app_pack",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        target = name + "_app",
        impl = _analyzes,
        config_settings = _DEBUG_SIMULATOR | own_toolchains(["//godot/private/config/tests/engines:all"]),
        attr_values = _MACOS_HOST,
    )

# Minimum operating-system versions: an application's minimum may not fall below the
# deployment target its runtime was built for, nor below what an extension requires. The
# runtime slots come from engines/floor.

def _floor_app_test(name, impl, expect_failure, config_settings = _FLOOR_ENGINES, **app_attributes):
    """Analyze an app with the attributes on the runtime slots of engines/floor."""
    godot_app(
        name = name + "_app",
        tags = ["manual"],
        **app_attributes
    )
    analysis_test(
        name = name,
        target = name + "_app",
        impl = impl,
        expect_failure = expect_failure,
        config_settings = config_settings,
        attr_values = _MACOS_HOST,
    )

def _test_macos_minimum_below_runtime_deployment_target_fails(name):
    _floor_app_test(
        name,
        _macos_minimum_below_runtime_deployment_target_fails,
        expect_failure = True,
        macos_minimum_os_version = "10.15",
        pack = ":app_pack",
    )

def _macos_minimum_below_runtime_deployment_target_fails(env, target):
    _expect_failure(env, target, "macos_minimum_os_version 10.15 is below the deployment target 11.0 of the runtime")

def _test_ios_minimum_below_runtime_deployment_target_fails(name):
    _floor_app_test(
        name,
        _ios_minimum_below_runtime_deployment_target_fails,
        expect_failure = True,
        config_settings = _DEBUG_SIMULATOR | _FLOOR_ENGINES,
        application_id = "org.example.floor",
        ios_minimum_os_version = "11.0",
        pack = ":app_pack",
    )

def _ios_minimum_below_runtime_deployment_target_fails(env, target):
    _expect_failure(env, target, "ios_minimum_os_version 11.0 is below the deployment target 12.0 of the runtime")

def _test_macos_minimum_below_extension_requirement_fails(name):
    _floor_app_test(
        name,
        _macos_minimum_below_extension_requirement_fails,
        expect_failure = True,
        pack = ":demanding_pack",
    )

def _macos_minimum_below_extension_requirement_fails(env, target):
    _expect_failure(env, target, "extension demanding_init requires macOS 13.0; macos_minimum_os_version is 11.0")

def _test_macos_minimum_meeting_extension_requirement_analyzes(name):
    _floor_app_test(
        name,
        _analyzes,
        expect_failure = False,
        macos_minimum_os_version = "13.0",
        pack = ":demanding_pack",
    )

# An extension without a library for the application's platform: by default the
# application fails and names it; with report it builds and lists it.

_MISSING = str(Label("//godot:missing_extension_libraries"))

def _test_missing_extension_library_fails(name):
    _floor_app_test(
        name,
        _missing_extension_library_fails,
        expect_failure = True,
        pack = ":linux_only_pack",
    )

def _missing_extension_library_fails(env, target):
    _expect_failure(env, target, "_app: no extension library for ")
    _expect_failure(env, target, "//godot/private/config/tests:linux_only_extension")
    _expect_failure(env, target, "--@autoload_rules_godot//godot:missing_extension_libraries=report")

def _test_missing_extension_library_reported(name):
    _floor_app_test(
        name,
        _missing_extension_library_reported,
        expect_failure = False,
        missing_extension_libraries = "report",
        pack = ":linux_only_pack",
    )

def _missing_extension_library_reported(env, target):
    # The public label resolves to the backend, whose name extends the application's.
    reports = target[OutputGroupInfo].missing_extension_libraries.to_list()
    env.expect.that_collection([report.basename for report in reports]).contains_exactly([
        env.ctx.label.name + "_app.missing_extension_libraries.txt",
    ])

def _test_flag_overrides_missing_extension_libraries(name):
    _floor_app_test(
        name + "_report",
        _missing_extension_library_reported,
        expect_failure = False,
        config_settings = _FLOOR_ENGINES | {_MISSING: "report"},
        pack = ":linux_only_pack",
    )
    _floor_app_test(
        name + "_error",
        _missing_extension_library_fails,
        expect_failure = True,
        config_settings = _FLOOR_ENGINES | {_MISSING: "error"},
        missing_extension_libraries = "report",
        pack = ":linux_only_pack",
    )
    native.test_suite(name = name, tests = [name + "_report", name + "_error"])

def _test_extension_rejects_unknown_minimum_os_key(name):
    godot_extension(
        name = name + "_extension",
        entry_symbol = "unknown_init",
        library = select({
            # A macOS-only library; the editor loads none.
            "//godot:tool": None,
            "//conditions:default": ":demanding_library",
        }),
        minimum_os_versions = {"windows": "10"},
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _extension_rejects_unknown_minimum_os_key,
        expect_failure = True,
        attr_values = _SMALL,
    )

def _extension_rejects_unknown_minimum_os_key(env, target):
    _expect_failure(env, target, "minimum_os_versions keys must be macos or ios")

def _test_desktop_app_rejects_platform_deps_and_resources(name):
    """Desktop rejects selected platform libraries and platform resources instead of dropping them."""
    godot_app(
        name = name + "_app",
        pack = ":app_pack",
        platform_deps = select({"//conditions:default": [":composition_private_library"]}),
        platform_resources = select({"//conditions:default": [":composition_private_resource"]}),
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        target = name + "_app",
        impl = _desktop_app_rejects_platform_deps_and_resources,
        expect_failure = True,
        attr_values = _SMALL,
    )

def _desktop_app_rejects_platform_deps_and_resources(env, target):
    _expect_failure(env, target, "does not support nonempty platform_deps or platform_resources")

def _test_desktop_app_name_with_separator_fails(name):
    """The application's filename comes from the godot_app's name, which may hold a slash."""
    godot_app(
        name = name + "_dir/app",
        pack = ":app_pack",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        target = name + "_dir/app",
        impl = _desktop_app_name_with_separator_fails,
        expect_failure = True,
        attr_values = _SMALL,
    )

def _desktop_app_name_with_separator_fails(env, target):
    _expect_failure(env, target, "app_name must be a filename without separators")

def _fails_with_message(env, target):
    _expect_failure(env, target, env.ctx.attr.message)

# A platform that is no export platform leaves the settings of the build's own target
# platform in place, such as Linux's under --config=buildbuddy-linux; this resets them.
_NO_EXPORT_PLATFORM = {
    setting: ""
    for setting in [OPERATING_SYSTEM, ENVIRONMENT, CPUS, EXPORT_PLATFORM, PLATFORM_SLICES]
}

# A target platform that no export platform declared reaches the application's invalid
# context, which names what the platform lacks.
def _invalid_context_test(name, constraint_values, message):
    native.platform(name = name + "_platform", constraint_values = constraint_values)
    godot_app(
        name = name + "_app",
        application_id = "org.example.invalidcontext",
        pack = ":app_pack",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        target = name + "_app",
        impl = _fails_with_message,
        expect_failure = True,
        attrs = {"message": attr.string()},
        config_settings = _NO_EXPORT_PLATFORM | {"//command_line_option:platforms": str(native.package_relative_label(name + "_platform"))},
        attr_values = _SMALL | {"message": message},
    )

def _test_mobile_platform_without_export_platform_fails(name):
    _invalid_context_test(
        name,
        ["@platforms//os:android", "@platforms//cpu:aarch64"],
        "Select an export platform for the mobile operating system android",
    )

def _test_desktop_platform_with_unsupported_cpu_fails(name):
    _invalid_context_test(
        name,
        ["@platforms//os:linux", "@platforms//cpu:s390x"],
        "Unsupported CPU for operating system linux at",
    )

def app_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_desktop_app_exposes_archive_launcher_and_runtime_component,
            _test_simulator_app_links_runtime_component_of_its_platform_slice,
            _test_macos_minimum_below_runtime_deployment_target_fails,
            _test_ios_minimum_below_runtime_deployment_target_fails,
            _test_macos_minimum_below_extension_requirement_fails,
            _test_macos_minimum_meeting_extension_requirement_analyzes,
            _test_extension_rejects_unknown_minimum_os_key,
            _test_desktop_app_rejects_platform_deps_and_resources,
            _test_desktop_app_name_with_separator_fails,
            _test_mobile_platform_without_export_platform_fails,
            _test_desktop_platform_with_unsupported_cpu_fails,
            _test_missing_extension_library_fails,
            _test_missing_extension_library_reported,
            _test_flag_overrides_missing_extension_libraries,
        ],
    )
