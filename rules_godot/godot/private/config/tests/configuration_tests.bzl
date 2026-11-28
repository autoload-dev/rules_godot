"""Split flag propagation contracts for supplied export platforms."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("//godot/private/config:settings.bzl", "CPU_TABLE", "configured_context", "context_attrs", "cpu_tag", "export_platform_error", "ios_cpu")

visibility("private")

_CapturedInfo = provider(doc = "Configured regression observations.", fields = ["configured", "independent"])

def _capture_impl(ctx):
    return [_CapturedInfo(configured = ctx.attr.configured, independent = ctx.attr.independent)]

capture = rule(
    implementation = _capture_impl,
    attrs = {"configured": attr.bool(), "independent": attr.bool()},
)

_ContextInfo = provider(doc = "Configured regression observations.", fields = ["value"])

def _context_impl(ctx):
    return [_ContextInfo(value = configured_context(ctx))]

context_fixture = rule(implementation = _context_impl, attrs = context_attrs())

_SMALL = {"size": "small"}

def _configuration_settings(platform):
    return {
        "//command_line_option:platforms": str(Label(platform)),
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:copt": ["-DRULES_GODOT_INDEPENDENT"],
    }

def _export_platform_supplies_cpu_flags_and_compiler_policy(env, target):
    info = target[_CapturedInfo]
    env.expect.that_bool(info.configured, expr = "The export platform must supply its CPU flags").equals(True)
    env.expect.that_bool(info.independent, expr = "The export platform must preserve independent C++ compiler policy").equals(True)

def _test_android_export_platform_supplies_cpu_flags_and_compiler_policy(name):
    analysis_test(
        name = name,
        target = ":android_configuration",
        impl = _export_platform_supplies_cpu_flags_and_compiler_policy,
        config_settings = _configuration_settings("//godot/platforms:android_arm64"),
        attr_values = _SMALL,
    )

def _test_ios_export_platform_supplies_cpu_flags_and_compiler_policy(name):
    analysis_test(
        name = name,
        target = ":ios_configuration",
        impl = _export_platform_supplies_cpu_flags_and_compiler_policy,
        config_settings = _configuration_settings("//godot/platforms:ios_arm64"),
        attr_values = _SMALL,
    )

def _context_test(name, platform, cpus, operating_system, environment):
    analysis_test(
        name = name,
        target = ":context",
        impl = _context_reads_export_platform,
        attrs = {"cpus": attr.string_list(), "operating_system": attr.string(), "environment": attr.string()},
        config_settings = {"//command_line_option:platforms": str(Label(platform))},
        attr_values = _SMALL | {
            "cpus": cpus,
            "environment": environment,
            "operating_system": operating_system,
        },
    )

def _context_reads_export_platform(env, target):
    value = target[_ContextInfo].value
    env.expect.that_collection(value.cpus).contains_exactly(env.ctx.attr.cpus).in_order()
    env.expect.that_str(value.operating_system).equals(env.ctx.attr.operating_system)
    env.expect.that_str(value.environment).equals(env.ctx.attr.environment)

def _test_context_reads_android_export_platform(name):
    _context_test(name, "//godot/private/config/tests:android_distribution", ["arm64", "x86_64"], "android", "")

def _test_context_reads_simulator_export_platform(name):
    _context_test(name, "//godot/private/config/tests:simulator_distribution", ["arm64", "x86_64"], "ios", "simulator")

def _test_child_platform_contradicting_export_platform_fails(name):
    analysis_test(
        name = name,
        target = ":context",
        impl = _child_platform_contradicting_export_platform_fails,
        expect_failure = True,
        config_settings = {"//command_line_option:platforms": str(Label("//godot/private/config/tests:contradictory_child"))},
        attr_values = _SMALL,
    )

def _child_platform_contradicting_export_platform_fails(env, target):
    env.expect.that_target(target).failures().contains_predicate(
        matching.contains("conflicts with effective target platform"),
    )

def _test_export_platform_error_names_each_invalid_field(env):
    for operating_system, cpus, environment, parents, message in [
        ("android", [], None, [], "nonempty"),
        ("android", ["arm64", "arm64"], None, [], "duplicate-free"),
        ("android", ["sparc"], None, [], "Unsupported CPU sparc"),
        ("linux", ["arm64", "x86_64"], None, [], "one CPU"),
        ("android", ["arm64"], "device", [], "only valid for iOS"),
        ("ios", ["x86_64"], "device", [], "iOS device has no CPU @@platforms//cpu:x86_64"),
        ("ios", ["arm32"], "simulator", [], "iOS simulator has no CPU @@platforms//cpu:armv7"),
        ("ios", ["arm64"], "mixed", [], "device or simulator"),
        ("android", ["arm64"], None, ["one", "two"], "at most one"),
        ("web", ["x86_64"], None, [], "exactly the CPU @platforms//cpu:wasm32"),
        ("android", ["arm64", "wasm32"], None, [], "exactly the CPU @platforms//cpu:wasm32"),
    ]:
        env.expect.that_str(export_platform_error(operating_system, cpus, environment, parents)).contains(message)

    # Whether a runtime exists for a CPU is not a declaration error.
    for operating_system, cpus, environment in [
        ("android", ["arm32", "arm64", "x86_32", "x86_64"], None),
        ("android", ["rv64"], None),
        ("linux", ["x86_32"], None),
        ("linux", ["arm32"], None),
        ("ios", ["x86_64", "arm64"], "simulator"),
        ("ios", ["arm64"], None),
        ("macos", ["arm64"], None),
        ("web", ["wasm32"], None),
    ]:
        env.expect.that_str(export_platform_error(operating_system, cpus, environment, [])).equals("")

def _test_cpu_table_maps_constraints_to_godot_and_android_names(env):
    for label, tag, abi in [
        ("@platforms//cpu:armv7", "arm32", "armeabi-v7a"),
        ("@platforms//cpu:aarch64", "arm64", "arm64-v8a"),
        ("@platforms//cpu:arm64", "arm64", "arm64-v8a"),
        ("@platforms//cpu:x86_32", "x86_32", "x86"),
        ("@platforms//cpu:x86_64", "x86_64", "x86_64"),
        ("@platforms//cpu:riscv64", "rv64", "riscv64"),
    ]:
        env.expect.where(label = label).that_str(cpu_tag(Label(label))).equals(tag)
        env.expect.where(label = label).that_str(CPU_TABLE[tag].android_abi).equals(abi)
    env.expect.that_bool(cpu_tag(Label("@platforms//cpu:s390x")) == None, expr = "a CPU outside the table has no tag").equals(True)
    for environment, cpu, split in [
        ("device", "arm64", "arm64"),
        ("simulator", "arm64", "sim_arm64"),
        ("simulator", "x86_64", "x86_64"),
    ]:
        env.expect.where(environment = environment, cpu = cpu).that_str(ios_cpu(environment, cpu)).equals(split)

def configuration_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_android_export_platform_supplies_cpu_flags_and_compiler_policy,
            _test_ios_export_platform_supplies_cpu_flags_and_compiler_policy,
            _test_context_reads_android_export_platform,
            _test_context_reads_simulator_export_platform,
            _test_child_platform_contradicting_export_platform_fails,
        ],
        basic_tests = [
            _test_export_platform_error_names_each_invalid_field,
            _test_cpu_table_maps_constraints_to_godot_and_android_names,
        ],
    )
