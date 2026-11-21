# Projects and resources

Declare project inputs explicitly so Bazel can reuse unrelated imports. A
`godot_project` is the configuration of a product: its `project.godot`, settings,
autoloads, main scene and the add-ons it names. It holds no resources. Every operation that runs Godot, such
as `godot_pack`, `godot_run` or `godot_test`, names its
`project` and lists what it works on in its own `deps`, as an IDE project view lists
targets.

Declare every script, scene and asset in `godot_resources` targets and name them in
the `deps` of the operations that use them. Resources compose using `deps` as well; `import_inputs`
contributes processing context without runtime membership, and
`runtime_references` records path relationships without forcing cyclic Bazel
dependencies. Reusable functionality with its own configuration, editor tooling or
native code is a `godot_addon` that resources list in `deps`; see [add-ons](#add-ons). See [execution and tests](development.md#execution-and-tests) for source-run and GdUnit tests.

## Split imports at useful boundaries

Each `godot_resources` target with files of its own is one import unit with its own
cache entry. It imports once per project and target platform, and every operation of
that project for the same target platform reuses the import. Put
independent assets in separate targets. When a model uses materials or
textures, declare those resources as `deps`, which are imported first, or put
the connected group in one target:

```starlark
load("@autoload_rules_godot//godot:defs.bzl", "godot_project", "godot_resources")

godot_resources(
    name = "texture",
    srcs = ["textures/ship.png", "textures/ship.png.import"],
)

godot_resources(
    name = "ship",
    srcs = ["models/ship.gltf"],
    deps = [":texture"],
)

godot_resources(
    name = "main",
    srcs = ["main.gd", "main.tscn", "main.gd.uid"],
)

godot_project(
    name = "game",
    project_file = "project.godot",
)

godot_pack(
    name = "content",
    project = ":game",
    deps = [":main", ":ship"],
)
```

Use sidecar entries only when those files exist. Track authored `.import`
settings and `.uid` files in version control; [`godot_metadata_sync`](development.md#checkout-metadata)
writes the ones the build generated for files that have none. Generated `.godot/` data belongs
to Bazel outputs. Declare authored sidecars in the same target as
their source, including sidecars supplied through `import_inputs`. Adding a
sidecar to a resource whose dependencies already provide its source
fails analysis, because their cached conversions would otherwise use a different
identity or importer settings.

Godot ignores some files: everything below a directory that holds a `.gdignore` or its own
`project.godot`, and hidden files and directories, whose names begin with a dot. Godot never
imports or registers them and writes no sidecars for them, while code reads them through
`FileAccess` when Godot runs from the sources, as GdUnit's HTML reporter reads its
templates. Declare them like any other files, the `.gdignore` or `project.godot` in the
same target as the files below it: source runs, tests and editors stage them, imports, class
lists and validations skip them, and packs leave out the ignored directories. Godot still
packs a hidden file of a visible directory. A file whose `.gdignore` or `project.godot`
another target declares fails analysis.

A pack whose files refer to a file it leaves out fails, since the reference works from the
sources but not in the exported game: a `preload`, `load`, `ext_resource` or any other
reference to it is an `ignored_reference` error that names the referencing file, the line and
the `.gdignore`, `project.godot` or hidden directory that hides the target. A `FileAccess` read
of it is a warning, since code may read the file only when it runs from the sources. A
`runtime_references` entry from the reading file to the file, or to a directory above it,
acknowledges the read and silences the warning:

```starlark
godot_resources(
    name = "report_templates",
    srcs = glob(["report/**"]),  # report/.gdignore, report/index.html, ...
)

godot_resources(
    name = "report_writer",
    srcs = ["report_writer.gd"],  # reads res://report/index.html through FileAccess
    runtime_references = {"report_writer.gd": ["report"]},
    deps = [":report_templates"],
)
```

Godot runs an import only for a unit with a file one of its importers handles,
such as textures, audio, fonts and models. Scripts, scenes and Godot's own
resource files (`.gd`, `.tscn`, `.tres`) cost no import; each operation's
initialization derives their UIDs and class index. Which file suffixes are
importable is reported by the project's editor, with Godot's own importers and the
[importers](#importers) of the add-ons the project names. The editor reports the
suffixes its resource loaders recognize, and those also recognized without the editor
are direct loads; a suffix with both an importer and a runtime loader therefore gets
no import; no built-in type of Godot 4.7.2 has both. An extension is an
[add-on](#add-ons) of only itself: declare it in `deps` of the resources that use it,
and it reaches every operation and application that contains them.

## Keep resource paths stable

Each file in `srcs` takes its path relative to the package of the target that lists
it, optionally after `strip_prefix`: a file of the declaring package, a generated file,
or a filegroup of another package or repository. `glob(["levels/**"])` in `//game` places
`levels/level_01.tscn` at `res://levels/level_01.tscn`, and `@vendor//data:values`, a
filegroup of `values/default.tres` in the vendor's `data` package, places it at
`res://values/default.tres`. A target that lists a file outside its own package, such as
a filegroup of a sibling package's files, fails analysis. Where a file's path relative to
its package is not its resource path, assign the resource path explicitly:

```starlark
godot_resources(
    name = "configuration",
    resource_paths = {"//configuration:generated": "config/generated.tres"},
)
```

The example's output becomes `res://config/generated.tres`, regardless of its
Bazel output path.

Resources whose package is not laid out as their project directory place their
`srcs` with `prefix`, after `strip_prefix` removes their package directory:

```starlark
godot_resources(
    name = "levels",
    srcs = glob(["content/**"]),
    strip_prefix = "content",
    prefix = "levels",
)
```

`content/level_01.tscn` becomes `res://levels/level_01.tscn`. An add-on places its
files below its directory the same way.
`resource_paths` keep their explicit paths. Duplicate resource paths, escaping paths and Godot-owned paths
are rejected. Do not include undeclared files by relying on a local `.godot`
cache or editor state.

## Export and inspect

```starlark
load("@autoload_rules_godot//godot:defs.bzl", "godot_test")

godot_test(name = "smoke_test", pack = ":content")
```

The `content` pack of the [first example](#split-imports-at-useful-boundaries) exports
the files of its `deps` and what they depend on. The selected target platform
determines the operating system, CPU set and iOS
environment; see [export platforms](platforms.md#export-platforms). The same declared pack can
serve a standalone export and matching application contexts. The smoke test
passes when the exported game exits with 0; see
[execution and tests](development.md#execution-and-tests).

```sh
bazel build //:content --output_groups=+report
bazel test //:smoke_test
```

The `.export.json` report records the declared editor version, PCK hash, declared,
selected, excluded and actual PCK paths, plus resources reimported during packing.
A pack contains its `deps` and what they depend on (`packing = "deps"`, the default), or
only what its configuration and entry points reach with `packing = "reachable"`. `required_packs`
describes prerequisite resource availability; it does not deliver or mount another pack. See
[reachable packs and pack prerequisites](#reachable-packs-and-pack-prerequisites).
Imports run in isolated projects
with the project's own import settings and application name, while runtime
configuration is removed: the main scene, autoloads, settings that name project
resources (theme, boot splash) and feature overrides the editor never applies.
The editor part of an add-on runs only in editor views, and as an importer in the
processes that convert its files; extensions run wherever Godot runs the game or exports
it; see [the purposes](#purposes). The
final export reuses the imported results and creates class/UID metadata over the
pack's files. `godot_pack.settings` sets project settings for one export,
such as a version or build number, without reimporting; `export_options` sets the
preset options exporters and extensions' export plugins define. See the
[Godot configuration guide](configuration.md).

### Pack forms

A pack's PCK comes in one of two forms, chosen per build. Outside optimized builds the
pack is written without Godot's conversions: its scenes, resources and scripts go in as
text, and Godot runs only once per pack configuration, for the exported project settings,
so an edit of a scene, a script or an imported file reruns no Godot export. Under
`--compilation_mode=opt`, Godot exports the pack and converts text scenes and resources to
binary and scripts to tokens.

| Command | Pack form |
|---|---|
| `bazel build //:app` | written |
| `bazel build -c dbg //:app` | written |
| `bazel build -c opt //:app`, or a release config that sets it, such as `--config=ios-release` or `--config=android-release` in the [examples' `.bazelrc`](../../examples/.bazelrc) | Godot's export |
| `bazel build --@autoload_rules_godot//godot:pack_conversion=godot //:app` | Godot's export |
| `bazel build -c opt --@autoload_rules_godot//godot:pack_conversion=none //:app` | fails: text packs are for development builds |

A store release therefore builds with `-c opt`, through its release config, and gets
Godot's export; a build without it ships a text pack. `--@autoload_rules_godot//godot:pack_conversion`
takes `auto` (the default, which follows `-c`), `godot` or `none`.

The pack form sits on the optimization axis. The variant, which picks Godot's debug or
release export template, stays independent of it:

| Setting | Chooses | Values |
|---|---|---|
| `-c` / `--compilation_mode` | C++ optimization and the pack form | `fastbuild`, `dbg`: written pack; `opt`: Godot's export |
| `--@autoload_rules_godot//godot:variant` | Godot's export template and the `debug`/`release` feature tags, or the editor for [runs from sources](platforms.md#the-editor-variant) | `release` (default), `debug`, `editor` |

A written pack holds what Godot's own export holds with `script_export_mode` 0 and
`editor/export/convert_text_resources_to_binary` off, and the runtime loads it the same
way. It differs from Godot's export in four points:

- It has no binary conversion and no script tokenization; scripts are readable in the PCK, and the
  pack's `script_export_mode` has no effect.
- It runs no [export plugin](#export-plugins) an extension registers natively; only
  Godot's export runs them.
- It gives a script or shader without a `.uid` sidecar no UID, where Godot's export gives
  it a random one; code reaches such a file by its path.
- It carries the text server's support data in every pack whose project lists translations; Godot's
  export packs it only for the locales whose line breaking needs it.

The `.export.json` report names the form as `"pack_conversion"`, `"godot"` or `"none"`.

Text scenes and resources hold two kinds of metadata that packs complete in the
copy they export, while the files themselves stay as authored:

- **Node IDs.** Godot 4.7 gives every node a text scene declares without a
  `unique_id` a random one, which the export writes into the PCK, so two exports
  of the same scene would differ. The pack adds a stable ID derived from the
  scene's and node's path. A node entry that overrides a node of an instanced
  scene takes that scene's ID and needs none.
- **Resource UIDs.** An `ext_resource` names a file by path and by `uid`; Godot
  resolves the UID first, so a reference with the file's UID survives the file
  being moved or renamed. The pack sets a missing or stale `uid` to the UID the
  named file has in its `.uid` sidecar, its `.import` file or its own header.
  The exported PCK is the same either way. Runs and tests from source, such as
  `godot_test(deps = ...)`, see the same corrected references.

`bazel run` on a [`godot_metadata_sync`](development.md#checkout-metadata)
target commits the same values. `--@autoload_rules_godot//godot/metadata:node_ids` and
`--@autoload_rules_godot//godot/metadata:resource_uids` each set how far that goes:

| Value | Pack | `godot_metadata_sync` | `.test` |
|---|---|---|---|
| `off` | Exports files as authored | Leaves files alone | Ignores them |
| `assign` | Completes the copy it exports | Leaves files alone | Ignores them |
| `sync` (default) | Completes the copy it exports | Writes the values | Ignores them |
| `require` | Fails while a file lacks values, for example in CI | Writes the values | Fails while a file lacks them |

Binary `.scn` and `.res` files keep the metadata they were saved with. Each operation records
both kinds in its metadata index, a JSON file with the UIDs its files declare and the node
IDs it assigns; packs and source runs complete their copies from it, and
`godot_metadata_sync` writes it into the checkout.

External applications such as Blender need an explicitly declared upstream conversion
action. They are not automatically discovered or downloaded.

## Composition, processing and consumers

| Layer | Contract | Why it is separate |
|---|---|---|
| `godot_resources` | One import unit: stable paths, transitive membership, import inputs, runtime relationships and the add-ons its files use | Declaring resources needs neither Godot nor a particular project configuration; only genuinely independent conversion work gets a separate cache entry. |
| `godot_addon` | One add-on: its runtime part, its editor part with its roles, extensions, platform libraries, Info.plist fragments, autoloads and settings | Declared once, it reaches every operation and application containing the resources that use it, and its files never become inputs of their imports. |
| `godot_project` | The configuration context: `project.godot`, settings, autoloads, main scene and the add-ons it names; every unit imports under it | Holding no resources, one context serves the game's packs, runs, tests and editor views alike, which share each unit's import. |
| `godot_pack`, `godot_run`, `godot_test`, `godot_editor`, `godot_metadata_sync` | A concrete export, execution, test or editor view of one project over its own `deps` | A test does not need an export; a data pack does not need an app bundle. |

Resource references can cycle. Bazel target dependencies cannot: declare mutually
referencing files together or record their paths in `runtime_references` rather
than introducing cyclic `deps`. A target's `deps` combines membership and
imports those units first;
`runtime_deps` also includes its complete membership for dynamic loads;
`import_inputs` supplies conversion context without making those files runtime
members. A group relationship does not invent per-file reference edges.

```starlark
godot_resources(
    name = "inventory",
    srcs = ["inventory.gd", "item.tres", "inventory.gd.uid"],
    deps = ["//common:utilities"],
    runtime_references = {
        "inventory.gd": ["item.tres"],
        "item.tres": ["inventory.gd"],
    },
)

godot_resources(
    name = "inventory_suites",
    testonly = True,
    srcs = glob(["tests/*_test.gd"]),
    deps = [":inventory", "@autoload_gdunit//:gdunit"],
)

godot_project(
    name = "test_project",
    project_file = "test_project.godot",
)

gdunit_test(
    name = "inventory_test",
    project = ":test_project",
    suites = [":inventory_suites"],
)
```

Generated and external files get their resource paths as local files do. Use
checksum-pinned Bazel repositories and explicit BUILD files for acquisition;
there is no additional package manager. Reuse an add-on by listing its `godot_addon`
target in the `deps` of the resources that use it, and declare test-framework inputs in
that consumer's module.

## Import context and cache correctness

Resources declare no project file. A unit imports under the `project_file` and own
`settings` of the project of the operation that reaches it, so resources never repeat
their consumer's configuration. The `settings` and `autoloads` of add-ons apply to the
operations that contain them and never reach an import, except the `import_settings` of
an [importer](#importers) in the imports that run it. No file of an add-on is an input of the import of the
resources that use it; only an [importer](#importers) of a named add-on reaches the imports
of the units whose files it converts.

Whether a unit needs an import depends on the project, not the unit. One
`GodotImportableSuffixes` action per project asks its editor which file suffixes its
importers handle. For each unit with a file of such a suffix, a `GodotImport` action runs;
other units cost no Godot process. A unit's result is one archive in its
output directory, or nothing. Another project imports the same unit again under its
own configuration.

One `GodotImportConfig` action per project builds the configuration of conversion from
the authored `project.godot` and the project's `settings`, without what configures the
game: `application/run/main_scene`, autoloads, editor plugins, every setting that names a
file (such as a custom theme, boot splash or translations), every key outside Godot's own
sections (such as an add-on's own key) and every feature override whose tags the editor
of import actions never has. Which settings name a file, and which sections are Godot's,
comes from rules_godot's table of Godot's settings per version, not from the value: a
string that happens to start with `res://` in another setting stays. Each import stages
only its own unit, so the file settings would name files it lacks, and none of them
configures a conversion. A `GodotImportFeatures` action asks the editor which tags of the
project's overrides it has: `editor` and the operating system and CPU of the
editor's execution platform apply during imports, while `mobile`, `android` or a custom
feature such as `integration_test` do not. A project without feature overrides starts no
Godot process for this.
An edit confined to runtime configuration reruns `GodotImportConfig`, but an unchanged
import `project.godot` preserves the downstream `GodotImport` cache entries. All other
settings, including the application name used in Godot's generated identities,
are conservative import inputs: changing one reimports every unit of that
project. Importer inputs are declared action inputs. Scripts, scenes and extension
files are not, so editing them never reimports a unit; only the files of an add-on's
importer are inputs of the imports that stage it.

Import inputs remain available during the final Godot scan as well. For
example, a glTF's external `.bin` file is staged for processing, excluded from
runtime membership, and its absence from the resulting PCK is checked. Imported
outputs can remain referenced by the converted model. This distinction avoids
relying on incidental state in a previous editor checkout.

Each unit with importable files starts a Godot process.
One target per tiny asset can be slower than a small connected group,
especially on cold builds. A unit's import also stages everything its
dependencies bring, sources and imported results, so a long `deps` chain of
large assets costs more per import. Group coupled
models or importer inputs, and split independent expensive conversions. Runtime
reference analysis does not automatically turn every referenced file into an
import input. Class/UID metadata is finalized by Godot for each operation's files;
it is not reimplemented as a Bazel compiler.

Native compilation keeps the existing object-level Bazel graph, and native code builds
once whatever the number of projects.

Add-ons and projects contribute `settings` and `autoloads` as
[Godot literals](configuration.md#three-namespaces);
[precedence and conflicts](configuration.md#precedence-and-conflicts) describes how they
compose per operation. An autoload, the main scene or a setting naming a file of the game,
such as a custom theme, translations or an add-on's own key whose value is a `res://`
path, is part of an operation only when its file is among the operation's `deps` or what
they depend on; otherwise the operation leaves it out. A setting may name a directory, which
counts when a file below it is among them; the project never depends on what it holds. A program entry, a `godot_run`
or a pack without `required_packs`, fails instead, since it starts the game itself: during
analysis for what `godot_project` and add-ons declare, and in a build for what the
authored `project.godot` names, whose values only a build reads: a `godot_run` target while
building its configuration, a pack in a check of its `_validation` output group. A program
entry skips a feature override whose tags it never has, neither one of Godot's own nor among
its project's [custom features](configuration.md#custom-features), such as
`run/main_scene.gdunit_host` of a test runner in a build without that tag. Files bound to the configuration itself, such as an application icon a
setting names, go in `godot_project.context_files` and are part of every operation.

## Add-ons

An add-on is a directory of a Godot project with optional parts, declared once with
`godot_addon`: a runtime part of scripts, scenes and assets that become members like
resources; an editor part, its `plugin.cfg` and the files its editor plugin loads;
extensions; Android and Apple platform libraries and Info.plist fragments; autoloads and
settings; and the add-ons it needs.

```starlark
load("@autoload_rules_godot//godot:defs.bzl", "godot_addon", "godot_project", "godot_resources")

godot_addon(
    name = "inventory",
    srcs = glob(["runtime/**"]),
    editor_srcs = glob(["editor/**"]),
    autoloads = {"Inventory": "*res://addons/inventory/runtime/inventory.gd"},
    platform_deps = select({
        "@platforms//os:android": [":inventory_android"],
        "//conditions:default": [],
    }),
    deps = [":inventory_extension"],
)

godot_resources(
    name = "shop",
    srcs = ["shop.gd", "shop.tscn"],
    deps = [":inventory"],
)

godot_project(
    name = "game",
    project_file = "project.godot",
    deps = ["//tools/mobile_settings"],
)
```

Every file lives below the add-on's directory, `res://addons/<name>/` unless `directory`
says otherwise: `srcs` and `editor_srcs` are placed there after `strip_prefix`, as `prefix`
places resources, so `runtime/inventory.gd` becomes
`res://addons/inventory/runtime/inventory.gd`. `resource_paths` and
`editor_resource_paths` place single files at explicit paths below the directory.

Every extension in `deps` is the add-on's, wherever its descriptor lies: operations
containing the add-on contain it, and its parts and importer load it. A file in both parts, a `.uid` or `.import` sidecar in
another part than its file, a `plugin.cfg` outside the editor part, two add-ons of one
operation whose directories overlap, and resources with a file in the directory of an
add-on of the operation fail analysis.

A vendored add-on keeps its upstream directory: its parts select files of it with globs,
and what neither part selects stays out. GdUnit4, for example, whose runtime classes use
classes of its UI directory, keeps everything but its plugin in the runtime part:

```starlark
_EDITOR = ["addons/gdUnit4/plugin.cfg", "addons/gdUnit4/plugin.gd"]

godot_addon(
    name = "gdunit4",
    srcs = glob(["addons/gdUnit4/**"], exclude = _EDITOR + ["addons/gdUnit4/test/**"]),
    editor_srcs = glob(_EDITOR),
    directory = "addons/gdUnit4",
    strip_prefix = "addons/gdUnit4",
    testonly = True,
)
```

A release downloaded into a repository of its own keeps only filegroups of its parts in
the repository's `build_file`; the add-on lives in the consumer's package and places them
by their path in the release, so `directory` names where the release keeps it:

```starlark
# BUILD file of @vendor_release, given to http_archive as build_file.
filegroup(name = "runtime", srcs = glob(["addons/vendor/runtime/**"]))

filegroup(name = "editor", srcs = glob(["addons/vendor/plugin.cfg", "addons/vendor/editor/**"]))
```

```starlark
# //third_party/vendor/BUILD.bazel
godot_addon(
    name = "vendor",
    srcs = ["@vendor_release//:runtime"],
    editor_srcs = ["@vendor_release//:editor"],
    directory = "addons/vendor",
    strip_prefix = "addons/vendor",
)
```

Without `directory`, the add-on's directory follows its target name, `addons/<name>`.

A release with prebuilt libraries, such as Sentry's, declares its libraries as the
`library` of a `godot_extension` in `deps` and leaves the descriptor it ships out of both
parts: rules_godot writes the descriptor packs list.

An add-on reaches an operation in two ways:

- **Use.** Resources whose files use the add-on list it in `deps`. Every operation whose
  `deps` contain those resources contains the add-on, and the add-ons it needs.
- **Named add-on.** The project lists in its `deps` the add-ons no content uses, such as an
  editor-only add-on with editor tooling, and every add-on whose
  [importer](#importers) its content needs. Every operation of the project contains them.

Each part imports once per project, like a resources target, whether content uses the
add-on or the project names it. The runtime part may use the runtime parts of the add-ons
it needs, the editor part both parts of them, so each part imports after those parts with
their assets staged, as resources import after their dependencies. A use never makes an
add-on's files inputs of the resources' import.

The editor part is a tool, never a member: no pack, source run or application contains
it. Tests of an editor part's scripts, such as suites of its editor tooling, reach it
through the add-on's always test-only `<name>.editor` target in the `deps` of test-only
resources, which makes its files members of those tests. Editor views of `godot_editor`
load the editor part of every add-on of the operation; editing an editor part reruns no
import, initialization or export.

### Export plugins

No export runs an add-on's `EditorExportPlugin`. What one does in Godot's own export is
declared instead, so Bazel sees each contribution as an input of the step that uses it:

| An export plugin in Godot's own export | Declaration under rules_godot |
|---|---|
| `_get_android_libraries`, `_get_android_dependencies`, manifest contents | the add-on's `platform_deps` (`android_library`, `aar_import`, Maven artifacts), the library's manifest, `godot_app.android_manifest` |
| `add_apple_embedded_platform_framework`, Swift packages, linker flags, bundle files | `platform_deps` (`swift_library`, `objc_library` with `linkopts`, `sdk_frameworks`, `data`) |
| Info.plist content | `godot_addon.infoplists`, `godot_app.ios_infoplists` |
| `_get_export_features` | build settings the project names in `godot_project.custom_features`; see [Custom features](configuration.md#custom-features) |
| settings stamped into `project.binary`, such as a version | `godot_pack.settings`, `--@autoload_rules_godot//godot:app_version`, `--@autoload_rules_godot//godot:build_number` |
| `add_file` | resources; a file only some builds have sits behind a `select()` or `label_flag` |
| `_customize_resource`, `_customize_scene`, `skip` | a `genrule` that transforms the files before they become resources |

Export plugins an extension registers natively run in every Godot export of a pack, which
loads every extension of the pack; their Gradle and Xcode hooks have no effect there. A
[written pack](#pack-forms) runs none.

An add-on's autoload names a file of its runtime part or of the runtime part of an add-on
it needs; any other fails analysis. An operation merges the autoloads and settings of its
add-ons in their dependency order,
a needed add-on before the one that needs it, and the project's own last. Two add-ons
contributing the same key with different values fail unless the project overrides it
with `autoload_overrides` or `setting_overrides`. Applications deliver the extensions,
platform libraries and Info.plist fragments of the add-ons of the packs they ship; see
[add-on platform libraries](platforms.md#add-on-platform-libraries). Resources declare no
autoloads, settings, extensions or platform libraries of their own.

### Importers

An add-on whose editor plugin or extension registers an `EditorImportPlugin` declares
the file suffixes it converts in `importer_suffixes`, and the project names the add-on in
its `deps`. Godot picks an importer by the file's suffix, not by a reference in the
content, so the project decides which importers its content imports with.

```starlark
godot_addon(
    name = "markdown",
    editor_srcs = glob(["editor/**"]),
    importer_suffixes = ["md"],
    settings = {"markdown/heading_level": "2"},
    import_settings = ["markdown/heading_level"],
)

godot_resources(name = "notes", srcs = ["notes/intro.md"])
godot_resources(name = "art", srcs = ["art/logo.png"])

godot_project(
    name = "game",
    project_file = "project.godot",
    deps = [":markdown"],
)
```

The import of `:notes` stages and enables the importer, with the add-on's parts and those
of the add-ons it needs; the import of `:art` stages no file of the add-on. A file that a
unit's import only reads, through `import_inputs`, does not count: an importer runs on the
files it converts. Editing the importer reimports exactly the units with an `.md` file of
their own. The add-on's own files of such a suffix import with its importer too.

Initializations and pack exports of operations with files of such a suffix stage and
enable the importer as well, since Godot's scan skips a file no importer recognizes;
editor views load every add-on's editor part anyway. `import_settings` lists the keys of
the add-on's `settings` that its importer reads at import time; they reach the Godot
processes that run the importer, so changing one reimports only the units the importer
converts, and its other settings reach none. The project's `setting_overrides` win over
them, as over any add-on setting.

Each build checks the declaration: the project's importer probe loads the scripts of the
add-on's editor part and fails, naming the add-on and the suffix, when they convert a
suffix `importer_suffixes` lacks or none converts a declared one. For an add-on with an
extension, the probe compares the suffixes the editor recognizes with and without the
add-on, so a declared suffix that one of Godot's own importers also handles cannot be
checked there. Resources that use an add-on with `importer_suffixes` under a project that
does not name it fail analysis.

### Purposes

Each Godot process runs for one purpose, which decides the editor parts, importers and
extensions it loads. What a process loads follows from the operation's `deps` and from how
each add-on is declared; there is no switch per project. A product without an add-on is an
operation whose `deps` do not contain it, and an add-on with other roles is declared again
with them.

| Purpose | Godot processes | Editor parts of add-ons | Extensions |
|---|---|---|---|
| `import` | every import, and the probe for the file types Godot imports | the [importers](#importers) of named add-ons whose suffixes match the unit's own files; the probe stages every one | those of the importers it stages |
| `initialize` | the initialization of each operation | the importers of named add-ons whose suffixes match the operation's files | those of the importers it stages |
| `export` | each pack's export and the probe of an application's export | the importers of named add-ons whose suffixes match the pack's files, in the export only | every one of the pack's; the PCK lists them in `.godot/extension_list.cfg` |
| `runtime` | packs, source runs (`godot_run`, `godot_test`) and applications | none | every one of the operation's |
| `editor` | the editor of a `godot_editor` [editor view](development.md#editor-view) | every add-on's, for docks and inspectors | every one of the operation's |

Plugins the authored `project.godot` enables in `editor_plugins/enabled` never run. A pack
whose export meets a class Godot does not know, such as one of an extension without a
library for the platform that runs the export, fails, naming the class: Godot would
otherwise drop that class's values from the scenes and resources it converts.

## Export membership

Name whole resource targets in the pack's `deps`. Raw JSON/CSV and dynamically loaded files
are members even when no static reference reaches them. The generated preset follows the
configured operating system and CPU set. Pack `settings`, `preset_settings` and
`export_options` configure the export, not its membership; the
[Godot configuration guide](configuration.md) describes them.

A pack contains its resources and extension descriptors, never their extension
libraries or link archives. A resource that merely has a library-like name, such as
`data/table.so`, is ordinary content.

```starlark
godot_pack(name = "pack", project = ":project", deps = [":game"])
godot_run(name = "run", pack = ":pack")
```

Every pack checks what its files reference, such as
[files Godot ignores](#split-imports-at-useful-boundaries) that the export leaves out. A pack
of all members runs the check beside its export as a Bazel validation action, which
`--norun_validations` skips. Its errors fail the build; its warnings are printed in the build
output when the check runs and listed in the `selection` output group's report.

`godot_run`, pack-based tests and `godot_app` deliver the pack's extension libraries
beside the PCK or link them into the application. A PCK used elsewhere, including
an additional or required pack, needs its extension libraries delivered at the paths its
descriptors name, or its static extension libraries linked into the application. Libraries stored in a
PCK are not loaded, including through Godot's Android extraction fallback.

The export report contains the declared, selected, excluded and actual PCK paths and the
extension library paths. Checks accept Godot's import/remap representation, reject omitted ordinary
members, and reject excluded source paths, or the `.uid` files Godot writes
beside them, that leak into the PCK. Metadata and
extension libraries have their own representation/delivery rules. Hidden files
and other inputs Godot cannot export are not silently renamed to bypass Godot.
Linking, runtime layout and signing belong to `godot_app`.
The inspector streams the PCK directory and hashes the file incrementally, so
inspection does not load the complete asset contents into memory.

## Detected references

Reachable packs follow the references a bounded scan finds in their files, without running
Godot. The scanners cover text scenes/resources, literal GDScript loads/preloads,
`FileAccess` reads of `res://` paths, known global script class uses, shader includes,
local glTF inputs and resource paths in project settings other than editor plugins.
Each resolved reference names its kind of target: a `file`, a `uid` or a `directory`. A
project setting or a declared runtime reference may name a directory, such as
`modules="res://modules"`, and resolves when the scanned files include files below it; any
other reference that names a directory is invalid. Files Godot ignores are not scanned.
Non-literal accesses and `DirAccess` listings are not followed. Binary resources and
arbitrary code evaluation are outside the scanners' coverage. Inferred references never add
undeclared Bazel dependencies. Group membership and processing edges retain their separate
meaning.

The scan knows the UIDs the [metadata index](#export-and-inspect) knows,
including those only generated sidecars declare. While
`--@autoload_rules_godot//godot/metadata:resource_uids` is not `require`, a reference whose
`uid` names another declared file than its `path` points at its path's UID.

UID and import sidecars remain metadata/import dependencies, so changes propagate to
resource consumers. Relative runtime `load` paths resolve from `res://`, while `preload`
and script inheritance paths resolve from the script directory, matching Godot's separate
loading semantics.

## Reachable packs and pack prerequisites

`packing = "reachable"` packs only what the pack's configuration uses: everything the main
scene, autoloads, other configured resources, `entry_points` and
extensions reach among the files of its `deps` through detected references and declared
`runtime_references`, plus the complete `runtime_deps` of every target whose files are
reached. A setting or `runtime_references` entry that names a directory reaches every
member below it.
`required_packs` names packs whose resources are available to this pack and must not be
packed again. It does not ship them or establish runtime load order. For example:

```starlark
godot_pack(
    name = "shared_pack",
    project = ":game_project",
    deps = [":shared"],
    entry_points = ["shared/common.tres"],
    packing = "reachable",
)

godot_pack(
    name = "level_pack",
    project = ":game_project",
    deps = [":level"],
    entry_points = ["levels/level.tscn"],
    required_packs = [":shared_pack"],
    packing = "reachable",
)
```

In a reachable pack, every reference of a packed file must resolve in this pack or a
required pack. Violations fail the `GodotPackSelection` action and name the referencing file. Loading
a pack at runtime and delivering it are up to the game.

Reachability does not guess. A reached file with a non-literal `load()`, file
read, directory listing or shader include, and a reached binary `.scn` or `.res`
file, fails unless its own `runtime_references` or its target's `runtime_deps`
declare what it uses. A file Godot loads from a default path without a setting,
such as `res://default_bus_layout.tres`, needs an entry point.

The `selection` output group holds the selection report: the reference chain
from a root to every packed file, the resources that required packs provide and
the resolved references. A path that a required pack provides must have the same source file
in this pack. Identities Godot generates during import are not compared, so
build packs that are loaded together under one project, which share its imports,
unless their resources carry authored `.uid` and `.import` sidecars.

Each pack scans the files of its own `deps`. Bazel fixes the export's inputs before the
scan runs, so the export still depends on every file of its `deps`: changing an
unreachable file reruns the scan and the export, with unchanged contents.
When a required pack's contents change, a dependent pack reruns its scan
and keeps its cached export if its own contents are unchanged.
