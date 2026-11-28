"""
godot_extension: the rule that writes an extension's descriptor fragment for its configured
library and gives projects its files' resource paths, its tool view, and the macro that
declares both.
"""

load("@rules_apple//apple:aspects.bzl", "framework_provider_aspect")
load("@rules_apple//apple:providers.bzl", "AppleFrameworkImportInfo", "apple_provider")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//godot/platforms/private:manifest_graph.bzl", "manifest_graph_aspect")
load("//godot/private:addon.bzl", "extension_addon")
load("//godot/private:context.bzl", "reset_transition")
load("//godot/private:execution.bzl", "EDITOR_TOOLCHAIN", "RUN_EXEC_GROUPS")
load("//godot/private:macros.bzl", "CALLER_PACKAGE")
load("//godot/private:providers.bzl", "GodotExtensionInfo")
load("//godot/private:symbols.bzl", "keep_debug_info")
load("//godot/private:versions.bzl", "dotted_version", "require_supported_godot_minimum")
load("//godot/private/config:transitions.bzl", "tool_transition")
load(":extension_library.bzl", "GodotExtensionLibraryInfo")
load(":library.bzl", "LIBRARY_ATTRS", "configured_library", "library_context")

visibility(["//godot/extension"])

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

def _require_minimum_os_versions(minimum_os_versions):
    """Fail unless the keys are macos or ios and the values dotted numeric versions."""
    for operating_system, version in minimum_os_versions.items():
        if operating_system not in ["macos", "ios"]:
            fail("minimum_os_versions keys must be macos or ios; got %s" % operating_system)
        if not dotted_version(version):
            fail("minimum_os_versions[%s] must be a dotted numeric version; got %r" % (operating_system, version))

def _resolved_library(ctx, target):
    """
    Return the configured library's target, entry symbol and linked frameworks.

    The frameworks are the AppleFrameworkImportInfo of those a godot_extension_library's
    code links.

    A godot_extension_library carries its entry symbol. A library from any other rule, or
    a prebuilt file, carries none, so the extension names it.
    """
    if GodotExtensionLibraryInfo in target:
        info = target[GodotExtensionLibraryInfo]
        if ctx.attr.entry_symbol and ctx.attr.entry_symbol != info.entry_symbol:
            fail("%s: the entry symbol %s differs from %s, the entry symbol of %s" % (
                ctx.label,
                ctx.attr.entry_symbol,
                info.entry_symbol,
                target.label,
            ))
        return info.library, info.entry_symbol, info.frameworks
    if not ctx.attr.entry_symbol:
        fail("%s: %s carries no entry symbol; name it with entry_symbol" % (ctx.label, target.label))
    return target, ctx.attr.entry_symbol, []

def _write_descriptor(ctx, descriptor, configured, entry_symbol):
    """Write the descriptor fragment with the entries of configured, a configured_library or None."""
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
            "{ENTRY_SYMBOL}": json.encode(entry_symbol),
            "{COMPATIBILITY_MINIMUM}": json.encode(ctx.attr.compatibility_minimum),
            "{RELOADABLE}": "true" if ctx.attr.reloadable else "false",
            "{LIBRARIES}": "\n".join(library_lines),
            # A section of its own, set off by blank lines, or nothing.
            "{DEPENDENCIES}": "\n[dependencies]\n\n%s\n" % "\n".join(
                dependency_lines,
            ) if dependency_lines else "",
        },
    )

def _library_providers(ctx, target, library, linked_frameworks):
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
    # provider, so it carries the frameworks of the platform libraries too, and those the
    # library links, which the application embeds once however many extensions link them.
    if library.link_kind == "framework":
        sources = (
            [target] +
            getattr(ctx.attr, "deps", []) +
            getattr(ctx.attr, "implementation_deps", [])
        )
        providers.append(apple_provider.merge_apple_framework_import_info([
            target[AppleFrameworkImportInfo]
            for target in sources
            if AppleFrameworkImportInfo in target
        ] + linked_frameworks))
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
    target = None
    entry_symbol = ctx.attr.entry_symbol
    linked_frameworks = []
    resource_paths = {}

    # A label attribute with a Starlark transition arrives as a list, empty for None.
    if ctx.attr.library:
        target, entry_symbol, linked_frameworks = _resolved_library(ctx, ctx.attr.library[0])
        configured = configured_library(ctx, target, prefix, library_context(ctx))
        resource_paths = {resource: descriptor} | configured.resource_paths
    elif ctx.files.data:
        fail("%s: data needs a library in this configuration" % ctx.label)
    _write_descriptor(ctx, descriptor, configured, entry_symbol)
    library = configured.library if configured else None
    files = depset([descriptor] + resource_paths.values())

    # The tool view's own provider leaves the editor fields empty; only the extension's
    # are read.
    tool_view = getattr(ctx.attr, "tool_view", None)
    host_tool_view = getattr(ctx.attr, "host_tool_view", None)
    extension = GodotExtensionInfo(
        label = str(ctx.label).removeprefix("@@"),
        files = files,
        library = library,
        minimum_os_versions = dict(ctx.attr.minimum_os_versions),
        runtime_resource_paths = resource_paths,
        editor_resource_paths = tool_view[GodotExtensionInfo].runtime_resource_paths if tool_view else {},
        host_editor_resource_paths = host_tool_view[GodotExtensionInfo].runtime_resource_paths if host_tool_view else {},
        runtime_descriptor = descriptor,
        descriptor_path = resource,
        entry_symbol = entry_symbol,
        platform_libraries = getattr(ctx.attr, "deps", []),
        platform_contributions = struct(infoplists = depset(getattr(ctx.files, "infoplists", []))),
    )
    providers = [DefaultInfo(files = files), extension]
    if tool_view:
        # Used by itself, the extension is an add-on of only that extension.
        providers.append(extension_addon(ctx.label, extension))
    return providers + _library_providers(ctx, target, library, linked_frameworks)

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
        doc = """
        Exported Godot initialization function, identical for every extension library.
        Needed only when the library comes from another rule or is a prebuilt file; a
        godot_extension_library passes its own on, and a value set beside one must equal
        it.
        """,
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
        default = Label(":descriptor.gdextension.tpl"),
        allow_single_file = True,
    ),
} | LIBRARY_ATTRS

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
    attrs = _EXTENSION_ATTRS,
    exec_groups = _EXEC_GROUPS,
    # Native code builds once, whatever the number of project contexts reaching it.
    cfg = reset_transition,
)

# rules_apple's resource aspect follows implementation_deps and collects the resources it
# finds there; the extension itself reads only the frameworks the library links from it.
source_extension = rule(
    doc = "A godot_extension whose library godot_cc_extension builds.",
    implementation = _extension_impl,
    attrs = _EXTENSION_ATTRS | {
        "implementation_deps": attr.label_list(
            doc = """
            The extension's cc_library on iOS, so that iOS applications bundle the Apple
            resources of its native dependencies, such as a Swift package's resource
            bundle, and embed the dynamic frameworks it links, transitive ones included.
            The godot_cc_extension macro sets it; it adds nothing to linking.
            """,
            # The frameworks the extension's framework links, as deps collects them.
            aspects = [framework_provider_aspect],
            cfg = keep_debug_info,
        ),
    },
    exec_groups = _EXEC_GROUPS,
    cfg = reset_transition,
)

_VIEW_ATTRS = ["library", "data", "resource_path", "entry_symbol", "compatibility_minimum", "reloadable", "testonly"]

def tool_view_of(name, kwargs):
    """
    Declare the tool view of extension name and return the attributes that reach it.

    Both point at the same resource path: the extension's, by default
    addons/<name>/<name>.gdextension.
    """
    kwargs = kwargs | {"resource_path": kwargs.get("resource_path") or "addons/%s/%s.gdextension" % (name, name)}
    _tool_view(
        name = name + ".tool",
        visibility = CALLER_PACKAGE,
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
        **tool_view_of(name, kwargs)
    )

godot_extension = macro(
    doc = """
    Declare a GDExtension by its library in each configuration.

    The library varies with select() over platform constraints and
    @autoload_rules_godot//godot:debug, :release, :editor and :tool; the extension derives its Godot
    feature tags from the configuration, the link kind from the library's providers and
    its runtime dependencies from the library and data. Each configuration writes a
    descriptor fragment with its one library entry; packs merge the fragments of their
    platform slices. The extension links nothing itself: it takes a
    godot_extension_library, or a library as another rule linked it, in any language, or
    a prebuilt file; godot_cc_extension is the C++ shorthand that declares the code, its
    library and the extension. Editor
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
