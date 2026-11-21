"""Generated extension descriptors hold their sections and entries in Godot's layout."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:util.bzl", "TestingAspectInfo")

def descriptor_contents(target):
    """Return the contents of the extension descriptors the target writes."""
    return [
        action.content
        for action in target[TestingAspectInfo].actions
        if action.mnemonic == "TemplateExpand" and
           action.outputs.to_list()[0].basename.endswith(".gdextension")
    ]

_LINUX = {"//command_line_option:platforms": str(Label("//godot/platforms:linux_x86_64"))}

# The optional [dependencies] section is a block of its own between the others.
_DEPENDENCY_DESCRIPTOR = """[configuration]

entry_symbol = "dependency_fixture_init"
compatibility_minimum = "4.7.2"
reloadable = false

[dependencies]

linux.x86_64.release = {"res://native/dependency_fixture.txt": ""}

[libraries]

linux.x86_64.release = "res://native/bin/linux.x86_64.release/libandroid_contract_fixture.so"
"""

def _test_dependencies_section_sits_between_others(name):
    analysis_test(
        name = name,
        target = ":dependency_extension",
        impl = _test_dependencies_section_sits_between_others_impl,
        config_settings = _LINUX,
    )

def _test_dependencies_section_sits_between_others_impl(env, target):
    env.expect.that_collection(descriptor_contents(target), expr = "descriptor contents").contains_exactly(
        [_DEPENDENCY_DESCRIPTOR],
    )

# A debug fragment names its library under the debug feature tag.
_DEBUG_DESCRIPTOR = """[configuration]

entry_symbol = "variant_fixture_init"
compatibility_minimum = "4.7.2"
reloadable = false

[libraries]

linux.x86_64.debug = "res://native/bin/linux.x86_64.debug/libvariant_debug.so"
"""

def _test_debug_fragment_names_its_library_alone(name):
    analysis_test(
        name = name,
        target = ":variant_extension",
        impl = _test_debug_fragment_names_its_library_alone_impl,
        config_settings = _LINUX | {str(Label("//godot:variant")): "debug"},
    )

def _test_debug_fragment_names_its_library_alone_impl(env, target):
    env.expect.that_collection(descriptor_contents(target), expr = "descriptor contents").contains_exactly(
        [_DEBUG_DESCRIPTOR],
    )

def descriptor_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_dependencies_section_sits_between_others,
            _test_debug_fragment_names_its_library_alone,
        ],
    )
