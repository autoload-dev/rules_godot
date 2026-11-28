"""
Build an application under an export platform and build settings of its own, instead of a
`--config`: the implementation of `godot_configured_app`, `ANDROID_RELEASE` and
`APPLE_RELEASE`, which `godot:app.bzl` exports. The platform tests extend the same
transition (`configured_settings`).
"""

load("@rules_android//providers:providers.bzl", "AndroidBundleInfo", "ApkInfo")
load("@rules_apple//apple:providers.bzl", "AppleBundleInfo")
load("//godot/private:macros.bzl", "VOLATILE_API")
load("//godot/private/config:native.bzl", "PLATFORMS", "STRIP")
load("//godot/private/config:settings.bzl", "VARIANT")

visibility([
    "//godot",
    "//godot/platforms/private/tests/...",
])

_COMPILATION_MODE = "//command_line_option:compilation_mode"
_COPT = "//command_line_option:copt"
_DSYM = "//command_line_option:apple_generate_dsym"
_OBJCSTRIP = "//command_line_option:objc_enable_binary_stripping"
_ANDROID_FORMAT = str(Label("//godot:android_format"))
_MACOS_SIGNING = str(Label("//godot:macos_signing"))

# The settings the transition reads and writes.
CONFIGURED_SETTINGS = [
    PLATFORMS,
    _COMPILATION_MODE,
    STRIP,
    _COPT,
    _DSYM,
    _OBJCSTRIP,
    _ANDROID_FORMAT,
    _MACOS_SIGNING,
    VARIANT,
]

# The attributes that replace a setting when they are set, by attribute name.
_REPLACED = {
    "compilation_mode": _COMPILATION_MODE,
    "strip": STRIP,
    "apple_generate_dsym": _DSYM,
    "objc_enable_binary_stripping": _OBJCSTRIP,
    "android_format": _ANDROID_FORMAT,
    "macos_signing": _MACOS_SIGNING,
    "variant": VARIANT,
}

def configured_settings(settings, attr):
    """
    The settings of CONFIGURED_SETTINGS under the attributes of CONFIGURED_ATTRS.

    Args:
        settings: the incoming settings, at least those of CONFIGURED_SETTINGS.
        attr: the attributes of the rule whose transition this is.

    Returns:
        The outgoing value of each setting of CONFIGURED_SETTINGS.
    """
    result = {setting: settings[setting] for setting in CONFIGURED_SETTINGS}
    if attr.platform:
        result[PLATFORMS] = [str(attr.platform)]
    if attr.copts:
        result[_COPT] = list(settings[_COPT]) + attr.copts
    for name, setting in _REPLACED.items():
        value = getattr(attr, name)
        if value:
            result[setting] = value
    return result

# The attributes of the configuration; an unset one keeps the build's own setting.
CONFIGURED_ATTRS = {
    "platform": attr.label(
        doc = """
        The export platform or platform slice, such as `//examples:android_distribution`; the
        build's own target platform by default.
        """,
    ),
    "compilation_mode": attr.string(
        doc = "C++ optimization, `--compilation_mode`, such as `opt` for a release build.",
        values = ["", "fastbuild", "dbg", "opt"],
    ),
    "strip": attr.string(
        doc = """
        `--strip`: whether linking strips the libraries, such as `always` for release
        libraries whose debug symbols ship apart.
        """,
        values = ["", "always", "sometimes", "never"],
    ),
    "copts": attr.string_list(
        doc = "C++ options appended to `--copt`, such as `-g` for debug symbols of an optimized build.",
    ),
    "apple_generate_dsym": attr.bool(
        doc = "`--apple_generate_dsym`: Apple applications get their debug symbols as `.dSYM` directories.",
    ),
    "objc_enable_binary_stripping": attr.bool(
        doc = "`--objc_enable_binary_stripping`: Apple binaries are stripped of their debug symbols.",
    ),
    "android_format": attr.string(
        doc = "The Android delivery format, `//godot:android_format`: `apk` or `aab`.",
        values = ["", "apk", "aab"],
    ),
    "macos_signing": attr.string(
        doc = "How macOS applications are signed, `//godot:macos_signing`, such as `adhoc`.",
        values = ["", "unsigned", "adhoc"],
    ),
    "variant": attr.string(
        doc = "The `//godot:variant` setting: which of Godot's binaries the build is for.",
        values = ["", "debug", "editor", "release"],
    ),
}

# The native settings of a release build whose debug symbols ship apart.
ANDROID_RELEASE = {
    "compilation_mode": "opt",
    # Do not encode a changing sandbox directory in DWARF.
    "copts": [
        "-g",
        "-fdebug-compilation-dir=.",
    ],
    "strip": "always",
}

APPLE_RELEASE = {
    # Match the stripped application to its retained DWARF by executable/dSYM UUID.
    "apple_generate_dsym": True,
    "compilation_mode": "opt",
    "objc_enable_binary_stripping": True,
}

# Providers of applications that inspection rules, such as android_bundle_test, read.
_FORWARDED = [AndroidBundleInfo, ApkInfo, AppleBundleInfo, OutputGroupInfo]

def forwarded_providers(target):
    """
    The application providers of a target, which inspection rules read.

    Args:
        target: the configured target.

    Returns:
        A list of providers.
    """
    return [target[provider] for provider in _FORWARDED if provider in target]

def configured_providers(ctx):
    """
    The default outputs and application providers of the target a rule's `target` carries.

    Args:
        ctx: the context of the rule.

    Returns:
        A list of providers.
    """
    target = ctx.attr.target[0]
    files = target[DefaultInfo].files
    providers = [DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files))]
    return providers + forwarded_providers(target)

_configured = transition(
    implementation = configured_settings,
    inputs = CONFIGURED_SETTINGS,
    outputs = CONFIGURED_SETTINGS,
)

_configured_target = rule(
    doc = "The default outputs and application providers of a target built under an export platform and build settings of its own.",
    implementation = configured_providers,
    attrs = CONFIGURED_ATTRS | {
        "target": attr.label(doc = "The target to build.", mandatory = True, cfg = _configured),
    },
)

def _configured_launcher_impl(ctx):
    target = ctx.attr.target[0]
    launcher = target[DefaultInfo].files_to_run.executable
    if not launcher:
        fail("%s: %s has no launcher to run" % (ctx.label, target.label))
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = executable, target_file = launcher, is_executable = True)
    return [DefaultInfo(executable = executable, runfiles = target[DefaultInfo].default_runfiles)]

_configured_launcher = rule(
    doc = "The `bazel run` launcher of an application built under an export platform and build settings of its own.",
    implementation = _configured_launcher_impl,
    executable = True,
    attrs = CONFIGURED_ATTRS | {
        "target": attr.label(doc = "The application.", mandatory = True, cfg = _configured),
    },
)

def _configured_app_impl(name, visibility, app, debug_symbols, **kwargs):
    _configured_target(name = name, visibility = visibility, target = app, **kwargs)
    _configured_launcher(name = name + ".launcher", visibility = visibility, target = app, **kwargs)
    _configured_target(
        name = name + ".debug_symbols",
        visibility = visibility,
        target = debug_symbols,
        **kwargs
    )

godot_configured_app = macro(
    doc = """
    Build a godot_app and its debug symbols under an export platform and build settings of
    their own, instead of a `--config`.

    A configured application lets one `bazel build` or `bazel test` invocation build a
    mobile or release application beside the desktop targets. The macro declares `<name>`,
    the application, `<name>.debug_symbols`, its debug symbols, and `<name>.launcher`, what
    `bazel run` of the application runs, all under the same configuration; a test may run
    the launcher, as the web smoke test does with --headless. They carry the application's default outputs and its providers, such as
    rules_android's AndroidBundleInfo and ApkInfo and rules_apple's AppleBundleInfo. An
    attribute that is unset keeps the build's own setting. ANDROID_RELEASE and
    APPLE_RELEASE, from the same module, hold the native settings of a release whose debug
    symbols ship apart; pass them with `**`. See
    [release builds](../../platforms.md#release-builds-in-one-invocation).

    Example:
    ```starlark
    load("@autoload_rules_godot//godot:app.bzl", "ANDROID_RELEASE", "godot_configured_app")

    godot_configured_app(
        name = "android_release",
        app = ":app",
        debug_symbols = ":app.debug_symbols",
        platform = "@autoload_rules_godot//godot/platforms:android_arm64",
        android_format = "aab",
        tags = ["manual"],
        **ANDROID_RELEASE
    )
    ```
    """ + VOLATILE_API,
    implementation = _configured_app_impl,
    inherit_attrs = _configured_target,
    attrs = {
        "target": None,
        "app": attr.label(doc = "The godot_app to build.", mandatory = True),
        "debug_symbols": attr.label(
            doc = """
            The godot_app's debug symbols, `<app>.debug_symbols`. The caller names it: a
            macro may only use the labels its caller passes of targets that godot_app exports
            to its caller's package alone.
            """,
            mandatory = True,
        ),
    },
)
