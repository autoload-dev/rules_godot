# Projects, add-ons and their tests

Projects and add-ons of this repository's two consumer modules, `examples/` and `tests/`, use
`<module>/{projects,addons}/<name>/`, measured from the module root. The module selects
examples or ruleset regressions; the typed root determines application or add-on type. Games such as Lichtpost are applications under `examples/projects/`.
The [typed root convention](conventions.md#rg009) owns these roots and their checks.

Application configuration belongs to its project context and application content under
`main/`; [application ownership](conventions.md#rg008) follows the physical placement of the
project or add-on. A project's custom engine modules live in `engine/modules/<name>/` and its
engine patches in `engine/patches/`, following the [engine layout](conventions.md#rg014).
Add-ons keep reusable implementation independent of their separate `demo/` and `tests/`
projects. Their Godot suites use `unit/` for deterministic API behavior and `integration/`
for real operating-system behavior. Create only needed categories. Application suites,
helpers and fixtures live under its `tests/` package. Native unit tests remain beside
implementation/backend code, independently of consuming Godot projects.
The [add-on layout](conventions.md#rg010) and
[implementation independence](conventions.md#rg011) rules apply automatically in both areas.
Focused test-input libraries are not add-ons merely because they contain native sources.

Use `lower_snake_case` for package segments and authored logical target names. Additional
macro-generated targets use the [dot-separated naming convention](conventions.md#rg002).
Give a package's clear main entry point the package's final name and use its short label
across packages: the SQLite
add-on is `//addons/sqlite` and Platform Paths is `//addons/platform_paths`. Secondary
workflows keep descriptive names such as `edit`, `update`, `pack` and `exported`.
See [package and target names](#package-and-target-names) for selection and exceptions.

Place targets by the responsibility they own and the context they need. Keep the main
project/editor/metadata workflows beside the authored `project.godot`; suite execution
and resources share their owning test package. Runnable entry points and packs
may belong to the project or a smaller package according to their purpose. See
[target ownership and project context](#target-ownership-and-project-context).
Preserve each test's execution conditions and tags. Root operations may name child
suite resources while child test targets name the root project, provided target dependencies
remain acyclic. Direct test executables need no suite wrapper. Distinguish projects and
operations for tests with names such as `test_project` and `test_update`.

Keep an application, an add-on and the add-on's demonstration project in useful
Bazel packages. An add-on can then be reused without pulling its demo or tests
into a production pack. The [SQLite example](../../examples/addons/sqlite/README.md)
shows this structure with a real native library:

```text
examples/                         # one consuming Bazel module
  MODULE.bazel                    # dependency pins and toolchains
  deps/                           # BUILD files for pinned dependencies
  addons/sqlite/
    BUILD.bazel                   # reusable extension
    database.cc
    demo/
      BUILD.bazel                 # demo project, editor, pack and applications
      project.godot
      main/
        BUILD.bazel               # scene and its extension dependency
        database_demo.gd
        database_demo.gd.uid
        database_demo.tscn
      tests/
        BUILD.bazel               # exported-demo test
    tests/
      BUILD.bazel                 # project, editor, metadata sync and configuration export
      project.godot
      unit/
        BUILD.bazel               # suites and direct tests executable
        DatabaseTest.gd
        DatabaseTest.gd.uid
```

An application consumes reusable add-ons through explicit dependencies. Keep related code
together by purpose; an add-on can contain native code, scripts and resources
without being divided rigidly by file extension. Each application, reusable
add-on and add-on project owns a BUILD file. Test ownership and the production
boundary are defined in [test ownership](#test-ownership).

## BUILD files and package boundaries

This guidance applies to rules, tools, tests and examples. Choose package boundaries by
responsibility and dependency ownership. A directory containing `BUILD.bazel`
is a Bazel package, so its parent refers to its targets through labels rather
than owning those files as part of the parent package. See
[Bazel packages](https://bazel.build/versions/9.0.0/concepts/build-ref#packages).

| Boundary | When a separate BUILD file helps |
|---|---|
| Public composition and implementation | Consumers need a stable entry target while implementation targets have narrower visibility. |
| Operating-system backend | It owns a distinct SDK, framework, library or lifecycle integration. Keep the integration's related languages and resources together. |
| Reusable library, scene or resources | Other targets use it independently and it owns a coherent set of sources and dependencies. |
| Tests | Test-only sources, fixtures and dependencies must stay outside production packages. Follow test ownership rather than adding a test package to every directory. |

For example, an add-on can compose a common API, an Apple backend shared by
macOS/iOS, an Android backend containing both its C++ adapter and Java plugin,
and a Linux backend. Its demo project, scene resources and tests can own their
packages independently. A smaller add-on such as SQLite can keep its native
implementation in the add-on package because that extra boundary adds little.
The same reasoning applies to ruleset subsystems and build tools.

Target dependencies must be acyclic. Different targets may create dependencies
in both directions between packages, such as a root editor view naming test suites and the
suites' test targets naming the root project. Review the
actual target dependencies and visibility rather than requiring an acyclic
package graph. Production targets must remain independent of test targets and
test-only resources.

Several targets can share one BUILD file. A backend's parser and filesystem
adapter may need separate targets for testing and reuse while remaining one
package. Likewise, multiple application packaging targets can remain with the
project when they only compose the same content. Split further when sources,
dependencies or visibility justify it, rather than just because the file grows.

Keep public entry targets focused on composition, and expose implementation
or test-helper targets only to packages that need them. Define accurate direct
dependencies between targets: those boundaries, rather than the number of
BUILD files, determine which work can be reused. See
[Bazel dependencies](https://bazel.build/versions/9.0.0/concepts/dependencies).

## Package and target names

Follow the [naming conventions](conventions.md) for package segments, ordinary target names
and explicit declaration names.
The catalogue explains applicability, examples and the automated checks' limits.
The main entry takes its package's final directory name.
Bazel treats
`//addons/platform_paths` as `//addons/platform_paths:platform_paths`, so prefer the short
form in cross-package dependencies and commands. Within the same package, use ordinary
relative labels such as `:demo`.

Choose the main entry by the package's useful public responsibility, not by rule type or
declaration order:

| Package | Main target | Cross-package label |
|---|---|---|
| SQLite add-on | Extension `sqlite` | `//addons/sqlite` |
| Platform Paths add-on | Extension `platform_paths` | `//addons/platform_paths` |
| SQLite demo | Project `demo` | `//addons/sqlite/demo` |
| SQLite Godot test project | Project `tests` | `//addons/sqlite/tests` |
| SQLite unit suites | Executable `unit` | `//addons/sqlite/tests/unit` |
| Platform Paths operating-system suites | Executable `integration` | `//addons/platform_paths/tests/integration` |
| Lichtpost | Production project `lichtpost` | `//projects/lichtpost` |
| Lichtpost scene content | Resources `main` | `//projects/lichtpost/main` |
| Lichtpost gameplay suites | Executable `tests` | `//projects/lichtpost/tests` |

Keep meaningful secondary names: `edit`, `update`, `run`, `pack`, `suites`,
`fixtures`, `test_project` and operating-system/signing qualifiers describe different workflows or
content. Unit/integration categories are already in their package paths; their primary
executables need no extra `_tests` suffix. Extension use alone does not determine
the test category. Equal sibling projects or add-ons, independently useful rules, and regression
cases can retain their individual names without a fabricated default aggregate.

Additional macro-generated targets separate the complete main name and their role with a
dot, such as `game.debug_symbols` or `update.test`. Only documented companion targets are public;
the same notation also names private helpers. A file subset belongs in an output group
unless a separate operation or analysis boundary is required. See [RG002](conventions.md#rg002)
for naming and the [API reference](api/index.md) for each rule's defaults, groups, companion
targets and providers.

A short label is the same target, not an alias or dispatcher. Both example add-ons expose
their extension directly under matching package/target names. Keep library output
filenames, descriptor paths and registration symbols deliberate: renaming an extension
target can change its outputs. A directory move does not rename a Godot `res://` path automatically.
Source/exported filenames, generated artifact targets and external dependencies keep their
required naming; do not rewrite an upstream API to match local style. See
[Bazel labels](https://bazel.build/versions/9.0.0/concepts/labels) for label syntax.

## Target ownership and project context

Choose a target's owner independently from the Godot context it uses. A package owns a
coherent function and its resources. A project supplies the configuration: settings,
autoloads, main scene, the add-ons no content uses and the extensions it disables per
purpose. Each operation names
its project and the resources it works on in its own `deps`. A package-local operation can
name the root project without depending on every resource in the application or becoming
a project-wide operation.

| Target | Usual owner | Placement and scope |
|---|---|---|
| `godot_resources` | Resource or implementation package | Own related scripts, scenes, assets and authored sidecars near their sources. Declare their direct dependencies; operations name them in their `deps`, and they import under the operation's project. |
| `godot_addon` | Add-on package | Own the add-on's runtime part, editor part, extensions, platform libraries and contributions in one declaration, independently of the projects that use it. Resources whose scripts use it list it in their `deps`. |
| `godot_extension`, `godot_cc_extension` | Add-on or native implementation package | Own a reusable extension independently of the projects that consume it; by itself it is an add-on of only that extension. Keep SDK-specific implementation dependencies with the relevant backend. |
| `gdunit_test` of autoload_gdunit | Test package for the behavior under test | Keep executable suites, helpers and fixtures with their test owner; name the project and the suites explicitly. |
| `godot_test` | Package owning the tested behavior | Local scripts and end-to-end checks can both live in test packages. The tested scope determines their dependencies; an exported-app check need not be declared beside the app. |
| `godot_project` | Product configuration | Keep each project beside its `project.godot`. Operations of one project may name different resources; declare a second project, such as `test_project`, only where its operations need other configuration. |
| `godot_editor` from the core rules | Project development workflow | Keep the normal editor entry beside the project it opens. Additional editor views need a concrete authoring purpose. |
| `godot_metadata_sync` | Project development workflow | Keep the normal update operation beside its project. The authored sidecars belong with their source resources in the owning packages. |
| `godot_pack` | Project or independently delivered content | Keep the main PCK with the project. A DLC or other separately delivered content pack may belong to its own package and still use explicit project context. Do not add a pack for every resource package. |
| `godot_run` | Project or runnable feature/tool | Keep the normal game entry with the project. Put an independently useful scene or tool entry with its owner, supplying its required context. |
| Application and signing targets | Product delivery | Keep a game's APK/AAB, desktop app, iOS app and signing targets with the project, or in a separate delivery package when its dependencies or ownership justify one. |

Module repositories, engine components and their registration sets belong to workspace
or shared engine infrastructure, such as an `engines/` package per set. They provide
engines and SDK dependencies to projects; they do not belong to a gameplay package merely
because it uses them. An editor component supplies an executable; the core `godot_editor`
above opens an editor view of a project.

Use these as placement defaults. A target's BUILD location does not automatically add
resources or inherit project configuration: every operation names its project and its
`deps` explicitly. Generated private helper targets stay
with the operation that creates them. See [execution and checks](development.md) for inputs.

Scripts and scenes need no target of their own: every operation validates each resource
target it contains under its project, see [content validation](development.md#content-validation).
A target's validation sees its files and what its `deps` reach, not just files in the BUILD
package. Supply necessary global classes, autoloads, extension types and settings through
its declared inputs; limiting the source list must not remove required context.
Use [test ownership](#test-ownership) to separate test resources from production inputs.

Lichtpost validates both closures. From `examples/`:

```sh
bazel build //projects/lichtpost:pack
bazel test //projects/lichtpost/tests
```

The first validates the production resource closure, including route simulation and replay
parsing in `main/rules`, while it exports the pack. The second validates the test resource
closure and runs its behavior suites.

## Test ownership

Each example or application owns its behavior tests, replays, helpers and test data, including
exported-app and mobile runtime tests when present. The tested behavior determines ownership
and test level, not the presence of an extension or a desire for symmetric directories.

| Tested behavior | Owner and context |
|---|---|
| Native implementation/backend | Unit tests beside the implementation, such as `<addon>/native/backends/linux/tests/`; depend on its interface/implementation without requiring Godot |
| Deterministic Godot API behavior or contract | Add-on `tests/unit/`, with suites, helpers and execution together |
| Real operating-system behavior | Add-on `tests/integration/`, using the required operating-system context |
| Exported demo behavior | `demo/tests/`, consuming the demo artifact |
| Game/application behavior | The application's `tests/` package, including suites, helpers, fixtures and execution |

The add-on's `tests/` Godot project owns its configuration, such as the warning rules for the
add-on under test, and its editor/metadata workflows. The suites' test targets name that project and the necessary dependencies explicitly.
Reusable helpers and frameworks are dependencies, not implicitly selected suites. Create only
categories with actual behavior tests; extension use alone does not make a suite an
integration test. Preserve each execution target's conditions and tags.

A test package can own suites and execution while its test targets name the parent project
and the parent's operations, such as its editor view, name its suites. Review the actual target graph; this package
relationship is not itself a cycle. Add a separate shared-source package only for a useful
ownership, dependency, reuse or visibility boundary. See [package boundaries](#build-files-and-package-boundaries)
and [target placement](#target-ownership-and-project-context).

Behavior suites, assertion helpers and fixtures stay in test packages and remain test-only;
production code under test and shared runtime resources remain production-eligible. Do not
mark an entire mixed package test-only; a `godot_project` is never test-only. Godot test
operations own their generated helpers and make them
test-only by default. The [test-only convention](conventions.md#rg007) defines those operation
guarantees; [production isolation](conventions.md#rg012) defines the automatically checked
boundary. Neither requires a wrapper suite around a useful direct test executable.

Use [package and target names](#package-and-target-names) for main test entrypoints and
meaningful test case names. Public examples demonstrate the public test rules; the
[development guide](development.md) explains execution inputs, filtering and failure behavior.

## Godot scenes and scene components

Organize Godot projects around scenes and scene components. Keep each scene's
`.tscn`, script and exclusively used assets together. In a single-scene demo,
`main/` already owns that scene; do not add another directory that repeats the
demo's purpose. Use separate scene directories when a project contains
several independently meaningful units. Put shared assets at a clearly named shared
location instead of mixing them with one scene's files. Use descriptive names even for the only
playable scene: `level_01` describes a level; `main` does not. The SQLite demo's
single UI scene is named `database_demo` for the same reason.

The scene directories can share one `BUILD.bazel` while retaining separate
resource targets with their own dependencies. Add another package when visibility,
dependencies, reuse or test ownership need that boundary, rather than for each scene.

Extract smaller scene components such as dialogs, HUDs, characters and effects
into their own scenes. Give each a small, explicit interface through methods,
signals and exported properties. Parent scenes compose these scene components and
coordinate their interfaces rather than reaching into their internal nodes.

Separate reusable gameplay from level content. Define the round and its
components once; a level supplies its own definition, for example a Resource,
and its specific assets. Adding a level should not require copying or changing
the game's mechanics. A game can use the following illustrative layout:

```text
main/run/run.tscn
main/run/run.gd
main/components/courier/courier.tscn
main/components/courier/courier.gd
main/components/light/light.tscn
main/components/light/light.gd
main/components/light/light_material.tres
main/ui/hud/hud.tscn
main/ui/hud/hud.gd
main/levels/level_01/level_01.tres
main/levels/level_01/sky.png
main/shared/palette/garden_palette.tres
main/shared/ui/interface_theme.tres
```

The [Lichtpost game](../../examples/projects/lichtpost/README.md)
provides a complete example: `main/game.tscn` composes the reusable `main/run/run.tscn`,
scene component and UI scenes own their folders, and
`main/levels/level_01/level_01.tres` supplies level data. Shared palette and UI assets
live under `main/shared/`.

## Run the complete host workflow

These commands use the standalone examples module. A host C/C++ toolchain is
needed for the SQLite extension; Android and Apple mobile SDKs are not needed
for its host checks.

These commands build applications for the host. Build mobile applications by their
labels with an [export platform](platforms.md#export-platforms).

1. From the repository root, enter the module and run the demo:

   ```sh
   cd examples
   bazel run //addons/sqlite/demo:run
   ```

   The window shows **SQLite says: Hello from SQLite**.
2. Open the declared project in Godot:

   ```sh
   bazel run //addons/sqlite/demo:edit
   ```

   Edit and save through this editor view. Changes to authored files reach the checkout;
   the editor view's `deps` determine which files it contains.
3. Write missing UID/import sidecars and keep them beside their sources:

   ```sh
   bazel run //addons/sqlite/demo:update
   bazel run //addons/sqlite/tests:update
   bazel test //addons/sqlite/demo:update.test //addons/sqlite/tests:update.test
   ```

4. Run the add-on's suites and exported content, which validates their scripts:

   ```sh
   bazel test //addons/sqlite/tests/unit //addons/sqlite/demo/tests:exported
   ```

5. Export its production content:

   ```sh
   bazel build //addons/sqlite/demo:pack
   ```

6. Build a desktop application for your host:

   ```sh
   bazel build //addons/sqlite/demo:app
   ```

   On macOS, use `bazel build //addons/sqlite/demo:app --@autoload_rules_godot//godot:macos_signing=adhoc` instead for
   an ad hoc signed local application. Distribution signing is separate.

The [platform guide](platforms.md) gives Android/iOS setup and packaging, source-built
engines and symbol outputs. The [development guide](development.md) describes
editor views, checkout metadata and the public test rules in detail.

## Declare sources and dependencies

`godot_resources` owns the files of an import unit. Keep a script's UID and an
asset's `.import` file with that source. Name independent assets separately so
changing one does not reimport the rest of the project. An imported model and
the files its importer reads belong in one connected import unit.

Use `deps` for declared resources and the add-ons and extensions their scripts use; use
`runtime_deps` where a script loads a resource dynamically. Platform libraries belong to
the add-on or extension that needs them. Declare generated files explicitly.
`resource_paths`, `strip_prefix` and `prefix` define the mounted `res://` paths;
filesystem location alone does not make a file part of an operation. See
[resource paths](resources.md) for the complete rules.

The SQLite demo's scene and extension are dependencies of its
production pack. Its separate Godot test project's `unit/` package declares
the GdUnit suites and framework. Production does not depend on those targets.
Its exported-pack test starts the normal demo scene headless; that scene checks
the database result and returns a failing exit status on error.

## Module ownership

Run example commands from `examples/` and regression commands from `tests/`; each
consumer module's `MODULE.bazel` configures its own repositories and toolchains. Dependencies of another root module, including
development-only dependencies, do not provide repository names to this one.
Every module must declare the names used by its own targets. Reusing another
module's exported resources does not transfer that module's repository mapping.

The local override points to the parent rules_godot checkout. For an independent
consumer, replace it with your chosen pinned source and keep the example's
needed dependency declarations and lockfiles. Public BUILD loads use
`@autoload_rules_godot`; example code does not load private implementation modules.
