"""A godot_test whose main script is a rules_godot test adapter over listed cases."""

load("//godot/private:macros.bzl", "common_kwargs")
load("//godot/private:providers.bzl", "GodotResourcesInfo")
load("//godot/private:resources.bzl", "godot_resources", "own_paths")
load("//godot/private:run.bzl", "godot_test")

# Test framework modules, such as autoload_gdunit, load adapter_test across repositories. It
# is no supported API (docs/public/api/modules.bzl): each such module pins a matching
# rules_godot.
visibility("public")

def _case_list_impl(ctx):
    cases = sorted({
        path: True
        for target in ctx.attr.deps
        for path in own_paths(target[GodotResourcesInfo])
    })
    if not cases:
        fail("%s: deps contain no file" % ctx.label)
    output = ctx.outputs.out
    ctx.actions.write(output, "".join(["res://%s\n" % path for path in cases]))
    return [DefaultInfo(files = depset([output]))]

_case_list = rule(
    doc = "Write the `res://` paths of a test adapter's cases, one per line.",
    implementation = _case_list_impl,
    attrs = {
        "deps": attr.label_list(providers = [GodotResourcesInfo]),
    },
    # Loading-time tools can classify this as generated resource content before
    # the adapter has been analyzed or built.
    outputs = {"out": "%{name}.txt"},
)

def adapter_test(name, deps, adapter, main, cases, kwargs):
    """
    Declare a godot_test whose main script reads its cases from a project file.

    Args:
        name: Name of the test target.
        deps: The test's deps, whose own files are the cases, in path order; the
            files of their dependencies are none.
        adapter: The adapter's main script file, which the test declares as resources of
            its own, `<name>.adapter`, that use the deps and the shared case selection,
            for a script that uses what the deps bring, such as GdUnit.
        main: Resource path of the main script.
        cases: Resource path of the case list the main script reads.
        kwargs: Remaining godot_test arguments.
    """
    if any([key in kwargs for key in ["main", "pack", "engine_errors"]]):
        fail("%s: this test sets its own main script" % name)

    # Like godot_test's own view, the case helpers are test-only.
    kwargs = dict(kwargs, testonly = kwargs.get("testonly", True))
    common = dict(common_kwargs(kwargs), visibility = ["//visibility:private"])
    _case_list(
        name = name + ".case_list",
        deps = deps,
        **common
    )
    godot_resources(
        name = name + ".cases",
        resource_paths = {":" + name + ".case_list": cases},
        **common
    )
    godot_resources(
        name = name + ".adapter",
        resource_paths = {adapter: main},
        deps = deps + [Label("//godot/private:test_cases")],
        **common
    )
    godot_test(
        name = name,
        deps = deps + [
            ":" + name + ".adapter",
            ":" + name + ".cases",
        ],
        main = main,
        # The adapter decides the outcome. Its cases provoke engine errors on
        # purpose, and stopping Godot after the first would cut its report short.
        engine_errors = "report",
        **kwargs
    )
