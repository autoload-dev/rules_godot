"""
What a godot_cc_extension builds from its attributes.

A select() over //godot:tool in deps builds the tool configuration's library from other
dependencies; the shared library finds its shared dependencies beside it; headers reach the
archive, which the shared library links; the shared library exports only the entry symbol, on
macOS through the linker's export list and on Android through a version script;
descriptor attributes and data reach the extension and its tool view; minimum
operating-system versions reach GodotExtensionInfo. On iOS the extension is a framework
named after the target, whose binary combines the library of every CPU and gets the
framework's install name and which carries the dynamic frameworks its library links, or
with ios_linkage = "static" the archive the application links.
"""

load("@rules_apple//apple:providers.bzl", "AppleFrameworkImportInfo")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("@rules_testing//lib:util.bzl", "TestingAspectInfo")
load("//godot/extension:defs.bzl", "godot_cc_extension")
load("//godot/private:providers.bzl", "GodotExtensionInfo")
load("//godot/private/config:transitions.bzl", "platform_slice_transition")
load("//godot/private/tests:fixture_files.bzl", "fixture_file")
load("//godot/private/tests:toolchains.bzl", "own_toolchains")
load(":descriptor_tests.bzl", "descriptor_contents")
load(":library_fixtures.bzl", "dynamic_xcframework_fixture")

visibility("private")

_SMALL = {"size": "small"}
_MACOS_ONLY = _SMALL | {"target_compatible_with": ["@platforms//os:macos"]}
_IOS_SIMULATOR = {"//command_line_option:platforms": str(Label("//godot/platforms:ios_sim_arm64"))}
_IOS_SIMULATOR_BOTH_CPUS = {"//command_line_option:platforms": str(Label(":ios_simulator_both_cpus"))}

# Android analysis needs the SDK and NDK toolchains, which MODULE.bazel registers; without an
# SDK the test is skipped.
_ANDROID = {
    "//command_line_option:platforms": str(Label("//godot/platforms:android_arm64")),
} | own_toolchains()
_ANDROID_SDK = {"target_compatible_with": [Label("//godot/platforms/private/tests:requires_android_sdk")]}

def _extension(name, **kwargs):
    godot_cc_extension(
        name = name,
        srcs = ["static_fixture.cc"],
        entry_symbol = "archive_fixture_init",
        tags = ["manual"],
        **kwargs
    )

def _shared(name):
    """The shared library target of the test's extension."""
    return "%s_extension.library.shared/lib%s_extension.so" % (name, name)

def _links(target):
    """The input paths of a target's one CppLink action."""
    links = [action for action in target[TestingAspectInfo].actions if action.mnemonic == "CppLink"]
    return struct(
        count = len(links),
        inputs = [file.path for file in links[0].inputs.to_list()] if links else [],
        argv = links[0].argv if links else [],
    )

def _test_tool_branch_of_deps_builds_the_tool_library(name):
    _extension(
        name + "_extension",
        deps = select({
            "//godot:tool": [":editor_only_dependency"],
            "//conditions:default": [":runtime_only_dependency"],
        }),
    )
    for configuration, settings, linked, unlinked in [
        ("tool", {str(Label("//godot/private/config:tool")): True, str(Label("//godot:variant")): "editor"}, "editor_only_dependency", "runtime_only_dependency"),
        ("runtime", {}, "runtime_only_dependency", "editor_only_dependency"),
    ]:
        analysis_test(
            name = name + "_" + configuration,
            target = _shared(name),
            impl = _tool_branch_of_deps_builds_the_tool_library,
            attrs = {"linked": attr.string(), "unlinked": attr.string()},
            attr_values = _SMALL | {"linked": linked, "unlinked": unlinked},
            config_settings = settings,
        )
    native.test_suite(name = name, tests = [name + "_tool", name + "_runtime"])

def _tool_branch_of_deps_builds_the_tool_library(env, target):
    links = _links(target)
    env.expect.that_int(links.count, expr = "number of CppLink actions").equals(1)

    # Paths, not names: macOS links the dependencies' archives, Linux their objects under
    # _objs/<library>/.
    for dependency, expected in [(env.ctx.attr.linked, True), (env.ctx.attr.unlinked, False)]:
        env.expect.where(dependency = dependency).that_bool(
            bool([path for path in links.inputs if dependency in path]),
            expr = dependency + " linked",
        ).equals(expected)

def _test_tool_view_is_the_tool_configuration(name):
    _extension(name + "_extension")
    analysis_test(
        name = name,
        target = name + "_extension.tool",
        impl = _tool_view_is_the_tool_configuration,
        attr_values = _SMALL,
    )

def _tool_view_is_the_tool_configuration(env, target):
    tags = target[GodotExtensionInfo].library.tags
    env.expect.that_bool(tags.endswith(".editor"), expr = "tool view tags " + tags).equals(True)

def _test_shared_library_finds_its_dependencies_beside_it(name):
    _extension(name + "_extension")
    analysis_test(
        name = name,
        target = _shared(name),
        impl = _shared_library_finds_its_dependencies_beside_it,
        attr_values = _SMALL,
    )

def _shared_library_finds_its_dependencies_beside_it(env, target):
    argv = _links(target).argv
    env.expect.that_bool(
        "-Wl,-rpath,$ORIGIN" in argv or "-Wl,-rpath,@loader_path" in argv,
        expr = "the link has a loader-relative run path",
    ).equals(True)

def _test_shared_library_exports_only_the_entry_symbol(name):
    _extension(name + "_extension")
    analysis_test(
        name = name + "_host",
        target = _shared(name),
        impl = _shared_library_exports_only_the_entry_symbol,
        attr_values = _SMALL,
    )
    analysis_test(
        name = name + "_android",
        target = _shared(name),
        impl = _shared_library_exports_only_the_entry_symbol,
        attr_values = _SMALL | _ANDROID_SDK,
        config_settings = _ANDROID,
    )
    native.test_suite(name = name, tests = [name + "_host", name + "_android"])

def _shared_library_exports_only_the_entry_symbol(env, target):
    links = _links(target)
    scripts = [path for path in links.inputs if path.endswith(".exports.lds")]
    if "-Wl,-exported_symbol,_archive_fixture_init" in links.argv:
        env.expect.that_collection(scripts).has_size(0)
        return
    env.expect.that_collection(scripts).has_size(1)
    env.expect.that_collection(links.argv).contains("-Wl,--version-script," + scripts[0])

def _test_hdrs_reach_the_code_the_shared_library_links(name):
    fixture_file(
        name = name + "_header",
        out = name + "_fixture.h",
        content = "#pragma once",
    )
    _extension(name + "_extension", hdrs = [":" + name + "_header"])
    analysis_test(
        name = name,
        targets = {
            "code": name + "_extension.native",
            "archive": name + "_extension.library.archive",
            "shared": _shared(name),
        },
        impl = _hdrs_reach_the_code_the_shared_library_links,
        attrs = {"header": attr.string()},
        attr_values = _SMALL | {"header": name + "_fixture.h"},
    )

# Compile actions discover their headers at execution, so analysis sees the headers in the
# code's hdrs. The shared library compiles nothing; it links the library's archive, which
# holds the code.
def _hdrs_reach_the_code_the_shared_library_links(env, targets):
    files = [
        file.basename
        for dependency in targets.code[TestingAspectInfo].attrs.hdrs
        for file in dependency[DefaultInfo].files.to_list()
    ]
    env.expect.that_collection(files).contains(env.ctx.attr.header)
    env.expect.that_collection(
        [str(dependency.label) for dependency in targets.archive[TestingAspectInfo].attrs.deps],
    ).contains_exactly([str(targets.code.label)])
    env.expect.that_collection(
        [str(dependency.label) for dependency in targets.shared[TestingAspectInfo].attrs.deps],
    ).contains_exactly([str(targets.archive.label)])

def _test_descriptor_attributes_reach_both_extensions(name):
    _extension(
        name + "_extension",
        compatibility_minimum = "4.8.0",
        data = ["dependency_fixture.txt"],
        reloadable = True,
    )
    analysis_test(
        name = name,
        targets = {
            "editor": name + "_extension.tool",
            "runtime": name + "_extension",
        },
        impl = _descriptor_attributes_reach_both_extensions,
        attr_values = _SMALL,
    )

def _descriptor_attributes_reach_both_extensions(env, targets):
    for extension in ["editor", "runtime"]:
        contents = descriptor_contents(getattr(targets, extension))
        env.expect.where(extension = extension).that_collection(contents).has_size(1)
        for content in contents:
            lines = env.expect.where(extension = extension).that_collection(content.split("\n"))
            lines.contains_at_least(['compatibility_minimum = "4.8.0"', "reloadable = true"])
            lines.contains_predicate(matching.contains('/dependency_fixture.txt": ""}'))

def _test_minimum_os_versions_reach_extension_info(name):
    _extension(name + "_extension", minimum_os_versions = {"macos": "13.0"})
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _minimum_os_versions_reach_extension_info,
        attr_values = _SMALL,
    )

def _minimum_os_versions_reach_extension_info(env, target):
    env.expect.that_dict(target[GodotExtensionInfo].minimum_os_versions).contains_exactly({"macos": "13.0"})

def _ios_analysis_test(name, impl, target_suffix = "", config_settings = _IOS_SIMULATOR, **extension_kwargs):
    """Declare an extension and analyze it, or its target_suffix target, in the iOS Simulator."""
    _extension(name + "_extension", **extension_kwargs)
    analysis_test(
        name = name,
        target = name + "_extension" + target_suffix,
        impl = impl,
        attr_values = _MACOS_ONLY,
        config_settings = config_settings,
    )

def _test_ios_extension_is_a_framework(name):
    _ios_analysis_test(name, _ios_extension_is_a_framework)

def _ios_extension_is_a_framework(env, target):
    library = target[GodotExtensionInfo].library
    framework = target.label.name + ".framework"
    env.expect.that_str(library.link_kind).equals("framework")
    env.expect.that_str(library.file.basename).equals(target.label.name)
    env.expect.that_str(library.resource_path).equals(
        "addons/%s/bin/ios.arm64.simulator.release/%s" % (target.label.name, framework),
    )
    env.expect.that_collection(
        [file.path.split(framework + "/")[-1] for file in target[AppleFrameworkImportInfo].framework_imports.to_list()],
        expr = "the files an Apple application embeds",
    ).contains_exactly([target.label.name, "Info.plist"])

def _test_ios_framework_carries_the_frameworks_it_links(name):
    core = name + "_core"
    analytics = name + "_analytics"
    dynamic_xcframework_fixture(name = core, binary = "FixtureCore", linked = True)
    dynamic_xcframework_fixture(
        name = analytics,
        binary = "FixtureAnalytics",
        linked = True,
        deps = [":" + core],
    )
    _ios_analysis_test(
        name,
        _ios_framework_carries_the_frameworks_it_links,
        deps = [":" + analytics],
    )

def _ios_framework_carries_the_frameworks_it_links(env, target):
    # rules_apple's framework aspect stops at the extension, so an application embeds the
    # frameworks its library links, transitive ones included, only through its provider.
    binaries = [
        file.basename
        for file in target[AppleFrameworkImportInfo].framework_imports.to_list()
        if file.extension != "plist"
    ]
    env.expect.that_collection(
        binaries,
        expr = "the framework binaries an Apple application embeds",
    ).contains_exactly(["FixtureAnalytics", "FixtureCore", target.label.name])

def _test_ios_framework_binary_has_its_install_name(name):
    _ios_analysis_test(name, _ios_framework_binary_has_its_install_name, ".library.ios_framework_files")

def _ios_framework_binary_has_its_install_name(env, target):
    # The toolchain names the linked library after its file, so the framework's copy
    # gets the framework's install name afterwards.
    framework = target.label.name.removesuffix(".library.ios_framework_files")
    actions = [action for action in target[TestingAspectInfo].actions if action.mnemonic == "GodotFrameworkBinary"]
    env.expect.that_int(len(actions), expr = "number of install name actions").equals(1)
    env.expect.that_collection(actions[0].argv).contains("@rpath/%s.framework/%s" % (framework, framework))

def _test_ios_framework_binary_combines_every_cpu(name):
    _ios_analysis_test(name, _ios_framework_binary_combines_every_cpu, ".library.ios_framework_files", config_settings = _IOS_SIMULATOR_BOTH_CPUS)

def _ios_framework_binary_combines_every_cpu(env, target):
    # rules_apple embeds one binary per framework, whichever CPU's framework it takes.
    (action,) = [action for action in target[TestingAspectInfo].actions if action.mnemonic == "GodotFrameworkBinary"]
    libraries = [file.path for file in action.inputs.to_list() if file.extension == "so"]
    env.expect.that_int(len(libraries), expr = "number of combined libraries").equals(2)
    for cpu in ["ios_sim_arm64", "ios_x86_64"]:
        env.expect.that_bool(
            any([cpu in path for path in libraries]),
            expr = "a library of the %s configuration among %s" % (cpu, libraries),
        ).equals(True)

_FrameworkBinariesInfo = provider(
    doc = "The paths of the iOS framework binary each platform slice of an extension reaches.",
    fields = ["paths"],
)

def _framework_slices_impl(ctx):
    return [_FrameworkBinariesInfo(paths = {
        cpu: extension[GodotExtensionInfo].library.file.path
        for cpu, extension in ctx.split_attr.extension.items()
    })]

# What a pack does with an extension: splits it once per platform slice of the application.
_framework_slices = rule(
    implementation = _framework_slices_impl,
    attrs = {
        "extension": attr.label(mandatory = True, providers = [GodotExtensionInfo], cfg = platform_slice_transition),
    },
)

def _test_ios_framework_is_one_configuration_for_every_cpu(name):
    _extension(name + "_extension")
    _framework_slices(name = name + "_slices", extension = ":" + name + "_extension", tags = ["manual"])
    analysis_test(
        name = name,
        target = name + "_slices",
        impl = _ios_framework_is_one_configuration_for_every_cpu,
        attr_values = _MACOS_ONLY,
        config_settings = _IOS_SIMULATOR_BOTH_CPUS,
    )

def _ios_framework_is_one_configuration_for_every_cpu(env, target):
    # Every platform slice reaches the same framework, so its one action combines the
    # libraries for all of them; rules_apple embeds the one binary whichever it takes.
    paths = target[_FrameworkBinariesInfo].paths
    env.expect.that_collection(paths.keys(), expr = "platform slices").contains_exactly(["arm64", "x86_64"])
    env.expect.that_int(
        len({binary: None for binary in paths.values()}),
        expr = "distinct framework binaries of the slices",
    ).equals(1)

def _test_ios_static_linkage_links_the_archive(name):
    _ios_analysis_test(name, _ios_static_linkage_links_the_archive, ios_linkage = "static")

def _ios_static_linkage_links_the_archive(env, target):
    library = target[GodotExtensionInfo].library
    env.expect.that_str(library.link_kind).equals("static")
    env.expect.that_str(library.file.extension).equals("a")

def cc_extension_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_tool_branch_of_deps_builds_the_tool_library,
            _test_tool_view_is_the_tool_configuration,
            _test_shared_library_finds_its_dependencies_beside_it,
            _test_shared_library_exports_only_the_entry_symbol,
            _test_hdrs_reach_the_code_the_shared_library_links,
            _test_descriptor_attributes_reach_both_extensions,
            _test_minimum_os_versions_reach_extension_info,
            _test_ios_extension_is_a_framework,
            _test_ios_framework_carries_the_frameworks_it_links,
            _test_ios_framework_binary_has_its_install_name,
            _test_ios_framework_binary_combines_every_cpu,
            _test_ios_framework_is_one_configuration_for_every_cpu,
            _test_ios_static_linkage_links_the_archive,
        ],
    )
