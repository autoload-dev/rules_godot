"""
godot_cc_extension: the C++ shorthand over the extension primitives, which declares the
cc_library of the extension's code, its godot_extension_library and its godot_extension.
"""

load("@rules_cc//cc:cc_library.bzl", "cc_library")
load(":extension.bzl", "source_extension", "tool_view_of")
load(":extension_library.bzl", "godot_extension_library", "private_target_attrs", "rule_attrs")

visibility(["//godot/extension"])

def _cc_extension_impl(
        name,
        visibility,
        srcs,
        entry_symbol,
        deps,
        hdrs,
        data,
        resource_path,
        compatibility_minimum,
        reloadable,
        minimum_os_versions,
        tags,
        platform_deps,
        infoplists,
        ios_linkage,
        ios_bundle_id,
        linkstatic,
        **kwargs):
    # Unset attributes stay unset on the declared targets.
    kwargs = {key: value for key, value in kwargs.items() if value != None}
    tags = tags or []
    generated = private_target_attrs(kwargs, tags)
    code = name + ".native"

    # Linked whole, so static registrations survive every link.
    cc_library(
        name = code,
        srcs = srcs,
        hdrs = hdrs,
        deps = deps,
        alwayslink = True,
        linkstatic = True,
        **(kwargs | generated)
    )
    library = name + ".library"
    godot_extension_library(
        name = library,
        deps = [":" + code],
        entry_symbol = entry_symbol,
        library_name = name,
        ios_linkage = ios_linkage,
        ios_bundle_id = ios_bundle_id,
        # linkstatic reaches only the shared library; the cc_library always links statically.
        linkstatic = linkstatic,
        **(generated | rule_attrs(kwargs))
    )
    source_extension(
        name = name,
        minimum_os_versions = minimum_os_versions,
        implementation_deps = select({
            Label("@platforms//os:ios"): [":" + code],
            "//conditions:default": [],
        }),
        deps = platform_deps,
        infoplists = infoplists,
        visibility = visibility,
        target_compatible_with = kwargs.get("target_compatible_with"),
        **tool_view_of(name, dict(
            # No library where godot_extension_library links none, so applications there
            # report the extension as missing.
            library = select({
                Label("@platforms//os:" + operating_system): ":" + library
                for operating_system in ["android", "ios", "linux", "macos"]
            } | {"//conditions:default": None}),
            data = data,
            resource_path = resource_path,
            compatibility_minimum = compatibility_minimum,
            reloadable = reloadable,
            tags = tags,
            testonly = kwargs.get("testonly"),
        ))
    )

godot_cc_extension = macro(
    doc = """
    Build a C++ extension the same way on every platform: its code as a cc_library, the
    godot_extension_library linked from it and the godot_extension of that library.

    The macro declares the three parts and the extension's tool view; an extension that supports
    only some platforms, mixes prebuilt and built libraries or is written in another
    language declares them itself. On iOS the library is a dynamic framework the
    application embeds and signs; with ios_linkage = "static", iOS takes the archive
    instead, which the application links, and the application's static extensions share
    one godot-cpp. godot_app links the extension and its C++ dependencies when one of
    the packs it ships contains it. Like godot_extension, the target is an add-on of only
    that extension.

    Creates the named godot_extension target and the private targets `<name>.native`,
    the cc_library, `<name>.library`, the godot_extension_library, whose shared library
    applications deliver as `lib<name>.so` and whose iOS framework is `<name>.framework`,
    and `<name>.tool`, the extension in the tool configuration that editor actions and
    the host editor load. The public target exposes GodotExtensionInfo, DefaultInfo and,
    on iOS, CcInfo. copts, defines, local_defines, includes and linkopts reach the
    cc_library; the attributes every rule has, such as features or exec_compatible_with,
    also reach the library, and linkstatic reaches only the library. Compilation uses rules_cc
    toolchains. The feature tags of the libraries derive from the target platform's
    operating system and CPU, the iOS environment and the variant; features keeps its
    meaning as rules_cc toolchain features. An editor-specific backend is a select()
    over @autoload_rules_godot//godot:tool in deps.

    Example:
    ```starlark
    godot_cc_extension(
        name = "extension",
        srcs = ["extension.cpp"],
        deps = ["@godot_cpp//:godot_cpp"],
        entry_symbol = "my_extension_init",
    )
    ```

    See [a complete C++ extension](../../gdextension.md).
    """,
    implementation = _cc_extension_impl,
    inherit_attrs = "common",
    attrs = {
        "copts": attr.string_list(doc = "C/C++ compiler options of the extension's code, as cc_library's."),
        "defines": attr.string_list(
            doc = "Preprocessor definitions of the extension's code and its dependents, as cc_library's.",
        ),
        "local_defines": attr.string_list(
            doc = "Preprocessor definitions of the extension's code only, as cc_library's.",
        ),
        "includes": attr.string_list(doc = "Include directories of the extension's code, as cc_library's."),
        "linkopts": attr.string_list(doc = "Linker options of the extension's libraries, as cc_library's."),
        "linkstatic": attr.bool(
            doc = """
            Whether the shared library links its C++ dependencies statically, as cc_binary's;
            True by default, so the library needs no shared library of its dependencies.
            """,
            default = True,
        ),
        "srcs": attr.label_list(doc = "C/C++ source labels.", allow_files = True, mandatory = True),
        "entry_symbol": attr.string(
            doc = "Exported Godot entry function.",
            mandatory = True,
            configurable = False,
        ),
        "deps": attr.label_list(
            doc = """
            rules_cc dependencies; shared libraries among them are runtime dependencies
            placed beside the extension library, and iOS applications embed the dynamic
            frameworks they link, transitive ones included.
            """,
        ),
        "hdrs": attr.label_list(doc = "Private extension headers.", allow_files = True),
        "data": attr.label_list(
            doc = """
            Files the descriptor's [dependencies] lists beyond the libraries deps link, as
            godot_extension's data.
            """,
            allow_files = True,
        ),
        "resource_path": attr.string(
            doc = "Resource path of the descriptor; empty uses addons/<name>/<name>.gdextension.",
            configurable = False,
        ),
        "compatibility_minimum": attr.string(doc = "Oldest compatible Godot version.", default = "4.7.2"),
        "reloadable": attr.bool(doc = "Enable Godot editor reloading."),
        "minimum_os_versions": attr.string_dict(
            doc = """
            Minimum operating-system versions the extension libraries need, by Godot
            platform (macos, ios); a godot_app whose minimum is lower fails.
            """,
        ),
        "platform_deps": attr.label_list(
            doc = """
            Android or Apple platform libraries the extension's native code uses without
            linking them; godot_extension's platform_deps. Libraries it links belong to
            deps.
            """,
        ),
        "infoplists": attr.label_list(
            doc = "Info.plist fragments for the extension's native code; godot_extension's infoplists.",
            allow_files = True,
        ),
        "ios_linkage": attr.string(
            doc = """
            How iOS applications take the extension: "framework", the default, embeds a
            dynamic framework named after the extension, with its own godot-cpp; "static"
            links the archive into the executable, where all static extensions share one
            godot-cpp and its main loop callbacks.
            """,
            default = "framework",
            values = ["framework", "static"],
            configurable = False,
        ),
        "ios_bundle_id": attr.string(
            doc = "CFBundleIdentifier of the iOS framework; empty derives one from the extension's label.",
            configurable = False,
        ),
    },
)
