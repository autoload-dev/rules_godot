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
load("//godot/private/config:settings.bzl", "THREADS_CONSTRAINT")
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

def _pack_file(ctx, pack, option):
    """The file of the pack an export option names, such as its own HTML shell, or None."""
    path = string_option(pack.export_options, option)
    if not path:
        return None
    file = pack.project.member_resource_paths.get(path.removeprefix("res://"))
    if not file:
        fail("%s: %s names %s, which is no file of the pack" % (ctx.label, option, path))
    return file

# Headers that make a page cross-origin isolated, which threads need.
_ISOLATION_HEADERS = {
    "Cross-Origin-Embedder-Policy": "require-corp",
    "Cross-Origin-Opener-Policy": "same-origin",
}

def _authored_true(pack, option, default):
    """
    Whether a boolean export option is true, as the pack authors it or by Godot's default.

    Analysis cannot read the probe's facts, so the default of each option this reads
    stands here; the packager writes the files from the facts.
    """
    return pack.export_options.get(option, default).strip() in ["true", "1"]

def _isolation(pack, threads):
    """
    What the host must do for the application to start: none, headers or service_worker.

    A progressive web app that ensures the isolation headers supplies them from its service
    worker; the export options are Godot literals, and Godot's defaults apply when unset.
    """
    if not threads:
        return "none"
    pwa = _authored_true(pack, "progressive_web_app/enabled", "false")
    ensures = _authored_true(pack, "progressive_web_app/ensure_cross_origin_isolation_headers", "true")
    return "service_worker" if pwa and ensures else "headers"

def _package(ctx, pack, runtime, name):
    """Write the web export's directory, named name, and its ZIP; return both."""
    site = ctx.actions.declare_directory(ctx.label.name + "/" + name)
    archive = ctx.actions.declare_file(ctx.label.name + "/" + name + ".zip")
    files = {
        flag: file
        for flag, file in {
            "--shell": _pack_file(ctx, pack, "html/custom_html_shell"),
            # Godot reads the offline page only for a progressive web app.
            "--offline-page": _pack_file(ctx, pack, "progressive_web_app/offline_page") if _authored_true(pack, "progressive_web_app/enabled", "false") else None,
        }.items()
        if file
    }
    args = ctx.actions.args()
    args.add("--runtime", _template(ctx, runtime).dirname)
    args.add("--pack", pack.pack_file)
    args.add("--facts", pack.facts)

    # The web's images are one directory.
    args.add("--images", pack.icons[0].path)
    for flag, file in files.items():
        args.add(flag, file)
    args.add("--output", site.path)
    args.add("--archive", archive)
    ctx.actions.run(
        executable = ctx.executable._packager,
        arguments = [args],
        inputs = depset(
            [pack.pack_file, pack.facts] + pack.icons + files.values(),
            transitive = [runtime.files],
        ),
        outputs = [site, archive],
        mnemonic = "GodotWebPackage",
        progress_message = "Packaging web application %{label}",
    )
    return site, archive

def _template(ctx, runtime):
    """The godot.wasm of the runtime's template that the export platform needs."""
    kind = "threads" if _threads(ctx) else "nothreads"
    templates = getattr(runtime, "web_templates", None) or {"nothreads": runtime.executable}
    if kind not in templates:
        fail("%s: the web runtime %s has no template with %s" % (ctx.label, runtime.origin, kind))
    return templates[kind]

def _threads(ctx):
    return ctx.target_platform_has_constraint(ctx.attr._threads[platform_common.ConstraintValueInfo])

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
        # The local server isolates the page that threads need, as Godot's own does.
        "headers": _ISOLATION_HEADERS if _threads(ctx) else {},
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
            cross_origin_isolation = _isolation(pack, _threads(ctx)),
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
        "_threads": attr.label(default = THREADS_CONSTRAINT),
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
