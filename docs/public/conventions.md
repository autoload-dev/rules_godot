# Repository conventions

Use these rules when authoring Bazel packages, targets, examples and documentation.
Stable IDs make diagnostics searchable even if the catalogue is reorganized. They apply to
repository-maintained rules, tools, examples, test projects and documentation, including
standalone modules. External repositories and source files are separate identities, not
authored target declarations.

| ID | Rule | Policy | Automated coverage | Enforcement |
|---|---|---|---|---|
| [RG001](#rg001) | Package segments use lower snake case | Required | All inventoried owned BUILD paths, relative to the nearest module | Error |
| [RG002](#rg002) | Authored names use lower snake case; owned helpers use dotted roles | Required | Bazel-evaluated owned expansions and explicit roots; computed roots require review | Error; incomplete required ownership fails |
| [RG003](#rg003) | Target declarations pass `name` explicitly | Required | BUILD calls associated with at least one evaluated rule | Error |
| [RG004](#rg004) | Public documentation does not reference test fixtures | Required | Concrete paths of regression projects and add-ons in public guides and READMEs | Error |
| [RG006](#rg006) | Documented commands name existing targets | Required | Labels of `bazel build`, `run` and `test` commands in documentation | Error |
| [RG007](#rg007) | Godot test operations and their helpers are test-only | Required | Effective flags on recognized Godot test macro expansions | Error; missing evidence is reported as not checked |
| [RG008](#rg008) | Application content lives under `main/` | Required | Production-eligible resource inputs physically owned by typed application or add-on demo/test scopes | Error; unresolved membership is reported as not checked |
| [RG009](#rg009) | Applications and add-ons use their typed roots | Required | Project and add-on directories and authored Godot configurations of every consumer module | Error |
| [RG010](#rg010) | Add-ons separate demo and Godot test projects | Required | Every add-on under either typed add-on root | Error |
| [RG011](#rg011) | Reusable add-on implementation is independent of its demo | Required | Direct authored workspace inputs of production-eligible implementation declarations, resolved by Bazel | Error; missing role flags are reported as not checked |
| [RG012](#rg012) | Production targets are independent of test scopes | Required | Direct authored workspace inputs of every production-eligible declaration outside a test scope, resolved by Bazel | Error; missing role flags are reported as not checked |
| [RG013](#rg013) | Public documentation does not link to internal documentation | Required | Local Markdown and HTML link destinations in public guides and READMEs | Error |
| [RG014](#rg014) | Engine modules and patches live under `engine/` | Required | Files of every Godot project root in both areas, owned by their nearest `project.godot` | Error |
| [RG015](#rg015) | Add-on modules share one layout | Required | Every module `addons/<module>/` of this repository, and every `backends/` directory | Error |

The [project layout guide](project-layout.md) shows where these conventions fit into an
application, add-on or test project. Choosing the main entry point and useful package
boundaries still requires judgment; these checks do not elect a primary target.

## RG001

**Package segments use lower snake case.** Each segment of an owned Bazel package path
must match `[a-z][a-z0-9]*(?:_[a-z0-9]+)*`: an ASCII lowercase letter first, then lowercase
letters/digits, separated by single underscores. Leading, trailing and repeated underscores
are excluded. This makes package labels predictable and consistent across operating systems.

`addons/platform_paths` and `tools/conventions` conform; `addons/platform-paths`,
`tools/_checks`, `tools/checks_` and `tools/my__checks` do not. Check every ancestor segment,
even when only the leaf directory contains a BUILD file. A module root has no package
segment. Names of directories containing only assets are outside this rule unless they
form part of a package path.

The checker inventories Git-tracked and untracked, non-ignored `BUILD`/`BUILD.bazel` files
and resolves each against its nearest `MODULE.bazel`. It does not scan fetched repositories,
Bazel output trees or generated BUILD templates as if they were maintained packages.

## RG002

**Ordinary target names use lower snake case.** Authored logical target names follow the
same spelling as RG001. Consistent names make labels easy to type and distinguish logical
targets from output filenames and generated artifacts.

```starlark
# Conforming declarations; helper names describe separate responsibilities.
godot_resources(name = "main", srcs = ["game.gd"])
filegroup(name = "linux_package", srcs = [":bundle"])
```

Names such as `LinuxPackage`, `linux-package`, `linux/package` and `linux__package` do not
conform as ordinary authored names. A slash in a target name is not a package boundary.
Preserve meaningful secondary names; do not create aliases or aggregates just for naming.

For additional targets generated by a rules_godot-owned macro, separate the complete authored
main name and the generated role with a dot: `<name>.<role>`. Use lower snake case within
each logical segment; for example, `space_game` and `space_game.debug_symbols` make the
boundary visible. This is a naming example, not a promise that every macro exports a
`debug_symbols` target. Nested owned helpers may append another dotted role. Keep the main
target unchanged and reserve its generated namespace for that macro.

The dot does not make a helper public. Only documented exported companion targets are
supported consumer interfaces; private targets keep actual Bazel visibility restrictions.
Target labels and artifact filenames are separate contracts: a helper rename must not
accidentally rename a bundle, native library or executable. Bazel's
[symbolic macro schema](https://github.com/bazelbuild/bazel/blob/9.3.0/site/en/extending/macros.md#naming)
allows this separator. The checker examines the Bazel-evaluated expansions of owned macros, including
nested helpers; a compliant main name alone does not establish compliance for its helpers.

This convention covers every rules_godot-owned public macro and its nested private macros,
including project, test, extension, export-platform and packaging helpers. A generated repository's
independent entrypoints do not acquire a fictitious common main target; apply the separator
where a main target actually has companion targets. Repository names and output-group keys
are separate interfaces.

Upstream-generated identities retain upstream spelling. rules_android and rules_apple derive delivered
basenames from a slash suffix, so a role may continue after a slash with the main name again,
as in `app.android_apk/app.native_apk`; the owning definition explains why.

Source-file labels and external identities retain their required spelling.
An explicit output filename is also distinct: for example,
`cc_binary(name = "libnative.so", linkshared = True)` names a shared library artifact.
The checker recognizes that qualification only for a `cc_binary` with effective
`linkshared = True`, a filename without `/`, and a `.so`, `.dylib` or `.dll` suffix.
A `filegroup` named `libnative.so` has no such output contract and is a violation.

For literal names, the authored declaration establishes the complete main name. Bazel supplies
the emitted labels and the instantiation frames of each evaluated rule; generated names are checked against
that main name, including its existing underscores.

**Computed macro roots remain a review obligation**: `generator_name` may identify an internal
helper instead of the authored invocation. Review the expression and its inputs while
preserving output filenames, registration symbols and resource paths. Record
the roots in `REVIEWED` in [the RG002 module](../../tools/conventions/rules/rg002.py), by BUILD
path. The roots are the call's emitted names without a role; every other emitted owned label is
checked against exactly one of them. A changed root set requires renewed review; stale
reviews fail. Missing required ownership or review evidence fails the check.
Incomplete review evidence is reported as `RG002 not checked`. This strictness does not
change other conventions' coverage policy.

## RG003

**Target declarations pass `name` explicitly.** Show the target's identity at its declaration
so readers can locate it without following an inferred default or a dictionary expansion.
A computed expression still counts as explicit:

```starlark
godot_resources(name = "main", srcs = ["game.gd"])
godot_resources(name = variant + "_resources", srcs = sources)
```

A target-producing call such as `target_macro(**options)` does not express `name` explicitly.
Use `target_macro(name = target_name, **other_options)` instead. Calls such as `load`,
`package`, `exports_files`, `glob` and arbitrary helpers are not target declarations merely
because they appear in a BUILD file.

The checker joins parsed BUILD calls with evaluated rules by their source location. This
classifies actual target-producing calls without a guessed list of function names and
handles macros, aliases and comprehensions. Macro implementation calls inside `.bzl` files
and generated targets are outside this authored-BUILD check. Calls producing no evaluated
rules are outside its coverage. Ambiguous or missing source evidence and failed parsing or
loading stop the audit with an error rather than silently passing.

## RG004

**Public documentation does not reference test fixtures.** Public guides and READMEs show
runnable examples, which users can copy, instead of named regression projects or add-ons from the
test area. The check reports each line with a concrete path of a project or add-on in either area in Markdown under
`docs/` and in every README, except
`docs/internal/` and `AGENTS.md` files. Abstract layout placeholders remain usable in
structural guidance; they are not runnable fixture references. Maintainer fixture commands belong in internal contributor documentation.

## RG006

**Documented commands name existing targets.** Copying a command from the documentation
works only if its labels exist.
The check reads the labels of `bazel build`, `bazel run` and `bazel test` commands in
Markdown under `docs/` and in every README, except `AGENTS.md` files. Arguments after `--`,
`...` patterns and `//path/to` placeholders are skipped.

Each label resolves in exactly one module that contains its package:

- `@autoload_rules_godot//` labels resolve in the root module.
- A document inside a standalone module, such as `examples/`, resolves labels in its own
  module first.
- `//:target` labels in root-module documents are consumer templates and are not checked.

The named rule must exist in that package; `:all`, `:*` and `:all-targets` only require the
package. A label is reported at its command's line when no module or several modules
contain the package, or when the package has no such rule. A resolved label does not prove
that the documented workflow succeeds.

## RG007

**Godot test operations and their helpers are test-only.** The targets created by
`godot_test` and autoload_gdunit's `gdunit_test` must have effective
`testonly = True`. This includes their generated case lists, resources and views of
the project. They belong exclusively to the test operation and must not become production
dependencies, following [test ownership](project-layout.md#test-ownership).

The operations set `testonly = True` on themselves and their helpers unless the caller
passes `testonly = False`, so a test can sit in a mixed production/test package without
further flags. The rule reports such opt-outs. The checker asks Bazel for
[attribute defaults](https://bazel.build/query/language#xml), so it judges the effective
value, including package defaults, without requiring a literal attribute.
[Bazel's test-only dependency check](https://bazel.build/reference/be/common-definitions#common.testonly)
then protects the marked targets from production consumers.

Applicability comes from the evaluated `generator_function` metadata of the three named
operations, including source aliases and comprehensions. Each attributed rule target is
checked. Each false flag is reported at the call with the affected target label. Missing
scalar flags or missing generator evidence for a directly named operation are reported as
not checked. Other targets at the same authored call with an unknown or different generator
are also reported as not checked; their ownership must not be inferred from a neighboring
test target. Arbitrary wrappers which hide the operation's
identity are outside automated coverage; a `_test` suffix alone does not establish ownership.

Shared runtime resources, code under test and existing projects supplied as inputs retain
their production eligibility. This rule does not traverse a test's dependency closure or
classify separately declared suites and test data; those still follow the broader ownership
policy. Loading-time flags do not establish configured resource membership or runtime behavior.

## RG008

**Application content lives under `main/` of its physical project.** The location of the
project or add-on establishes ownership in both repository areas, following [typed roots](#rg009).
Application cases own their scenes, scripts and exclusively used assets below `main/`.
An add-on's implementation retains its own layout; its `demo/` and `tests/` project scopes
apply the same application-content rule. Keep authored UID/import sidecars beside sources.

For example:

```starlark
godot_resources(
    name = "main",
    srcs = ["main/game.gd", "main/game.tscn"],
)
```

These sources use `res://main/game.gd` and `res://main/game.tscn`. Update configuration,
scene/script references, authored import sidecars and assertions when moving application
files. Do not preserve an old application path through an unnecessary `resource_paths` entry.
Godot plugin namespaces and deliberate resource path regressions can retain explicit entries;
a mounted `addons/` path never changes the project or add-on that physically owns a source.

The check inspects loaded `godot_resources` inputs declared through `srcs` and `resource_paths`,
including sources supplied across modules. Ownership comes from the physical source path,
not the project consuming it. In an application case, the nearest authored configuration
owns its application inputs; shared inputs without their own configuration use the case
root's `main/`. Contexts for one operating system may each own their configuration and `main/`.
Several resource paths of one physical source produce one finding.

There is no blanket exemption for regression projects, test-only project compositions or
macro-generated projects. Test-only suites/helpers belong in an application's `tests/`
scope, or in `unit/`/`integration/` of an add-on's Godot test project. Both the physical test
scope and the `godot_resources` target's effective test-only flag establish that ownership; the flag
alone does not waive application layout. Generated outputs and the build and delivery inputs of
extension and platform libraries are
outside this declared Godot-resource subset. Missing role/membership facts and unresolved
aggregate inputs are reported as not checked. The check does not classify undeclared files
or require an empty `main/` where no application-owned resources exist. No manually listed
application roots or reusable-resource exemptions select applicability.

## RG009

**Applications and add-ons use their typed roots.** Every consumer module of this
repository uses the same layout of projects and add-ons, measured from its module root:

| Module | Application projects | Add-ons |
|---|---|---|
| Examples, `examples/` | `examples/projects/<name>/` | `examples/addons/<name>/` |
| Regression tests, `tests/` | `tests/smoke/<operating_system>/`, `tests/script_run/`, `tests/patched_engine/` | `tests/shared_addon/` |
| Add-on examples, `addons/<module>/examples/` | `addons/<module>/examples/projects/<name>/` | none: the add-ons are in the module |

The path determines whether a directory is a project or an add-on, and which rules apply.
A project case owns a BUILD
file and at least one authored Godot configuration; related operating-system contexts can share
one named case. Add-on project structure follows [the add-on layout rule](#rg010).
There is no per-directory admission list and no exemption based on a mobile module root.

Focused unit/analysis packages and their C++/provider fixture inputs remain with their
owning test domain when they are not independently reusable add-ons. C++ source files
alone do not establish an add-on. A helper library should not be put in a project directory
and given an empty Godot project just to fit the taxonomy.

The check inventories project and add-on directories and authored `project.godot` files in
every consumer module; the white-box fixture projects of the ruleset module and of an add-on
module's `tests/` are outside it. Configurations must belong to a named project or add-on.
Temporary projects constructed inside source strings and generated configuration templates are outside the
inventory. This does not require a project or BUILD package for each assertion. See the
[test ownership](project-layout.md#test-ownership) for test ownership and
[the layout guide](project-layout.md) for navigation.

## RG010

**Add-ons separate implementation, demo and Godot tests.** Every add-on under either
add-on root owns its reusable implementation, a normal-use project under `demo/` and a Godot
test project under `tests/`. Each of those three scopes owns a BUILD file. The two projects
own `project.godot` directly; do not add another project at the add-on root or inside a suite
category. Native backend unit tests do not require a Godot configuration.

Both add-on roots are discovered from the shared workspace inventory. Adding an add-on
immediately applies this rule without editing a list. Use `unit/` or `integration/` packages
only for the behavior actually present, following [test ownership](project-layout.md#test-ownership).
Reuse the test root configuration for those categories. The inventory establishes project
and BUILD locations, not suite classification or every configured composition input.

## RG011

**Reusable add-on implementation is independent of its demo.** The location under
either typed add-on root selects this rule automatically. Implementation declarations must
not consume targets or source files owned by the add-on's `demo/`. The demo depends on the
reusable implementation; production dependency direction must not return to it. Test inputs
are covered for every production target by [RG012](#rg012).

For production-eligible implementation declarations, the check examines authored label,
label-list and label-keyed-string inputs; implicit attributes from the rule definition are
not inputs the declaration chose. Bazel resolves each input to its defining target or source
file, including source symlinks and labels of the workspace's other modules. External
repositories cannot be a demo and are not resolved. Resource paths
and name suffixes do not establish whether a directory is a project or an add-on. Generated helpers sharing an authored input
produce one finding at that call. Test-only declarations are outside this rule, and visibility
grants are not implementation dependencies.

This is a loading-time direct-input check over conditional branches reported by Bazel query,
not one selected configuration. Missing effective role flags are reported as not checked.
Indirect paths through helper packages remain outside this automated subset; review them
separately. Passing alone does not prove the complete configured dependency closure.

## RG012

**Production targets are independent of test scopes.** A target that is not test-only must
not consume targets or source files owned by a test scope. Mark the consumer `testonly` when
it exists only for tests, or move the input out of `tests/` when production code really
shares it. This applies to applications, add-ons, their demos and the ruleset itself,
following [test ownership](project-layout.md#test-ownership).

A test scope is a `tests/` directory below the root of a project or add-on, such as
`<project>/tests/`, `<addon>/tests/`, `<addon>/demo/tests/` or a backend's
`<addon>/native/backends/linux/tests/`. Outside projects and add-ons it is a `tests/` directory below the
module root, such as the ruleset's white-box packages `godot/private/tests/`. Paths are measured
from the owning module, so the regression module's directory `tests/` is not itself a test
scope: a regression project's `main/` may use the module's `support/` fixtures, but not its own
`tests/` suites.

```starlark
# game/main/BUILD.bazel
godot_resources(
    name = "main",
    srcs = ["game.gd"],
    deps = ["//game/tests:suites"],  # Reported: suites are test-owned.
)
```

The check uses the same input resolution as [RG011](#rg011): authored label, label-list and
label-keyed-string attributes, resolved by Bazel to their defining target or source file
across the workspace's modules. Declarations inside a test scope and test-only targets are
consumers, not subjects. Missing effective role flags are reported as not checked. Bazel's own
test-only dependency check covers edges to marked targets; this rule also covers unmarked
targets and source files by their location. Indirect paths and configured closures remain
outside this automated subset.

## RG013

**Public documentation does not link to internal documentation.** Consumer guides and
READMEs must stand on their own. Link to public setup and usage guides instead of requiring
readers to follow contributor implementation or verification instructions.

The check resolves static local destinations in Markdown links, images, reference definitions
and quoted or unquoted HTML `href`/`src` attributes against the document's directory.
Root-relative paths, fragments, query strings, percent encoding, Markdown punctuation escapes
and HTML character references are handled too. Inline code, top-level fenced or indented code
blocks and HTML comments are ignored. Merely naming an internal directory or showing a link
inside such a code example does not create a link.

Internal reference pages, agent instructions, historical specifications and the shared
documentation index are outside this public-documentation check. The shared index routes
readers to the appropriate audience. External URLs and dynamically generated links are
outside automated coverage and need review; the checker does not fetch remote documents.
This source check does not implement a full Markdown renderer: nested list/blockquote blocks
and destinations containing whitespace or nested parentheses need review.

## RG014

**Engine modules and patches live under `engine/`.** A Godot project that builds its engine
from sources keeps each custom engine module in `engine/modules/<name>/` and each engine
patch as a `.patch` or `.diff` file directly in `engine/patches/`. Readers and source
recipes then find a project's engine inputs in one place, separate from its application
content under `main/`.

```text
examples/projects/<name>/
  project.godot
  main/
  engine/
    modules/
      <module>/               # config.py, SCsub, register_types.cpp, sources, BUILD.bazel
    patches/
      BUILD.bazel             # exports the patches to the module's recipes
      <change>.patch
```

The check inventories the files of every project root under `examples/` and `tests/`; a
`project.godot` marks a root, and a nested project owns its own files. In each project it
reports:

- any entry of `engine/` other than `modules/` and `patches/`;
- any file directly in `engine/modules/`, and any directory there without both `config.py`
  and `SCsub`;
- any entry of `engine/patches/` other than `.patch`/`.diff` files and a BUILD file,
  including subdirectories;
- any engine module directory outside `engine/` (a directory owning `config.py` together
  with `SCsub` or `register_types.*`) and any `.patch`/`.diff` file outside
  `engine/patches/`.

A stray directory is reported once, at its first file. An add-on's own `register_types.*`
without `config.py` is an extension, not an engine module. Files outside every project
root, such as dependency patches in `examples/deps/`, are outside this rule. The check does
not read module or patch contents and does not prove that a recipe consumes them.

## RG015

**Add-on modules share one layout, and backends live in `native/backends/`.** This
repository's add-on modules in `addons/<module>/` follow the layout of the add-on generator's
template, so that the same tasks build, test and release every module and nothing outside a
module lists it. Each module:

- is named `autoload_<module>` and owns `MODULE.bazel`, `README.md`, `REPO.bazel`,
  `BUILD.bazel`, `.bazelrc`, `.bazelversion`, `.gitignore`, `.gitattributes`, `addon.pkl`,
  `presubmit.yml` and an `examples/` module with `MODULE.bazel`, `BUILD.bazel`, `.bazelrc`
  and `.bazelversion`;
- imports the shared settings: `.bazelrc` imports `addons/module.bazelrc`, and
  `examples/.bazelrc` imports `addons/examples.bazelrc`;
- sets `lanes` (some of `host`, `android`, `ios`) and `hosts` (some of `linux`, `macos`) in
  `addon.pkl`, each a `List`, and nothing else;
- has at least one example project in `examples/projects/<name>/`, each defining the targets
  `app`, `edit` and `pack`;
- gives each `godot_cc_extension` a name no other add-on module uses: on iOS it names the
  extension's framework, and an application's frameworks share one directory.

In every add-on, including those of `examples/`, a `backends/` directory sits in `native/`:
the backends implement the platform-independent API beside them. The check reads the files
and their text without loading Bazel; it reports a stray `backends/` directory once.

## Run and maintain the checks

From the rules_godot repository root:

```sh
mise run conventions
```

The command runs the registered convention rules across all owned modules. Violations include the stable rule ID, file, line and a link to
this catalogue. The checker reports unreviewed computed macro names separately.
Exit status `1` indicates convention findings; `2` indicates an incomplete audit.
The hk hooks and CI select complementary code and documentation tasks, so each rule runs
at most once per check invocation. The full command above explicitly runs both sets.

Run one rule independently or list the registered rules:

```sh
bazel run //tools/conventions -- --rule RG001
bazel run //tools/conventions -- --list-rules
```

Each rule lives in its own module under [`tools/conventions/rules`](../../tools/conventions/rules)
with its regression tests beside it. The convention checks do not
prove configured dependencies or runtime behavior.

Fix findings in their sources. A target rename can change outputs, so update references and
artifact assertions deliberately; there is no automatic rename fixer. Temporary exceptions
belong beside their owning rule, with a reason and removal condition. For automated rules,
keep qualifications and reviewed coverage limits in the owning rule module.
There is no blanket exemption for fixtures or the test tree.
