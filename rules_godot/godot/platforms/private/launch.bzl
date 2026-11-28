"""The launcher behind `bazel run` on every application backend."""

load("//godot/private:paths.bzl", "runfile_key")

visibility(["//godot/platforms/private", "//godot/private"])

LAUNCH_ATTRS = {
    "_launch_template": attr.label(
        default = Label(":launch.sh.tpl"),
        allow_single_file = True,
    ),
    "_launcher": attr.label(
        default = Label("//tools/platforms/launch"),
        allow_files = [".py", ".js"],
    ),
    "_launcher_entry": attr.label(
        default = Label("//tools/platforms/launch:launch.py"),
        allow_single_file = True,
    ),
}

def launcher(ctx, executable, manifest):
    """
    Write the launcher that installs and starts an application for `bazel run`.

    Args:
        ctx: Analysis context of an executable rule with LAUNCH_ATTRS.
        executable: The declared launcher file.
        manifest: The platform and the application's files, as the platform's launcher
            in tools/platforms/launch reads them. A File value, or a (File, path) pair
            naming a path inside a directory, becomes a runfile path, and the file joins
            the runfiles.

    Returns:
        The launcher's runfiles.
    """
    files = []
    data = {}
    for key, value in manifest.items():
        if type(value) == "tuple":
            files.append(value[0])
            data[key] = runfile_key(ctx, value[0].short_path) + "/" + value[1]
        elif type(value) == "File":
            files.append(value)
            data[key] = runfile_key(ctx, value.short_path)
        else:
            data[key] = value
    manifest_file = ctx.actions.declare_file(executable.basename + ".launch.json", sibling = executable)
    ctx.actions.write(manifest_file, json.encode(data))
    ctx.actions.expand_template(
        template = ctx.file._launch_template,
        output = executable,
        substitutions = {
            "{LAUNCHER}": runfile_key(ctx, ctx.file._launcher_entry.short_path),
            "{MANIFEST}": runfile_key(ctx, manifest_file.short_path),
        },
        is_executable = True,
    )
    return ctx.runfiles(files = [manifest_file] + ctx.files._launcher + files)
