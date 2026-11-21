"""
What an extension makes of its library in one configuration.

The configuration decides the library through select() and the feature tags of its
descriptor fragment; the library's providers decide its link kind and its runtime
dependencies; the tool view configures the same declaration for editor processes. A link
kind the operating system cannot load, a non-library data file on Android, two runtime
files of one name and an Apple import that bundles several frameworks without linking any
fail analysis; a configuration without a select() branch is Bazel's
error.
"""

load("@rules_apple//apple:providers.bzl", "AppleFrameworkImportInfo")
load("@rules_cc//cc:cc_binary.bzl", "cc_binary")
load("@rules_cc//cc:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("//godot/extension:defs.bzl", "godot_extension")
load("//godot/private:providers.bzl", "GodotExtensionInfo")
load(":descriptor_tests.bzl", "descriptor_contents")
load(":extension_contracts.bzl", "dynamic_xcframework_fixture", "extension_library_fixture", "xcframework_fixture")

_SMALL = {"size": "small"}
_MACOS_ONLY = _SMALL | {"target_compatible_with": ["@platforms//os:macos"]}

def _platform(name):
    return {"//command_line_option:platforms": str(Label("//godot/platforms:" + name))}

def _extension(name, **kwargs):
    godot_extension(
        name = name,
        entry_symbol = "configured_fixture_init",
        tags = ["manual"],
        **kwargs
    )

def _directory(target):
    """The directory of an extension's descriptor by default: Godot's add-on convention."""
    return "addons/%s/" % target.label.name

def _library(name, filename):
    extension_library_fixture(name = name + "_fixture", filename = filename, tags = ["manual"])
    return ":" + name + "_fixture"

def _test_android_cpus_select_their_libraries(name):
    _extension(
        name + "_extension",
        # The editor of this Android-only extension loads no library.
        library = select({
            "//godot:tool": None,
            "@platforms//cpu:armv7": _library(name + "_arm32", "libarm32.so"),
            "@platforms//cpu:aarch64": _library(name + "_arm64", "libarm64.so"),
        }),
    )
    for cpu, platform in [("arm32", "android_arm32"), ("arm64", "android_arm64")]:
        analysis_test(
            name = name + "_" + cpu,
            target = name + "_extension",
            impl = _android_cpu_selects_its_library,
            attrs = {"cpu": attr.string()},
            attr_values = _SMALL | {"cpu": cpu},
            config_settings = _platform(platform),
        )
    native.test_suite(name = name, tests = [name + "_arm32", name + "_arm64"])

def _android_cpu_selects_its_library(env, target):
    cpu = env.ctx.attr.cpu
    library = target[GodotExtensionInfo].library
    env.expect.that_str(library.tags).equals("android.%s.release" % cpu)
    env.expect.that_str(library.cpu).equals(cpu)
    env.expect.that_str(library.link_kind).equals("dynamic")
    env.expect.that_str(library.file.basename).equals("lib%s.so" % cpu)
    env.expect.that_str(library.resource_path).equals(_directory(target) + "bin/android.%s.release/lib%s.so" % (cpu, cpu))
    lines = descriptor_contents(target)[0].split("\n")
    env.expect.that_collection(lines).contains('android.%s.release = "res://%sbin/android.%s.release/lib%s.so"' % (cpu, _directory(target), cpu, cpu))
    env.expect.that_collection([line for line in lines if " = \"res://" in line]).has_size(1)

# Without resource_path the descriptor lies where Godot add-ons keep theirs, in the
# extension and its tool view alike.
def _test_descriptor_defaults_to_the_addon_convention(name):
    _extension(name + "_extension", library = _library(name + "_library", "libdefault.so"))
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _descriptor_defaults_to_the_addon_convention,
        attr_values = _SMALL,
    )

def _descriptor_defaults_to_the_addon_convention(env, target):
    extension = target[GodotExtensionInfo]
    path = _directory(target) + target.label.name + ".gdextension"
    env.expect.that_str(extension.descriptor_path).equals(path)
    for field in ["runtime_resource_paths", "editor_resource_paths"]:
        env.expect.where(field = field).that_collection(getattr(extension, field).keys()).contains(path)

def _test_variant_reaches_the_tags(name):
    _extension(name + "_extension", library = _library(name + "_library", "libvariant.so"))
    for case, platform, variant, tags in [
        ("debug", "android_arm64", "debug", "android.arm64.debug"),
        ("linux_release", "linux_x86_64", "release", "linux.x86_64.release"),
    ]:
        analysis_test(
            name = name + "_" + case,
            target = name + "_extension",
            impl = _tags_derive_from_configuration,
            attrs = {"tags_": attr.string()},
            attr_values = _SMALL | {"tags_": tags},
            config_settings = _platform(platform) | {str(Label("//godot:variant")): variant},
        )
    native.test_suite(name = name, tests = [name + "_debug", name + "_linux_release"])

def _tags_derive_from_configuration(env, target):
    env.expect.that_str(target[GodotExtensionInfo].library.tags).equals(env.ctx.attr.tags_)

def _test_shared_library_dependencies_load_from_beside_it(name):
    cc_import(
        name = name + "_dependency",
        shared_library = _library(name + "_dependency_file", "libdependency.so"),
        tags = ["manual"],
    )
    cc_import(
        name = name + "_library",
        shared_library = _library(name + "_library_file", "libvendor.so"),
        deps = [":" + name + "_dependency"],
        tags = ["manual"],
    )
    _extension(
        name + "_extension",
        library = ":" + name + "_library",
        data = [_library(name + "_handler", "crash_handler")],
    )
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _shared_library_dependencies_load_from_beside_it,
        attr_values = _SMALL,
    )

def _shared_library_dependencies_load_from_beside_it(env, target):
    extension = target[GodotExtensionInfo]
    library = extension.library

    # The host's configuration: cc_import needs a C++ toolchain for the target platform.
    directory = _directory(target) + "bin/%s/" % library.tags

    # Data that is no shared library keeps its path below its package, as a vendor's
    # add-on lays it out; applications place it beside the executable.
    handler = _directory(target) + "%s_handler_fixture/crash_handler" % target.label.name.removesuffix("_extension")
    env.expect.that_str(library.file.basename).equals("libvendor.so")
    env.expect.that_collection(library.runtime_dependencies.keys()).contains_exactly([
        handler,
        directory + "libdependency.so",
    ])
    env.expect.that_collection(library.beside_executable).contains_exactly([handler])
    env.expect.that_collection(sorted(extension.runtime_resource_paths)).contains_at_least([
        handler,
        directory + "libdependency.so",
        directory + "libvendor.so",
    ])
    lines = descriptor_contents(target)[0].split("\n")
    env.expect.that_collection(lines).contains(
        '%s = {"res://%slibdependency.so": "", "res://%s": ""}' % (library.tags, directory, handler),
    )

def _test_linked_shared_library_carries_its_shared_deps(name):
    cc_import(
        name = name + "_dependency",
        shared_library = _library(name + "_dependency_file", "libshared_dependency.so"),
        tags = ["manual"],
    )
    cc_binary(
        name = "lib%s.so" % name,
        srcs = ["static_fixture.cc"],
        linkshared = True,
        deps = [":" + name + "_dependency"],
        tags = ["manual"],
    )
    _extension(name + "_extension", library = ":lib%s.so" % name)
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _linked_shared_library_carries_its_shared_deps,
        attr_values = _SMALL,
    )

def _linked_shared_library_carries_its_shared_deps(env, target):
    library = target[GodotExtensionInfo].library
    env.expect.that_str(library.link_kind).equals("dynamic")
    env.expect.that_collection([file.basename for file in library.runtime_dependencies.values()]).contains_exactly([
        "libshared_dependency.so",
    ])

# A consumer's cc_shared_library is the library as it is: the copy of the library in its
# runfiles, under rules_cc's _solib directory, is no dependency of it.
def _test_cc_shared_library_is_the_library(name):
    cc_import(
        name = name + "_dependency",
        shared_library = _library(name + "_dependency_file", "libshared_library_dependency.so"),
        tags = ["manual"],
    )
    cc_library(
        name = name + "_code",
        srcs = ["static_fixture.cc"],
        deps = [":" + name + "_dependency"],
        tags = ["manual"],
    )
    cc_shared_library(
        name = name + "_shared",
        shared_lib_name = "lib%s.so" % name,
        deps = [":" + name + "_code"],
        tags = ["manual"],
    )
    _extension(name + "_extension", library = ":" + name + "_shared")
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _cc_shared_library_is_the_library,
        attr_values = _SMALL,
    )

def _cc_shared_library_is_the_library(env, target):
    library = target[GodotExtensionInfo].library
    env.expect.that_str(library.link_kind).equals("dynamic")
    env.expect.that_str(library.file.basename).equals("libtest_cc_shared_library_is_the_library.so")
    env.expect.that_collection([file.basename for file in library.runtime_dependencies.values()]).contains_exactly([
        "libshared_library_dependency.so",
    ])

def _test_tool_view_selects_the_tool_branch(name):
    _extension(
        name + "_extension",
        library = select({
            "//godot:tool": _library(name + "_editor", "libeditor.so"),
            "//godot:debug": _library(name + "_debug", "libdebug.so"),
            "//conditions:default": _library(name + "_release", "librelease.so"),
        }),
    )
    for variant, runtime in [("debug", "libdebug.so"), ("release", "librelease.so")]:
        analysis_test(
            name = name + "_" + variant,
            target = name + "_extension",
            impl = _tool_view_selects_the_tool_branch,
            attrs = {"runtime": attr.string()},
            attr_values = _SMALL | {"runtime": runtime},
            config_settings = {str(Label("//godot:variant")): variant},
        )
    native.test_suite(name = name, tests = [name + "_debug", name + "_release"])

def _tool_view_selects_the_tool_branch(env, target):
    extension = target[GodotExtensionInfo]
    env.expect.that_str(extension.library.file.basename).equals(env.ctx.attr.runtime)
    for field in ["editor_resource_paths", "host_editor_resource_paths"]:
        paths = getattr(extension, field)
        env.expect.where(field = field).that_collection([file.basename for file in paths.values()]).contains(
            "libeditor.so",
        )
        env.expect.where(field = field).that_bool(
            [path for path in paths if path.endswith(".editor/libeditor.so")] != [],
            expr = "the tool configuration's tags end in editor",
        ).equals(True)
        env.expect.where(field = field).that_bool(
            paths.get(extension.descriptor_path) not in [None, extension.runtime_descriptor],
            expr = "the tool view writes its own fragment at the descriptor path",
        ).equals(True)

# A select() over platform keys alone needs no //godot:tool branch: the tool view takes
# the branch of the execution platform's operating system.
def _test_platform_keys_need_no_tool_branch(name):
    _extension(
        name + "_extension",
        library = select({
            "@platforms//os:macos": _library(name + "_macos", "libplatform_keys.dylib"),
            "@platforms//os:linux": _library(name + "_linux", "libplatform_keys.so"),
        }),
    )
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _platform_keys_need_no_tool_branch,
        attr_values = _SMALL,
    )

def _platform_keys_need_no_tool_branch(env, target):
    extension = target[GodotExtensionInfo]
    for field in ["editor_resource_paths", "host_editor_resource_paths"]:
        env.expect.where(field = field).that_bool(
            [path for path in getattr(extension, field) if path.endswith((".editor/libplatform_keys.dylib", ".editor/libplatform_keys.so"))] != [],
            expr = "the tool view loads the execution platform's library",
        ).equals(True)

def _test_absent_library_leaves_the_configuration_empty(name):
    _extension(
        name + "_extension",
        library = select({
            "//godot:tool": None,
            "//conditions:default": _library(name + "_library", "libios_only.so"),
        }),
    )
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _absent_library_leaves_the_configuration_empty,
        attr_values = _SMALL,
    )

def _absent_library_leaves_the_configuration_empty(env, target):
    extension = target[GodotExtensionInfo]
    env.expect.that_bool(extension.library != None, expr = "the runtime configuration has a library").equals(True)
    env.expect.that_dict(extension.editor_resource_paths).contains_exactly({})
    env.expect.that_dict(extension.host_editor_resource_paths).contains_exactly({})

def _test_ios_static_library_links(name):
    cc_library(
        name = name + "_archive_library",
        srcs = ["static_fixture.cc"],
        alwayslink = True,
        linkstatic = True,
        tags = ["manual"],
    )
    xcframework_fixture(name = name + "_xcframework_library", tags = ["manual"])
    for case in ["archive", "xcframework"]:
        # An iOS-only library; the editor loads none.
        _extension(name + "_" + case + "_extension", library = select({
            "//godot:tool": None,
            "//conditions:default": ":%s_%s_library" % (name, case),
        }))
        analysis_test(
            name = name + "_" + case,
            target = name + "_" + case + "_extension",
            impl = _ios_static_library_links,
            attr_values = _MACOS_ONLY,
            config_settings = _platform("ios_sim_arm64"),
        )
    native.test_suite(name = name, tests = [name + "_archive", name + "_xcframework"])

def _ios_static_library_links(env, target):
    library = target[GodotExtensionInfo].library
    env.expect.that_str(library.tags).equals("ios.arm64.simulator.release")
    env.expect.that_str(library.link_kind).equals("static")
    env.expect.that_str(library.file.extension).equals("a")
    env.expect.that_bool(library.cc_info == target[CcInfo], expr = "the extension forwards the library's CcInfo").equals(True)
    env.expect.that_bool(
        library.resource_path.startswith(_directory(target) + "bin/ios.arm64.simulator.release/"),
        expr = "resource path " + library.resource_path,
    ).equals(True)

def _dynamic_framework(name, binary, **kwargs):
    dynamic_xcframework_fixture(name = name, binary = binary, **kwargs)
    return ":" + name

def _test_ios_dynamic_framework_loads(name):
    # The binary's name has dots, as Sentry's does; an import that links it fails in rules_cc.
    _extension(
        name + "_extension",
        library = select({
            "//godot:tool": None,
            "//conditions:default": _dynamic_framework(name + "_framework", "libfixture.ios.release"),
        }),
        # A framework it loads, which the application embeds beside it.
        platform_deps = select({
            "//godot:tool": [],
            "//conditions:default": [_dynamic_framework(name + "_support", "FixtureSupport")],
        }),
    )
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _ios_dynamic_framework_loads,
        attr_values = _MACOS_ONLY,
        config_settings = _platform("ios_sim_arm64"),
    )

def _ios_dynamic_framework_loads(env, target):
    extension = target[GodotExtensionInfo]
    library = extension.library
    framework = _directory(target) + "bin/ios.arm64.simulator.release/libfixture.ios.release.framework"
    env.expect.that_str(library.link_kind).equals("framework")
    env.expect.that_str(library.file.basename).equals("libfixture.ios.release")
    env.expect.that_str(library.resource_path).equals(framework)
    env.expect.that_collection(
        [file.basename for file in target[AppleFrameworkImportInfo].framework_imports.to_list()],
        expr = "the frameworks an Apple application embeds",
    ).contains_exactly(["FixtureSupport", "Info.plist", "Info.plist", "libfixture.ios.release"])
    env.expect.that_collection(extension.runtime_resource_paths.keys()).contains_at_least([
        framework + "/libfixture.ios.release",
        framework + "/Info.plist",
    ])
    env.expect.that_dict(library.runtime_dependencies).contains_exactly({})
    env.expect.that_collection(descriptor_contents(target)[0].split("\n")).contains(
        'ios.arm64.simulator.release = "res://%s"' % framework,
    )

def _test_bundled_frameworks_without_a_linked_one_fail(name):
    support = _dynamic_framework(name + "_support", "FixtureSupport")
    _failure_test(
        name,
        {"library": select({
            "//godot:tool": None,
            "//conditions:default": _dynamic_framework(name + "_framework", "libfixture.ios.release", deps = [support]),
        })},
        "bundles the frameworks [\"FixtureSupport.framework\", \"libfixture.ios.release.framework\"] and links none",
        platform = "ios_sim_arm64",
        attr_values = _MACOS_ONLY,
    )

def _failure_test(name, attributes, message, platform = None, attr_values = _SMALL):
    """
    Declare an extension with attributes and expect its analysis to fail with message.

    Without a platform, the extension builds for the host, which has a C++ toolchain.
    """
    _extension(name + "_extension", **attributes)
    analysis_test(
        name = name,
        target = name + "_extension",
        impl = _fails_with_message,
        attrs = {"message": attr.string()},
        attr_values = attr_values | {"message": message},
        config_settings = _platform(platform) if platform else {},
        expect_failure = True,
    )

def _fails_with_message(env, target):
    env.expect.that_target(target).failures().contains_predicate(matching.contains(env.ctx.attr.message))

def _test_unloadable_link_kinds_fail(name):
    cc_library(
        name = name + "_archive",
        srcs = ["static_fixture.cc"],
        linkstatic = True,
        tags = ["manual"],
    )
    _failure_test(
        name,
        {"library": ":" + name + "_archive"},
        "_archive is a static library, which ",
    )
    _failure_test(
        name + "_ios",
        {"library": select({
            "//godot:tool": None,
            "//conditions:default": _library(name + "_dylib", "libbare.dylib"),
        })},
        "is a dynamic library, which ios arm64 simulator cannot load; expected a static library",
        platform = "ios_sim_arm64",
        attr_values = _MACOS_ONLY,
    )

def _test_runtime_file_conflicts_fail(name):
    _failure_test(
        name,
        {
            "library": _library(name + "_library", "libconflict.so"),
            "data": [_library(name + "_same_name", "libconflict.so")],
        },
        "are named libconflict.so; extension libraries load their dependencies by name from beside them",
    )
    _failure_test(
        name + "_android",
        {
            "library": _library(name + "_android_library", "libandroid.so"),
            "data": [_library(name + "_handler", "crash_handler")],
        },
        "Android applications deliver only shared libraries named lib*.so beside an extension library",
        platform = "android_arm64",
    )
    _failure_test(
        name + "_android_unprefixed",
        {
            "library": _library(name + "_android_prefixed_library", "libandroid.so"),
            "data": [_library(name + "_unprefixed", "vendor.so")],
        },
        "Android applications deliver only shared libraries named lib*.so beside an extension library; ",
        platform = "android_arm64",
    )
    _failure_test(
        name + "_ios",
        {
            "library": select({
                "//godot:tool": None,
                "//conditions:default": ":" + name + "_ios_archive",
            }),
            "data": select({
                "//godot:tool": [],
                "//conditions:default": [_library(name + "_ios_handler", "crash_handler")],
            }),
        },
        "iOS applications deliver no files beside an extension library, so ",
        platform = "ios_sim_arm64",
        attr_values = _MACOS_ONLY,
    )
    cc_library(
        name = name + "_ios_archive",
        srcs = ["static_fixture.cc"],
        linkstatic = True,
        tags = ["manual"],
    )

def configured_library_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_android_cpus_select_their_libraries,
            _test_descriptor_defaults_to_the_addon_convention,
            _test_variant_reaches_the_tags,
            _test_shared_library_dependencies_load_from_beside_it,
            _test_linked_shared_library_carries_its_shared_deps,
            _test_cc_shared_library_is_the_library,
            _test_tool_view_selects_the_tool_branch,
            _test_platform_keys_need_no_tool_branch,
            _test_absent_library_leaves_the_configuration_empty,
            _test_ios_static_library_links,
            _test_ios_dynamic_framework_loads,
            _test_bundled_frameworks_without_a_linked_one_fail,
            _test_unloadable_link_kinds_fail,
            _test_runtime_file_conflicts_fail,
        ],
    )
