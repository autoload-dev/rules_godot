"""The host's editor of the build's engine, as a test runs it beside the files it built."""

load("//godot/private:execution.bzl", "RUN_EXEC_GROUPS", "exec_group_editor")

visibility("private")

def _host_editor_impl(ctx):
    tc = exec_group_editor(ctx, "run")
    return [DefaultInfo(
        files = depset([tc.editor.executable]),
        runfiles = ctx.runfiles(transitive_files = tc.files),
    )]

host_editor = rule(
    doc = "The editor of the build's engine on this host, with its runfiles.",
    implementation = _host_editor_impl,
    exec_groups = RUN_EXEC_GROUPS,
)
