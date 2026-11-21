# Development and testing

Use the rules to run projects, test them, validate their scripts and edit declared resources.
From `examples/`, run `bazel test //projects/lichtpost/tests` for the Lichtpost gameplay suites.

## Execution and tests

For repository test locations and production/test package boundaries, see
[test ownership](project-layout.md#test-ownership).

`godot_run` and `godot_test` work like `py_binary` and `py_test`. Each runs
one of two things: the resources and add-ons in its `deps` under the configuration
of its `project`, a minimal project when unset, or an exported `pack`; see
[program entries](resources.md#import-context-and-cache-correctness) for the project's
autoloads and main scene. `main` names what Godot starts: a `SceneTree`
script runs with `--script`, a scene replaces the main scene, and an empty `main`
starts the project's main scene. `args` is Godot's command line, which Bazel
splits like a shell; arguments for the script follow Godot's `--`. `env` and
`data` work as for any Bazel binary.

```starlark
godot_resources(
    name = "smoke",
    srcs = ["smoke_test.gd"],
)

godot_test(
    name = "smoke_test",
    deps = [":smoke", ":game"],
    main = "smoke_test.gd",
    args = ["--", "'expected title'"],
)
```

A source run copies its project from declared runfiles together with its imports and
its Godot editor caches (global script classes, UIDs), which one cached
`GodotInitialize` action per run derives. The checkout is never used as an
implicit input. A test names only the resources it needs, without the main
application, production pack, editor cache or a global Godot installation.
`additional_packs` copies further PCKs into the working directory under the given
names; the running project loads them with `ProjectSettings.load_resource_pack()`,
for example to add DLC content on top of the base pack.

A test passes when Godot exits with 0, so a script reports a failed check with
`quit(1)`. An error Godot reports while the game runs, such as a script error,
fails the test as well, although Godot keeps running and exits with 0: the test
stops after the first one, so it does not run into its timeout. rules_godot
records these errors with a logger it adds to the game as the last autoload; errors
Godot reports before that autoload exists, such as a parse error in another
autoload, or after the game's scene tree is gone, such as leaks at exit, are not
recorded. `engine_errors = "report"` keeps Godot's exit
status instead, for a test framework that provokes errors on purpose. Either way
the runner names the number of recorded errors, and the test's undeclared outputs
hold them in `godot/errors.jsonl`. `godot_run` targets follow the same rule without stopping.

Imports, initialization and exports do not read Godot's output. Each is decided by
the result Godot itself records for it, such as the files whose import failed or
the export's error messages, and by its declared outputs; a crash after a finished
export is printed as a note. Errors in the content, such as script errors, do not
fail these actions; [content validation](#content-validation) does.

`size`, `timeout`, `shard_count` and `flaky` work as for any Bazel test. Godot
receives Bazel's test environment, such as `TEST_SHARD_INDEX`,
`TESTBRIDGE_TEST_ONLY` and `XML_OUTPUT_FILE`, so a test framework running as the
main script can implement sharding, `--test_filter` and JUnit reports. Godot's
output is kept among the test's undeclared outputs under `godot/`.

Targets in `data` remain outside `res://`. Tests locate them under
`TEST_SRCDIR` and `TEST_WORKSPACE`; Bazel's `RUNFILES_DIR` and
`RUNFILES_MANIFEST_FILE` also reach Godot when set. This lets a GdUnit suite
inspect and launch declared application artifacts without reading the checkout.

`godot_run` and `godot_test` targets run headless. `headless = False` declares a target that must
render, `headless = True` one that never may. Targets that leave `headless`
unset follow the `--@autoload_rules_godot//godot:headless` flag, for example to watch a
test that works both ways:

```sh
bazel test //path/to:target --@autoload_rules_godot//godot:headless=false
```

Replace `//path/to:target` with your test label.

### GdUnit

GdUnit4 comes from the add-on module `autoload_gdunit` of this repository: its add-on
`@autoload_gdunit//:gdunit` and `gdunit_test` from `@autoload_gdunit//:defs.bzl`, a
`godot_test` whose main script is a GdUnit test adapter, as `py_pytest_test` is a
`py_test` that runs pytest. The adapter follows Bazel's test contract: `shard_count`,
`--test_filter` and the JUnit report work as for any Bazel test.

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

The [module's README](../../addons/gdunit/README.md) describes how to depend on it, what a
suite is, how the test passes and fails and how to split suites across test environments.

Bazel owns test-result caching and selected configuration matrices. Declare
separate test targets, with a project of their own where the configuration differs, and choose toolchains and target platforms using normal Bazel
configuration. There is no second test scheduler or promise that an undeclared
runtime dependency is discovered by executing a test.

## Content validation

Every build of an operation checks the scripts and scenes it contains, one
`godot_resources` target or add-on part at a time, as `go build` runs `nogo` over each
package. A unit's check is its target's validation, in the `_validation` output group,
so Bazel runs it beside the build whenever it builds anything containing the unit, and a
script error fails that build:

```console
$ bazel build //path/to:pack
ERROR: /work/path/to/BUILD.bazel:7:16: Validating //path/to:player failed: (Exit 1): godot_validation failed: ...
//path/to:player: Godot reports errors in its scripts or scenes:
  res://player/player.gd:12: Parse Error: Identifier "speeed" not declared in the current scope.
  res://player/player.gd: Failed to load script "res://player/player.gd" with error "Parse error". (modules/gdscript/gdscript_resource_format.cpp:46)
```

The export, the imports and the initialization over the same files still succeed, so
`bazel build --run_validations=false //path/to:pack` builds the pack while the script is
broken, and `bazel build //path/to:pack --output_groups=_validation` runs the checks of every
unit the pack contains without exporting it. A target built on its own, outside every
operation, has no project and no check.

A check loads its unit's scripts and then its scenes with the registered editor, under its
project's configuration, with only what the unit may use: its files, its
`deps` and what they depend on, and the runtime parts of the add-ons they use with those
add-ons' extensions. It registers the game's autoloads whose files are among these: those
of the project's `project.godot`, also one named by `uid://` as Godot's editor writes
them, and those its `autoloads`, `autoload_overrides` and the add-ons declare, which
replace one of the same name. Godot resolves global classes and UIDs as in the game. A
script that uses a global class, an autoload or a scene of another target that its `deps`
do not reach fails with Godot's error, as `Could not find type` or `Identifier not
declared`. Of the other targets, a check reads only what Godot's analyzer and loader read
from them, as javac reads a header jar: their scripts' declarations and signatures, whether
each function awaits, and of each asset with an `.import` file its UID and its resource's
class. So an edit inside a function body or of an asset's pixels or samples reruns only the
check of the target that holds it, and an error inside a function body fails only that
target's check; an edit of a declaration or a scene reruns the checks of every target that
depends on it. Every error Godot reports
while a file loads fails the unit, and warnings do not, except a reference whose `uid` is
stale while its path is right, which fails where
[`--@autoload_rules_godot//godot/metadata:resource_uids=require`](#checkout-metadata) requires UIDs.
A GDScript warning the project raises to an error through `debug/gdscript/warnings/*` is
an error. Godot's `debug/gdscript/warnings/directory_rules` exempt `res://addons` from
warnings unless the project's rules include an add-on's directory, so an add-on's test
project includes the add-on under test while the add-ons it uses stay exempt:

```starlark
godot_project(
    name = "tests",
    project_file = "project.godot",
    settings = {"debug/gdscript/warnings/directory_rules": '{"res://addons": 0, "res://addons/inventory": 1}'},
)
```

An error of a file the unit uses, such as a broken base script, fails the unit that owns
that file and every unit whose script uses it.

A check parses, analyzes and compiles, and runs no code of the project: no autoload, no
static initializer, no constructor, setter or `_ready`, no editor plugin and no `@tool`
script, also when a scene or a resource it loads holds a script. Godot registers each
autoload without instantiating it, and a script that calls one is type-checked against the
autoload's script, or a scene autoload's root script: `Tracker.track(5)` fails as
`Invalid argument for "track()"` when `track` takes a `String`. A scene autoload whose
root has no script file, such as a script built into the scene, is checked as a plain
`Node`. The check treats every script as one without `@tool`, so Godot's warning that a
script extends a `@tool` script without being one is not reported. A script built into a
binary `.scn` or `.res` keeps its `@tool` and runs as one. A `.gd`, `.tscn` or `.tres` that
is not UTF-8 text, which Godot reads them as, fails the build with its path. The extensions
a unit uses load their native code, as the editor does.

A check runs for the target platform of the build that contains its unit, such as an iOS
application's. An extension without a library for that platform, as a `select()` branch of
`None` declares, does not load there, since that platform's runtime cannot load it either.
A script that uses its classes directly then fails with `Identifier not declared`, and the
failure names the extension; a use guarded with `ClassDB.class_exists` and
`ClassDB.instantiate` passes. Give the extension a library for the platform, or leave it
out of that platform's `deps`. An add-on's editor part runs in the editor, so its check
loads every extension the editor loads.

A check runs once per unit, project and target platform and reruns only when a file of its
unit or of what it may use changes.

## Editor view

`godot_editor` opens a project in the Godot editor with `bazel run`, and what you
save in the editor changes the checkout. The editor works on an editor view in
`.godot-editor/<package>/<name>` under the workspace: the files of its `deps` under the
project's configuration, laid out at their `res://` paths:

```starlark
godot_editor(
    name = "edit",
    project = ":project",
    deps = [":game"],
)
```

```sh
cd examples
bazel run //projects/lichtpost:edit
```

Bazel must ignore the editor views: add the line `.godot-editor` to `.bazelignore`.
The editor views link to package directories, which `bazel build //...` would
otherwise find a second time; the run fails until the line is there. Git ignores
the editor views on its own. Arguments after `--` go to the editor, and `env` sets
environment variables for it; the editor otherwise runs with your own editor
settings.

| In the view | Comes from | Editing it in Godot |
|---|---|---|
| A directory whose files all come from one checkout directory, at the same relative paths, such as `levels/` | A link to that directory | Edits, new files, renames and deletes change the checkout |
| Other files of this repository: files at the project root, files placed elsewhere through `resource_paths`, files next to generated ones | A link to each file | Edits change the checkout; new files stay in the view |
| Generated files, files of other repositories such as add-ons, extension descriptors and extension libraries | Read-only copies from the build | Not editable; change their source or BUILD target |
| Imported resources and Godot's caches | The imports of its `deps` and the view's initialization | Godot keeps them current; the next run replaces them |

The editor loads each extension's library in the
[tool configuration](gdextension.md#the-tool-configuration), built for the host. Because the imports come from the build, the editor
opens without reimporting. Before it opens, the run writes the
[sidecars](#checkout-metadata) the build generated for checkout files that have none,
as `godot_metadata_sync` does. With `write_sidecars = False` it only names them,
and Godot writes its own when it finds the files, reimporting assets.

The view's `project.godot` is the project's configuration: its settings,
autoloads and main scene, merged with what the add-ons of the view contribute, and the
editor plugin of every add-on's editor part, which the view holds. Plugins enabled only
in the authored `project.godot` stay off. When the editor
exits, settings it changed that come from the authored `project.godot` are
written back to that file. A setting that `settings`, `autoloads`, `main_scene`
or an add-on's contribution sets, and the plugin list, stay as declared, and the
run names the target that sets each one. A setting that also changed in the
authored file while the editor was open keeps the authored value.

BUILD files stay yours. After the editor exits, and on every run, the runner
lists files that exist only in the view with the checkout directory they belong
in, links the editor moved or deleted, and files in linked directories that the
view's `deps` do not declare. They become part of the view once a target among
its `deps` declares them.

Editor views need symbolic links, so they work on macOS and Linux. One editor at a
time opens an editor view. Godot writes `project.godot` in its own format and adds
`application/config/features` when it saves, as it does in any project, so a
write-back can add that setting and reformat one that was not written that way
before.

### Checkout metadata

Godot keeps a script's or shader's UID in a `.uid` file beside it and an
imported asset's import settings, including its UID, in a `.import` file beside
it. Both belong in version control and in the target that declares their file.
Where a checkout file has none, the build generates them for its imports and
initialization. An editor view writes those into the checkout when it opens;
`godot_metadata_sync` does so without the editor:

```starlark
godot_metadata_sync(
    name = "metadata",
    project = ":project",
    deps = [":game"],
)
```

```sh
bazel run //path/to:metadata
bazel test //path/to:metadata.test
```

Replace `path/to` with the package declaring the snippet above. For a runnable
example, from `examples/`, `bazel run //projects/lichtpost:update` writes Lichtpost's missing
metadata, and `bazel test //projects/lichtpost:update.test` checks its sidecars are declared.

The first command writes each missing sidecar beside its file and names the
target to declare it in; a `glob` in `srcs` picks it up on its own. An existing
file is never replaced, and one that exists but is not declared is named until
a target declares it. `metadata.test` fails while the build generates a sidecar
for a checkout file, so `bazel test //...` keeps the checkout complete. Both
read a list of these sidecars that the build makes from the imports and
initialization of its `deps`; the test needs neither the checkout nor the imported assets.

With the [metadata flags](resources.md#export-and-inspect) at `sync` (default)
or `require`, the same run also completes the metadata of checkout text files:
a `unique_id` for each node a `.tscn` scene declares without one, and the named
file's UID for each `ext_resource` whose `uid` is missing or stale. These are the
values a pack otherwise adds only to the copy it exports, so committing them
leaves the PCK unchanged. The run inserts or replaces only those attributes, in
the file as it is when the run writes it. `metadata.test` requires these values
only with `require`. An editor view leaves them to this run and to the editor's
own saves.
