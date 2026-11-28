"""
Rules for the payloads that generated prebuilt archive repositories declare.

Loaded by the BUILD files of godot_editor_archive and godot_export_templates_archive,
so it needs public load visibility; it is not a consumer API.
"""

load("//godot/private:providers.bzl", "GodotRuntimeInfo")
load("//godot/private:versions.bzl", "require_supported_godot_version")

visibility("public")

PrebuiltArtifactInfo = provider(
    doc = "The acquired archive behind a prebuilt payload, for component provenance.",
    fields = {"digest": "Subresource Integrity digest of the archive the payload came from."},
)

_BUNDLED_PACKAGES_ATTR = attr.label_list(
    doc = "The targets that carry the package metadata of the libraries the archive's Godot bundles; they add no files.",
)

def _editor_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = ctx.file.binary, is_executable = True)
    files = depset(
        [ctx.file.binary],
        transitive = [t[DefaultInfo].files for t in ctx.attr.data],
    )
    return [DefaultInfo(
        executable = out,
        files = depset([out], transitive = [files]),
        runfiles = ctx.runfiles(transitive_files = files),
    ), PrebuiltArtifactInfo(digest = ctx.attr.digest)]

prebuilt_editor = rule(
    doc = "An archived editor executable with the rest of its archive as runfiles.",
    implementation = _editor_impl,
    executable = True,
    attrs = {
        "binary": attr.label(mandatory = True, allow_single_file = True),
        "data": attr.label_list(allow_files = True),
        "digest": attr.string(doc = "Integrity digest of the editor archive."),
        "bundled_packages": _BUNDLED_PACKAGES_ATTR,
    },
)

def _runtime_impl(ctx):
    require_supported_godot_version(ctx.attr.version)
    bundle_files = {}
    for target, destination in ctx.attr.bundle_files.items():
        payload = target[DefaultInfo].files.to_list()
        if len(payload) != 1:
            fail("runtime bundle_files requires one file per target: " + str(target.label))
        if destination in bundle_files:
            fail("duplicate runtime bundle destination: " + destination)
        bundle_files[destination] = payload[0]
    files = depset(
        ctx.files.binary + bundle_files.values(),
        transitive = [d[DefaultInfo].files for d in ctx.attr.data],
    )
    return [DefaultInfo(files = files), GodotRuntimeInfo(
        executable = ctx.file.binary,
        files = files,
        platform = ctx.attr.platform,
        cpu = ctx.attr.cpu,
        environment = ctx.attr.environment,
        facts_source = "declared",
        origin = str(ctx.label),
        version = ctx.attr.version,
        bundle_files = bundle_files,
        variant = ctx.attr.variant,
        debug_symbols = None,
        minimum_os = "",
        emscripten_version = ctx.attr.emscripten_version,
    ), PrebuiltArtifactInfo(digest = ctx.attr.digest)]

prebuilt_runtime = rule(
    doc = "An archived export template, or another prebuilt runtime binary, with its declared facts.",
    implementation = _runtime_impl,
    attrs = {
        "binary": attr.label(allow_single_file = True),
        "data": attr.label_list(allow_files = True),
        "bundle_files": attr.label_keyed_string_dict(allow_files = True),
        "platform": attr.string(mandatory = True, values = ["linux", "macos", "ios", "android", "web"]),
        "emscripten_version": attr.string(doc = "The Emscripten version a web template was built with; empty elsewhere."),
        "cpu": attr.string(mandatory = True),
        "environment": attr.string(values = ["", "device", "simulator"]),
        "version": attr.string(mandatory = True),
        "variant": attr.string(default = "release", values = ["debug", "release"]),
        "digest": attr.string(doc = "Integrity digest of the archive the template came from."),
        "bundled_packages": _BUNDLED_PACKAGES_ATTR,
    },
)
