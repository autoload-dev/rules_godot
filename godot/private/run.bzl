"""Run Godot projects or packs with `bazel run` and `bazel test`, like py_binary/py_test."""

load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")
load("//godot:providers.bzl", "GodotPackInfo")
load("//godot/platforms/private:launch.bzl", "LAUNCH_ATTRS", application_launcher = "launcher")
load("//godot/private:execution.bzl", "EDITOR_TOOLCHAIN", "RUN_EXEC_GROUPS", "TEST_EXEC_GROUPS", "exec_group_editor")
load("//godot/private:metadata.bzl", "METADATA_ATTRS", "metadata_entry", "metadata_kinds")
load("//godot/private:paths.bzl", "declared_path", "runfile_key", "validate_resource_path", "with_extensions_for")
load("//godot/private:view.bzl", "GodotViewInfo", "declare_view", "require_entries")
load("//godot/private/config:transitions.bzl", "editor_variant_transition")

visibility("//godot/...")

def _short_path(file):
    return file.short_path

def import_results(ctx, project, imports = None):
    """
    List a project's import results for a runner, which tools/godot_run.py reads.

    Args:
        ctx: Analysis context of an executable rule.
        project: GodotViewInfo of the view the runner stages.
        imports: The import results to list; None lists the view's imports.

    Returns:
        The manifest's imports and initialized fields, and the Files the runner
        needs at run time.
    """

    # Import results are listed in a separate file so the depset stays
    # unflattened during analysis.
    if imports == None:
        imports = project.imports
    listed = ctx.actions.declare_file(ctx.label.name + ".imports")
    arguments = ctx.actions.args()
    arguments.set_param_file_format("multiline")
    arguments.add_all(imports, map_each = _short_path, expand_directories = False)
    ctx.actions.write(listed, arguments)
    fields = {
        "imports": listed.short_path,
        "initialized": project.initialized.short_path,
    }
    return fields, depset([listed, project.initialized], transitive = [imports])

def launcher(ctx, data):
    """
    Write a runner's manifest and the launcher that starts the runner with it.

    Args:
        ctx: Analysis context of an executable rule with _runner and
            _launcher_template attributes.
        data: The manifest's content.

    Returns:
        The launcher, and the manifest, which belongs in its runfiles.
    """
    manifest = ctx.actions.declare_file(ctx.label.name + ".run.json")
    ctx.actions.write(manifest, json.encode(data))
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.expand_template(
        template = ctx.file._launcher_template,
        output = executable,
        substitutions = {
            "{RUNNER}": runfile_key(ctx, ctx.executable._runner),
            "{MANIFEST}": runfile_key(ctx, manifest),
        },
        is_executable = True,
    )
    return executable, manifest

def _foreign(ctx, test):
    """
    Whether bazel run starts the editor on a host that cannot run the target platform.

    A test runs on an execution platform matching its target platform. The editor then loads
    the extension host editor libraries instead of the extension runtime libraries.
    """
    return not test and not all([
        ctx.target_platform_has_constraint(constraint[platform_common.ConstraintValueInfo])
        for constraint in ctx.attr._host_constraints
    ])

def _project_data(ctx, project, foreign):
    import_fields, inputs = import_results(ctx, project)
    member_resource_paths = dict(project.member_resource_paths)
    if foreign:
        member_resource_paths = with_extensions_for(
            member_resource_paths,
            project.runtime_extensions,
            "host_editor",
        )
    data = dict(
        import_fields,
        project_file = project.runtime_project_file.short_path,
        custom_features = project.project.custom_features,
        flag_settings = project.project.flag_settings,
        member_resource_paths = {
            path: file.short_path
            for path, file in member_resource_paths.items()
        },
        import_resource_paths = {
            path: file.short_path
            for path, file in project.import_resource_paths.items()
        },
    )
    index = project.metadata_index
    if index:
        # Runs complete resource UIDs as packs do; node IDs matter only in exports.
        kinds = metadata_kinds(ctx, ["assign", "sync", "require"])
        data.update(metadata_entry(index.short_path, [kind for kind in kinds if kind == "resource_uids"]))
    files = depset(
        [project.runtime_project_file] + ([index] if index else []) + member_resource_paths.values() +
        project.import_resource_paths.values(),
        transitive = [inputs],
    )
    return data, files

def _additional_packs(ctx):
    """The additional packs by their distinct file names in the working directory."""
    additional_packs = {}
    for target, name in ctx.attr.additional_packs.items():
        validate_resource_path(name)
        if name in additional_packs:
            fail("Additional packs %s and %s share the file name %r" % (
                additional_packs[name].label,
                target.label,
                name,
            ))
        additional_packs[name] = target
    return additional_packs

def _pack_run_fields(pack, project, foreign):
    """
    The manifest fields of a pack run and the Files it stages beside the pack.

    Args:
        pack: GodotPackInfo of the pack the run starts.
        project: The pack's project.
        foreign: Whether the editor runs on a host that cannot run the target platform.

    Returns:
        The fields, and a depset of the pack and the extension files staged beside it.
    """
    extension_resource_paths = {}
    extension_files = []
    descriptors = {}
    release_descriptors = []
    desktop_release = pack.variant == "release" and pack.operating_system in ["linux", "macos"]
    for extension in project.runtime_extensions:
        staged = dict(
            extension.host_editor_resource_paths if foreign else extension.runtime_resource_paths,
        )
        if not staged:
            # The host's tool configuration has no library of the extension.
            continue

        # The pack's own descriptor wins over staged files. On a host that cannot run
        # the target platform the editor loads the extension host editor libraries
        # instead; for a desktop release pack the runner lists the libraries under the
        # editor_runtime tag too, which the editor running the pack has.
        descriptor = staged.pop(extension.descriptor_path)
        if foreign:
            descriptors[extension.descriptor_path] = descriptor.short_path
            extension_files.append(descriptor)
        elif desktop_release:
            release_descriptors.append(extension.descriptor_path)
        for path, file in staged.items():
            extension_resource_paths[path] = file.short_path
            extension_files.append(file)
    data = {
        "pack": pack.pack_file.short_path,
        "pack_descriptors": descriptors,
        "release_descriptors": release_descriptors,
        "extension_resource_paths": extension_resource_paths,
    }
    return data, depset([pack.pack_file] + extension_files)

def _runfiles(ctx, tc, manifest, inputs):
    """The runfiles of a run: its manifest, the editor, the runner, data and inputs."""
    runfiles = ctx.runfiles(
        files = [manifest, tc.editor.executable, ctx.executable._runner] + ctx.files.data,
        transitive_files = depset(transitive = [tc.files, inputs]),
    )
    runfiles = runfiles.merge(ctx.attr._runner[DefaultInfo].default_runfiles)
    for target in ctx.attr.data:
        runfiles = runfiles.merge(target[DefaultInfo].default_runfiles)
    return runfiles

def _main_path(ctx, project):
    """The resource path of the run's main, or empty for the project's main scene."""
    if not ctx.attr.main:
        return ""
    return declared_path(project.member_resource_paths, ctx.attr.main, "main")

def _run_fields(ctx, pack, project, foreign):
    """The manifest fields and inputs of a pack run, or of a source run's project."""
    if pack:
        return _pack_run_fields(pack, project, foreign)
    fields, inputs = _project_data(ctx, project, foreign)
    return {"project": fields}, inputs

def _executable_impl(ctx, test, tc = None, foreign = None):
    if not tc:
        tc = exec_group_editor(ctx, "test" if test else "run")
        foreign = _foreign(ctx, test)
    pack = ctx.attr.pack[GodotPackInfo] if ctx.attr.pack else None

    # A label attribute with a Starlark transition arrives as a list.
    project = ctx.attr.view[0][GodotViewInfo] if ctx.attr.view else pack.project
    if not pack and not test:
        # A source run starts the game, so it needs every file its configuration names.
        require_entries(project)
    main = _main_path(ctx, project)
    additional_packs = _additional_packs(ctx)
    data = {
        "workspace": ctx.workspace_name,
        "editor": tc.editor.executable.short_path,
        "headless": ctx.attr.headless,
        "stop_on_error": test,
        "main": main,
        "engine_errors": ctx.attr.engine_errors,
        "env": ctx.attr.env,
        "additional_packs": {
            name: target[GodotPackInfo].pack_file.short_path
            for name, target in additional_packs.items()
        },
    }
    fields, inputs = _run_fields(ctx, pack, project, foreign)
    data |= fields
    inputs = depset(
        [target[GodotPackInfo].pack_file for target in additional_packs.values()],
        transitive = [inputs],
    )
    executable, manifest = launcher(ctx, data)
    return executable, manifest, _runfiles(ctx, tc, manifest, inputs)

# The godot_run and godot_test macros document these attributes.
_ATTRS = {
    # A source run runs the project with the editor, in the editor variant; a pack run keeps
    # the variant of its pack.
    "view": attr.label(providers = [GodotViewInfo], cfg = editor_variant_transition),
    "pack": attr.label(providers = [GodotPackInfo]),
    "additional_packs": attr.label_keyed_string_dict(providers = [GodotPackInfo]),
    "main": attr.string(),
    "data": attr.label_list(allow_files = True),
    "env": attr.string_dict(),
    "headless": attr.bool(default = True),
    "engine_errors": attr.string(default = "fail", values = ["fail", "report"]),
    "_launcher_template": attr.label(
        default = Label("//godot/private:run_launcher.sh.tpl"),
        allow_single_file = True,
    ),
    "_host_constraints": attr.label_list(
        default = [Label(constraint) for constraint in HOST_CONSTRAINTS],
        providers = [platform_common.ConstraintValueInfo],
    ),
    "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
} | METADATA_ATTRS

def _runner(group = None):
    """The runner, built for the execution platform of the group, or of the rule."""
    return {"_runner": attr.label(
        default = Label("//tools:godot_run"),
        executable = True,
        cfg = config.exec(group),
    )}

def _run_impl(ctx):
    executable, _, runfiles = _executable_impl(ctx, test = False)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

def _test_impl(ctx):
    executable, _, runfiles = _executable_impl(ctx, test = True)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

def _source_application_impl(ctx):
    # The runner stages and runs the project with its manifest; the application
    # launcher starts it with the options every application backend shares.
    # The application runs on its target platform, which its execution platform matches.
    _, manifest, runfiles = _executable_impl(ctx, test = False, tc = ctx.toolchains[EDITOR_TOOLCHAIN].godot, foreign = False)
    executable = ctx.actions.declare_file(ctx.label.name + ".run")
    runfiles = runfiles.merge(application_launcher(
        ctx,
        executable,
        {"platform": "editor", "runner": ctx.executable._runner, "manifest": manifest},
    ))
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

godot_source_application = rule(
    doc = """
    Run an application's project from sources with Godot's editor binary; the editor
    variant's backend of godot_app. Its editor and runner resolve for the rule's own
    execution platform, which the target execution toolchain fixes to the target
    platform's operating system and CPU: the application runs where its target platform
    says, on this host or on a remote executor.
    """,
    implementation = _source_application_impl,
    attrs = _ATTRS | _runner() | LAUNCH_ATTRS,
    executable = True,
    toolchains = [EDITOR_TOOLCHAIN, Label("//godot/private/config:target_execution_toolchain_type")],
)

_godot_run = rule(
    doc = """
    Run a project or PCK in a writable, isolated workspace; the rule behind godot_run.
    """,
    implementation = _run_impl,
    attrs = _ATTRS | _runner("run"),
    executable = True,
    exec_groups = RUN_EXEC_GROUPS,
)

_godot_test = rule(
    doc = """
    Run a project or PCK as a Bazel test; the rule behind godot_test.
    """,
    implementation = _test_impl,
    attrs = _ATTRS | _runner("test"),
    test = True,
    exec_groups = TEST_EXEC_GROUPS,
)

# The project operations use when they name none: a minimal project.godot.
DEFAULT_PROJECT = Label("//godot/private:default_project")

def _headless(headless):
    if headless != None:
        return headless
    return select({
        Label("//godot/private:display"): False,
        "//conditions:default": True,
    })

def validate_run_sources(name, deps, project, pack, _fail = fail):
    """
    Reject deps or a project together with a pack.

    Args:
        name: Name of the godot_run or godot_test, for the failure message.
        deps: The deps argument.
        project: The project argument.
        pack: The pack argument.
        _fail: Reports the error; tests collect it instead of stopping.
    """
    if (deps or project) and pack:
        _fail("%s: specify a project and deps, or a pack" % name)

def _executable(name, rule_, deps, project, pack, kwargs, test):
    validate_run_sources(name, deps, project, pack)
    view = None
    if not pack:
        view = declare_view(
            name,
            project or DEFAULT_PROJECT,
            deps,
            kwargs,
            # A source run starts the game itself; a test runs its own main.
            program_entry = "" if test else str(native.package_relative_label(":" + name)),
        )
    rule_(name = name, view = view, pack = pack, **kwargs)

def godot_run(
        name,
        deps = [],
        main = "",
        project = None,
        pack = None,
        data = [],
        env = {},
        headless = None,
        engine_errors = "fail",
        additional_packs = {},
        **kwargs):
    """
    Run a Godot project or exported PCK with `bazel run`, like py_binary.

    The run uses the registered editor toolchain in a fresh, writable copy of the
    project, so nothing in the checkout changes. Give it what to run in one of
    two ways: a project and the resources it runs in deps, or an exported pack. `args` are Godot's command line, which
    Bazel splits like a shell; arguments for the running script follow Godot's `--`
    separator.

    Example:
    ```starlark
    godot_run(
        name = "game",
        project = ":project",
        deps = [":main", ":assets"],
        headless = False,
    )
    ```

    `bazel run :game` opens the game's window. See
    [execution and tests](../../development.md#execution-and-tests).

    ### Default outputs
    - executable (one): run Godot with project or PCK; project and editor data are runfiles

    Args:
        name: Name of the executable target.
        deps: godot_resources and godot_extension targets the run contains, such as
            code, assets and add-ons. The project's autoloads and main scene must be
            among them.
        main: Resource path, with optional res:// prefix, of what Godot starts: a
            SceneTree or MainLoop script runs with --script, a .tscn or .scn scene
            replaces the main scene. Empty starts the project's main scene.
        project: The godot_project whose configuration the run uses; defaults to a
            minimal project.
        pack: An exported godot_pack to run instead of a project.
        data: Files available at run time through runfiles, outside the Godot
            project. Godot receives Bazel's runfiles directory/manifest variables
            when set. Tests also receive TEST_SRCDIR and TEST_WORKSPACE for locating them.
        env: Environment variables set for Godot.
        headless: Whether Godot runs without a display: True always, False never,
            for a target that must render. Unset follows the
            --@autoload_rules_godot//godot:headless flag, which is true by default.
        engine_errors: "fail" or "report": what an error Godot reports while the
            game's tree exists, such as a script error, does to the run. Godot can
            report one and still exit with 0. "fail" ends the run with 1 instead;
            "report" keeps Godot's exit status. Either names the number of recorded
            errors.
        additional_packs: Pack -> file name in the working directory, for the
            running project to load with ProjectSettings.load_resource_pack().
        **kwargs: Common attributes such as args and visibility.
    """
    _executable(
        name,
        _godot_run,
        deps,
        project,
        pack,
        dict(
            kwargs,
            main = main,
            data = data,
            env = env,
            headless = _headless(headless),
            engine_errors = engine_errors,
            additional_packs = additional_packs,
        ),
        test = False,
    )

def godot_test(
        name,
        deps = [],
        main = "",
        project = None,
        pack = None,
        data = [],
        env = {},
        headless = None,
        engine_errors = "fail",
        additional_packs = {},
        **kwargs):
    """
    Run a Godot project or exported PCK as a Bazel test, like py_test.

    The test passes when Godot exits with 0, so a script reports a failed check
    with `quit(1)`. Test frameworks run as the main script: autoload_gdunit's
    gdunit_test sets up GdUnit this way. Godot receives Bazel's test environment,
    such as TEST_SHARD_INDEX, TESTBRIDGE_TEST_ONLY and XML_OUTPUT_FILE, so a test
    framework can implement sharding, `--test_filter` and JUnit reports. size, timeout,
    shard_count and flaky work as for any Bazel test. The test and its view of the
    project are testonly unless testonly = False is passed, so production
    targets cannot depend on them.

    Example:
    ```starlark
    godot_test(
        name = "smoke_test",
        deps = [":smoke", ":game"],
        main = "smoke_test.gd",
    )
    ```

    Watch it with `bazel test :smoke_test --@autoload_rules_godot//godot:headless=false`.
    See [execution and tests](../../development.md#execution-and-tests).

    ### Default outputs
    - test (one): execute Godot under bazel test; failure follows the exit status and engine_errors; project/editor are runfiles

    Args:
        name: Name of the test target.
        deps: godot_resources and godot_extension targets the test contains: the
            test scripts and fixtures, the code under test, a test framework and
            its add-ons. Autoloads and a main scene of the project whose files are
            not among them are left out.
        main: Resource path, with optional res:// prefix, of what Godot starts: a
            SceneTree or MainLoop script runs with --script, a .tscn or .scn scene
            replaces the main scene. Empty starts the project's main scene.
        project: The godot_project whose configuration the test uses; defaults to a
            minimal project.
        pack: An exported godot_pack to test instead of a project.
        data: Files available at run time through runfiles, outside the Godot
            project. Godot receives Bazel's runfiles directory/manifest variables
            when set. Tests also receive TEST_SRCDIR and TEST_WORKSPACE for locating them.
        env: Environment variables set for Godot.
        headless: Whether Godot runs without a display: True always, False never,
            for a test that must render. Unset follows the
            --@autoload_rules_godot//godot:headless flag, which is true by default.
        engine_errors: "fail" or "report": what an error Godot reports while the
            game's tree exists, such as a script error, does to the test. "fail"
            fails the test and stops it after the first error, since a script error
            does not end Godot; "report" keeps Godot's exit status, for a test
            framework that provokes errors on purpose. Either names the number of
            recorded errors; the errors are in the test's undeclared outputs under
            godot/errors.jsonl.
        additional_packs: Pack -> file name in the working directory, for the
            running project to load with ProjectSettings.load_resource_pack().
        **kwargs: Common test attributes such as args, size and shard_count.
    """
    kwargs.setdefault("testonly", True)
    _executable(
        name,
        _godot_test,
        deps,
        project,
        pack,
        dict(
            kwargs,
            main = main,
            data = data,
            env = env,
            headless = _headless(headless),
            engine_errors = engine_errors,
            additional_packs = additional_packs,
        ),
        test = True,
    )
