"""Private desktop assembly used by godot_app."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("//godot:providers.bzl", "GodotDesktopAppInfo", "GodotPackInfo")
load("//godot/private:export_options.bzl", "string_option")
load("//godot/private:minimum_os.bzl", "check_minimum_os")
load("//godot/private:paths.bzl", "resolve_project_path")
load("//godot/private:providers.bzl", "GodotComponentInfo", "GodotRuntimeInfo")
load("//godot/private:release.bzl", "RELEASE_ATTRS")
load(
    "//godot/private:symbols.bzl",
    "STRIP_ATTRS",
    "SYMBOLS_ZIP_ATTRS",
    "dsym",
    "packaged",
    "symbols_zip",
)
load("//godot/private:versions.bzl", "MACOS_MINIMUM_OS")
load("//godot/private/config:native.bzl", "APPLICATION_SCOPED_OPTIONS", "macos_application_options")
load("//godot/private/engine:profiles.bzl", "engine_profile")
load(":launch.bzl", "LAUNCH_ATTRS", "launcher")
load(":shell.bzl", "ENGINE_CHECK_ATTRS", "SHELL_ATTRS", "check_engine", "privacy_manifest", "release_values", "shell_file")

visibility(["//godot", "//godot/platforms", "//godot/platforms/private/tests"])

def _runtime_file(runtime, operating_system):
    # Only the runtime's own facts are checked; its version and variant are never
    # compared with the editor that exported the pack.
    if runtime.platform != operating_system:
        fail("%s runtime cannot package a %s app" % (runtime.platform, operating_system))
    if not runtime.executable:
        fail("desktop runtime must provide an executable")
    return runtime.executable

def _liquid_glass_icon(ctx, pack):
    """Compile the .icon of application/liquid_glass_icon with actool, as Godot does."""
    value = string_option(pack.export_options, "application/liquid_glass_icon")
    if not value:
        return None
    icon = resolve_project_path(pack.project.member_resource_paths, value)
    if not icon or icon.kind != "directory":
        fail("application/liquid_glass_icon names %s, which is %s, not an Icon Composer .icon directory" % (
            value,
            "a file" if icon else "neither a declared file nor a directory",
        ))
    path = icon.path
    files = {
        member.removeprefix(path + "/"): file
        for member, file in icon.files.items()
    }
    manifest = ctx.actions.declare_file(ctx.label.name + "/liquid_glass_icon.json")
    ctx.actions.write(manifest, json.encode({
        relative: file.path
        for relative, file in files.items()
    }))
    compiled = ctx.actions.declare_directory(ctx.label.name + "/liquid_glass_icon")
    icon_name = path.split("/")[-1].removesuffix(".icon")
    apple_support.run(
        actions = ctx.actions,
        xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
        apple_fragment = ctx.fragments.apple,
        executable = ctx.executable._compile_icon,
        arguments = ["--files", manifest.path, "--name", icon_name, "--output", compiled.path],
        inputs = [manifest] + files.values(),
        outputs = [compiled],
        mnemonic = "GodotLiquidGlassIcon",
        progress_message = "Generating %{label}",
    )
    return struct(name = icon_name, resources = compiled)

def _macos_metadata(ctx, pack, name):
    """Write the Info.plist, privacy manifest and localizations of Godot's macOS export."""
    profile = engine_profile(pack.version)
    plist = ctx.actions.declare_file(ctx.label.name + "/Info.plist")
    privacy = ctx.actions.declare_file(ctx.label.name + "/PrivacyInfo.xcprivacy")
    localizations = ctx.actions.declare_directory(ctx.label.name + "/localizations")
    icon = _liquid_glass_icon(ctx, pack)
    args = ctx.actions.args()
    args.add("--localizations", localizations.path)
    shell_file(
        ctx,
        "macos-plist",
        plist,
        pack,
        {
            "profile": profile["macos"],
            "fallback_name": name,
            "executable": name,
            "bundle_id": ctx.attr.bundle_id,
            "icon_name": icon.name if icon else "",
        } | release_values(ctx, pack),
        outputs = [localizations],
        args = args,
        infoplists = pack.project.infoplists,
    )
    privacy_manifest(ctx, pack, profile, "macos", privacy)
    return struct(
        plist = plist,
        privacy = privacy,
        resources = [localizations] + ([icon.resources] if icon else []),
    )

def _package_binaries(ctx, binaries, linked_dsyms):
    """
    Return the binaries to package and their debug symbols, both by bundle path.

    Args:
        ctx: Rule context.
        binaries: Dictionary of bundle paths to the unstripped runtime executable and
            shared libraries.
        linked_dsyms: Dictionary of those Files to the .dSYM directories their
            linker wrote, which macOS uses instead of running dsymutil.

    Returns:
        A struct with `packaged`, the Files to package, and `symbols`, the ZIP
        entries of the debug symbols.
    """
    macho = ctx.attr._operating_system == "macos"
    if macho:
        symbols = {
            destination + ".dSYM": linked_dsyms.get(file) or dsym(
                ctx,
                file,
                ctx.label.name + "_symbols/" + destination + ".dSYM",
            )
            for destination, file in binaries.items()
        }
    else:
        symbols = binaries
    files = packaged(ctx, {
        ctx.label.name + "_stripped/" + destination: file
        for destination, file in binaries.items()
    }, macho = macho)
    return struct(packaged = dict(zip(binaries.keys(), files.values())), symbols = symbols)

def _bundle_layout(operating_system):
    """Where an application bundle holds resource paths and the files beside its executable."""
    macos = operating_system == "macos"
    return struct(
        resources = "Contents/Resources/" if macos else "",
        beside_executable = "Contents/Frameworks/" if macos else "",
        placed = {},
    )

def _extension_copy(layout, owner, destination, source):
    """
    The copy of an extension's runtime file that is no native code.

    Data that is no shared library goes where Godot's export puts [dependencies]: beside
    the executable, in Contents/Frameworks on macOS, keeping its mode. Other files keep
    their resource path. Two data files of one name fail.
    """
    if destination not in owner.beside_executable:
        return {"source": source.path, "destination": layout.resources + destination}
    placed = layout.beside_executable + source.basename
    if placed in layout.placed:
        fail("%s and %s both place a file at %s beside the executable" % (layout.placed[placed], owner.context, placed))
    layout.placed[placed] = owner.context
    return {"source": source.path, "destination": placed, "keep_mode": True}

def _desktop_application_impl(ctx):
    operating_system = ctx.attr._operating_system
    if ctx.attr.platform_deps or ctx.attr.platform_resources:
        fail("godot_app %s does not support nonempty platform_deps or platform_resources: %s" % (operating_system, [str(target.label) for target in ctx.attr.platform_deps + ctx.attr.platform_resources]))
    name = ctx.attr.app_name or ctx.label.name
    if name in [".", ".."] or "/" in name or "\\" in name:
        fail("app_name must be a filename without separators")
    runtime = ctx.attr.runtime[GodotRuntimeInfo]

    # A transitioned label attribute, as the macOS backend's pack is, arrives as a list.
    pack_target = ctx.attr.pack[0] if type(ctx.attr.pack) == "list" else ctx.attr.pack
    pack = pack_target[GodotPackInfo]
    if operating_system == "macos":
        check_minimum_os(ctx.attr.minimum_os_version, "macos_minimum_os_version", "macos", runtime, pack.project.runtime_extensions)
    runtime_executable = _runtime_file(runtime, operating_system)
    binary_relative = "Contents/MacOS/" + name if operating_system == "macos" else name
    binaries = {binary_relative: runtime_executable}
    linked_dsyms = {runtime_executable: runtime.debug_symbols}
    binary_contexts = {}
    pack_file = pack.pack_file
    bundle = ctx.actions.declare_directory(
        ctx.label.name + "/" + name + (".app" if operating_system == "macos" else ".bundle"),
    )
    archive = ctx.actions.declare_file(
        ctx.label.name + "/" + name + (".zip" if operating_system == "macos" else ".tar.gz"),
    )
    executable = ctx.actions.declare_file(ctx.label.name + "/" + name + ".run")
    manifest = ctx.actions.declare_file(ctx.label.name + ".bundle.json")
    copies = []
    copied_files = []
    for destination, source in runtime.bundle_files.items():
        copied_files.append(source)
        copies.append({"source": source.path, "destination": destination})

    # Destinations are resource paths: extension libraries stay loose files beside the
    # mounted pack. The library and the shared libraries it needs are native code to
    # package; its descriptor and other runtime files are copied (_extension_copy).
    layout = _bundle_layout(operating_system)
    prefix = layout.resources
    for extension in pack.project.runtime_extensions:
        library = extension.library
        context = "res://%s: %s" % (extension.descriptor_path, library.tags)
        if library.debug_symbols:
            linked_dsyms[library.file] = library.debug_symbols
        native = {
            path: file
            for path, file in extension.runtime_resource_paths.items()
            if file == library.file or (path in library.runtime_dependencies and (file.extension in ["so", "dylib"] or ".so." in file.basename))
        }
        for destination, source in extension.runtime_resource_paths.items():
            if destination in native:
                binaries[prefix + destination] = source
                binary_contexts[prefix + destination] = context
                continue
            copied_files.append(source)
            copies.append(_extension_copy(layout, struct(context = context, beside_executable = library.beside_executable), destination, source))
    packaged_binaries = _package_binaries(ctx, binaries, linked_dsyms)
    for destination, source in packaged_binaries.packaged.items():
        if destination == binary_relative:
            runtime_executable = source
            continue
        copied_files.append(source)
        copies.append({"source": source.path, "destination": destination, "context": binary_contexts.get(destination)})
    args = ctx.actions.args()
    engine_check = check_engine(ctx, {"--library": depset([runtime.executable])}, engine = ctx.attr.runtime)
    inputs = [runtime_executable, pack_file, manifest]
    if operating_system == "macos":
        metadata = _macos_metadata(ctx, pack, name)
        copied_files.append(metadata.privacy)
        copies.append({
            "source": metadata.privacy.path,
            "destination": "Contents/Resources/PrivacyInfo.xcprivacy",
        })
        args.add("--infoplist-base", metadata.plist)
        inputs.append(metadata.plist)
        args.add_all(metadata.resources, before_each = "--resources", expand_directories = False)
        inputs.extend(metadata.resources)
        if pack.icons:
            # The icon Godot rendered for the pack.
            args.add("--icons", pack.icons[0].path)
            inputs.extend(pack.icons)
    ctx.actions.write(manifest, json.encode(copies))
    args.add("--operating-system", operating_system)
    args.add("--runtime", runtime_executable)

    args.add("--cpu", pack.cpus[0])
    args.add("--pack", pack_file)
    args.add("--output", bundle.path)
    args.add("--archive", archive)
    args.add("--app-name", name)
    args.add("--manifest", manifest)
    inputs += copied_files
    ctx.actions.run(
        executable = ctx.executable._packager,
        inputs = depset(inputs, transitive = [runtime.files]),
        outputs = [bundle, archive],
        arguments = [args],
        mnemonic = "GodotDesktopPackage",
        progress_message = "Bundling %{label}",
    )
    debug_symbols = ctx.actions.declare_file(ctx.label.name + "/" + name + "_debug_symbols.zip")
    symbols_zip(ctx, packaged_binaries.symbols, debug_symbols)
    return desktop_result(
        ctx,
        executable = executable,
        bundle = bundle,
        archive = archive,
        operating_system = operating_system,
        executable_path = binary_relative,
        debug_symbols = depset([debug_symbols]),
        validation = depset(engine_check),
        runtime_component = ctx.attr.runtime[GodotComponentInfo] if GodotComponentInfo in ctx.attr.runtime else None,
    )

def desktop_result(ctx, executable, bundle, archive, operating_system, executable_path, debug_symbols, validation, runtime_component):
    """
    Return the providers of one selected desktop application result.

    Assembly and signing both describe their result this way, so a consumer cannot
    tell a signed bundle from an unsigned one by its interface.

    Args:
        ctx: Rule context with LAUNCH_ATTRS.
        executable: Declared launcher file.
        bundle: Application bundle tree artifact.
        archive: Distributable archive of the bundle.
        operating_system: "linux" or "macos".
        executable_path: Bundle-relative path of the runtime executable.
        debug_symbols: Depset of the matching debug symbols.
        validation: Depset of validation outputs to keep.
        runtime_component: GodotComponentInfo of the packaged runtime component, or None.

    Returns:
        DefaultInfo, OutputGroupInfo and GodotDesktopAppInfo.
    """
    runfiles = launcher(ctx, executable, {"platform": "desktop", "executable": (bundle, executable_path)})
    return [
        DefaultInfo(
            executable = executable,
            files = depset([archive, bundle]),
            runfiles = runfiles,
        ),
        OutputGroupInfo(
            bundle = depset([bundle]),
            archive = depset([archive]),
            debug_symbols = debug_symbols,
            _validation = validation,
        ),
        GodotDesktopAppInfo(
            bundle = bundle,
            archive = archive,
            operating_system = operating_system,
            executable_path = executable_path,
            runtime_component = runtime_component,
        ),
    ]

_DOC = """
Package a Godot PCK and a matching {operating_system} runtime into a runnable application.

Returns DefaultInfo with the {bundle} and {archive} archive, GodotDesktopAppInfo
and OutputGroupInfo.bundle / .archive / .debug_symbols. bazel run launches the
assembled bundle.
Extension libraries of the pack's project keep their resource paths inside the
bundle. godot_app supplies the runtime the runtime toolchain resolves for the
platform slice and `--@autoload_rules_godot//godot:variant`; its version and variant are not
compared with the editor that exported the pack.

The debug_symbols output group is `<name>_debug_symbols.zip`: {symbols}, at
their paths in the bundle. The application packages the runtime and these
libraries stripped as Bazel's `--strip` asks: always, or by default in
fastbuild only.
{details}
godot_app builds this application backend for {operating_system} apps.

See [desktop packaging](../../platforms.md) for operating system and toolchain setup.
"""

_MACOS_DETAILS = """With `--apple_generate_dsym`, the .dSYM of native code rules_cc links, such
as godot_cc_extension libraries and source-built engines, is the one its linker
writes, with file and line information. Other files, such as prebuilt runtimes
and prebuilt libraries, get a .dSYM made from the file alone, which names
functions only.

This application backend stays unsigned; godot_app selects a separately signed copy with the macos_signing setting. It gets the
Info.plist and privacy manifest Godot's macOS export writes: from the pack's
export options under Godot's names, such as `application/app_category`,
`application/copyright`, `display/high_res` or
`privacy/camera_usage_description`, and from the project's
`application/config/name` and `application/config/version`. The build settings
`--@autoload_rules_godot//godot:app_version` and `--@autoload_rules_godot//godot:build_number`
set the versions that `application/short_version` and `application/version`
leave empty. Its icon is the one Godot renders from `application/icon`, the
project's `application/config/icon` or Godot's default icon; with Xcode 26, the
Icon Composer `.icon` of `application/liquid_glass_icon` adds the Liquid Glass
icon. A project with translations gets the localized display name, copyright
and usage descriptions as InfoPlist strings.
"""

_ATTRS = {
    "platform_deps": attr.label_list(),
    "platform_resources": attr.label_list(allow_files = True),
    "pack": attr.label(
        doc = """
        PCK target providing GodotPackInfo; extension libraries are collected from
        its project.
        """,
        mandatory = True,
        providers = [GodotPackInfo],
    ),
    "runtime": attr.label(
        doc = """
        GodotRuntimeInfo with a matching operating system and executable; godot_app passes
        the runtime component its runtime toolchain resolves.
        """,
        mandatory = True,
        providers = [GodotRuntimeInfo],
    ),
    "app_name": attr.string(
        doc = "Application filename without path separators; empty uses the target name.",
    ),
    "_packager": attr.label(
        default = Label("//tools/platforms:package_desktop"),
        executable = True,
        cfg = "exec",
    ),
} | STRIP_ATTRS | SYMBOLS_ZIP_ATTRS | ENGINE_CHECK_ATTRS | LAUNCH_ATTRS

def _macos_minimum_impl(settings, attr):
    # Only the macOS backend's edge sets the application's minimum, so Linux and host
    # builds of other targets share the pack's configuration.
    return macos_application_options(settings, attr.minimum_os_version)

_macos_minimum = transition(
    implementation = _macos_minimum_impl,
    inputs = APPLICATION_SCOPED_OPTIONS,
    outputs = APPLICATION_SCOPED_OPTIONS,
)

_MACOS_ATTRS = {
    "minimum_os_version": attr.string(
        doc = "The application's minimum macOS version: the deployment target of the native code its pack builds, checked against the runtime's deployment target and the extensions' requirements.",
        default = MACOS_MINIMUM_OS,
    ),
    "pack": attr.label(
        doc = """
        PCK target providing GodotPackInfo; extension libraries are collected from
        its project and built for the application's minimum macOS version.
        """,
        mandatory = True,
        providers = [GodotPackInfo],
        cfg = _macos_minimum,
    ),
    "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
    "bundle_id": attr.string(
        doc = """
        CFBundleIdentifier; empty uses the pack's export option
        application/bundle_identifier, else org.godotengine.game.
        """,
    ),
    "_compile_icon": attr.label(
        default = Label("//tools/platforms:compile_icon"),
        cfg = "exec",
        executable = True,
    ),
} | SHELL_ATTRS | RELEASE_ATTRS | apple_support.action_required_attrs()

def _desktop_rule(operating_system):
    macos = operating_system == "macos"
    return rule(
        doc = _DOC.format(
            operating_system = "macOS" if macos else "Linux",
            bundle = ".app" if macos else ".bundle directory",
            archive = "deterministic ZIP" if macos else "deterministic tar.gz",
            details = _MACOS_DETAILS if macos else "",
            symbols = (
                "a .dSYM of the runtime and of each extension library" if macos else "the unstripped runtime and extension libraries"
            ),
        ),
        implementation = _desktop_application_impl,
        executable = True,
        attrs = _ATTRS | {"_operating_system": attr.string(default = operating_system)} |
                (_MACOS_ATTRS if macos else {}),
        toolchains = use_cc_toolchain(mandatory = False),
        fragments = ["apple", "cpp"] if macos else ["cpp"],
    )

godot_linux_application = _desktop_rule("linux")
godot_macos_application = _desktop_rule("macos")
