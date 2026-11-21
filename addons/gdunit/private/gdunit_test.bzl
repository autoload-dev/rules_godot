"""GdUnit4 as a godot_test main script, like a pytest driver over py_test."""

# rules_godot's test adapter macro: loadable across repositories, but no supported API of
# rules_godot. This module pins a rules_godot that matches it.
# buildifier: disable=bzl-visibility
load("@autoload_rules_godot//godot/private:adapter.bzl", "adapter_test")

visibility("//...")

def gdunit_test(name, suites, **kwargs):
    """
    Run GdUnit4 test suites as a Bazel test.

    A rules_godot `godot_test` whose main script is this module's GdUnit test adapter. A
    suite is a script of the suites targets, generated ones included, that extends GdUnit's
    `GdUnitTestSuite`; helper scripts and sidecars beside the suites are none. The suites
    declare what they use in their deps: the code under test and GdUnit itself,
    `@autoload_gdunit//:gdunit`. The adapter follows Bazel's test contract: shard_count
    distributes the suites round-robin, `--test_filter` keeps the suites whose `res://`
    path contains it, the JUnit report becomes the test's XML result and all GdUnit reports
    appear among its undeclared outputs. The test fails when a test fails, when no test
    runs or when the suites targets hold no suite; a shard or `--test_filter` that leaves no
    suite passes. Orphan nodes fail no test, as GdUnit's command line judges them; the log
    names the tests that left them. GdUnit's assertions provoke engine errors deliberately,
    so only the exit code decides.

    Arguments after Godot's `--` in args, and those from `--test_arg`, are GdUnit options,
    as pytest receives a py_pytest_test's arguments.

    Example:
    ```starlark
    load("@autoload_gdunit//:defs.bzl", "gdunit_test")
    load("@autoload_rules_godot//godot:defs.bzl", "godot_resources")

    godot_resources(
        name = "unit_suites",
        testonly = True,
        srcs = glob(["test/**/*_test.gd"]),
        deps = [":game", "@autoload_gdunit//:gdunit"],
    )

    gdunit_test(
        name = "unit_tests",
        project = ":project",
        suites = [":unit_suites"],
        shard_count = 4,
    )
    ```

    Run one suite with `bazel test :unit_tests --test_filter=inventory_test`.

    Args:
        name: Name of the test target.
        suites: godot_resources targets whose own files are the suites. Their deps bring
            what the suites use, including the GdUnit add-on, helpers and fixtures; those
            files are not suites.
        **kwargs: godot_test arguments, such as args, project, size and shard_count.
    """
    if not suites:
        fail("%s: gdunit_test requires at least one suites target" % name)
    args = kwargs.pop("args", [])
    adapter_test(
        name = name,
        deps = suites,
        adapter = Label("//private:run.gd"),
        main = "addons/autoload_gdunit/run.gd",
        cases = "addons/autoload_gdunit/suites.txt",
        # Bazel appends --test_arg values, which then follow the separator too.
        kwargs = dict(kwargs, args = args if "--" in args else args + ["--"]),
    )
