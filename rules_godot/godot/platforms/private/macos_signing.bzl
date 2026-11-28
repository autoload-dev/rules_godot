"""Sign an assembled macOS application bundle."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//godot:providers.bzl", "GodotDesktopAppInfo")
load(":desktop.bzl", "desktop_result")
load(":launch.bzl", "LAUNCH_ATTRS")

visibility(["//godot/platforms/private/tests", "//godot/private"])

_MAC_TOOLS = "@rules_apple//apple/internal:mac_tools_toolchain_type"

def _sign_impl(ctx):
    app = ctx.attr.app[GodotDesktopAppInfo]
    if app.operating_system != "macos":
        fail("godot_macos_sign requires a macOS application")
    mode = ctx.attr._mode[BuildSettingInfo].value
    if mode not in ["adhoc", "certificate"]:
        fail("macOS signer requires adhoc or certificate mode")
    identity = "-" if mode == "adhoc" else ctx.attr.identity
    if mode == "certificate" and identity in ["", "-"]:
        fail("certificate mode requires a nonempty macos_signing_identity other than '-'")
    tool = ctx.toolchains[_MAC_TOOLS].mac_tools_info.codesigningtool
    bundle = ctx.actions.declare_directory(ctx.label.name + "/" + app.bundle.basename)
    archive = ctx.actions.declare_file(ctx.label.name + "/" + app.archive.basename)
    executable = ctx.actions.declare_file(ctx.label.name + "/" + app.bundle.basename.removesuffix(".app") + ".run")
    args = ctx.actions.args()
    args.add("--input", app.bundle.path)
    args.add("--output", bundle.path)
    args.add("--archive", archive)
    args.add("--codesigning-tool", tool.executable)
    args.add("--identity", identity)
    inputs = [app.bundle]
    if ctx.file.entitlements:
        args.add("--entitlements", ctx.file.entitlements)
        inputs.append(ctx.file.entitlements)
    requirements = {"no-remote": "1", "requires-darwin": "1"}
    if mode == "certificate":
        requirements.update({"no-cache": "1", "no-sandbox": "1"})
    ctx.actions.run(
        executable = ctx.executable._signer,
        tools = [tool],
        inputs = inputs,
        outputs = [bundle, archive],
        arguments = [args],
        execution_requirements = requirements,
        mnemonic = "GodotMacosSign",
        progress_message = "Signing %{label}",
    )

    # Signing keeps the UUIDs the application's debug symbols match.
    groups = ctx.attr.app[OutputGroupInfo]
    return desktop_result(
        ctx,
        executable = executable,
        bundle = bundle,
        archive = archive,
        operating_system = "macos",
        executable_path = app.executable_path,
        debug_symbols = groups.debug_symbols,
        validation = groups._validation,
        runtime_component = app.runtime_component,
        missing_extension_libraries = groups.missing_extension_libraries,
    )

godot_macos_sign = rule(
    doc = "Sign a selected macOS bundle copy, preserving its debug symbols and validation.",
    implementation = _sign_impl,
    executable = True,
    attrs = {
        "_mode": attr.label(default = Label("//godot:macos_signing")),
        "app": attr.label(
            doc = """
            macOS application target providing GodotDesktopAppInfo; Linux bundles are
            rejected.
            """,
            mandatory = True,
            providers = [GodotDesktopAppInfo],
        ),
        "identity": attr.string(
            doc = """
            codesign identity; '-' uses ad hoc signing, certificate names use the local
            keychain and disable caching/sandboxing.
            """,
            default = "",
        ),
        "entitlements": attr.label(
            doc = "Optional entitlements plist passed to the pinned signing tool.",
            allow_single_file = [".plist", ".entitlements"],
        ),
        "_signer": attr.label(
            default = Label("//tools/platforms:sign_macos"),
            executable = True,
            cfg = "exec",
        ),
    } | LAUNCH_ATTRS,
    toolchains = [_MAC_TOOLS],
    exec_compatible_with = ["@platforms//os:osx"],
)
