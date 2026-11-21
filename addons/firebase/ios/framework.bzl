"""
firebase_framework: a dynamic iOS framework of a Firebase product, linked from the
product's static XCFrameworks (README.md, "Design").
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import")
load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

# The Info.plist of a framework; the layout of rules_godot's extension frameworks.
_INFO_PLIST = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleExecutable</key>
\t<string>{name}</string>
\t<key>CFBundleIdentifier</key>
\t<string>dev.autoload.addons.firebase.{name}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>{name}</string>
\t<key>CFBundlePackageType</key>
\t<string>FMWK</string>
\t<key>CFBundleShortVersionString</key>
\t<string>{version}</string>
\t<key>CFBundleSupportedPlatforms</key>
\t<array><string>{platform}</string></array>
\t<key>CFBundleVersion</key>
\t<string>{version}</string>
\t<key>MinimumOSVersion</key>
\t<string>{minimum_os}</string>
</dict>
</plist>
"""

def _slice(target):
    """The XCFramework slice directory a static XCFramework import links in this configuration."""
    includes = target[CcInfo].compilation_context.framework_includes.to_list()
    if len(includes) != 1:
        fail("%s: expected the framework search path of one XCFramework slice, got %s" % (target.label, includes))
    return includes[0]

def _framework_content(prefix, files, public):
    """
    The files to copy from the slice framework at prefix, by path in the framework.

    These are its resource bundles, such as the privacy manifests, and with public its
    Headers and Modules.
    """
    content = {}
    for file in files:
        if not file.path.startswith(prefix):
            continue
        path = file.path[len(prefix):]
        top = path.split("/", 1)[0]
        if top.endswith(".bundle") or (public and top in ["Headers", "Modules"]):
            content[path] = file
    return content

def _firebase_framework_files_impl(ctx):
    name = ctx.attr.framework_name
    directory = ctx.label.name + "/" + name + ".framework/"
    xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig]

    # rules_cc sets the install name after the linkopts, from the library's file name.
    binary = ctx.actions.declare_file(directory + name)
    apple_support.run_shell(
        actions = ctx.actions,
        xcode_config = xcode_config,
        apple_fragment = ctx.fragments.apple,
        command = 'cp "$1" "$2" && chmod u+w "$2" && xcrun install_name_tool -id "$3" "$2"',
        arguments = [ctx.file.binary.path, binary.path, "@rpath/%s.framework/%s" % (name, name)],
        inputs = [ctx.file.binary],
        outputs = [binary],
        mnemonic = "FirebaseFrameworkInstallName",
        progress_message = "Setting the install name of %{output}",
    )

    content = {}
    simulator = False
    for target in ctx.attr.libraries:
        slice = _slice(target)
        simulator = slice.endswith("-simulator")
        prefix = "%s/%s.framework/" % (slice, target.label.name)
        content |= _framework_content(prefix, ctx.files.xcframeworks, target.label.name == name)
    outputs = [binary]
    for path, file in content.items():
        output = ctx.actions.declare_file(directory + path)
        ctx.actions.symlink(output = output, target_file = file)
        outputs.append(output)

    plist = ctx.actions.declare_file(directory + "Info.plist")
    ctx.actions.write(plist, _INFO_PLIST.format(
        name = name,
        version = ctx.attr.version,
        platform = "iPhoneSimulator" if simulator else "iPhoneOS",
        minimum_os = str(xcode_config.minimum_os_for_platform_type(apple_common.platform_type.ios)),
    ))
    return [DefaultInfo(files = depset(outputs + [plist]))]

_firebase_framework_files = rule(
    doc = "Lay out a Firebase product's dynamic library as <framework_name>.framework.",
    implementation = _firebase_framework_files_impl,
    attrs = {
        "binary": attr.label(
            doc = "The dynamic library; its copy gets the framework's install name.",
            allow_single_file = True,
            mandatory = True,
        ),
        "framework_name": attr.string(mandatory = True),
        "libraries": attr.label_list(
            doc = """
            The static XCFramework imports the library links. The framework takes their
            resource bundles, and the Headers and Modules of the one named framework_name.
            """,
            providers = [CcInfo],
            mandatory = True,
        ),
        "version": attr.string(doc = "The Firebase version.", mandatory = True),
        "xcframeworks": attr.label_list(doc = "The files of the XCFrameworks' iOS slices.", allow_files = True),
    } | apple_support.action_required_attrs(),
    fragments = ["apple"],
)

def _compilation_only_impl(ctx):
    return [CcInfo(compilation_context = cc_common.merge_compilation_contexts(
        compilation_contexts = [dep[CcInfo].compilation_context for dep in ctx.attr.deps],
    ))]

_compilation_only = rule(
    doc = "Forward only the headers and framework search paths of deps, nothing to link.",
    implementation = _compilation_only_impl,
    attrs = {"deps": attr.label_list(providers = [CcInfo])},
    provides = [CcInfo],
)

def firebase_framework(
        name,
        framework_name,
        libraries,
        version,
        frameworks = [],
        header_libraries = [],
        sdk_frameworks = [],
        sdk_dylibs = [],
        xcframeworks = ["@firebase_ios//:xcframework_files"],
        visibility = None):
    """
    Declare the dynamic framework framework_name of a Firebase product.

    Creates `<name>`, the framework import that native code links and compiles against,
    and `<name>.bundle`, a bundle_only import of the same framework and of those it links,
    for an extension's platform_deps: through it, iOS applications embed and sign them.

    Args:
        name: Name of the framework import.
        framework_name: Name of the framework and its binary, such as FirebaseCore.
        libraries: The static XCFramework imports the framework holds, entirely.
        version: The Firebase version.
        frameworks: Names of the firebase_framework targets this one links.
        header_libraries: Libraries among libraries whose headers the framework's headers
            include, such as FirebaseFirestoreInternal: code that compiles against the
            framework finds them in their XCFramework, but links only the framework.
        sdk_frameworks: System frameworks the libraries need.
        sdk_dylibs: System libraries the libraries need, without the lib prefix.
        xcframeworks: The files of the XCFrameworks' iOS slices.
        visibility: Visibility of the imports.
    """
    compatible = ["@platforms//os:ios"]
    binary = "lib%s.dylib" % framework_name
    cc_binary(
        name = binary,
        # Static XCFramework imports are alwayslink: every object, Objective-C
        # categories included, goes into the framework, which exports all their symbols.
        deps = libraries + frameworks,
        linkshared = True,
        linkopts = [
            "-Wl,-rpath,@executable_path/Frameworks",
            "-Wl,-rpath,@loader_path/..",
            # Room for the framework's install name, which is longer than the library's.
            "-Wl,-headerpad_max_install_names",
        ] + ["-framework " + f for f in sdk_frameworks] + ["-l" + d for d in sdk_dylibs],
        tags = ["manual"],
        target_compatible_with = compatible,
        visibility = ["//visibility:private"],
    )
    files = name + ".files"
    _firebase_framework_files(
        name = files,
        binary = ":" + binary,
        framework_name = framework_name,
        libraries = libraries,
        version = version,
        xcframeworks = xcframeworks,
        tags = ["manual"],
        target_compatible_with = compatible,
        visibility = ["//visibility:private"],
    )
    headers = []
    if header_libraries:
        headers = [":" + name + ".headers"]
        _compilation_only(
            name = name + ".headers",
            deps = header_libraries,
            tags = ["manual"],
            target_compatible_with = compatible,
            visibility = ["//visibility:private"],
        )
    for suffix, bundle_only in [("", False), (".bundle", True)]:
        apple_dynamic_framework_import(
            name = name + suffix,
            bundle_only = bundle_only,
            framework_imports = [":" + files],
            deps = [framework + suffix for framework in frameworks] + ([] if bundle_only else headers),
            target_compatible_with = compatible,
            visibility = visibility,
        )
