"""
Public providers of the applications and packs godot_pack and godot_app build.

Read them in a consuming rule's implementation after declaring a provider constraint on
the input attribute, for example to deploy a pack or a desktop application.

Example:
```starlark
load("@autoload_rules_godot//godot:providers.bzl", "GodotPackInfo")

def _consume_impl(ctx):
    pack = ctx.attr.pack[GodotPackInfo]
    return [DefaultInfo(files = depset([pack.pack_file]))]

consume_pack = rule(
    implementation = _consume_impl,
    attrs = {"pack": attr.label(providers = [GodotPackInfo])},
)
```
"""

GodotPackInfo = provider(
    doc = """A Godot-exported PCK and its declared project. Produced by godot_pack; consumed by run/test rules and application rules.""",
    fields = {
        "pack_file": "File: exported .pck with extension descriptors but no extension libraries",
        "pack_files": "depset[File] of PCK outputs",
        "project": "what the pack delivers in the current platform slice: member_resource_paths, which include the project's context files, runtime_extensions, export_extensions, platform_libraries and infoplists; common content is exported separately",
        "operating_system": "string: the operating system the pack is exported for: linux, macos, android or ios",
        "cpus": "list[string]: canonical full requested CPU set",
        "environment": "string: device or simulator for iOS, otherwise empty",
        "available": "depset of JSON Files {pack, resources} of this pack and every pack it requires; resources maps each contained path to its source path",
        "export_options": "dict[string, string] of the export preset options the pack sets, as Godot literals",
        "facts": "File: JSON of what Godot decides for the pack's export, which application rules write their shell files from: features, the export's feature tags; options, every export option of the operating system with its value or default; settings, the project settings with the export's feature overrides; versions, the values of the version options as Godot's exporter reads them; name_translations, the project's name by locale of its translations",
        "version": "string: canonical version of the editor that exported the pack; diagnostic only, never compared with the runtime",
        "editor_component": "provenance of the editor component that exported the pack: label (component), kind, version, origin, digest and customizations",
        "variant": "string: release or debug, the template variant of the export and of the runtime it needs; debug in the editor variant",
        "icons": "list[File] of the application icons Godot renders for the pack's operating system, which only applications using them build: for Android a resource directory with the launcher icons, for iOS an asset catalog with the AppIcon set, for macOS a directory with icon.icns; empty for other operating systems",
        "splash": "list[File] of the splash images Godot renders for the pack's operating system: for Android a resource directory with the splash screen's drawables, for iOS an asset catalog with the launch screen's SplashImage, Godot's boot splash unless the project sets one; empty for other operating systems",
    },
)

GodotDesktopAppInfo = provider(
    doc = """
    Selected desktop application bundle and distributable archive.

    Produced by godot_app on desktops; macOS fields refer to the unsigned or signed
    bundle the macos_signing setting selects. executable_path stays relative to that
    bundle.
    In a consuming rule implementation, read `ctx.attr.app[GodotDesktopAppInfo].archive`
    to obtain the distributable File. The bundle field contains the application
    tree artifact; executable_path locates the runtime executable inside it.
    """,
    fields = {
        "bundle": "File: tree artifact containing the application directory.",
        "archive": "File: deterministic ZIP (macos) or tar.gz (linux) distribution archive.",
        "operating_system": "string: linux or macos.",
        "executable_path": "string: POSIX executable path relative to the bundle root.",
        "runtime_component": "provenance of the runtime component packaged in the bundle, with the fields of editor_component of GodotPackInfo, or None for an opaque runtime",
    },
)

GodotWebAppInfo = provider(
    doc = """
    A web application: the directory of Godot's web export and its archive.

    Produced by godot_app for a web export platform. A rule that deploys or starts the
    application reads `ctx.attr.app[GodotWebAppInfo]`: it serves the bundle as it is and
    opens its entry_point, and sends the headers cross_origin_isolation names.
    """,
    fields = {
        "bundle": "File: tree artifact with the files of Godot's web export, named after the page.",
        "archive": "File: deterministic ZIP of the bundle's files, as static hosts and itch.io take it.",
        "entry_point": "string: the page to open, relative to the bundle: index.html.",
        "cross_origin_isolation": "string: what the host must do for the application to start: none without threads.",
        "runtime_component": "provenance of the runtime component packaged in the bundle, with the fields of editor_component of GodotPackInfo, or None for an opaque runtime",
    },
)
