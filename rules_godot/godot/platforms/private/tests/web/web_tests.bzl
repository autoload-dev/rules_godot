"""
What a godot_app for the web export platform provides, and what it rejects.

It provides GodotWebAppInfo, whose page is index.html and which needs no cross-origin
isolation without threads, the host's headers with threads, or the service worker of a
progressive web app that ensures them; its variant is Bazel's, so a pack that authors thread support or
extension support fails, and so does a pack with C#.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:test_suite.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "matching")
load("//godot:app.bzl", "godot_app")
load("//godot:defs.bzl", "godot_pack", "godot_resources")
load("//godot:providers.bzl", "GodotWebAppInfo")

visibility("private")

_PARITY = "//godot/platforms/private/tests/web/fixtures/parity:"

_WEB = {"//command_line_option:platforms": str(Label("//godot/platforms:web_wasm32"))}

_SMALL = {"size": "small"}

def _test_web_app_provides_its_page(name):
    analysis_test(
        name = name,
        target = _PARITY + "app",
        impl = _web_app_provides_its_page,
        config_settings = _WEB,
        attr_values = _SMALL,
    )

def _web_app_provides_its_page(env, target):
    app = target[GodotWebAppInfo]
    env.expect.that_str(app.entry_point).equals("index.html")
    env.expect.that_str(app.cross_origin_isolation).equals("none")
    env.expect.that_str(app.archive.basename).equals("app.zip")
    env.expect.that_collection([file.basename for file in target[OutputGroupInfo].bundle.to_list()]).contains_exactly(["app"])

def _app(name, export_options = {}, deps = [_PARITY + "main"]):
    godot_pack(
        name = name + "_pack",
        export_options = export_options,
        project = _PARITY + "parity",
        tags = ["manual"],
        deps = deps,
    )
    godot_app(name = name + "_app", pack = ":" + name + "_pack", tags = ["manual"])
    return name + "_app"

def _failure_test(name, cases):
    """Declare one application per (export options, deps, message) case and expect each to fail with its message."""
    targets = {}
    for index, (options, deps, _) in enumerate(cases):
        targets["case_%d" % index] = _app("%s_%d" % (name, index), options, deps)
    analysis_test(
        name = name,
        targets = targets,
        impl = _fails_with_messages,
        attrs = {"messages": attr.string_list()},
        attr_values = _SMALL | {"messages": [message for _, _, message in cases]},
        config_settings = _WEB,
        expect_failure = True,
    )

def _fails_with_messages(env, targets):
    for index, message in enumerate(env.ctx.attr.messages):
        env.expect.that_target(getattr(targets, "case_%d" % index)).failures().contains_predicate(
            matching.contains(message),
        )

def _test_variant_and_pwa_are_bazels(name):
    main = [_PARITY + "main"]
    _failure_test(name, [
        ({"variant/thread_support": "true"}, main, "variant/thread_support"),
        ({"variant/extensions_support": "true"}, main, "variant/extensions_support"),
        ({"custom_template/release": '"web.zip"'}, main, "custom_template/release"),
    ])

_THREADS = {"//command_line_option:platforms": str(Label("//godot/platforms:web_wasm32_threads"))}

def _test_threads_need_isolation(name):
    for case, target, expected in [
        ("headers", "app", "headers"),
        ("service_worker", "pwa_app", "service_worker"),
    ]:
        analysis_test(
            name = name + "_" + case,
            target = _PARITY + target,
            impl = _isolation_is,
            attrs = {"expected": attr.string()},
            attr_values = _SMALL | {"expected": expected},
            config_settings = _THREADS,
        )
    native.test_suite(name = name, tests = [name + "_headers", name + "_service_worker"])

# Threads need cross-origin isolation: from the host's headers, or from the progressive web
# app's service worker where it ensures them.
def _isolation_is(env, target):
    env.expect.that_str(target[GodotWebAppInfo].cross_origin_isolation).equals(env.ctx.attr.expected)

def _test_csharp_project_fails(name):
    godot_resources(
        name = name + "_scripts",
        srcs = ["fixtures/csharp/Player.cs"],
        strip_prefix = "fixtures/csharp",
        tags = ["manual"],
    )
    _failure_test(name, [({}, [":" + name + "_scripts"], "Godot exports no C# project for the web")])

def _test_pwa_disabled_is_accepted(name):
    analysis_test(
        name = name,
        target = _app(name, {"progressive_web_app/enabled": "false"}),
        impl = _analyzes,
        config_settings = _WEB,
        attr_values = _SMALL,
    )

def _analyzes(env, target):
    _ = (env, target)  # @unused

def web_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_web_app_provides_its_page,
            _test_variant_and_pwa_are_bazels,
            _test_csharp_project_fails,
            _test_threads_need_isolation,
            _test_pwa_disabled_is_accepted,
        ],
    )
