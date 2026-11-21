# GdUnit

GdUnit4 runs an application's GdUnit test suites as Bazel tests, with sharding, test filters
and JUnit reports. The module `autoload_gdunit` brings
[GdUnit4](https://github.com/godot-gdunit-labs/gdUnit4) as an add-on and `gdunit_test`, a
`godot_test` that runs GdUnit suites.

| Target | What it is |
| --- | --- |
| `@autoload_gdunit//:gdunit` | The GdUnit4 add-on at `addons/gdUnit4`, test-only. Its editor part is the editor plugin and the scenes it docks. |
| `@autoload_gdunit//:defs.bzl%gdunit_test` | A `godot_test` whose main script is this module's GdUnit test adapter. |

## Setup

Depend on the module, for tests only:

```starlark
bazel_dep(name = "autoload_gdunit", version = "0.1.0", dev_dependency = True)
```

Give the suites their own `godot_resources`, with GdUnit among their deps, and run them with
`gdunit_test`:

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

`gdunit_test` is a `godot_test` whose main script is this module's GdUnit test adapter, as
`py_pytest_test` is a `py_test` that runs pytest. A suite is a script of a `suites` target,
generated ones included, that extends GdUnit's `GdUnitTestSuite`, as GdUnit itself defines
one; helper scripts and sidecars beside the suites are none. The suites bring what they use
through their own `deps`, the GdUnit add-on included. Arguments after Godot's `--` in
`args`, and those from `--test_arg`, are GdUnit options. The test adapter

- runs only the suites whose `res://` path contains the `--test_filter` value,
- distributes those round-robin over `shard_count` shards,
- hands GdUnit's JUnit report to Bazel and keeps all its reports among the undeclared
  outputs under `gdunit/`,
- fails when a test fails or none runs, including when all are skipped, and when its
  `suites` hold no suite; a shard or `--test_filter` that leaves no suite passes,
- passes with orphan nodes, as GdUnit's command line does, and names the tests that left
  them in the log.

GdUnit's assertions provoke engine errors deliberately, so only its results decide.

`bazel test //path/to:unit_tests --test_filter=inventory_test` runs one suite. Bazel caches
a test target as a whole: split suites into several targets where a change should rerun
only some of them.

A `gdunit_test` runs every suite of its `suites` targets, so give each test environment its
own suites target, such as host unit suites and device integration suites. Where suites of
both environments use the same classes, move those classes into a third `godot_resources`
target that both depend on, as a Bazel package splits shared test helpers into a `testonly`
library. Keep the device test out of host runs with `tags = ["manual"]`:

```starlark
godot_resources(
    name = "test_support",
    testonly = True,
    srcs = glob(["test/support/**/*.gd"]),
    deps = [":game", "@autoload_gdunit//:gdunit"],
)

godot_resources(
    name = "unit_suites",
    testonly = True,
    srcs = glob(["test/unit/**/*_test.gd"]),
    deps = [":test_support"],
)

godot_resources(
    name = "device_suites",
    testonly = True,
    srcs = glob(["test/device/**/*_test.gd"]),
    deps = [":test_support"],
)

gdunit_test(name = "unit_tests", project = ":project", suites = [":unit_suites"])

gdunit_test(
    name = "device_tests",
    project = ":project",
    suites = [":device_suites"],
    tags = ["manual"],
)
```

## rules_godot version

`gdunit_test` builds on rules_godot's test adapter, `adapter_test` in
`@autoload_rules_godot//godot/private:adapter.bzl`. rules_godot lets other repositories load
it, but it is no supported API: each release of this module pins the rules_godot release
it works with. Use a rules_godot at least that new.

## Design

GdUnit4 is a GDScript add-on without native code, so the module has no backends; this
repository verifies it on the host only.
`third_party/gdunit4.BUILD.bazel` splits GdUnit's sources into the runtime part and the
editor part, and `//:gdunit` assembles them into the add-on. `gdunit_test` is a macro over
rules_godot's test adapter: the adapter lists the suites, and `private/run.gd` runs them with
GdUnit and reports to Bazel.

The example application in `examples/` consumes the module as applications do: the project
`projects/scores` tests its scripts with GdUnit. `examples/tests/` holds the module's own
tests: GdUnit runs that pass, fail, shard, filter and report the way Bazel's test
encyclopedia requires, a pack with GdUnit, and a GdUnit run in a project with strict
warnings. `mise run addon:host gdunit` runs both.
