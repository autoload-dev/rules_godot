"""
Import units: the import of one unit's own files, its class fragment, interface and validation.

Sections: Unit import, Class fragment and interface, Validation.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//godot/private:actions.bzl", "PATH_MAPPING", "add_output_roots", "editor_manifest", "write_manifest")
load("//godot/private:configuration.bzl", "merge_configuration")
load("//godot/private:execution.bzl", "EDITOR_TOOLCHAIN")
load("//godot/private:metadata.bzl", "METADATA_ATTRS", "metadata_modes")
load("//godot/private:paths.bzl", "mapped_path", "mapped_paths", "merge_resource_paths", "with_extensions_for")

visibility(["//godot", "//godot/private/config"])

# ==== Unit import =============================================================

def _suffix(path):
    name = path.rpartition("/")[2]
    return name.rpartition(".")[2].lower() if "." in name else ""

def importers_of(context, paths):
    """
    The add-ons whose importers convert some of these files (FR-017).

    Args:
        context: GodotProjectInfo of the context.
        paths: Resource paths, such as a unit's own files.

    Returns:
        The GodotAddonInfo, outside every context, of the named add-ons whose importer
        role declares the suffix of one of the files, each once, ordered by label.
    """
    found = {}
    for suffix in {_suffix(path): True for path in paths}:
        for addon in context.importers.get(suffix, []):
            found[str(addon.label)] = addon
    return [found[label] for label in sorted(found)]

def importer_staging(context, importers):
    """
    What a Godot process stages and enables to run importers.

    Args:
        context: GodotProjectInfo of the context.
        importers: GodotAddonInfo of the add-ons whose importers run.

    Returns:
        A struct of resource_paths, what the importers need to run; plugins, the res://
        paths of their plugin.cfg files, which the process enables; and settings, the
        import settings they read, key to Godot literal, with the project's overrides.
    """
    resource_paths = {}
    settings = {}
    origins = {}
    for addon in importers:
        merge_resource_paths(resource_paths, addon.importer_resource_paths, owner = str(addon.label))
        read = {key: value for key, value, _ in addon.settings if key in addon.import_settings}
        merge_configuration(settings, read, origins, str(addon.label), context.setting_overrides)
        settings.update({key: context.setting_overrides[key] for key in read if key in context.setting_overrides})
    return struct(
        resource_paths = resource_paths,
        plugins = sorted({"res://" + addon.plugin_config: True for addon in importers if addon.plugin_config}),
        settings = settings,
    )

def _with_importers(context, outputs, staging):
    """
    The import's manifest fields, resource path manifests and inputs, with its importers.

    The import stages and enables only the importers of the add-ons the context names
    whose suffixes match one of the unit's own files, with what they need to run; import
    inputs do not count (FR-017, D14).
    """
    importers = importers_of(context, outputs)
    data = {
        "project_file": mapped_path(context.import_configuration),
        "outputs": outputs,
    }
    if not importers:
        return struct(data = data, resource_path_manifests = staging.resource_path_manifests, inputs = staging.inputs)
    own = {path: True for path in outputs}
    tools = importer_staging(context, importers)
    return struct(
        data = data | {
            "editor_plugins": tools.plugins,
            "settings": tools.settings,
            "tools": sorted([path for path in tools.resource_paths if path not in own]),
        },
        resource_path_manifests = depset(
            [addon.importer_resource_path_manifest for addon in importers],
            transitive = [staging.resource_path_manifests],
        ),
        inputs = depset(tools.resource_paths.values(), transitive = [staging.inputs]),
    )

def _import_if_needed(
        template_ctx,
        input_directories,
        output_directories,
        additional_inputs,
        tools,
        additional_params):
    """Import a unit only if Godot has an importer for one of its own files."""
    importable = {
        child.basename: True
        for child in input_directories["importable"].children
    }
    suffixes = additional_params["suffixes"].split(",")
    if not [suffix for suffix in suffixes if suffix in importable]:
        return

    # A template action can only declare files, so the result is one archive.
    out = template_ctx.declare_file("import.tar", directory = output_directories["out"])
    arguments = template_ctx.args()
    arguments.add_all([
        "import",
        "--manifest",
        additional_inputs["manifest"],
        "--output",
        out,
    ])
    arguments.add_all(additional_inputs["resource_path_manifests"], before_each = "--resource-path-manifest")
    arguments.add_all(
        additional_inputs["imports"],
        before_each = "--import",
        expand_directories = False,
    )

    arguments.add("--editor", additional_inputs["editor"])
    add_output_roots(arguments, additional_inputs["named"])
    template_ctx.run(
        executable = tools["actions"],
        arguments = [arguments],
        inputs = additional_inputs["inputs"],
        outputs = [out],
        progress_message = "Importing %s" % additional_params["owner"].removeprefix("@@"),
    )

def import_unit(ctx, context, unit, staging):
    """
    Import one unit's own files under a context's import configuration.

    Args:
        ctx: Analysis context of a rule with an _actions tool and the editor toolchain.
        context: GodotProjectInfo of the context, a real project.
        unit: struct of the unit: suffix, which distinguishes its outputs from other units
            the target imports (empty for a target that imports one unit); owner, its
            label string, for the progress message; and files, its own resource paths to
            Files.
        staging: struct of resource_path_manifests, a depset of the manifests of every
            file the import stages; inputs, a depset of the Files it stages; and imports,
            the import results of the unit's dependencies.

    Returns:
        The tree artifact holding the import result, possibly empty.
    """
    tc = ctx.toolchains[EDITOR_TOOLCHAIN].godot
    out = ctx.actions.declare_directory(ctx.label.name + unit.suffix + ".import")
    outputs = sorted(unit.files)
    staged = _with_importers(context, outputs, staging)
    manifest = editor_manifest(ctx, unit.suffix + ".import", staged.data)
    ctx.actions.map_directory(
        input_directories = {"importable": context.importable},
        output_directories = {"out": out},
        additional_inputs = {
            "manifest": manifest,
            "editor": tc.editor.executable,
            # What the manifests name, whose output roots resolve their mapped paths.
            "named": depset([context.import_configuration], transitive = [staged.inputs]),
            "resource_path_manifests": staged.resource_path_manifests,
            "imports": staging.imports,
            "inputs": depset(
                [manifest, context.import_configuration, tc.editor.executable],
                transitive = [
                    tc.files,
                    staged.resource_path_manifests,
                    staged.inputs,
                    staging.imports,
                ],
            ),
        },
        additional_params = {
            "owner": unit.owner,
            # Template parameters are scalars, so the suffixes are joined.
            "suffixes": ",".join(sorted({_suffix(path): True for path in outputs if _suffix(path)})),
        },
        tools = {"actions": ctx.attr._actions[DefaultInfo].files_to_run},
        implementation = _import_if_needed,
        mnemonic = "GodotImport",
        execution_requirements = PATH_MAPPING,
        toolchain = EDITOR_TOOLCHAIN,
    )
    return out

# ==== Class fragment and interface ============================================

def _scripts(files, ignored):
    """The GDScript files among a unit's own that Godot does not ignore."""
    return {path: file for path, file in files.items() if path.endswith(".gd") and path not in ignored}

def class_fragment(ctx, unit):
    """
    List the global script classes of a unit's scripts (D7).

    Args:
        ctx: Analysis context of a rule with a _class_fragment tool.
        unit: struct of the unit's suffix, its own resource paths to Files (files) and the
            resource paths Godot ignores (ignored), whose scripts it never registers.

    Returns:
        A list of the fragment File, empty for a unit without scripts.
    """
    scripts = _scripts(unit.files, unit.ignored)
    if not scripts:
        return []
    out = ctx.actions.declare_file(ctx.label.name + unit.suffix + ".classes.json")
    manifest = write_manifest(ctx, unit.suffix + ".classes.config", mapped_paths(scripts))
    arguments = ctx.actions.args()
    arguments.add_all(["--manifest", manifest, "--output", out])
    add_output_roots(arguments, depset(scripts.values()))
    ctx.actions.run(
        executable = ctx.executable._class_fragment,
        arguments = [arguments],
        inputs = [manifest] + scripts.values(),
        outputs = [out],
        mnemonic = "GodotClassFragment",
        progress_message = "Generating %{label}",
        execution_requirements = PATH_MAPPING,
    )
    return [out]

def _imported_asset(path, files, ignored):
    """Whether Godot loads a file through the .import file beside it, by exactly that name."""
    settings = path + ".import"
    if settings not in files:
        return False
    return path not in ignored and settings not in ignored

def unit_interface(ctx, unit, own_import):
    """
    Derive what the validations of a unit's dependents read from its files (#158).

    A script's interface is the script without its function bodies; an imported asset's is
    an empty file whose .import file remaps to a stand-in of its resource's class. A body
    or asset content change yields the same interface, so no dependent validation reruns.
    tools/validation/unit_interface.py states what Godot reads and why the interface is exact.

    Args:
        ctx: Analysis context of a rule with a _unit_interface tool.
        unit: struct of the unit's suffix, its own resource paths to Files (files) and the
            resource paths Godot ignores (ignored), which dependents stage as they are.
        own_import: The unit's own import result, from import_unit.

    Returns:
        A struct of interface, the File dependents stage in place of the unit's import
        result: the interface, or the import result itself for a unit with neither scripts
        nor assets with an .import file; and interfaced, the resource paths of the unit's
        files the interface replaces for dependents.
    """
    files = unit.files
    interfaced = _scripts(files, unit.ignored)
    for path, file in files.items():
        if _imported_asset(path, files, unit.ignored):
            interfaced[path] = file
            interfaced[path + ".import"] = files[path + ".import"]
    if not interfaced:
        return struct(interface = own_import, interfaced = [])
    out = ctx.actions.declare_directory(ctx.label.name + unit.suffix + ".interface")
    manifest = write_manifest(ctx, unit.suffix + ".interface", {
        "scripts": mapped_paths({path: file for path, file in interfaced.items() if path.endswith(".gd")}),
        "assets": mapped_paths({path: file for path, file in interfaced.items() if not path.endswith(".gd")}),
    })
    arguments = ctx.actions.args()
    arguments.add("--manifest", manifest)

    # Args.add takes no directory; add_all names one without expanding it.
    arguments.add_all([out], before_each = "--output", expand_directories = False)
    arguments.add_all([own_import], before_each = "--import", expand_directories = False)
    add_output_roots(arguments, depset(interfaced.values()))
    ctx.actions.run(
        executable = ctx.executable._unit_interface,
        arguments = [arguments],
        inputs = [manifest, own_import] + interfaced.values(),
        outputs = [out],
        mnemonic = "GodotUnitInterface",
        progress_message = "Generating %{label}",
        execution_requirements = PATH_MAPPING,
    )
    return struct(interface = out, interfaced = interfaced.keys())

# ==== Validation ==============================================================

# Script and scene members that only the exported game runs; no import reads them.
GAME_ONLY = (".gd", ".tscn", ".scn")

def _closure_files(own, uses):
    """
    The files the validation stages: the closure's other units' files, then the unit's own.

    The closure's other units stage their interfaces in place of their scripts, their
    imported assets and their import results (#158).
    """
    interfaced = {
        path: True
        for path in depset(transitive = [use.interfaced_resource_paths for use in uses]).to_list()
    }
    closure = {}
    for use in uses:
        closure.update(use.member_resource_paths)
    return {path: file for path, file in closure.items() if path not in interfaced} | own

def _absent_extensions(extensions):
    """The extensions with editor files but no library for this configuration's platform."""
    return [
        extension
        for extension in extensions
        if not extension.library and extension.editor_resource_paths
    ]

def _without_absent(staged, extensions, absent):
    """The staged files without the editor files only absent extensions bring."""
    loaded = {
        path: True
        for extension in extensions
        if extension not in absent
        for path in extension.editor_resource_paths
    }
    for extension in absent:
        for path in extension.editor_resource_paths:
            if path not in loaded:
                staged.pop(path, None)
    return staged

def _staged_extensions(files, extensions, runs_in_editor):
    """
    Stage the extensions' editor files, without the libraries of those the runtime cannot load.

    Returns:
        A struct of the staged files, the absent extensions, which have no library for this
        platform and whose editor files are left out unless the unit runs in the editor,
        and the toolless ones, whose library the platform's runtime loads but the editor
        of this action cannot.
    """
    absent = [] if runs_in_editor else _absent_extensions(extensions)
    staged = _without_absent(with_extensions_for(files, extensions, "editor"), extensions, absent)
    toolless = [
        extension
        for extension in extensions
        if extension.library and not extension.editor_resource_paths
    ]
    return struct(staged = staged, absent = absent, toolless = toolless)

def _declared_autoloads(autoloads, context):
    """The add-ons' autoload contributions, then the project's own and its overrides."""
    declared = {name: value for name, value, _ in autoloads}
    declared.update(context.autoloads)
    declared.update(context.autoload_overrides)
    return declared

def _validation_mode(ctx, absent):
    """
    Return what a failed validation does.

    It reports where an application builds without the absent extensions' libraries,
    since it cannot tell the failures they cause from others.
    """
    if absent and ctx.attr._missing_extension_libraries[BuildSettingInfo].value == "report":
        return "report"
    return ctx.attr._content_validation[BuildSettingInfo].value

def _run_validation(ctx, context, unit, plan):
    """Run the validation the plan describes; return its output File."""
    tc = ctx.toolchains[EDITOR_TOOLCHAIN].godot
    out = ctx.actions.declare_file(ctx.label.name + unit.suffix + ".validation.json")
    manifest = editor_manifest(ctx, unit.suffix + ".validate", {
        "owner": str(ctx.label).removeprefix("@@") + unit.suffix,
        "project_file": mapped_path(context.import_configuration),
        "member_resource_paths": mapped_paths(plan.extensions.staged),
        "checked": plan.checked,
        # The validation keeps those whose file the closure holds, as views do, once the
        # authored autoloads' UIDs resolve against the staged files.
        "authored_autoloads": mapped_path(context.authored_autoloads),
        "autoloads": plan.autoloads,
        "resource_uids": metadata_modes(ctx)["resource_uids"],
        "mode": _validation_mode(ctx, plan.extensions.absent),
    } | ({
        # Only then, so that platforms whose extensions agree validate alike.
        "absent_extensions": sorted([extension.descriptor_path for extension in plan.extensions.absent]),
    } if plan.extensions.absent else {}) | ({
        "toolless_extensions": sorted([extension.descriptor_path for extension in plan.extensions.toolless]),
    } if plan.extensions.toolless else {}))
    arguments = ctx.actions.args()
    arguments.add_all(["--manifest", manifest, "--output", out])
    arguments.add("--editor", tc.editor.executable)

    # Class fragments and import results stay unexpanded and their depsets unflattened
    # until execution.
    arguments.add_all(plan.fragments, before_each = "--fragment")
    arguments.add_all(plan.imports, before_each = "--import", expand_directories = False)
    named = [context.import_configuration, context.authored_autoloads] + plan.extensions.staged.values()
    add_output_roots(arguments, depset(named))
    ctx.actions.run(
        executable = ctx.executable._validation,
        arguments = [arguments],
        inputs = depset([manifest] + named, transitive = [tc.files, plan.fragments, plan.imports]),
        tools = [tc.editor],
        outputs = [out],
        mnemonic = "GodotValidate",
        progress_message = "Validating %{label}",
        toolchain = EDITOR_TOOLCHAIN,
        execution_requirements = PATH_MAPPING,
    )
    return out

def validate_unit(ctx, context, unit, closure):
    """
    Validate a unit's scripts and scenes under its context and closure (FR-031, D7).

    One Godot process in editor mode loads the unit's scripts and then its scenes with
    the unit's import result, the interfaces of the closure's other units in place of
    their scripts, imported assets and import results (unit_interface), the closure's
    other files, global script classes and UIDs, the autoloads
    of the runtime configuration whose files the closure holds and the extensions of the
    add-ons the unit uses that the unit's runtime can load: those with a library for
    this configuration's platform, or every one for a unit that runs only in the editor.
    The errors Godot reports while each loads decide, so a script that uses the classes
    of an extension its platform cannot load fails, as code compiled against a
    platform's dependencies does, while one that guards the use with ClassDB passes. No
    project code runs: the editor runs only tool scripts and the staged scripts lose
    their tool annotations, and the autoloads are registered and typed but never
    instantiated (FR-033, D19, D20). No producing action reads the output.

    Args:
        ctx: Analysis context of a rule with a _validation tool, the editor toolchain,
            METADATA_ATTRS, _content_validation and _missing_extension_libraries.
        context: GodotProjectInfo of the context, a real project.
        unit: struct of the unit's suffix, its own resource paths to Files (files) and the
            resource paths Godot ignores (ignored), whose scripts and scenes it never loads.
        closure: struct of the unit's own_import (from import_unit) and fragments (from
            class_fragment); uses, GodotResourcesInfo of what the unit may use, such as
            its dependencies and the runtime parts of the add-ons it uses, whose other
            units the validation stages through their interfaces; extensions, the unique
            GodotExtensionInfo of those add-ons; autoloads, their (name, res:// path,
            owner) contributions, which the project's own and overrides follow and which
            all replace autoloads of the same name in the authored project.godot; and
            runs_in_editor, whether the unit runs only in the editor, as an add-on's
            editor part does, which loads every extension's tool library.

    Returns:
        A list of the validation's output, empty for a unit without scripts or scenes.
    """

    # Scripts first, then scenes; Godot loads none it ignores.
    checked = sorted(
        [path for path in unit.files if path.endswith(GAME_ONLY) and path not in unit.ignored],
        key = lambda path: (not path.endswith(".gd"), path),
    )
    if not checked:
        return []
    files = _closure_files(unit.files, closure.uses)
    return [_run_validation(ctx, context, unit, struct(
        checked = checked,
        extensions = _staged_extensions(files, closure.extensions, closure.runs_in_editor),
        autoloads = _declared_autoloads(closure.autoloads, context),
        fragments = depset(closure.fragments, transitive = [use.class_fragments for use in closure.uses]),
        imports = depset([closure.own_import], transitive = [use.interfaces for use in closure.uses]),
    ))]

# The tools and flags per-unit validations, class fragments and interfaces need.
VALIDATION_ATTRS = {
    "_unit_interface": attr.label(
        default = Label("//tools/validation:unit_interface"),
        executable = True,
        cfg = "exec",
    ),
    "_class_fragment": attr.label(
        default = Label("//tools/resources:class_fragment"),
        executable = True,
        cfg = "exec",
    ),
    "_validation": attr.label(
        default = Label("//tools/validation:content_validation"),
        executable = True,
        cfg = "exec",
    ),
    "_content_validation": attr.label(
        default = Label("//godot/private:content_validation"),
        providers = [BuildSettingInfo],
    ),
    "_missing_extension_libraries": attr.label(
        default = Label("//godot:missing_extension_libraries"),
        providers = [BuildSettingInfo],
    ),
} | METADATA_ATTRS
