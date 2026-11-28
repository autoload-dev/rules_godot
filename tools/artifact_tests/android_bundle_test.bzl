"""Test an Android App Bundle through the universal APK bundletool generates."""

load("@rules_android//providers:providers.bzl", "AndroidBundleInfo")
load("@rules_java//java/common:java_common.bzl", "java_common")

def _runfile_key(ctx, short_path):
    # The path below a runfiles directory; those of external files start with ../.
    if short_path.startswith("../"):
        return short_path[3:]
    return ctx.workspace_name + "/" + short_path

def _quote(value):
    # bazel_skylib is only a development dependency of this module.
    return "'" + value.replace("'", "'\\''") + "'"

def _android_bundle_test_impl(ctx):
    bundle = ctx.attr.bundle[AndroidBundleInfo].unsigned_aab
    runtime = ctx.attr._jdk[java_common.JavaRuntimeInfo]
    inspector = ctx.attr._inspector[DefaultInfo].files_to_run.executable
    java_home = runtime.java_home_runfiles_path
    args = [
        ("--bundle", bundle.short_path),
        ("--bundletool", ctx.file.bundletool.short_path),
        ("--java", java_home + "/bin/java"),
    ]
    files = [bundle, ctx.file.bundletool]
    if ctx.attr.debug_symbols:
        args.append(("--debug-symbols", ctx.file.debug_symbols.short_path))
        files.append(ctx.file.debug_symbols)
    launcher = ctx.actions.declare_file(ctx.label.name)
    arguments = [
        '%s "$runfiles/%s"' % (flag, _runfile_key(ctx, path))
        for flag, path in args
    ] + ["--library " + library for library in ctx.attr.apk_libraries] + [
        "--manifest-entry " + _quote(entry)
        for entry in ctx.attr.manifest_entries
    ] + ["--java-class " + java_class for java_class in ctx.attr.classes] + [
        "--symbol-library " + library
        for library in ctx.attr.symbol_libraries
    ] + [
        "--pck-file " + _quote(path)
        for path in ctx.attr.pck_files
    ] + (["--debug-info"] if ctx.attr.debug_info else [])
    ctx.actions.expand_template(
        template = ctx.file._launcher_template,
        output = launcher,
        substitutions = {
            "{INSPECTOR}": _runfile_key(ctx, inspector.short_path),
            "{ARGUMENTS}": "\n".join(["  %s \\" % argument for argument in arguments]),
            "{APPLICATION_ID}": ctx.attr.application_id,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = files, transitive_files = runtime.files)
    runfiles = runfiles.merge(ctx.attr._inspector[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = launcher, runfiles = runfiles)]

android_bundle_test = rule(
    doc = """
    Test an Android App Bundle the way Google Play delivers it, without a device.

    The test validates the bundle with bundletool, generates its universal APK and
    checks that the APK stores `assets/main.pck` uncompressed and carries the export's
    command line, that the base manifest declares `application_id` and Godot's
    activity, and every listed manifest entry, native library, Java class and PCK
    resource. With `debug_symbols`, each library of the application's symbol ZIP must
    match the stripped library the APK packages by GNU build ID and keep its symbol
    table. The test fails with the list of what is missing. It writes the evidence,
    such as the PCK's resource paths, to `bundle.json` among the test's undeclared
    outputs.

    The inspection runs on the execution platform with the host JDK, so a bundle built
    for an Android platform is inspected on the machine running the test. Build the
    bundle with `--@autoload_rules_godot//godot:android_format=aab`; see
    [App Bundles](../../platforms.md#app-bundles-for-store-upload).

    Example:
    ```starlark
    android_bundle_test(
        name = "app_packages_extension_test",
        bundle = ":app",
        bundletool = "@bundletool//file",
        application_id = "org.example.game",
        apk_libraries = ["lib/arm64-v8a/libgame.so"],
        pck_files = ["main/main.gd"],
    )
    ```

    `@bundletool//file` is an `http_file` of the checksum-pinned `bundletool-all` JAR
    in the caller's `MODULE.bazel`.
    """,
    implementation = _android_bundle_test_impl,
    attrs = {
        "bundle": attr.label(
            doc = "The App Bundle to test: a godot_app built with the aab Android format, or another target providing rules_android's AndroidBundleInfo.",
            mandatory = True,
            providers = [AndroidBundleInfo],
        ),
        "bundletool": attr.label(
            doc = "The bundletool-all .jar that validates the bundle and generates its APK; it carries aapt2. Pin it by checksum.",
            mandatory = True,
            allow_single_file = [".jar"],
        ),
        "application_id": attr.string(
            doc = "The package name the base manifest must declare, as godot_app's application_id.",
            mandatory = True,
        ),
        "debug_symbols": attr.label(
            doc = """
            The application's `<name>.debug_symbols` ZIP of `<abi>/<name>.so` entries.
            Each library in it must be the one the APK packages stripped, by GNU build ID,
            and keep its symbol table. Unset, the test checks no symbols.
            """,
            allow_single_file = [".zip"],
        ),
        "symbol_libraries": attr.string_list(
            doc = "`<abi>/<name>.so` paths debug_symbols must contain, such as `arm64-v8a/libgodot_android.so`.",
        ),
        "debug_info": attr.bool(
            doc = "Whether the libraries of debug_symbols must also carry DWARF, as a release build with `--copt=-g` keeps it.",
        ),
        "apk_libraries": attr.string_list(
            doc = "APK paths of native libraries the universal APK must contain, such as `lib/arm64-v8a/libgodot_android.so`.",
        ),
        "pck_files": attr.string_list(
            doc = "Resource paths `assets/main.pck` must contain, without `res://`, such as `main/main.gd`.",
        ),
        "manifest_entries": attr.string_list(
            doc = """
            Text the base manifest bundletool prints must contain, such as a
            permission's name.
            """,
        ),
        "classes": attr.string_list(
            doc = "Fully qualified Java classes the universal APK's dex files must define, such as a plugin's entry class; a class only referenced does not count.",
        ),
        "_launcher_template": attr.label(
            default = Label("//tools/artifact_tests:android_bundle_test.sh.tpl"),
            allow_single_file = True,
        ),
        "_inspector": attr.label(
            default = Label("//tools/artifact_tests:inspect_android_bundle"),
            executable = True,
            cfg = config.exec("test"),
        ),
        "_jdk": attr.label(
            default = "@bazel_tools//tools/jdk:current_host_java_runtime",
            cfg = config.exec("test"),
            providers = [java_common.JavaRuntimeInfo],
        ),
    },
    # The inspection runs on the test's execution platform; without this group,
    # Bazel would look for an execution platform matching the Android target platform.
    exec_groups = {"test": exec_group()},
    test = True,
)
