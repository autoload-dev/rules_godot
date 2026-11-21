# Verification selection and lanes

Read this page when selecting the lanes a change needs, preparing a change for review, or changing
verification tooling. The [verification policy](verification.md) owns timing, TDD and reuse;
[recipes](verification-recipes.md) describe setup and individual fixtures.

## Supported verification matrix

This is the maintained representative verification set, not a Cartesian product. Product
support and acquisition availability remain in [platform setup](../public/platforms.md),
[versions](../public/versions.md) and [engines](../public/engine.md). A missing matrix cell
creates no automatic obligation to add it. Do not infer that all CPUs or upstream
Godot features are covered from one passing cell.

| Target / workflow | Where it runs | Representative engine/configuration | Required evidence when affected |
|---|---|---|---|
| Linux host behavior and desktop app | Linux CI; local Linux for focused feedback | CI runner CPU, pinned prebuilt engine; default build configuration | Selected host tests, example checks/suites and exported-app assertions |
| macOS host behavior and desktop app | macOS CI; local macOS for focused feedback | Host CPU, pinned prebuilt engine; default build configuration | Selected host tests, example checks/suites and exported-app assertions |
| Source-built engines | Source-engine lane: macOS ARM64 CI with Xcode and the Android SDK/NDK; local Mac for focused feedback | Pinned stable and next-minor preview source builds with patch/module fixture; the ruleset's tests tagged `source_engine` | Build and headless execution of the consumer's patched-engine apps; build-output tests of apps with source-built Android and iOS engines |
| Android packaging | The ruleset's tests in the Linux and macOS host sets, with SDK/NDK and Java 21; the Android lane on Linux CI for the consumer | Stable and preview prebuilt engines; ARM64 baseline; dedicated ARM64+x86_64 bundle case, each selected by its test's transition | APK/AAB build-output tests and platform library contracts in the ruleset; the consumer's Android smoke bundle and the Android API contract cases |
| Android release symbols | The host sets, with Android packaging | Optimized native compilation, debug information and stripping, selected by the test's transition | Match retained symbols/Build IDs/DWARF to delivered libraries |
| iOS packaging | macOS CI with Xcode, local Mac for focused feedback: the ruleset's tests in the macOS host set; the iOS lane for the consumer | Stable prebuilt x86_64 Simulator and prebuilt unsigned ARM64 device link in the ruleset; source-built ARM64 Simulator in the source-engine lane | Build-output tests of configured products; the consumer's iOS smoke app and the iOS API contract cases; a device link is not a provisioned device IPA |
| iOS release symbols | The macOS host set, with iOS packaging | Optimized build, stripping and dSYM, selected by the test's transition | Match executable/dSYM UUIDs and expected native libraries |
| Mobile operating-system behavior | Matching Android device/emulator or iOS device/simulator | One representative environment for the changed operating-system behavior | Focused runtime acceptance only if that behavior or explicit feature acceptance requires it |
| Signing/distribution | Appropriate identity, provisioning and environment | Configuration explicitly selected for the task | Only the signing/distribution operation in scope; never infer Store acceptance |

Each test runs in one lane. The ruleset's tests, its Android and iOS build-output tests
included, run in the host sets (`mise run test:bazel` provisions the Android SDK); the
source-engine lane runs those tagged `source_engine`, which build an engine from source and
are `manual`, so the host sets do not analyze their source recipes.
The Android and iOS lanes run the consumer module's mobile smoke scenarios and the API
contract cases of their lane.

The matrix separates **host**, **operating system of the application**, **CPU/ABI**,
**engine origin and version**, **build mode/optimization/symbols**, **execution venue** and
**device class**.
They are not independent in every combination: Apple tooling requires macOS; an engine archive
supplies runtimes for specific platform slices; a device link does not require running that device. Add a combination
only when it covers a distinct supported failure mode or explicit acceptance requirement.
Do not multiply every test across all dimensions.

Linux ARM64 and macOS Intel acquisition support does not imply dedicated CI execution for
every editor platform. Windows hosts, Windows and Web applications and .NET/C# have no routine
verification commitment here. The capability catalogue's open questions are not implied
test obligations. There is no default mobile GdUnit/device automation or visual/manual
desktop gameplay gate.

Engine compatibility uses the pinned stable release and pinned next-minor preview, not every
accepted patch/minor version. Engine acquisition/configuration changes require the relevant
archive, generator and build contracts; changing an extension API baseline requires its extension
compatibility checks. Package/symbol cases cover their specific contracts without replaying
all source suites in every release configuration.

## Change selection and execution

[`hk.pkl`](../../hk.pkl) owns changed-path selection, [`mise.toml`](../../mise.toml) owns the
commands, and [CI](../../.github/workflows/ci.yml), with the [Apple](../../.github/workflows/apple.yml)
workflow it calls, assigns execution environments. The CI planner
reads hk's JSON plan; it has no separate path policy. It fails on unknown selected steps or
statuses. A selection failure fails the Finalize job rather than appearing as
an empty successful plan. The plan decides as much as it can before any job sets up: it
leaves out a host lane's add-on tasks on a host their `addon.pkl` excludes, so no runner
starts for them, says whether a host job needs the Android SDK restored, and hands the
Apple workflow CI's plan, so that it does not plan again. A plan job installs only hk and
Python. Local hooks and CI use complementary code and documentation
convention tasks, selected from one rule list in mise. Mixed changes run each rule once;
documentation-only changes do not load the code rules.

| Changed scope | Normal selection | Additional scope only with a concrete reason |
|---|---|---|
| Markdown/instructions | Documentation conventions; API-reference edits also select API freshness | Behavior tests only if the described behavior itself is in question |
| Python/Starlark/BUILD/configuration | Applicable source quality; host tests when selected | Lanes whose packaging, build or runtime contract is affected |
| One example | That example's host suite; selected mobile package builds at the delivery boundary | Other examples only for shared dependencies; runtime acceptance for changed operating-system behavior |
| Shared rules, engine/build inputs | Selected host, package, compatibility and cache checks | Extra CPUs or clean builds only for the changed contract |
| One add-on module in `addons/<module>/` | Its own tasks in the lanes its `addon.pkl` names: `host:addon:<module>` (host, limited to its hosts, such as `host:addon:<module>@macos`), `android:addon:<module>` and `ios:addon:<module>` | None: rule changes alone do not select add-on lanes; a break shows in the module's next change |
| The add-on generator, `tools/addons/` | Its self-test in every lane: `<lane>:addon-template` generates a module and runs that lane | The add-on modules' own lanes |
| CI/toolchain configuration | Setup/selector tests, workflow/action validation, cleanup tests and affected non-host lanes | CI runner evidence when local tools cannot reproduce its setup |

Path selection is conservative for shared rules and build inputs: the `core` list can select
several lanes. It is a lane filter, not a second Bazel dependency graph. Within a lane,
Bazel handles declared inputs and result reuse. When adding an example dependency across
examples, update their selection together. Keep configuration-driven broadening at the
review boundary, not in every edit/check invocation.

The default `hk check` and pre-push run source quality, setup validation and the small
selection regression suite where applicable. They do not enable lane profiles. To execute or preview an
additional lane locally, enable its profile explicitly; use the same base for a branch-wide check:

```sh
hk --profile host check --plan --from-ref origin/main
hk --profile host check --from-ref origin/main
hk --profile source-engine check --step source-engine --from-ref origin/main
hk --profile ios check --step ios --from-ref origin/main
hk --profile android check --step android --from-ref origin/main
```

An explicit lane profile needs its lane's prerequisites; it must not silently succeed
because it was invoked on an unsuitable host. `mise run test:full`, `mise run android` and
`mise run ios` remain explicit full-lane commands. They are useful for broad investigations,
not extra mandatory steps after a selected check. `mise run test:examples` runs all examples;
`test:example:sqlite`, `test:example:platform_paths`, `test:example:app_auth`,
`test:example:dart` and `test:example:lichtpost` select one.
Each uses `--build_tests_only` over its example subtree, so new test targets are discovered
automatically without building unrelated app targets. The full examples task discovers all
example subtrees. Bazel still respects manual tags and platform compatibility.

Add-on modules are selected only by their own directory and the settings all modules share
(`addons/*.bazelrc`): `hk.pkl` finds them by their `addon.pkl` and runs the same generic
tasks for each, `addon:host`, `addon:android` and `addon:ios` (`tools/addons/lanes.py`), from
the module's `examples/`. The plan drops a host task from a workflow whose host the module's
`addon.pkl` leaves out. Their iOS task follows the Apple-lane policy below.

Lane suites run in CI at the PR boundary. Run a focused local regression when it provides
useful immediate feedback, without duplicating the whole CI suite.

### Apple lanes on pull requests

The lanes that need a macOS runner are the Apple lanes: the host tests on macOS, the apps
with source-built engines and the iOS apps. They run in the
[Apple](../../.github/workflows/apple.yml) workflow, which CI calls. A pull request's CI run
leaves them out, because macOS runners are expensive. The merge queue runs every selected
lane, the Apple lanes included, on the result of the merge, and CI's `Finalize` is its
required check: a pull request whose Apple lanes fail there leaves the queue and does not
reach main. The ruleset of main, which requires the merge queue and that check, is managed
in the repository settings. Main receives the merge group's commit unchanged, so its checks
show on the commit and a push to main runs no CI. The merge queue also saves the caches that
later runs read, such as the macOS jobs' downloads: Blacksmith's branch protection for the
Actions cache and sticky disks is off, so every branch reads a merge group's entries. Pure
Markdown changes select no Apple lane. A manual dispatch runs all lanes, the Apple lanes
included.
`hk check --plan --from-ref origin/main` shows the selection, as does the Plan job.

The `ci:macos` label runs the Apple workflow on a pull request before the merge queue does:
once, for the commit that is labeled, beside the checks of the CI run. To run it for a later
commit, remove the label and add it again. The run is optional and the label is the user's
decision. An agent opening or updating a pull request whose changes could affect macOS or
iOS behavior asks the user whether to add it and names the selected steps and those
changes; an agent that cannot ask states the same in the pull request body and leaves the
label off.

Each workflow keeps job identities and a final result even when unrelated lanes are skipped.
