# rules_godot

[![CI](https://github.com/autoload-dev/rules_godot/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/autoload-dev/rules_godot/actions/workflows/ci.yml)
[![BCR](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fbcr.bazel.build%2Fmodules%2Fautoload_rules_godot%2Fmetadata.json&query=%24.versions%5B-1%3A%5D&label=BCR&color=43a047)](https://registry.bazel.build/modules/autoload_rules_godot)
[![License: MPL 2.0](https://img.shields.io/badge/license-MPL--2.0-blue.svg)](LICENSE)

Bazel rules for building, testing and packaging [Godot](https://godotengine.org) games.

rules_godot turns a Godot project into Bazel targets: assets import independently, native
code compiles one object at a time, and the results are cached and reused across the editor,
tests and every application package.

## Features

- **Incremental imports:** each resource target imports once per project and platform and
  is shared by packs, tests and the editor.
- **GDExtensions:** build C ABI and godot-cpp extensions from source, or consume prebuilt
  libraries.
- **Applications:** package Linux, macOS, Android and iOS applications, including debug
  symbols, App Bundles and signing.
- **Engines:** use Godot's prebuilt engines or build one from source with only the modules
  your game needs.
- **Tests:** run GDScript tests as Bazel tests, and
  [GdUnit4](https://github.com/godot-gdunit-labs/gdUnit4) suites with the add-on module
  [`autoload_gdunit`](addons/gdunit/README.md).
- **Hermetic:** Bazel downloads the editor and export templates; no globally installed Godot
  is needed.

## Requirements

- Bazel 9 or later
- Godot >=4.7.2 and <5.0.0
- A Linux or macOS host with a C/C++ toolchain

## Quick start

1. Add rules_godot and an engine to your `MODULE.bazel`, with the latest version from the
   [Bazel Central Registry](https://registry.bazel.build/modules/autoload_rules_godot) or the
   [releases](https://github.com/autoload-dev/rules_godot/releases) in place of `<version>`:

   ```starlark
   bazel_dep(name = "autoload_rules_godot", version = "<version>")

   godot_engines = use_extension("@autoload_rules_godot//godot:extensions.bzl", "godot_engines")
   godot_engines.prebuilt(name = "godot", version = "4.7.2")
   use_repo(godot_engines, "godot")
   register_toolchains("@godot//toolchains:all")
   ```

2. Add these options to your `.bazelrc` and `.godot-editor` to your `.bazelignore`;
   [Installation](docs/public/installation.md) explains them:

   ```text
   build --incompatible_exclude_starlark_flags_from_exec_config
   common --experimental_output_paths=strip
   common --modify_execution_info=(?!Godot).*=-supports-path-mapping
   ```

3. Add a `BUILD.bazel` beside your `project.godot`:

   ```starlark
   load(
       "@autoload_rules_godot//godot:defs.bzl",
       "godot_run",
       "godot_editor",
       "godot_pack",
       "godot_project",
       "godot_resources",
   )

   godot_resources(name = "main", srcs = ["main.gd", "main.tscn"])
   godot_resources(name = "logo", srcs = ["textures/logo.svg"])

   godot_project(name = "game", project_file = "project.godot")

   godot_pack(name = "content", project = ":game", deps = [":logo", ":main"])
   godot_run(name = "play", pack = ":content", headless = False)
   godot_editor(name = "edit", project = ":game", deps = [":logo", ":main"])
   ```

   Give each independent asset or connected asset group its own `godot_resources` target:
   each is one import unit. [Projects and resources](docs/public/resources.md) covers
   dependencies, generated files and stable `res://` paths.

4. Run `bazel run :play` from that package. Your game opens in its window.
   `bazel run :edit` opens the project in the Godot editor.

## Example

Lichtpost is a small one-button courier game that uses tests, an editor view and
application packaging. With [mise](https://mise.jdx.dev/getting-started.html) installed:

```sh
git clone https://github.com/autoload-dev/rules_godot.git
cd rules_godot
mise trust
cd examples
mise exec -- bazel run //projects/lichtpost:run
```

Choose **Let's go**, then press Space to jump over gaps and pipes. The
[Lichtpost guide](examples/projects/lichtpost/README.md) walks through the project.

## Documentation

| Task | Guide |
| --- | --- |
| Install the module and set Bazel options | [Installation](docs/public/installation.md) |
| Organize a project and reusable add-ons | [Project layout](docs/public/project-layout.md) |
| Compose resources, add-ons, imports and packs | [Projects and resources](docs/public/resources.md) |
| Edit projects and run script or GdUnit tests | [Development and testing](docs/public/development.md) |
| Package desktop, Android or iOS applications | [Application platforms](docs/public/platforms.md) |
| Compile and package extensions | [GDExtensions](docs/public/gdextension.md) |
| Build an engine from source or inspect debug symbols | [Engines](docs/public/engine.md) |
| Choose an engine version | [Versions](docs/public/versions.md) |
| Look up a rule, provider or module extension | [API reference](docs/public/api/index.md) |

## Contributing

Issues and pull requests are welcome. See the [repository instructions](AGENTS.md) for
working conventions and verification.

## License

rules_godot is licensed under the [Mozilla Public License 2.0](LICENSE). You can use it to
build commercial and closed-source games; changes to rules_godot's own files that you
distribute must stay under the MPL-2.0.
