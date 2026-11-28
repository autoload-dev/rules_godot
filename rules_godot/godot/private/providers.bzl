"""
The ruleset's internal providers between resource, engine, extension and packaging rules.

They are not part of the public API: their fields follow the rules that produce and
consume them.
"""

visibility(["//godot/..."])

GodotResourcesInfo = provider(
    doc = """Godot resources, their import units and explicit dependency metadata. Produced by godot_resources and consumed by godot_resources and the operations that name them; an add-on's runtime and editor parts carry one each.""",
    fields = {
        "imports": "depset[File] of the import results of these resources and their dependencies under the context of the operation that reached them; empty without a context",
        "units": "list[dict] of import units, dependencies first: owner is a label string; outputs is list[string] of its own resource paths; deps is list[string] of nearest dependency unit owners",
        "unit_heads": "list[string] of the owner labels of the import units this target stands for when another unit depends on it: its own unit, or, without files of its own, the units its dependencies stand for; a dependent unit imports after them",
        "resource_path_manifests": "depset of JSON resource path manifests, one per contributing target, that together map every path an import of these resources stages to its File's path",
        "member_resource_paths": "dict of resource paths to the source or generated Files of the members",
        "import_resource_paths": "dict of resource paths to the Files of the import inputs, disjoint from member_resource_paths",
        "member_owners": "dict[string, string] of the members' resource paths to the label strings declaring them",
        "import_owners": "dict[string, string] of the import inputs' resource paths to the label strings declaring them",
        "ignored_resource_paths": "dict of the resource paths of the members and import inputs Godot ignores to their Files: hidden ones and those below a directory whose .gdignore or project.godot the same target declares. Each target decides it once for its own files; staging still takes them from member_resource_paths and import_resource_paths",
        "relationships": "depset of (source, target, kind, owner) string tuples; runtime cycles are allowed",
        "addons": "postorder depset of GodotAddonInfo the files of these resources and their dependencies use, with the add-ons those need, dependencies first; never an import input",
        "class_fragments": "depset[File] of the class fragments of these resources' scripts and their dependencies', which validations merge into Godot's global script class cache; empty without a context",
        "interfaces": "depset[File] of the interfaces of these resources and their dependencies under the context, which their dependents' validations stage in place of the files interfaced_resource_paths names and of the import results; empty without a context",
        "interfaced_resource_paths": "depset[string] of the resource paths of the members that interfaces replace for dependents' validations: scripts, imported assets and their .import files; empty without a context",
        "validations": "depset[File] of the validation outputs of these resources and their dependencies under the context, each in its target's _validation output group; empty without a context",
    },
)

GodotAddonInfo = provider(
    doc = """An add-on: its runtime part, its editor part with its roles, its extensions, platform libraries and Info.plist fragments, its autoloads and settings, and the add-ons it needs. Produced by godot_addon and, as an add-on of only that extension, by godot_extension and godot_cc_extension; consumed by resources that use it, projects that name it and the operations containing it.""",
    fields = {
        "label": "Label of the add-on",
        "directory": "string: resource path of the directory every file of the add-on lives below, without a trailing slash; empty for an extension-only add-on, whose files are its extension's",
        "runtime_files": "GodotResourcesInfo of the runtime part: members of every operation containing the add-on, one import unit owned by the add-on",
        "editor_files": "GodotResourcesInfo of the editor part: the plugin.cfg and the files its editor plugin loads, which only the Godot processes of its roles stage and no pack, source run or application contains",
        "plugin_config": "string: resource path of the editor part's plugin.cfg, or empty without an editor part",
        "importer_suffixes": "sorted list[string] of the lowercase file suffixes, without a dot, the add-on's importers convert; empty without an importer role",
        "importer_resource_paths": "dict of resource paths to the Files an importer of the add-on needs to run: both parts of the add-on and of the add-ons it needs, and the editor files of their extensions; empty without an importer role",
        "importer_resource_path_manifest": "JSON File of importer_resource_paths by execution path, which the imports staging the importer read; None without an importer role and under a context, since imports take the add-on from their project's index",
        "import_settings": "sorted list of the keys of its settings its importer reads at import time, which the Godot processes staging the importer set",
        "extensions": "list of GodotExtensionInfo of the extensions in the add-on's deps",
        "platform_libraries": "list[Target] of Android and Apple libraries of the add-on and its extensions, sorted by label",
        "platform_contributions": "struct with infoplists, a depset[File] of Info.plist fragments applications merge",
        "autoloads": "list of (name, res:// path, owner) autoload contributions, in declaration order",
        "settings": "list of (key, Godot literal, owner) setting contributions",
        "addons": "postorder depset of GodotAddonInfo the add-on needs, with the add-ons those need, dependencies first",
    },
)

GodotProjectInfo = provider(
    doc = """The configuration context of one product: its authored project.godot, settings, autoloads, main scene and the add-ons it names. Produced by godot_project; operations name it as their project, and resources import under the context their operation sets.""",
    fields = {
        "label": "Label of the godot_project, or of //godot/private:no_project for no context",
        "import_configuration": "project.godot File every import of the context reads: the authored file, the project's settings and the import settings of the add-ons it names, filtered by the import purpose; None for no context",
        "importable": "tree artifact File listing the file suffixes Godot imports under this context, the importers of the add-ons it names included, one empty file per suffix; None for no context",
        "importers": "dict of lowercase file suffixes to the GodotAddonInfo, outside every context, of the add-ons the project names whose importer role declares that suffix, in the order of named_addons",
        "authored_project_file": "project.godot File the configuration starts from, as declared; None for no context",
        "authored_autoloads": "JSON File of the authored project.godot's autoloads, name to value as written, which content validations register; None for no context",
        "settings": "dict[string, string] of the project's own settings, section/property to Godot literal",
        "setting_overrides": "dict[string, string] of settings replacing conflicting contributions",
        "autoloads": "dict[string, string] of the project's own autoloads, name to res:// path",
        "autoload_overrides": "dict[string, string] of autoloads replacing conflicting contributions",
        "main_scene": "string: declared resource path of the main scene, or empty",
        "context_files": "dict of resource paths to the Files bound to the context, such as the application icon",
        "named_addons": "postorder depset of GodotAddonInfo of the add-ons the project names in deps, with the add-ons those need, dependencies first, reached outside every context; every operation of the project contains them and they import their parts under its context",
        "custom_features": "sorted list[string] of the Godot custom features the project's custom-feature build settings give in this configuration; packs export with them and source runs start with them; empty for no context",
        "flag_settings": "dict of the setting keys settings_from_flags sets to the Godot literals of the flags' values in this configuration; packs export with them and source runs start with them",
    },
)

GodotRuntimeInfo = provider(
    doc = """A prebuilt or source-built engine runtime for one target platform. Produced by export-template archives and source recipes; carried by runtime components and consumed by desktop packaging.""",
    fields = {
        "executable": "File of the executable runtime, or None when the runtime is an engine library",
        "files": "depset of runtime inputs",
        "platform": "string: the Godot platform, that is the operating system the runtime is for: linux, macos, ios or android",
        "cpu": "string: target CPU identifier, such as arm64 or x86_64",
        "environment": "string: device or simulator for iOS; empty for non-iOS runtimes",
        "facts_source": "string: where the runtime's facts come from: source for a source recipe, declared for a prebuilt or opaque payload",
        "origin": "string: producer or imported target label used in mismatch diagnostics",
        "version": "string: actual runtime version; declared imports use canonical versions, while source producers may retain an unnumbered prerelease channel",
        "bundle_files": "dict of desktop bundle-relative paths to the Files the runtime executable needs beside it",
        "variant": "string: release or debug, the Godot template variant of the runtime",
        "debug_symbols": "File or None: .dSYM directory the linker wrote for a source recipe executable, as rules_cc's cc_binary does on Apple platforms with --apple_generate_dsym",
        "minimum_os": "string: the deployment target the runtime was built for on Apple platforms, such as 11.0 for a macOS source recipe; empty where the producer does not declare one, as for prebuilt and imported payloads",
    },
)

GodotComponentInfo = provider(
    doc = """The provenance of one engine component slot. Produced by godot_editor_component/godot_runtime_component; carried as provenance on the resolved editor and runtime toolchains for diagnostics, never as a compatibility condition.""",
    fields = {
        "component": "string: label of the component that declares the payload",
        "engine": "string: name of the engine the component belongs to; empty for the default engine, named or not",
        "role": "string: editor or runtime",
        "platform": "string: the Godot platform, that is the operating system of the editor platform for editors and of the target platform for runtimes: linux, macos, ios or android",
        "cpu": "string: arm64 or x86_64",
        "environment": "string: device or simulator for iOS runtimes; empty otherwise",
        "variant": "string: debug or release for runtimes; empty for editors",
        "version": "string: producer version where known, otherwise the declared version",
        "kind": "string: source for source-built payloads, prebuilt otherwise",
        "origin": "string: producer or payload label",
        "digest": "string: source or artifact content digest where the producer supplies one; empty when unknown",
        "customizations": "dict of requested build customization (patches, modules, options) where the producer supplies it; empty otherwise",
        "renderers": "list of the rendering methods a source-built runtime runs where its recipe declares renderers, or None: the one fact applications check, their project's rendering method against it, since Godot has no fallback for a missing renderer",
    },
)

GodotExtensionInfo = provider(
    doc = """A GDExtension in one configuration: its configured extension library, its descriptor fragment and the resource paths of both, and those of its tool view. Produced by godot_extension/godot_cc_extension; consumed by resources, projects and application rules.""",
    fields = {
        "label": "string: the extension's label, as applications name it when it has no library for their platform",
        "files": "depset of the descriptor fragment, the configured extension library and its runtime dependencies",
        "library": """struct, or None where the extension has no library in this configuration: the configured extension library, with
            tags (string: Godot's feature tags of the configuration joined with '.', such as android.arm64.release),
            operating_system (linux, macos, android or ios),
            cpu (Godot's CPU tag, such as arm32 or arm64),
            environment (device or simulator on iOS, otherwise empty),
            link_kind (static, dynamic or framework, from the library's providers),
            file (File: the static archive, shared library or framework binary),
            resource_path (string: where the descriptor fragment names it),
            cc_info (CcInfo that links a static library or framework, otherwise None),
            runtime_dependencies (dict of resource paths to the Files it needs at run time: dynamic libraries and frameworks of its providers and the extension's shared libraries in data, beside the library, and the extension's other data),
            beside_executable (list of the resource paths of the extension's data that is no shared library, which desktop applications place beside the executable),
            debug_symbols (File: the .dSYM directory the linker wrote for it, or None)""",
        "runtime_resource_paths": "dict of resource paths to the Files that packs, source runs and applications place in the project: the descriptor fragment, the configured extension library and its runtime dependencies; empty where the extension has no library in this configuration",
        "editor_resource_paths": "dict of resource paths to the Files editor actions such as exports stage: the runtime_resource_paths of the tool view, configured for their execution platform; empty where the tool configuration has no library",
        "host_editor_resource_paths": "dict of resource paths to the Files of the tool view configured for the host, which godot_editor and bazel run for a target platform the host cannot run stage",
        "runtime_descriptor": "the descriptor fragment File of this configuration: one [libraries] entry and its [dependencies] entry with the configuration's feature tags. Packs merge the fragments of their platform slices",
        "descriptor_path": "the resource path of the descriptor in runtime_resource_paths, editor_resource_paths and host_editor_resource_paths",
        "entry_symbol": "string: GDExtension initialization symbol shared by all extension libraries",
        "platform_libraries": "list[Target] of Android and Apple libraries from the extension's deps that applications link and package",
        "platform_contributions": "struct with infoplists, a depset[File] of the Info.plist fragments iOS applications merge for the extension, as GodotAddonInfo.platform_contributions",
        "minimum_os_versions": "dict of macos and ios to the minimum operating-system version the extension's libraries need there; an application whose minimum is lower fails. Empty where the libraries run on every version the engine supports",
    },
)
