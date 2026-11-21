"""Extensions, and the extension libraries rules_cc builds for them."""

load("@rules_apple//apple:aspects.bzl", "framework_provider_aspect")
load("@rules_apple//apple:providers.bzl", "AppleDynamicFrameworkInfo", "AppleFrameworkImportInfo", "apple_provider")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//godot/extension/private:cc_extension.bzl", "generated_attrs", "native_archive", "shared_library")
load("//godot/extension/private:ios_framework.bzl", "ios_framework")
load("//godot/platforms/private:manifest_graph.bzl", "manifest_graph_aspect")
load("//godot/private:addon.bzl", "extension_addon")
load("//godot/private:context.bzl", "TRANSITION_ATTRS", "reset_transition")
load("//godot/private:execution.bzl", "EDITOR_TOOLCHAIN", "RUN_EXEC_GROUPS")
load("//godot/private:flags.bzl", "FlagInfo")
load("//godot/private:paths.bzl", "resource_path")
load("//godot/private:providers.bzl", "GodotExtensionInfo")
load("//godot/private:symbols.bzl", "keep_debug_info", "linked_dsym")
load("//godot/private:variant.bzl", "VARIANT_ATTRS", "variant")
load("//godot/private:versions.bzl", "dotted_version", "require_supported_godot_minimum")
load("//godot/private/config:settings.bzl", "CPU_TABLE", "OPERATING_SYSTEM_CONSTRAINTS", "PLATFORM_ATTRS", "target_platform")
load("//godot/private/config:transitions.bzl", "tool_transition")

_SHARED = "a shared library (cc_shared_library, cc_import(shared_library), cc_binary(linkshared), one .%s)"
_FRAMEWORK = "a dynamic framework (apple_dynamic_xcframework_import, apple_dynamic_framework_import)"

# What each operating system's runtime loads: the link kinds, the file suffixes of its
# shared libraries, and the accepted forms for diagnostics.
_LOADABLE = {
    "linux": struct(kinds = ["dynamic"], suffixes = ["so"], versioned = True, accepted = _SHARED % "so"),
    # The package manager extracts only lib/<abi>/*.so.
    "android": struct(kinds = ["dynamic"], suffixes = ["so"], versioned = False, accepted = _SHARED % "so"),
    "macos": struct(
        kinds = ["dynamic", "framework"],
        suffixes = ["dylib", "so"],
        versioned = True,
        accepted = _SHARED % "dylib" + " or " + _FRAMEWORK,
    ),
    "ios": struct(
        kinds = ["static", "framework"],
        suffixes = [],
        versioned = False,
        accepted = "a static library (cc_library, cc_import(static_library), apple_static_xcframework_import) or " + _FRAMEWORK,
    ),
}

def _resource_path(path):
    segments = path.split("/")
    rejected = [
        not path,
        path.startswith("/"),
        "\\" in path,
        ":" in path,
        ".." in segments,
        "." in segments,
        "" in segments,
    ]
    if any(rejected):
        fail(
            "resource_path must be a nonempty relative res:// path without traversal: " +
            path,
        )
    return path

def _configured_context(ctx):
    """
    Return what the configuration fixes for an extension library, and its feature tags.

    The tags are the operating system, Godot's CPU tag, simulator in the iOS Simulator,
    and the variant.
    """
    platform = target_platform(ctx)
    if not platform.operating_system or not platform.cpu:
        fail((
            "%s: an extension library needs a target platform with one of the operating " +
            "systems %s and one of the CPUs %s"
        ) % (
            ctx.label,
            ", ".join(OPERATING_SYSTEM_CONSTRAINTS),
            ", ".join([str(row.constraint) for row in CPU_TABLE.values()]),
        ))
    tool = ctx.attr._tool[FlagInfo].value
    selected = variant(ctx)
    tags = [platform.operating_system, platform.cpu]
    if platform.environment == "simulator":
        tags.append("simulator")
    return struct(
        operating_system = platform.operating_system,
        cpu = platform.cpu,
        environment = platform.environment,
        tool = tool,
        tags = ".".join(tags + [selected]),
    )

def _context_name(context):
    return " ".join([part for part in [
        context.operating_system,
        context.cpu,
        context.environment,
        "tool configuration" if context.tool else "",
    ] if part])

def _dynamic_file(library):
    """The shared library a library to link loads, under its own name."""
    return library.resolved_symlink_dynamic_library or library.dynamic_library

def _is_shared_library(file, suffixes = ["so", "dylib"], versioned = True):
    return file.extension in suffixes or (versioned and "so" in suffixes and ".so." in file.basename)

def _framework_directory(file):
    """The path of the .framework directory that contains file, or None."""
    parts = file.path.split("/")
    for index in range(len(parts) - 1, -1, -1):
        if parts[index].endswith(".framework"):
            return "/".join(parts[:index + 1])
    return None

def _framework_files(target):
    """The files of each framework an Apple import bundles, by framework directory."""
    files = {}
    if AppleFrameworkImportInfo in target:
        for file in target[AppleFrameworkImportInfo].framework_imports.to_list():
            directory = _framework_directory(file)
            if directory:
                files.setdefault(directory, []).append(file)
    return files

def _framework_binary(directory, files):
    """The framework's binary, named after it at its root, or None."""
    path = directory + "/" + directory.rsplit("/", 1)[-1].removesuffix(".framework")
    binaries = [file for file in files if file.path == path]
    return binaries[0] if binaries else None

def _framework_binaries(frameworks):
    """The binaries of the frameworks, which _framework_files groups."""
    return [
        binary
        for directory, files in frameworks.items()
        for binary in [_framework_binary(directory, files)]
        if binary
    ]

def _linked_libraries(target):
    """Return the libraries of the target's own CcInfo linker input, and those of other owners."""
    linker_inputs = target[CcInfo].linking_context.linker_inputs.to_list() if CcInfo in target else []
    return struct(
        own = [library for linker_input in linker_inputs if linker_input.owner == target.label for library in linker_input.libraries],
        others = [linker_input for linker_input in linker_inputs if linker_input.owner != target.label],
    )

def _framework_library(ctx, target, linked, frameworks):
    """
    Return the dynamic framework of an Apple import, or None.

    Its binary is the one the import links or, with bundle_only, which links nothing,
    the binary of the one framework among frameworks.
    """
    binaries = [_dynamic_file(library) for library in linked.own if library.dynamic_library] or _framework_binaries(frameworks)
    if len(binaries) > 1 and not linked.own:
        fail((
            "%s: %s bundles the frameworks %s and links none, so the extension cannot " +
            "tell its library from their dependencies; import each dependency on its own " +
            "and list it in the extension's platform_deps"
        ) % (ctx.label, target.label, sorted([binary.basename + ".framework" for binary in binaries])))
    if len(binaries) != 1:
        return None
    return struct(link_kind = "framework", file = binaries[0], cc_info = target[CcInfo], linker_inputs = linked.others)

def _linked_library(target, linked):
    """Return the static or dynamic library the target's CcInfo links as its own, or None."""
    if len(linked.own) != 1:
        return None
    library = linked.own[0]
    if library.dynamic_library:
        return struct(link_kind = "dynamic", file = _dynamic_file(library), cc_info = None, linker_inputs = linked.others)
    archive = library.static_library or library.pic_static_library
    if archive:
        return struct(link_kind = "static", file = archive, cc_info = target[CcInfo], linker_inputs = linked.others)
    return None

def _shared_file_library(target):
    """Return the one shared library among the target's files, as cc_binary(linkshared) has it, or None."""
    files = [file for file in target[DefaultInfo].files.to_list() if _is_shared_library(file)]
    if len(files) != 1:
        return None
    return struct(link_kind = "dynamic", file = files[0], cc_info = None, linker_inputs = None)

def _provided_library(ctx, target, frameworks):
    """Return the link kind and file of the library the target's providers supply, or None."""
    linked = _linked_libraries(target)
    if AppleDynamicFrameworkInfo in target:
        return _framework_library(ctx, target, linked, frameworks)
    return _linked_library(target, linked) or _shared_file_library(target)

def _require_loadable(ctx, target, context, classified):
    """Fail unless the operating system of the context can load the classified library."""
    loadable = _LOADABLE[context.operating_system]
    if classified.link_kind not in loadable.kinds:
        fail("%s: %s is a %s library, which %s cannot load; expected %s" % (
            ctx.label,
            target.label,
            classified.link_kind,
            _context_name(context),
            loadable.accepted,
        ))
    if classified.link_kind == "dynamic" and not _is_shared_library(classified.file, loadable.suffixes, loadable.versioned):
        fail("%s: %s supplies %s, which %s cannot load; expected %s" % (
            ctx.label,
            target.label,
            classified.file.basename,
            _context_name(context),
            loadable.accepted,
        ))

def _classify(ctx, target, context, frameworks):
    """
    Return the link kind and file of the configured library, from its providers.

    The library is one the context's operating system can load, as _LOADABLE lists them.
    frameworks is the import's _framework_files.
    """
    classified = _provided_library(ctx, target, frameworks)
    if not classified:
        fail("%s: %s supplies no extension library for %s; expected %s, got %s" % (
            ctx.label,
            target.label,
            _context_name(context),
            _LOADABLE[context.operating_system].accepted,
            [file.basename for file in target[DefaultInfo].files.to_list()],
        ))
    _require_loadable(ctx, target, context, classified)
    return classified

def _own_framework(ctx, target, binary, frameworks):
    """
    Return the directory of the framework whose binary the extension loads.

    Args:
        ctx: Rule context of the extension.
        target: The Apple import.
        binary: The framework binary of the configured library.
        frameworks: The import's _framework_files.

    Returns:
        The directory among frameworks whose binary is binary.
    """
    own = [
        directory
        for directory, files in frameworks.items()
        if _framework_binary(directory, files) == binary
    ]
    if len(own) != 1:
        fail("%s: %s bundles no framework %s.framework with its binary" % (ctx.label, target.label, binary.basename))
    return own[0]

def _dependency_libraries(target, classified):
    """The shared libraries a dynamic library needs at run time, its own excluded."""
    if classified.link_kind != "dynamic":
        return []
    if classified.linker_inputs != None:
        # The shared libraries the library's CcInfo links, as cc_import's deps.
        return [
            _dynamic_file(library)
            for linker_input in classified.linker_inputs
            for library in linker_input.libraries
            if library.dynamic_library
        ]

    # A shared library a rule linked, as cc_binary(linkshared) or cc_shared_library,
    # carries the shared libraries of its deps in its runfiles. A file of the library's
    # own name is the library itself: cc_shared_library holds a second copy under _solib.
    return [
        file
        for file in target[DefaultInfo].default_runfiles.files.to_list()
        if _is_shared_library(file) and file.basename != classified.file.basename
    ]

def _placement(ctx, context, prefix):
    """Where the runtime files of one configured extension library go, beside the library."""
    return struct(
        label = ctx.label,
        context = _context_name(context),
        directory = prefix + "bin/" + context.tags + "/",
        resource_paths = {},
    )

def _place(placement, name, file):
    """Place file under name beside the extension library and return its resource path."""
    if placement.directory + name in placement.resource_paths:
        fail("%s: two runtime files of %s are named %s; extension libraries load their dependencies by name from beside them" % (
            placement.label,
            placement.context,
            name,
        ))
    return _place_at(placement, placement.directory + name, file)

def _place_at(placement, path, file):
    """Place file at the resource path path and return it."""
    if path in placement.resource_paths:
        fail("%s: two runtime files of %s lie at res://%s" % (placement.label, placement.context, path))
    placement.resource_paths[path] = file
    return path

def _place_framework(placement, frameworks, own):
    """Place the files of every framework; return the resource paths of those but own."""
    dependency_paths = []
    for framework, files in frameworks.items():
        name = framework.rsplit("/", 1)[-1]
        for file in files:
            _place(placement, name + file.path[len(framework):], file)
        if framework != own:
            dependency_paths.append(placement.directory + name)
    return dependency_paths

def _archive_file(ctx, context, classified):
    """Return the classified library's file, a static library as an archive named .a."""
    file = classified.file
    if classified.link_kind != "static" or file.extension == "a":
        return file

    # rules_cc names alwayslink archives .lo, and a static framework's binary has no
    # suffix. Godot resolves an iOS entry symbol in the executable only for a descriptor
    # path ending in .a; linking keeps the original CcInfo.
    stem = file.basename.removesuffix("." + file.extension) if file.extension else file.basename
    archive = ctx.actions.declare_file(ctx.label.name + "/" + context.tags + "/" + stem + ".a")
    ctx.actions.symlink(output = archive, target_file = file)
    return archive

def _is_android_library(file):
    """Whether Android's package manager extracts file: only lib/<abi>/lib*.so."""
    return file.basename.startswith("lib") and _is_shared_library(file, ["so"], versioned = False)

def _place_data(ctx, context, placement, prefix):
    """
    Place the files of data as Godot's [dependencies] and return their resource paths.

    Shared libraries lie beside the library, which loads them by name. Other files, such
    as a crash handler executable, lie at their path below the descriptor's directory,
    relative to the package of the target that lists them, as a vendor's add-on lays them
    out: code that finds them through res:// finds them there in runs and the editor.
    Desktop applications place those beside the executable, as Godot's export does.

    Returns:
        A struct of paths (all resource paths) and beside_executable (those of the files
        that are not shared libraries).
    """
    if context.operating_system == "ios" and ctx.files.data:
        fail((
            "%s: iOS applications deliver no files beside an extension library, so %s in " +
            "data would be lost; declare them with a platform library in platform_deps, such " +
            "as in an objc_library's data, or a framework the library loads as a " +
            "bundle_only import there"
        ) % (ctx.label, sorted([file.short_path for file in ctx.files.data])))
    paths = []
    beside_executable = []
    for target in ctx.attr.data:
        for file in target[DefaultInfo].files.to_list():
            if _is_data_library(ctx, context, file):
                paths.append(_place(placement, file.basename, file))
                continue
            path = _place_at(placement, resource_path(file, target.label, "", prefix), file)
            paths.append(path)
            beside_executable.append(path)
    return struct(paths = paths, beside_executable = beside_executable)

def _is_data_library(ctx, context, file):
    """Whether a file of data is a shared library the configuration loads; Android takes only those."""
    if context.operating_system == "android" and not _is_android_library(file):
        fail("%s: Android applications deliver only shared libraries named lib*.so beside an extension library; %s is not one" % (
            ctx.label,
            file.short_path,
        ))
    loadable = _LOADABLE[context.operating_system]
    return _is_shared_library(file, loadable.suffixes, loadable.versioned)

def _configured_library(ctx, target, prefix, context):
    """
    Return the configured extension library and the resource paths of its files.

    Args:
        ctx: Rule context of the extension.
        target: The library target of this configuration.
        prefix: The descriptor's directory with a trailing slash, or empty.
        context: The configured context.

    Returns:
        A struct of library (the configured extension library), resource_paths (dict of
        resource paths to Files) and dependency_paths (the resource paths the
        descriptor lists as the library's dependencies).
    """
    frameworks = _framework_files(target)
    classified = _classify(ctx, target, context, frameworks)
    placement = _placement(ctx, context, prefix)
    if classified.link_kind == "framework":
        own = _own_framework(ctx, target, classified.file, frameworks)
        library_file = classified.file
        library_path = placement.directory + own.rsplit("/", 1)[-1]
        dependency_paths = _place_framework(placement, frameworks, own)
    else:
        library_file = _archive_file(ctx, context, classified)
        library_path = _place(placement, library_file.basename, library_file)
        dependency_paths = [_place(placement, file.basename, file) for file in _dependency_libraries(target, classified)]
    data = _place_data(ctx, context, placement, prefix)
    dependency_paths += data.paths
    return struct(
        library = struct(
            tags = context.tags,
            operating_system = context.operating_system,
            cpu = context.cpu,
            environment = context.environment,
            link_kind = classified.link_kind,
            file = library_file,
            resource_path = library_path,
            cc_info = classified.cc_info,
            runtime_dependencies = {
                path: file
                for path, file in placement.resource_paths.items()
                if path != library_path and not path.startswith(library_path + "/")
            },
            beside_executable = data.beside_executable,
            debug_symbols = linked_dsym(target),
        ),
        resource_paths = placement.resource_paths,
        dependency_paths = sorted(dependency_paths),
    )

def _require_minimum_os_versions(minimum_os_versions):
    """Fail unless the keys are macos or ios and the values dotted numeric versions."""
    for operating_system, version in minimum_os_versions.items():
        if operating_system not in ["macos", "ios"]:
            fail("minimum_os_versions keys must be macos or ios; got %s" % operating_system)
        if not dotted_version(version):
            fail("minimum_os_versions[%s] must be a dotted numeric version; got %r" % (operating_system, version))

def _write_descriptor(ctx, descriptor, configured):
    """Write the descriptor fragment with the entries of configured, a _configured_library or None."""
    library_lines = []
    dependency_lines = []
    if configured:
        # GDExtensionLibraryLoader detects .a before passing an empty path to
        # OS_AppleEmbedded for RTLD_SELF. The descriptor itself must be nonempty.
        library_lines.append(configured.library.tags + " = " + json.encode("res://" + configured.library.resource_path))
        if configured.dependency_paths:
            dependency_lines.append("%s = {%s}" % (configured.library.tags, ", ".join([
                "%s: %s" % (json.encode("res://" + path), json.encode(""))
                for path in configured.dependency_paths
            ])))
    ctx.actions.expand_template(
        template = ctx.file._descriptor_template,
        output = descriptor,
        substitutions = {
            "{ENTRY_SYMBOL}": json.encode(ctx.attr.entry_symbol),
            "{COMPATIBILITY_MINIMUM}": json.encode(ctx.attr.compatibility_minimum),
            "{RELOADABLE}": "true" if ctx.attr.reloadable else "false",
            "{LIBRARIES}": "\n".join(library_lines),
            # A section of its own, set off by blank lines, or nothing.
            "{DEPENDENCIES}": "\n[dependencies]\n\n%s\n" % "\n".join(
                dependency_lines,
            ) if dependency_lines else "",
        },
    )

def _library_providers(ctx, library):
    """Return the providers that expose the library's C++ graph and frameworks; none without a library."""
    if not library:
        return []
    providers = []

    # Expose the C++ graph of a static library or framework to rules_apple or a custom
    # native application.
    if library.cc_info:
        providers.append(library.cc_info)

    # Godot loads a framework at run time, so an Apple application embeds and signs it
    # without linking it. rules_apple's framework aspect stops at a target with this
    # provider, so it carries the frameworks of the platform libraries too.
    if library.link_kind == "framework":
        providers.append(apple_provider.merge_apple_framework_import_info([
            target[AppleFrameworkImportInfo]
            for target in ctx.attr.library + getattr(ctx.attr, "deps", [])
            if AppleFrameworkImportInfo in target
        ]))
    return providers

def _extension_impl(ctx):
    require_supported_godot_minimum(ctx.attr.compatibility_minimum)
    resource = _resource_path(ctx.attr.resource_path)
    if not resource.endswith(".gdextension"):
        fail("resource_path must end in .gdextension")
    _require_minimum_os_versions(ctx.attr.minimum_os_versions)
    directory, separator, _ = resource.rpartition("/")
    prefix = directory + separator
    descriptor = ctx.actions.declare_file(ctx.label.name + ".gdextension")
    configured = None
    resource_paths = {}

    # A label attribute with a Starlark transition arrives as a list, empty for None.
    if ctx.attr.library:
        configured = _configured_library(ctx, ctx.attr.library[0], prefix, _configured_context(ctx))
        resource_paths = {resource: descriptor} | configured.resource_paths
    elif ctx.files.data:
        fail("%s: data needs a library in this configuration" % ctx.label)
    _write_descriptor(ctx, descriptor, configured)
    library = configured.library if configured else None
    files = depset([descriptor] + resource_paths.values())

    # The tool view's own provider leaves the editor fields empty; only the extension's
    # are read.
    tool_view = getattr(ctx.attr, "tool_view", None)
    host_tool_view = getattr(ctx.attr, "host_tool_view", None)
    extension = GodotExtensionInfo(
        files = files,
        library = library,
        minimum_os_versions = dict(ctx.attr.minimum_os_versions),
        runtime_resource_paths = resource_paths,
        editor_resource_paths = tool_view[GodotExtensionInfo].runtime_resource_paths if tool_view else {},
        host_editor_resource_paths = host_tool_view[GodotExtensionInfo].runtime_resource_paths if host_tool_view else {},
        runtime_descriptor = descriptor,
        descriptor_path = resource,
        entry_symbol = ctx.attr.entry_symbol,
        platform_libraries = getattr(ctx.attr, "deps", []),
        platform_contributions = struct(infoplists = depset(getattr(ctx.files, "infoplists", []))),
    )
    providers = [DefaultInfo(files = files), extension]
    if tool_view:
        # Used by itself, the extension is an add-on of only that extension.
        providers.append(extension_addon(ctx.label, extension))
    return providers + _library_providers(ctx, library)

_OWN_ATTRS = {
    "library": attr.label(
        doc = """
        The extension library of each configuration, varied with select() over platform
        constraints and @autoload_rules_godot//godot:debug, :release, :editor and :tool: a linked
        library from any rule, which the extension takes as it is and never links.
        Accepted: a shared library (cc_shared_library, cc_import(shared_library),
        cc_binary(linkshared) or a target with one .so, .dylib or .dll file), a static library on iOS (cc_library,
        cc_import(static_library), apple_static_xcframework_import) and a dynamic
        framework on iOS and macOS (apple_dynamic_xcframework_import,
        apple_dynamic_framework_import, with bundle_only = True as the GDExtension guide
        describes). Shared libraries that its CcInfo links, the shared libraries in a
        linked library's runfiles and the other frameworks of an Apple import that links
        its own are its runtime dependencies. None leaves the extension without a
        library in that configuration. Targets link without Bazel's --strip:
        applications strip the copy they package and provide this one as debug symbols.
        """,
        allow_files = True,
        cfg = keep_debug_info,
    ),
    "data": attr.label_list(
        doc = """
        Files the descriptor's [dependencies] lists beyond what the library's providers
        imply, such as a crash handler executable. Shared libraries lie beside the
        library, which loads them by name. Other files lie at their path relative to the
        package of the target that lists them, below the descriptor's directory, as a
        vendor's add-on lays them out; desktop applications place them beside the
        executable, in Contents/Frameworks on macOS, as Godot's export does. Files keep
        their executable bit. Android takes only lib*.so files; iOS takes none and fails,
        since its applications deliver files through platform libraries in platform_deps.
        """,
        allow_files = True,
    ),
    "resource_path": attr.string(
        doc = """
        Resource path of the .gdextension descriptor, for a vendor's layout; empty uses
        addons/<name>/<name>.gdextension, as Godot add-ons place theirs. The libraries
        lie in bin/<feature tags>/ beside it.
        """,
    ),
    "entry_symbol": attr.string(
        doc = "Exported Godot initialization function, identical for every extension library.",
        mandatory = True,
    ),
    "compatibility_minimum": attr.string(
        doc = """
        Oldest compatible canonical Godot version written into the descriptor; must be
        supported by this ruleset.
        """,
        default = "4.7.2",
    ),
    "reloadable": attr.bool(
        doc = "Whether the Godot editor may reload this extension after rebuilding its library.",
        default = False,
    ),
    "minimum_os_versions": attr.string_dict(
        doc = """
        Minimum operating-system versions the extension libraries need, by Godot
        platform: macos and ios, as dotted numeric versions. A godot_app that packages
        the extension for that operating system fails when its own minimum is lower.
        Empty where the libraries run on every version the engine supports.
        """,
    ),
    "_descriptor_template": attr.label(
        default = Label("//godot/extension:descriptor.gdextension.tpl"),
        allow_single_file = True,
    ),
    "_tool": attr.label(default = Label("//godot/private/config:tool"), providers = [FlagInfo]),
} | PLATFORM_ATTRS | VARIANT_ATTRS

# The tool view: the extension in the tool configuration. Editor actions reach it on
# their execution platform and godot_editor and bazel run on the host.
_tool_view = rule(
    doc = "An extension in the tool configuration, for the editor processes that load it.",
    implementation = _extension_impl,
    attrs = _OWN_ATTRS,
    cfg = tool_transition,
)

_EXTENSION_ATTRS = _OWN_ATTRS | {
    "infoplists": attr.label_list(
        doc = """
        Info.plist fragments iOS applications merge into their Info.plist for the
        extension's native code, such as the usage descriptions or SDK keys a native
        backend reads. They reach applications as an add-on's infoplists do, whether the
        extension is used by itself or in an add-on's deps; two fragments with different
        values for a key fail, and the application's own ios_infoplists win.
        """,
        allow_files = [".plist"],
    ),
    "deps": attr.label_list(
        doc = """
        Android or Apple platform libraries the extension's native code needs at
        runtime, such as an aar_import, a Maven artifact or an XCFramework
        import. godot_app links and packages them for every pack containing the
        extension.
        """,
        # The frameworks of Objective-C and Swift libraries, for an extension that
        # provides AppleFrameworkImportInfo.
        aspects = [framework_provider_aspect, manifest_graph_aspect],
        providers = [[JavaInfo], [CcInfo]],
    ),
    "tool_view": attr.label(
        doc = "The extension's tool view on the execution platform of editor actions; the extension macros set it.",
        cfg = config.exec("editor"),
        providers = [GodotExtensionInfo],
        mandatory = True,
    ),
    "host_tool_view": attr.label(
        doc = "The extension's tool view on the host; the extension macros set it.",
        cfg = config.exec("run"),
        providers = [GodotExtensionInfo],
        mandatory = True,
    ),
}

# The execution platform of editor actions, as godot_project resolves it, and the host's,
# as godot_editor and bazel run resolve it.
_EXEC_GROUPS = RUN_EXEC_GROUPS | {"editor": exec_group(toolchains = [EDITOR_TOOLCHAIN])}

_extension = rule(
    doc = """
    Generate a Godot descriptor fragment for the configured extension library and give
    godot_project its files' resource paths.
    """,
    implementation = _extension_impl,
    attrs = _EXTENSION_ATTRS | TRANSITION_ATTRS,
    exec_groups = _EXEC_GROUPS,
    # Native code builds once, whatever the number of project contexts reaching it.
    cfg = reset_transition,
)

# rules_apple's resource aspect follows implementation_deps and collects the resources it
# finds there; the extension itself reads nothing from it.
_source_extension = rule(
    doc = "A godot_extension whose library godot_cc_extension builds.",
    implementation = _extension_impl,
    attrs = _EXTENSION_ATTRS | {
        "implementation_deps": attr.label_list(
            doc = """
            The extension's cc_library on iOS, so that iOS applications bundle the Apple
            resources of its native dependencies, such as a Swift package's resource
            bundle. The godot_cc_extension macro sets it; it adds nothing to linking.
            """,
            cfg = keep_debug_info,
        ),
    } | TRANSITION_ATTRS,
    exec_groups = _EXEC_GROUPS,
    cfg = reset_transition,
)

_VIEW_ATTRS = ["library", "data", "resource_path", "entry_symbol", "compatibility_minimum", "reloadable", "testonly"]

def _tool_view_of(name, kwargs):
    """
    Declare the tool view of extension name and return the attributes that reach it.

    Both point at the same resource path: the extension's, by default
    addons/<name>/<name>.gdextension.
    """
    kwargs = kwargs | {"resource_path": kwargs.get("resource_path") or "addons/%s/%s.gdextension" % (name, name)}
    _tool_view(
        name = name + ".tool",
        visibility = ["//visibility:private"],
        # Only the extension's tool_view and host_tool_view reach it.
        tags = (kwargs.get("tags") or []) + ["manual"],
        **{key: value for key, value in kwargs.items() if key in _VIEW_ATTRS}
    )
    return kwargs | {"tool_view": ":" + name + ".tool", "host_tool_view": ":" + name + ".tool"}

def _godot_extension_impl(name, visibility, platform_deps, **kwargs):
    _extension(
        name = name,
        visibility = visibility,
        deps = platform_deps,
        **_tool_view_of(name, kwargs)
    )

godot_extension = macro(
    doc = """
    Declare a GDExtension by its library in each configuration.

    The library varies with select() over platform constraints and
    @autoload_rules_godot//godot:debug, :release, :editor and :tool; the extension derives its Godot
    feature tags from the configuration, the link kind from the library's providers and
    its runtime dependencies from the library and data. Each configuration writes a
    descriptor fragment with its one library entry; packs merge the fragments of their
    platform slices. The extension takes the library as another rule linked it, in any
    language, and links nothing itself; godot_cc_extension is the C++ shorthand. Editor
    actions and the host editor load the library of the tool configuration, where
    @autoload_rules_godot//godot:tool and :editor match; a select() with a branch for each
    execution platform's operating system needs no tool branch. Platform libraries that
    the native code uses without linking them, and their resources, follow platform_deps
    to every application shipping a pack that contains the extension. By itself the
    extension is an add-on of only that extension: resources list it in deps, a project
    names it in deps. See [extensions](../../gdextension.md).

    Example:
    ```starlark
    godot_extension(
        name = "sentry",
        library = select({
            ":linux_x86_64": ":libsentry_linux_x86_64",
            ":android_arm64": ":libsentry_android_arm64",
            "@platforms//os:macos": ":libsentry_macos",
        }),
        # What Sentry's descriptor lists under [dependencies] for Linux: at
        # res://addons/sentry/bin/linux/crashpad_handler, beside the executable of an
        # application.
        data = select({
            ":linux_x86_64": ["bin/linux/crashpad_handler"],
            "//conditions:default": [],
        }),
        entry_symbol = "gdextension_init",
    )
    ```

    ### Default outputs
    - files (many): build the descriptor fragment, the extension library and its runtime dependencies; no run behavior
    """,
    inherit_attrs = _extension,
    attrs = {
        "deps": None,
        "tool_view": None,
        "host_tool_view": None,
        "platform_deps": attr.label_list(
            doc = "Android or Apple platform libraries and their resources that the extension's native code uses without linking them, such as an Android plugin it fetches through Engine::get_singleton(), accepted through JavaInfo or CcInfo. Empty by default; select only libraries for the operating systems the extension supports. A dynamic framework the library loads, as a bundle_only Apple import, belongs here too; libraries the code links belong to the library's C++ deps.",
            providers = [[JavaInfo], [CcInfo]],
            default = [],
        ),
    },
    implementation = _godot_extension_impl,
)

def godot_cc_extension(
        name,
        srcs,
        entry_symbol,
        deps = [],
        hdrs = [],
        data = [],
        resource_path = "",
        compatibility_minimum = "4.7.2",
        reloadable = False,
        minimum_os_versions = {},
        visibility = None,
        tags = [],
        platform_deps = [],
        infoplists = [],
        ios_linkage = "framework",
        ios_bundle_id = "",
        **kwargs):
    """
    Build C/C++ once as a cc_library, link it, and package it as a godot_extension.

    Every supported operating system takes a shared library linked from it that finds its
    shared dependencies beside it and exports only the entry symbol, so extensions in one
    process never run each other's godot-cpp. On iOS the shared library is the binary of a
    dynamic framework the application embeds and signs; with ios_linkage = "static", iOS
    takes the archive instead, which the application links, and the application's
    static extensions share one godot-cpp. Code
    linked by another rule, in any language, goes to godot_extension directly. godot_app
    links the extension and its C++ dependencies when one of the packs it ships contains
    it. Like godot_extension, the target is an add-on of only that extension.

    Creates the named godot_extension target and the private targets `<name>.native`,
    the cc_library, `lib<name>_native.so`, the shared library linked from it,
    `<name>.ios_framework`, the framework import of iOS, and `<name>.tool`, the extension in the tool configuration that editor actions and the
    host editor load. The public target exposes
    GodotExtensionInfo, DefaultInfo and, on iOS, CcInfo. It returns no Starlark value.
    Compilation uses rules_cc toolchains. The feature tags of the libraries derive from
    the target platform's operating system and CPU, the iOS environment and the
    variant; features in kwargs keeps its meaning as rules_cc toolchain features. An
    editor-specific backend is a select() over @autoload_rules_godot//godot:tool in deps.

    Example:
        godot_cc_extension(
            name = "extension",
            srcs = ["extension.cpp"],
            deps = ["@godot_cpp//:godot_cpp"],
            entry_symbol = "my_extension_init",
        )

    See [a complete C++ extension](../../gdextension.md).

    ### Default outputs
    - files (many): build the descriptor fragment, the extension library and its runtime dependencies; no run behavior

    Args:
        name: Public extension target.
        srcs: C/C++ source labels.
        entry_symbol: Exported Godot entry function.
        deps: rules_cc dependencies; shared libraries among them are runtime
            dependencies placed beside the extension library.
        hdrs: Private extension headers.
        data: Files the descriptor's [dependencies] lists beyond the libraries deps
            link, as godot_extension's data.
        resource_path: Resource path of the descriptor; empty uses
            addons/<name>/<name>.gdextension.
        compatibility_minimum: Oldest compatible Godot version.
        reloadable: Enable Godot editor reloading.
        minimum_os_versions: Minimum operating-system versions the extension libraries
            need, by Godot platform (macos, ios); a godot_app whose minimum is lower fails.
        visibility: Public extension visibility.
        tags: Bazel target tags.
        platform_deps: Android or Apple platform libraries the extension's native code
            uses without linking them; godot_extension's platform_deps. Libraries it
            links belong to deps.
        infoplists: Info.plist fragments for the extension's native code;
            godot_extension's infoplists.
        ios_linkage: How iOS applications take the extension: "framework", the
            default, embeds a dynamic framework named after the extension, with its own
            godot-cpp; "static" links the archive into the executable, where all static
            extensions share one godot-cpp and its main loop callbacks.
        ios_bundle_id: CFBundleIdentifier of the iOS framework; empty derives one from
            the extension's label.
        **kwargs: Additional cc_library attributes, such as copts, defines or
            linkopts; the attributes every rule has, such as features or
            exec_compatible_with, also reach the shared library, and the cc_binary
            attributes dynamic_deps, env, link_extra_lib, linkstatic, malloc,
            reexport_deps and stamp reach only it.
    """
    if ios_linkage not in ["framework", "static"]:
        fail("ios_linkage must be framework or static; got %r" % ios_linkage)
    archive = name + ".native"
    native_archive(archive, srcs, hdrs, deps, entry_symbol, tags, kwargs)
    attrs = kwargs | {"tags": tags}
    shared = shared_library(name, archive, entry_symbol, attrs)
    ios_library = ios_framework(name, shared, ios_bundle_id, generated_attrs(attrs)) if ios_linkage == "framework" else archive
    library = select({
        Label("@platforms//os:ios"): ":" + ios_library,
        "//conditions:default": ":" + shared,
    })
    _source_extension(
        name = name,
        minimum_os_versions = minimum_os_versions,
        implementation_deps = select({
            Label("@platforms//os:ios"): [":" + archive],
            "//conditions:default": [],
        }),
        deps = platform_deps,
        infoplists = infoplists,
        visibility = visibility,
        target_compatible_with = kwargs.get("target_compatible_with"),
        **_tool_view_of(name, dict(
            library = library,
            data = data,
            entry_symbol = entry_symbol,
            resource_path = resource_path,
            compatibility_minimum = compatibility_minimum,
            reloadable = reloadable,
            tags = tags,
            testonly = kwargs.get("testonly"),
        ))
    )
