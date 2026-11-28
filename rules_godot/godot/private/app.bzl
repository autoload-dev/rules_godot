"""
godot_app: the application of the selected export platform, and the backends it forwards to.

godot_app declares the application pack, one backend per export platform and variant, and
public targets that select the backend of the build's platform and variant.
"""

load("//godot/engine/private:components.bzl", _resolved_runtime = "resolved_runtime")
load("//godot/engine/private:optimization.bzl", "LTO_VALUES", "OPTIMIZE_VALUES", "VFE_VALUES")
load(
    "//godot/platforms/private:android.bzl",
    _godot_android_application = "godot_android_application",
)
load(
    "//godot/platforms/private:desktop.bzl",
    _godot_linux_application = "godot_linux_application",
    _godot_macos_application = "godot_macos_application",
)
load("//godot/platforms/private:ios.bzl", _godot_ios_application = "godot_ios_application")
load("//godot/platforms/private:macos_signing.bzl", _godot_macos_sign = "godot_macos_sign")
load("//godot/platforms/private:web.bzl", _godot_web_application = "godot_web_application")
load("//godot/private:run.bzl", _godot_source_application = "godot_source_application")
load("//godot/private:versions.bzl", "IOS_MINIMUM_OS", "MACOS_MINIMUM_OS")
load(
    "//godot/private/config:application.bzl",
    _application_id = "application_id",
    _application_pack = "application_pack",
    _loadable_pack = "loadable_pack",
)
load(
    "//godot/private/config:settings.bzl",
    _DISPATCH_CONDITIONS = "DISPATCH_CONDITIONS",
    _configured_context = "configured_context",
    _context_attrs = "context_attrs",
)

visibility("//godot")

_LINUX = Label("//godot/platforms:is_linux")
_MACOS = Label("//godot/platforms:is_macos")
_ANDROID = Label("//godot/platforms:is_android")
_IOS_DEVICE = Label("//godot/platforms:is_ios_device")
_IOS_SIMULATOR = Label("//godot/platforms:is_ios_simulator")
_WEB = Label("//godot/platforms:is_web")

_DISPATCH = {
    Label("//godot/private/config:" + name): condition.operating_system
    for name, condition in _DISPATCH_CONDITIONS.items()
}

def _backend(name, backend):
    """
    Return the label of an application backend of godot_app.

    Android and iOS application backends nest the application name, which names their
    outputs. Basename exception: keep exactly <name>.<backend>/<name> until
    rules_android and rules_apple can name outputs explicitly while preserving the
    artifact basename and the backend providers.
    """
    if backend in ["ios", "android_apk", "android_aab"]:
        return ":%s.%s/%s" % (name, backend, name)
    return ":%s.%s" % (name, backend)

def _symbols(name, backend):
    """Return the label of an application backend's debug symbols."""
    return _backend(name, backend) + ".debug_symbols"

def _by_variant(name, suffix, template, hidden):
    """
    Return what godot_app's public label forwards to, by variant and then by platform.

    The variant decides first, so the editor variant needs no condition per export
    platform; the alias keeps each select() unambiguous.

    Args:
        name: Name of the godot_app.
        suffix: "" for the application, ".debug_symbols" for its debug symbols.
        template: The select() over the export platform's backends.
        hidden: Attributes of the private alias.

    Returns:
        The select() for the public alias.
    """
    native.alias(name = name + ".template" + suffix, actual = template, **hidden)
    return select({
        Label("//godot:editor"): ":" + name + ".editor" + suffix,
        "//conditions:default": ":" + name + ".template" + suffix,
    })

def _invalid_impl(ctx):
    _configured_context(ctx)
    fail("Invalid or unsupported export platform at %s" % ctx.label)

_invalid_context = rule(implementation = _invalid_impl, attrs = _context_attrs())

def _hidden(tags, testonly):
    """
    The attributes of a godot_app's private targets.

    Typed aliases retain caller-private labels even when they are selectors. Helper target
    names are implementation identities; physical output names use name.
    """
    return dict(tags = tags + ["manual"], testonly = testonly)

def _hidden_of(common):
    """The attributes of a godot_app's private targets among those of its backends."""
    return {key: common[key] for key in ["tags", "testonly"]}

def _application_packs(name, pack, loadable_packs, hidden, **context):
    """
    Declare the application pack that every backend of a godot_app uses.

    Args:
        name: Name of the godot_app.
        pack: The start pack.
        loadable_packs: The packs the application may load later.
        hidden: Attributes of private targets.
        **context: The application context's values, which are application_pack's attributes.
    """
    native.alias(name = name + ".pack_input", actual = pack, **hidden)
    loadable = []
    for index, loadable_pack in enumerate(loadable_packs or []):
        _loadable_pack(name = "%s.loadable_pack_input_%d" % (name, index), deps = [loadable_pack], **hidden)
        loadable.append(":%s.loadable_pack_input_%d" % (name, index))
    _application_pack(
        name = name + ".pack",
        deps = [":" + name + ".pack_input"] + loadable,
        **(context | hidden)
    )

def _desktop_backends(
        name,
        application_id,
        macos_minimum_os_version,
        macos_signing_identity,
        macos_entitlements,
        platform_deps,
        platform_resources,
        common):
    """
    Declare the Linux and macOS backends of a godot_app and the macOS signing choice.

    Args:
        name: Name of the godot_app.
        application_id: The macOS bundle identifier.
        macos_minimum_os_version: The application's minimum macOS version.
        macos_signing_identity: The signer's identity.
        macos_entitlements: The signer's entitlements.
        platform_deps: The application's platform libraries.
        platform_resources: The application's platform resources.
        common: Attributes of every backend, the private targets' among them.
    """
    _godot_linux_application(
        name = name + ".linux",
        app_name = name,
        pack = ":" + name + ".pack",
        runtime = ":" + name + ".runtime",
        platform_deps = platform_deps,
        platform_resources = platform_resources,
        **common
    )
    _godot_macos_application(
        name = name + ".macos",
        app_name = name,
        bundle_id = application_id,
        minimum_os_version = macos_minimum_os_version,
        pack = ":" + name + ".pack",
        runtime = ":" + name + ".runtime",
        platform_deps = platform_deps,
        platform_resources = platform_resources,
        **common
    )
    _godot_macos_sign(
        name = name + ".macos_signed",
        app = ":" + name + ".macos",
        identity = macos_signing_identity,
        entitlements = macos_entitlements,
        **common
    )
    native.alias(
        name = name + ".macos_result",
        actual = select({
            Label("//godot:macos_signing_unsigned"): ":" + name + ".macos",
            # The flag rejects values other than adhoc and certificate.
            "//conditions:default": ":" + name + ".macos_signed",
        }),
        **_hidden_of(common)
    )

def _android_backends(
        name,
        application_id,
        manifest_values,
        manifest,
        debug_key,
        platform_deps,
        platform_resources,
        common):
    """
    Declare the APK and App Bundle backends of a godot_app and the format choice.

    The application ID reaches them as the make variable of an application_id target,
    which carries only the ID: a select() cannot sit inside the manifest_values
    dictionary, and reading the pack for it would analyze the pack's native code in the
    backends' own configurations.

    Args:
        name: Name of the godot_app.
        application_id: The Android application ID.
        manifest_values: The application's manifest placeholder values.
        manifest: The application's own manifest, or None.
        debug_key: The application's debug signing key, or None.
        platform_deps: The application's platform libraries.
        platform_resources: The application's resource files.
        common: Attributes of every backend, the private targets' among them, and the
            application's engine settings.
    """
    hidden = _hidden_of(common)
    _application_id(name = name + ".application_id", application_id = application_id, **hidden)
    for format, bundle in [("apk", False), ("aab", True)]:
        _godot_android_application(
            name = name + ".android_" + format + "/" + name,
            pack = ":" + name + ".pack",
            application_id = "$(GODOT_APPLICATION_ID)",
            toolchains = [":" + name + ".application_id"],
            manifest_values = manifest_values,
            manifest = manifest,
            debug_key = debug_key,
            deps = platform_deps,
            resource_files = platform_resources,
            bundle = bundle,
            **common
        )
    native.alias(
        name = name + ".android",
        actual = select({
            Label("//godot:android_aab"): _backend(name, "android_aab"),
            "//conditions:default": _backend(name, "android_apk"),
        }),
        **hidden
    )

def _editor_backend(name, common, engine):
    """
    Declare the editor variant's backend of a godot_app and its empty debug symbols.

    Args:
        name: Name of the godot_app.
        common: Attributes of every backend, the private targets' among them.
        engine: The application's engine name, whose editor runs the project.
    """

    # The editor variant runs the start pack's project from sources: no export, runtime
    # or shell; its extensions build for the target platform. Elsewhere than on Linux and
    # macOS the backend is incompatible, and so is the application forwarding to it.
    editor_compatible = select({
        _LINUX: [],
        _MACOS: [],
        "//conditions:default": [Label("//godot:editor_variant_needs_linux_or_macos")],
    })
    _godot_source_application(
        name = name + ".editor",
        view = ":" + name + ".pack_input",
        headless = False,
        # A game's errors show in its log; its exit status stays Godot's.
        engine_errors = "report",
        target_compatible_with = editor_compatible,
        engine = engine,
        **common
    )
    native.filegroup(
        name = name + ".editor.debug_symbols",
        target_compatible_with = editor_compatible,
        **_hidden_of(common)
    )

def _backend_debug_symbols(name, hidden):
    """
    Declare the debug symbols of the desktop and Android backends of a godot_app.

    Args:
        name: Name of the godot_app.
        hidden: Attributes of private targets.
    """
    for backend in ["linux", "macos", "web"]:
        native.filegroup(
            name = name + "." + backend + ".debug_symbols",
            srcs = [_backend(name, backend)],
            output_group = "debug_symbols",
            **hidden
        )
    native.alias(
        name = name + ".android.debug_symbols",
        actual = select({
            Label("//godot:android_aab"): _backend(name, "android_aab") + ".debug_symbols",
            "//conditions:default": _backend(name, "android_apk") + ".debug_symbols",
        }),
        **hidden
    )

def _public_targets(name, visibility, target_compatible_with, deprecation, tags, testonly):
    """
    Declare godot_app's public application and debug symbols, which forward to the selected backend.

    Args:
        name: Name of the godot_app.
        visibility: Visibility of the public targets.
        target_compatible_with: The godot_app's own compatibility.
        deprecation: The godot_app's deprecation message, or empty.
        tags: The godot_app's tags.
        testonly: The godot_app's testonly.
    """
    hidden = _hidden(tags, testonly)
    _invalid_context(name = name + ".invalid_context", **hidden)
    invalid = ":" + name + ".invalid_context"
    _backend_debug_symbols(name = name, hidden = hidden)
    compatible = target_compatible_with + select({
        _LINUX: [],
        _MACOS: [],
        _ANDROID: [],
        _IOS_DEVICE: [],
        _IOS_SIMULATOR: [],
        _WEB: [],
        "//conditions:default": [Label("@platforms//:incompatible")],
    })
    native.alias(
        name = name + ".debug_symbols",
        actual = _by_variant(name, ".debug_symbols", select({
            condition: _symbols(name, backend)
            for condition, backend in _DISPATCH.items()
        } | {"//conditions:default": invalid}), hidden),
        target_compatible_with = compatible,
        visibility = visibility,
        tags = tags + ["manual"],
        testonly = testonly,
    )
    native.alias(
        name = name,
        actual = _by_variant(name, "", select({
            condition: ":" + name + ".macos_result" if backend == "macos" else _backend(name, backend)
            for condition, backend in _DISPATCH.items()
        } | {"//conditions:default": invalid}), hidden),
        target_compatible_with = compatible,
        visibility = visibility,
        tags = tags,
        testonly = testonly,
        deprecation = deprecation or None,
    )

# A symbolic macro's implementation takes each of godot_app's attributes by name and hands
# them to the backends; splitting it would only move that parameter list.
# @codescene(disable:"Large Method")
def _app_impl(
        name,
        visibility,
        pack,
        loadable_packs,
        application_id,
        macos_signing_identity,
        macos_entitlements,
        macos_minimum_os_version,
        ios_minimum_os_version,
        ios_families,
        android_min_sdk_version,
        android_target_sdk_version,
        android_manifest_values,
        android_manifest,
        android_debug_key,
        ios_provisioning_profile,
        ios_entitlements,
        ios_infoplists,
        ios_app_icons,
        ios_launch_storyboard,
        platform_deps,
        platform_resources,
        target_compatible_with,
        tags,
        exec_compatible_with,
        deprecation,
        exec_properties,
        features,
        engine,
        engine_optimize,
        engine_lto,
        engine_vfe,
        build_profile,
        missing_extension_libraries,
        **kwargs):
    # The inherited testonly is None unless set, which applies the package default.
    testonly = kwargs.pop("testonly")

    hidden = _hidden(tags, testonly)
    engine_settings = dict(
        engine = engine,
        engine_optimize = engine_optimize,
        engine_lto = engine_lto,
        engine_vfe = engine_vfe,
        build_profile = build_profile,
    )

    # Desktop application backends package the runtime component the runtime toolchain
    # resolves in their platform slice; Android and iOS application backends resolve it
    # inside their Android or Apple split.
    _resolved_runtime(name = name + ".runtime", **(engine_settings | hidden))
    _application_packs(
        name = name,
        pack = pack,
        loadable_packs = loadable_packs,
        hidden = hidden,
        application_id = application_id,
        macos_minimum_os_version = macos_minimum_os_version,
        ios_minimum_os_version = ios_minimum_os_version,
        ios_families = ios_families,
        android_min_sdk_version = android_min_sdk_version,
        android_target_sdk_version = android_target_sdk_version,
        missing_extension_libraries = missing_extension_libraries,
    )
    common = hidden | dict(
        exec_compatible_with = exec_compatible_with,
        exec_properties = exec_properties,
        features = features,
    )
    _desktop_backends(
        name = name,
        application_id = application_id,
        macos_minimum_os_version = macos_minimum_os_version,
        macos_signing_identity = macos_signing_identity,
        macos_entitlements = macos_entitlements,
        platform_deps = platform_deps,
        platform_resources = platform_resources,
        common = common,
    )
    _android_backends(
        name = name,
        application_id = application_id,
        manifest_values = android_manifest_values,
        manifest = android_manifest,
        debug_key = android_debug_key,
        platform_deps = platform_deps,
        platform_resources = platform_resources,
        common = common | engine_settings,
    )
    _godot_ios_application(
        name = name + ".ios/" + name,
        pack = ":" + name + ".pack",
        bundle_id = application_id,
        bundle_name = name,
        executable_name = name,
        minimum_os_version = ios_minimum_os_version,
        families = ios_families,
        deps = platform_deps,
        resources = platform_resources,
        provisioning_profile = ios_provisioning_profile,
        entitlements = ios_entitlements,
        infoplists = ios_infoplists,
        app_icons = ios_app_icons,
        launch_storyboard = ios_launch_storyboard,
        **(common | engine_settings)
    )
    _godot_web_application(
        name = name + ".web",
        app_name = name,
        pack = ":" + name + ".pack",
        runtime = ":" + name + ".runtime",
        platform_deps = platform_deps,
        platform_resources = platform_resources,
        **common
    )
    _editor_backend(name = name, common = common, engine = engine)
    _public_targets(
        name = name,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
        deprecation = deprecation,
        tags = tags,
        testonly = testonly,
    )

godot_app = macro(
    doc = """
    Package a start pack and the matching runtime into one application.

    Select the export platform with --platforms. The public label forwards the
    providers, default artifacts, run behavior and output groups of the application
    backend that export platform selects: a Linux or macOS bundle, an Android APK or
    AAB, an iOS application, or the directory of a web export with its ZIP. Unsupported wildcard targets are skipped; explicit
    unsupported requests fail. Selected application backends need their documented SDKs
    and runtime components. `bazel run` starts the application on this host, a device,
    an emulator or a Simulator, or from sources in the editor variant, and streams its log
    until it exits; see
    [Run an application](../../platforms.md#run-an-application). Configure Godot settings and content on the pack/project;
    this macro never creates or replaces the pack.

    macOS defaults to unsigned. Select --@autoload_rules_godot//godot:macos_signing=adhoc
    or certificate to sign a copy. Certificate mode requires macos_signing_identity;
    macos_entitlements affects only the selected signer. Unsigned actions never read
    signing inputs. The selected launcher and GodotDesktopAppInfo bundle/archive refer
    to the same result; executable_path stays bundle-relative. Signing requires local
    Darwin execution; certificates additionally require an accessible keychain and
    disable action caching and sandboxing. Failures never return unsigned output.
    The public <name>.debug_symbols companion bypasses signer analysis, including in
    certificate mode without identity; debug_symbols on the selected app does not.

    The application delivers the extension libraries, platform libraries and Info.plist
    fragments of the add-ons of its start pack and of its loadable_packs.

    Example: godot_app(name = "app", pack = ":pack"). Each application backend packages
    the runtime component that the runtime toolchain resolves for its platform slice and
    variant; register the components with register_toolchains or --extra_toolchains.
    See [platform setup](../../platforms.md) and the
    [Godot configuration catalogue](../../configuration.md) for config-only capabilities.
    """,
    implementation = _app_impl,
    # Common inheritance gives testonly Bazel's package default; other common
    # attributes are declared below or disabled.
    inherit_attrs = "common",
    # This dictionary excludes inherited package_metadata; it defines no custom field.
    # Remove the exclusion when macro inheritance stops exposing that built-in attribute.
    # buildifier: disable=attr-applicable_licenses
    attrs = {
        "expect_failure": None,
        "transitive_configs": None,
        "compatible_with": None,
        "restricted_to": None,
        "package_metadata": None,
        "aspect_hints": None,
        "toolchains": None,
        "exec_group_compatible_with": None,
        "pack": attr.label(doc = "The start pack: a godot_pack target, which also brings the extension libraries and platform libraries of its add-ons; a raw PCK file is not enough.", mandatory = True),
        "loadable_packs": attr.label_list(
            doc = """
            Packs the application may load later, such as DLC: godot_pack targets whose
            add-ons' extension libraries, platform libraries and Info.plist fragments the
            application delivers besides the start pack's. The application does not
            contain their PCKs.
            """,
            configurable = False,
        ),
        "macos_signing_identity": attr.string(doc = "App-specific local certificate identity; required and not '-' in certificate mode. Ad hoc ignores it; unsigned never analyzes it."),
        "macos_entitlements": attr.label(doc = "Optional declared entitlement plist, including generated files; only the selected signer consumes it."),
        "application_id": attr.string(doc = "Android application ID or Apple bundle identifier; required for mobile. On macOS an empty value keeps the pack's application/bundle_identifier; Linux ignores it."),
        "macos_minimum_os_version": attr.string(doc = "Minimum macOS version of the application: the bundle's LSMinimumSystemVersion and the deployment target of the native code its pack compiles, such as extension libraries. The default is Godot's floor; a source-built engine compiles for that floor regardless.", default = MACOS_MINIMUM_OS),
        "ios_minimum_os_version": attr.string(doc = "Minimum iOS version of the application. It is part of the application context, so the pack exports with it; the runtime must support it.", default = IOS_MINIMUM_OS),
        "ios_families": attr.string_list(doc = "Unique nonempty subset of iphone/ipad: the device families of the application's Info.plist and of the pack's export options.", default = ["iphone", "ipad"]),
        "android_min_sdk_version": attr.int(doc = "Minimum SDK; zero uses the selected engine profile fallback. Distinct from NDK/compile SDK."),
        "android_target_sdk_version": attr.int(doc = "Target SDK; zero uses the engine profile fallback and resolved target must be >= minimum."),
        "android_manifest_values": attr.string_dict(
            doc = """
            Values for the manifest placeholders of the Android manifest merge, like Gradle's
            `manifestPlaceholders`: `${key}` in the application's manifest and in the
            manifests of its platform libraries, such as an SDK's `${appAuthRedirectScheme}`,
            becomes the value. A placeholder without a value fails the merge with a message
            naming it. Keys the merger treats as overrides (the application ID, SDK versions,
            version code and name, `maxSdkVersion`) are rejected with a diagnostic naming
            the attribute or pack setting that owns the value. The values are not part of the
            application context, so a changed value reruns the manifest merge and packaging,
            not the pack's export. Other operating systems ignore them.
            """,
            default = {},
        ),
        "android_manifest": attr.label(
            doc = """
            The application's own Android manifest, the main manifest of the manifest merge;
            the manifest Godot's Android export writes merges below it. See
            [Android shell files](../../platforms.md#android-shell-files). Not configurable;
            other operating systems ignore it.
            """,
            allow_single_file = [".xml"],
            configurable = False,
        ),
        "android_debug_key": attr.label(doc = "Debug keystore that signs APKs, used in the exec configuration; AABs are signed outside Bazel.", default = Label("@rules_android//tools/android:debug_keystore")),
        "ios_provisioning_profile": attr.label(doc = "Optional provisioning profile file; installed profiles are never looked up."),
        "ios_entitlements": attr.label(doc = "Optional declared entitlement file, including generated files."),
        "ios_infoplists": attr.label_list(
            doc = """
            The application's own Info.plist fragments; each top-level key they set replaces
            that key of the generated Info.plist and of the add-ons' fragments. See
            [iOS shell files](../../platforms.md#ios-shell-files). Other operating systems ignore
            them.
            """,
            allow_files = [".plist"],
        ),
        "ios_app_icons": attr.label_list(
            doc = """
            The application's own app icons, as rules_apple's `app_icons` takes them, which
            replace those Godot renders. See
            [iOS shell files](../../platforms.md#ios-shell-files). Other operating systems ignore
            them.
            """,
            allow_files = True,
        ),
        "ios_launch_storyboard": attr.label(
            doc = """
            The application's own launch screen, a `.storyboard` or `.xib` file, which
            replaces the one Godot's export writes. Other operating systems ignore it.
            """,
            allow_single_file = [".storyboard", ".xib"],
        ),
        "platform_deps": attr.label_list(doc = "Platform libraries of this application only: Android Java or native libraries, or iOS libraries and frameworks. Use select() with empty desktop branches; platform libraries other applications reuse belong to the platform_deps of add-ons or extensions."),
        "platform_resources": attr.label_list(doc = "Platform resources of this application only: Android primary resource files or iOS bundle resources. Use select() with empty desktop branches; the resources of a platform library stay on that library. An Android resource with the type, name and configuration qualifiers of a shell resource, such as a launcher icon or the `GodotAppSplashTheme` style, and an iOS `PrivacyInfo.xcprivacy` replace the shell's."),
        "target_compatible_with": attr.label_list(doc = "Consumer compatibility constraints/select; sole restriction of the supported export platforms."),
        "tags": attr.string_list(doc = "Conventional Bazel tags; helpers additionally exclude wildcard selection.", configurable = False),
        "exec_compatible_with": attr.label_list(doc = "Execution-platform constraints of the application backends.", configurable = False),
        "deprecation": attr.string(doc = "Optional conventional Bazel deprecation message.", configurable = False),
        "exec_properties": attr.string_dict(doc = "Execution properties of the application backends."),
        "features": attr.string_list(doc = "rules_cc toolchain features, independent of Godot feature tags."),
        "engine": attr.string(
            doc = "The engine whose runtime this application packages, by engine name; empty keeps the build's engine, the default one or the one --@autoload_rules_godot//godot:engine names. It must be the engine its packs were exported with.",
            configurable = False,
        ),
        "engine_optimize": attr.string(
            doc = "How this application's source-built engine compiles under -c opt, overriding --@autoload_rules_godot//godot:engine_optimize; empty keeps the build's. See [optimization](../../engine.md#optimization).",
            configurable = False,
            values = [""] + OPTIMIZE_VALUES,
        ),
        "engine_lto": attr.string(
            doc = "Link-time optimization of this application's source-built engine under -c opt, overriding --@autoload_rules_godot//godot:engine_lto; empty keeps the build's.",
            configurable = False,
            values = [""] + LTO_VALUES,
        ),
        "engine_vfe": attr.string(
            doc = "Whether this application's source-built engine drops the virtual functions nothing calls under -c opt, overriding --@autoload_rules_godot//godot:engine_vfe: on, off, or empty to keep the build's. Needs full LTO and Clang.",
            configurable = False,
            values = VFE_VALUES,
        ),
        "missing_extension_libraries": attr.string(
            doc = """
            What the application does with an extension its packs reach that has no library
            for its platform, a select() branch of None in the extension's library: "error",
            the default, fails analysis and names the extensions; "report" builds without
            them, prints the list as a warning and writes it to
            <name>.missing_extension_libraries.txt in the output group of that name, and the
            content validation of its packs reports instead of failing where such an
            extension is absent. --@autoload_rules_godot//godot:missing_extension_libraries,
            when given, overrides it for one invocation. See
            [missing extension libraries](../../gdextension.md#missing-extension-libraries).
            """,
            default = "error",
            values = ["error", "report"],
            configurable = False,
        ),
        "build_profile": attr.label(
            doc = """
            A Godot build profile (.gdbuild), such as godot_runtime_profile derives or the
            editor's Engine Compilation Configuration writes, that cuts this application's
            runtime to what the game uses. Only the runtime is affected: packs, imports and
            the editor keep every class. Its disabled_classes reach the engine's class
            generator as an input, so no recipe is repinned and only the sources that
            register classes recompile. Its disabled_build_options, such as disable_3d or a
            module switch, change the engine's build graph: the profile must then be
            registered with godot_engines.runtime_profile, which pins it as a runtime
            variant of the engine's recipes, or the build fails naming that line.
            Applications with different profiles share every object a profile leaves alone.
            The runtime must be built from source, as a source build or a prebuilt engine's
            source_runtimes; a prebuilt runtime fails analysis. See
            [build profiles](../../engine-size.md#4-use-a-build-profile) and
            [build options in a build profile](../../engine.md#build-options-in-a-build-profile).
            """,
            allow_single_file = [".gdbuild"],
            configurable = False,
        ),
    },
)
