# Verification hosts

Read this page when deciding which tests a change needs locally, preparing a change for review, or changing
verification tooling. The [verification policy](verification.md) owns timing, TDD and reuse;
[recipes](verification-recipes.md) describe setup and individual fixtures.

## Supported verification matrix

This is the maintained representative verification set, not a Cartesian product. Product
support and acquisition availability remain in [platform setup](../../rules_godot/docs/public/platforms.md),
[versions](../../rules_godot/docs/public/versions.md) and [engines](../../rules_godot/docs/public/engine.md). A missing matrix cell
creates no automatic obligation to add it. Do not infer that all CPUs or upstream
Godot features are covered from one passing cell.

| Target / workflow | Where it runs | Representative engine/configuration | Required evidence when affected |
|---|---|---|---|
| Linux desktop: ruleset behavior and desktop app | Linux CI; local Linux for focused feedback | CI runner CPU, pinned prebuilt engine; default build configuration | Selected desktop tests, example checks/suites and exported-app assertions |
| macOS desktop: ruleset behavior and desktop app | macOS CI; local macOS for focused feedback | Host CPU, pinned prebuilt engine; default build configuration | Selected desktop tests, example checks/suites and exported-app assertions |
| Source-built engines | Source engine workflow: macOS ARM64 CI with Xcode and the Android SDK/NDK, and Linux CI for the cases Linux can build; local Mac for focused feedback | The stable and next-minor preview engines `patched` and `patched_beta`, with the patch/module fixture; the ruleset's tests tagged `source_engine` | Build and headless execution of the consumer's patched-engine apps; build-output tests of apps with source-built Android and iOS engines |
| Android packaging | The ruleset's tests in the Linux and macOS host jobs, with SDK/NDK and Java 21; the consumer's tests tagged `android` in the Linux job | Stable and preview prebuilt engines; ARM64 baseline; dedicated ARM64+x86_64 bundle case, each selected by its test's transition | APK/AAB build-output tests and platform library contracts in the ruleset; the consumer's Android smoke bundle |
| Android release symbols | The host jobs, with Android packaging | Optimized native compilation, debug information and stripping, selected by the test's transition | Match retained symbols/Build IDs/DWARF to delivered libraries |
| iOS packaging | macOS CI with Xcode, local Mac for focused feedback: the ruleset's tests in the macOS job; the consumer's tests tagged `ios` in the macOS job | Stable prebuilt x86_64 Simulator and prebuilt unsigned ARM64 device link in the ruleset; source-built ARM64 Simulator in the Source engine workflow | Build-output tests of configured products; the consumer's iOS smoke app; a device link is not a provisioned device IPA |
| iOS release symbols | The macOS job, with iOS packaging | Optimized build, stripping and dSYM, selected by the test's transition | Match executable/dSYM UUIDs and expected native libraries |
| Web applications | The Linux and macOS host jobs, with a Chromium browser the job's setup installs where the runner lacks one | Stable and preview prebuilt web templates, without threads | The ruleset's build-output test that compares the web export with Godot's own; the consumer's web smoke app, which starts in the headless browser and exits with its own code |
| Mobile operating-system behavior | Matching Android device/emulator or iOS device/simulator | One representative environment for the changed operating-system behavior | Focused runtime acceptance only if that behavior or explicit feature acceptance requires it |
| Signing/distribution | Appropriate identity, provisioning and environment | Configuration explicitly selected for the task | Only the signing/distribution operation in scope; never infer Store acceptance |

Each test runs in the host jobs that its tags select. The ruleset's tests, its Android and
iOS build-output tests included, run in both host jobs, which provision the Android SDK; the
Source engine workflow runs those tagged `source_engine`, which build an engine from source.
The ruleset's `.bazelrc` leaves them out of every build and test unless `--config=source-engine`
selects them, so the host jobs do not analyze their source recipes; one named by its label
runs only with that config too. CI runs them only in the
[Source engine](#source-engine-workflow) workflow; locally, `aspect work source-engine`
runs `--config=source-engine-main`, which leaves out the tests also tagged
`source_engine_extended`.
The tests tagged `android` and `ios` are the scenarios' mobile smoke tests and the mobile
release builds.

The matrix separates **host**, **operating system of the application**, **CPU/ABI**,
**engine origin and version**, **build mode/optimization/symbols**, **execution venue** and
**device class**.
They are not independent in every combination: Apple tooling requires macOS; an engine archive
supplies runtimes for specific platform slices; a device link does not require running that device. Add a combination
only when it covers a distinct supported failure mode or explicit acceptance requirement.
Do not multiply every test across all dimensions.

Linux ARM64 and macOS Intel acquisition support does not imply dedicated CI execution for
every editor platform. Windows hosts, Windows and Web applications and .NET/C# have no routine
verification commitment here. There is no default mobile GdUnit/device automation or
visual/manual desktop gameplay gate.

Engine compatibility uses the pinned stable release and pinned next-minor preview, not every
accepted patch/minor version. Engine acquisition/configuration changes require the relevant
archive, generator and build contracts; changing an extension API baseline requires its extension
compatibility checks. Package/symbol cases cover their specific contracts without replaying
all source suites in every release configuration.

## Host jobs and execution

CI runs both host jobs on every run: pull requests, the merge queue and a manual dispatch.
Bazel's caches keep unchanged work cheap. [CI](../../.github/workflows/ci.yml) has one job
per host, each `aspect ci <host>`: `linux` and `macos`. Each starts with the Android SDK's
setup; `linux` then runs the formatter, the checks that are no Bazel tests (Gazelle's
and the conventions tool's), `bazel build --config=lint` over every target and the
[file lint](verification-recipes.md#the-file-lint) over every file. Bazel selects
each host's tests by tag: the configs `ci-linux` and `ci-macos` of
[shared.bazelrc](../../shared.bazelrc) run every test with `--build_tests_only` but those
tagged `source_engine` and those of the other host's mobile operating system. A test that
needs Linux's Android toolchains is tagged `android`, one that needs macOS's iOS toolchains
`ios`; a mobile release build is such a test through its `<name>.build_test`
([examples/releases.bzl](../../examples/releases.bzl)). Tests without either run on both
hosts, compatibility permitting, such as the `<app>_build_test` of each example's desktop
`godot_app` ([examples/AGENTS.md](../../examples/AGENTS.md)).
The root module and the
ruleset each run one `bazel test`, one after the other, the root module's over its add-on
modules too: two servers that fetch the same repository at once can fail to move it into the
shared repository contents cache. On Linux the formatter, the checks that are no Bazel
targets, the lint check of every target and the file lint run first; the add-on generator's self-test
follows in a server of its own: it tests a fresh module with `--config=ci-<host>` and, on
Linux, its `bcr/smoke` module. Last, the macOS job runs every registry test
module in place with the rules of the checkout (`python3 -m tools.ci.release_archive
--in-place`), so that a break shows before a release does;
[develop.axl](../../.aspect/develop.axl) says why only there. The merge queue requires both
jobs, `Linux` and `macOS`, by name. The matrix fails fast: the first job to fail cancels the
other, so it frees its runner and the merge queue removes the entry without waiting for the
slower job; the work it finished stays in Bazel's caches.

The named work lives in [`tools/ci/work.py`](../../tools/ci/work.py): the pieces that are no
single Bazel command, such as the Android SDK's setup, the add-on generator's self-test and
the source-engine cases; the checks are `aspect` tasks of their own. Locally, `aspect ci <host>`
runs a host's job, `aspect work <name>...` single pieces, and `aspect work` lists them. Where
a piece is one Bazel command, the documentation shows that command instead. The
[tiers](../../shared.bazelrc) `fast` (no test tagged `godot_process`, `source_engine`,
`android` or `ios`) and `all` (every test but those tagged `source_engine`) select the
tests of `aspect tests --tier=<tier>`. The pre-push hook runs the checks and the `fast` tier,
as the [verification policy](verification.md#when-to-verify) describes.

Work that needs the Android SDK provisions the pinned SDK first and must not silently succeed
because it was invoked on an unsuitable host. `--build_tests_only` finds new test targets
without building unrelated app targets; Bazel still respects manual tags and platform
compatibility.

Each application of `examples/` and each add-on module's examples build and test in the same
jobs. An example project that builds an application has an `app`,
and its Android and iOS releases are tests tagged `android` and `ios` ([add-on guidance](../../addons/AGENTS.md#tests-and-ci)).
Their iOS tests follow the Apple host policy below.

Python's lint is a Bazel check: `--config=check` adds the aspect `python` of
[tools/lint/check.bzl](../../tools/lint/check.bzl) to a build or test, which runs Ruff and
ty on each Python target the build reaches through `deps` and fails it with their reports.
`bazel build --config=lint` builds only the check's stamps, in the root module with its
add-on modules and in the ruleset, whose targets need the Android NDK to be analysed. An add-on
module's Python target needs the tag `lint-genfiles`, without which rules_lint would skip its
sources from the root module; the check fails on one without it. Files without targets of their own, such as Markdown, GDScript
and shell scripts, are linted by the [file lint](verification-recipes.md#the-file-lint).

### Source engine workflow

The source-engine tests are the most expensive and the least likely to change with a
commit, so CI has no host job for them. The
[Source engine](../../.github/workflows/source-engine.yml) workflow runs all of them on
macOS, `source-engine:full`, and on Linux those Linux can build, `source-engine:linux`: the
Android engines and the applications' Linux engines, without the iOS cases and the
macOS-only patched-engine scenario (`aspect ci source-engine --host=<host>`, macOS by
default). It runs them on each push of a pull request whose
changes reach them or that carries the label `source-engine`, and on manual dispatch for any
branch. A change reaches them when it touches the engine recipes, repositories or their tools, the engines of the examples or of the patched-engine scenario, or a package
with a test tagged `source_engine`
([source_engine_changes.py](../../tools/ci/source_engine_changes.py) holds the list and reads
the tagged packages from their BUILD files). Its job is skipped, not failed, on other pull
requests; it is no required check. Code that every build shares, such as the ruleset's rules
or `shared.bazelrc`, does not reach them, nor does a change of how the workflow runs them,
such as the work `source-engine:full` or `source-engine:linux`: a pull request that may break source-built engines
that way carries the label. Stale
recipe pins need no dispatch to show: `//examples/engines/simulation:pinned_test`, a fast
test that the pre-push hook runs too, fails on a pin whose inputs changed, such as
rules_godot's graph capture.
`aspect work source-engine` runs
locally the cases users depend on most: the runtimes the official artifacts lack, built
from the release's sources for the iOS arm64 Simulator and for Android, and the
consumer's patched engine with its custom module, editor included; the tests tagged
`source_engine_extended`, the stable and beta patched engines and the tests of the
root module tagged `source_engine` join them in `source-engine:full`.

### Apple hosts

The work that needs a macOS runner is the macOS job, with the iOS apps, and the Source engine
workflow's macOS job, with the source-built iOS engines and the patched-engine scenario. Their [CI](../../.github/workflows/ci.yml) jobs
run on the self-hosted runners labeled `macos-ci`: four runners in one macOS VM, which keep
their tools and repository cache on their own disk between jobs and share a Bazel cache
server on the VM's host with the host's own builds. The VM, its runners and its
BuildBuddy executor are set up in the private repository `autoload-dev/macos-ci`; a change
there takes effect through a new image and a replaced VM, done only while no job runs on
it. CI runs the macOS job like the Linux job, on pull requests and in the merge queue.
CI's `Linux` and `macOS` jobs are the merge queue's required checks: a pull request
whose jobs fail there leaves the queue and does not reach main. The ruleset of main, which
requires the merge queue and those checks, is managed in the repository settings. Main receives the merge group's commit unchanged, so its
checks show on the commit and a push to main runs no CI. The merge queue also saves the
caches that later runs read, such as the Linux job's repository cache: Blacksmith's branch
protection for the Actions cache and sticky disks is off, so every branch reads a merge
group's entries.
