"""
The web application backend of godot_app: Godot's web export from a prebuilt runtime.

The packager writes what EditorExportPlatformWeb::export_project writes for the same pack and
export options, under the same names: the template's files renamed after the page, the
PCK, the page with its configuration, the boot splash and the icons the shell probe
rendered. The directory deploys as it is; its ZIP holds the same files.
"""

load("//godot:providers.bzl", "GodotPackInfo", "GodotWebAppInfo")
load("//godot/private:export_options.bzl", "string_option")
load("//godot/private:providers.bzl", "GodotComponentInfo", "GodotRuntimeInfo")
load("//godot/private/config:application.bzl", "missing_extension_libraries_report")
load(":launch.bzl", "LAUNCH_ATTRS", "launcher")
load(":shell.bzl", "ENGINE_CHECK_ATTRS", "check_engine", "pack_facts")

visibility(["//godot/platforms/private/tests/...", "//godot/private"])

# Godot names every file after the exported page; static hosts and itch.io open index.html.
_ENTRY_POINT = "index.html"

def _check_inputs(ctx, pack, runtime):
    if ctx.attr.platform_deps or ctx.attr.platform_resources:
        fail("godot_app web does not support nonempty platform_deps or platform_resources: %s" % [
            str(target.label)
            for target in ctx.attr.platform_deps + ctx.attr.platform_resources
        ])
    if runtime.platform != "web":
        fail("%s: a %s runtime cannot package a web application" % (ctx.label, runtime.platform))

    # Godot's web export rejects C#; the editor of a project with C# would export it anyway.
    scripts = sorted([path for path in pack.project.member_resource_paths if path.endswith(".cs")])
    if scripts:
        fail("%s: Godot exports no C# project for the web; the pack contains %s" % (ctx.label, ", ".join(scripts)))

def _custom_shell(ctx, pack):
    """The pack's own HTML shell that html/custom_html_shell names, or None."""
    path = string_option(pack.export_options, "html/custom_html_shell")
    if not path:
        return None
    shell = pack.project.member_resource_paths.get(path.removeprefix("res://"))
    if not shell:
        fail("%s: html/custom_html_shell names %s, which is no file of the pack" % (ctx.label, path))
    return shell

def _package(ctx, pack, runtime, name):
    """Write the web export's directory, named name, and its ZIP; return both."""
    site = ctx.actions.declare_directory(ctx.label.name + "/" + name)
    archive = ctx.actions.declare_file(ctx.label.name + "/" + name + ".zip")
    shell = _custom_shell(ctx, pack)
    args = ctx.actions.args()
    args.add("--runtime", runtime.executable.dirname)
    args.add("--pack", pack.pack_file)
    args.add("--facts", pack.facts)
    args.add_all(pack.icons, before_each = "--images", expand_directories = False)
    if shell:
        args.add("--shell", shell)
    args.add("--output", site.path)
    args.add("--archive", archive)
    ctx.actions.run(
        executable = ctx.executable._packager,
        arguments = [args],
        inputs = depset(
            [pack.pack_file, pack.facts] + pack.icons + ([shell] if shell else []),
            transitive = [runtime.files],
        ),
        outputs = [site, archive],
        mnemonic = "GodotWebPackage",
        progress_message = "Packaging web application %{label}",
    )
    return site, archive

def _web_application_impl(ctx):
    pack = ctx.attr.pack[GodotPackInfo]
    runtime = ctx.attr.runtime[GodotRuntimeInfo]
    _check_inputs(ctx, pack, runtime)
    name = ctx.attr.app_name or ctx.label.name
    site, archive = _package(ctx, pack, runtime, name)
    validation = check_engine(
        ctx,
        {"--library": depset([runtime.executable])} | pack_facts(pack),
        engine = ctx.attr.runtime,
        pack = pack,
    )
    executable = ctx.actions.declare_file(ctx.label.name + "/" + name + ".run")
    runfiles = launcher(ctx, executable, {
        "platform": "web",
        "site": site,
        "entry_point": _ENTRY_POINT,
        "hook": ctx.file._web_hook,
        # Without threads the page needs no cross-origin isolation.
        "headers": {},
    })
    return [
        DefaultInfo(executable = executable, files = depset([site, archive]), runfiles = runfiles),
        OutputGroupInfo(
            bundle = depset([site]),
            archive = depset([archive]),
            # A browser loads no native debug symbols.
            debug_symbols = depset(),
            missing_extension_libraries = missing_extension_libraries_report(ctx.attr.pack),
            _validation = depset(validation),
        ),
        GodotWebAppInfo(
            bundle = site,
            archive = archive,
            entry_point = _ENTRY_POINT,
            cross_origin_isolation = "none",
            runtime_component = ctx.attr.runtime[GodotComponentInfo] if GodotComponentInfo in ctx.attr.runtime else None,
        ),
    ]

godot_web_application = rule(
    doc = """
    Package a Godot PCK and a prebuilt web runtime into the files of Godot's web export.

    Returns DefaultInfo with the directory and its ZIP, GodotWebAppInfo and
    OutputGroupInfo.bundle / .archive. bazel run serves the directory on this host and
    opens it in a browser.
    """,
    implementation = _web_application_impl,
    executable = True,
    attrs = {
        "platform_deps": attr.label_list(doc = "Rejected when nonempty: the web has no platform libraries."),
        "platform_resources": attr.label_list(doc = "Rejected when nonempty.", allow_files = True),
        "pack": attr.label(doc = "The application pack.", mandatory = True, providers = [GodotPackInfo]),
        "runtime": attr.label(doc = "The resolved web runtime.", mandatory = True, providers = [GodotRuntimeInfo]),
        "app_name": attr.string(doc = "The name of the directory and its ZIP; the target's name by default."),
        "_web_hook": attr.label(
            default = Label("//tools/platforms/launch:launch_web_hook.js"),
            allow_single_file = True,
        ),
        "_packager": attr.label(
            default = Label("//tools/platforms:package_web"),
            executable = True,
            cfg = "exec",
        ),
    } | LAUNCH_ATTRS | ENGINE_CHECK_ATTRS,
)
