# Capabilities

This page inventories what rules_godot supports: the user outcomes, grouped by workflow,
with the limits that apply and the guides that own the details. rules_godot gives developers
fast, trustworthy feedback while they work on Godot applications and reusable add-ons with
Bazel.

Each row has a stable ID. The guides in the Sources section own how to use a capability; the
API documentation is generated from the Starlark definitions, not from this page. Execution
platform (the host that runs the engine and tools), operating system of the application,
CPU or ABI, and device execution are distinct dimensions.

## Overview

1. **Suitable engines.** Obtain or build editor and runtime engines for the project and the
   selected target: [Engines](#engine-selection-and-builds).
2. **Reusable content and consistent configuration.** Reuse resources and settings across
   operations, select what each operation needs, and override settings deliberately,
   including for tests: [Resources and project context](#resources-and-project-context).
3. **Add-on consumption and authoring.** Acquire or create reusable script, resource and
   native content. An add-on may contain an extension, an Android plugin, both or neither,
   built from source or prebuilt, and a script/resource add-on needs no native API:
   [Add-ons](#add-on-consumption-and-development).
4. **Usable processed content.** Import and process content with the project's plugins and
   native dependencies: [Import and processing tools](#import-and-processing-tools).
5. **Editor changes and controlled execution.** Work live in the editor and run content
   with the intended inputs and environment:
   [Editor](#interactive-editor-and-authored-metadata) and [execution](#execution).
6. **Check and test feedback.** GDScript checks and GdUnit suites with the right context:
   [Script checks](#script-checks) and [testing](#testing).
7. **Content and application delivery.** Main and DLC packs and runnable applications for
   Linux, macOS, Android, iOS and the web: [Packs](#resource-packs-and-dlc) and
   [applications](#application-products).
8. **Incremental feedback.** Repeat only the work a change affects:
   [Incremental feedback and caching](#incremental-feedback-and-caching).
9. **Understandable workflows.** Predictable declarations, pinned inputs and actionable
   errors: [Reproducibility and usability](#reproducibility-and-usability).

Reference compositions show how the parts combine: `addons/sentry` consumes the vendor's
prebuilt extension and platform libraries on Android, iOS, Linux and macOS; Platform Paths
is a source-built native add-on that combines a Godot-facing API with operating-system
backends, including Android integration; a script/resource add-on needs only its content,
activation, demo and tests.

## Engine selection and builds

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-eng-01">ENG-01</a> | Acquire and use a pinned prebuilt editor without a globally installed Godot. | Supported distribution, version and editor platform constraints apply. | [ROOT] [VERS] |
| <a id="cap-eng-02">ENG-02</a> | Use prebuilt runtimes and templates for supported export platforms. | Runtime availability and device/simulator CPUs are artifact-specific. | [PLAT] [ENG] |
| <a id="cap-eng-03">ENG-03</a> | Build an editor from pinned source. | Supported source-build, configure and module scope; no universal SCsub support. | [ENG] |
| <a id="cap-eng-04">ENG-04</a> | Build a runtime from source for the required target platform and ABI. | Per-target SDK, toolchain and source-build boundaries apply. | [ENG] |
| <a id="cap-eng-05">ENG-05</a> | Apply patches, select engine modules and options, and include owned custom modules. | Source configure, generator and native dependencies are explicit within the supported scope. | [ENG] |
| <a id="cap-eng-06">ENG-06</a> | Use a supplied compatible editor or runtime and the files it needs beside it. | The actual binary and provider identity matters in addition to a version string. | [API] [ENG] |
| <a id="cap-eng-07">ENG-07</a> | Keep editor, runtime, extension API/ABI, precision and variant choices compatible. | Compatibility checks and explicit choices exist; vendor combinations need their own assessment. | [VERS] [EXT] [ENG] |

## Resources and project context

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-res-01">RES-01</a> | Reuse a scene, script or asset set in several projects without copying its source declaration. | Resource ownership is context-free; each project imports the resources under its own settings. | [RES] [API] |
| <a id="cap-res-02">RES-02</a> | Use generated and external resources at deliberate, stable logical resource paths. | Generated and external inputs and explicit resource paths are supported; ownership stays explicit. | [RES] |
| <a id="cap-res-03">RES-03</a> | Compose shared and application-specific resources without packaging them prematurely. | Resource composition is independent of producing a PCK. | [RES] |
| <a id="cap-res-04">RES-04</a> | Declare dynamic resource dependencies and runtime reference cycles without cyclic build dependencies. | Dynamic and opaque access needs explicit declarations; discovery is bounded. A setting or declared runtime reference that names a directory reaches every member below it. | [RES] [CAT] |
| <a id="cap-res-05">RES-05</a> | Contribute settings and autoloads from reused resources and resolve conflicts deliberately. | Explicit conflicts and overrides exist; settings do not discover dependency files. | [RES] |
| <a id="cap-res-06">RES-06</a> | Reuse authored settings across editor, checks, tests, runs and export, with deliberate operation-specific differences. | Authored settings are reused; test adapters compose their own projects. | [DEV] [ADAPTER] [CAT] |
| <a id="cap-res-07">RES-07</a> | Choose only an operation's required resources while keeping its configuration-required dependencies. | Small test compositions select only the resources they need. | [DEV] [CAT] |
| <a id="cap-res-08">RES-08</a> | Use the same sources under different configurations with correct identities and generated metadata. | Different projects are supported; equal sources alone do not imply interchangeable imports or UIDs. | [RES] [CAT] |
| <a id="cap-res-09">RES-09</a> | Detect conflicting resource paths, authored identities and missing declared dependencies. | Static diagnostics have format and dynamic limits; they do not prove arbitrary code hermetic. | [RES] [CAT] |
| <a id="cap-res-10">RES-10</a> | Keep production content independent of test-only sources and frameworks. | Separate production and test resource compositions are available. | [LAYOUT] [TESTS] [CAT] |

## Add-on consumption and development

An add-on is a reusable composition. Its contents can include resources and GDScript, an
extension, an Android plugin, platform libraries and editor, import and export tools. These
are compatible roles of an add-on's parts, not exclusive categories. Owned versus external
and source-built versus prebuilt are separate dimensions. A GDExtension and an Android
plugin can supply one add-on, and neither is mandatory: an extension can provide the
Godot-facing API while an Android plugin supplies Android context and lifecycle integration,
and a source-built and a vendor-prebuilt add-on can use the same composition pattern.
Consuming and developing an add-on share the same operations; developing adds native
building and focused demo and test projects.

### Add-on composition

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-add-07">ADD-07</a> | Propagate add-on resources, settings, extensions and platform libraries so consumers do not repeat internal dependency lists. | `godot_addon` declares an add-on's runtime and editor parts, autoloads, settings, extensions, platform libraries and Info.plist fragments once, with the add-ons it needs. Every operation whose resources use the add-on, or whose project names it, contains them; applications deliver the native code of the add-ons of every pack they ship (PCK-08). Project-specific plugin activation is intentional (ADD-02). | [RES] [PLAT] |

### GDExtension integration

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-ext-01">EXT-01</a> | Build a compatible C++ Godot-facing extension with godot-cpp. | Binding acquisition and generated C++ library integration exist. | [EXT] [VERS] |
| <a id="cap-ext-02">EXT-02</a> | Build a C-compatible extension without requiring godot-cpp. | Existing C ABI fixtures use the extension integration. | [API] [EXT] |
| <a id="cap-ext-03">EXT-03</a> | Consume compatible prebuilt extension variants without rebuilding vendor source. | Feature-tagged libraries, XCFramework and static provider constraints apply. | [EXT] |
| <a id="cap-ext-04">EXT-04</a> | Provide an extension editor library while building a different extension runtime library. | A shared extension editor library beside an iOS static or other shared extension runtime library is supported. | [EXT] |
| <a id="cap-ext-05">EXT-05</a> | Carry dependent libraries, entry symbols and the registration and link requirements of each operating system. | Includes static iOS retention and Android and Apple platform dependency providers. | [EXT] [PLAT] |
| <a id="cap-ext-06">EXT-06</a> | Keep deliberate library identity and compatible debug/release selection when composed with other extensions. | Unique names and entry symbols and the actual descriptor feature selection matter. | [EXT] [PLAT] |

### Android plugin integration

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-add-06">ADD-06</a> | Use native Android code with Godot Android plugin registration and lifecycle access. | Platform Paths demonstrates plugin and context integration; a feature's individual lifecycle hooks need their own acceptance. | [PATHS] [PLAT] |

### Consume add-ons

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-add-01">ADD-01</a> | Consume externally sourced GDScript and resource add-ons without copying sources into an application. | External acquisition uses normal dependency tools plus resource adaptation. | [RES] [LAYOUT] |
| <a id="cap-add-02">ADD-02</a> | Consume external editor, import and export add-ons with deliberate activation. | Plugin phase and closure constraints from IMP apply. | [RES] |
| <a id="cap-add-03">ADD-03</a> | Consume prebuilt native add-ons with their extension editor and runtime libraries and platform dependencies. | Extension and platform library integrations exist; this is not proof of every vendor distribution. | [EXT] [PLAT] |
| <a id="cap-add-04">ADD-04</a> | Use a pinned Sentry add-on in the editor and in exported applications. | `addons/sentry` packages the vendor's prebuilt release for Android, iOS, Linux and macOS, with the editor on Linux and macOS. | [SENTRY] [EXT] |

### Develop and distribute add-ons

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-add-11">ADD-11</a> | Author reusable add-on contents and any needed Godot-facing API that demo and test projects and applications consume through declared dependencies. | The documented script/resource and extension patterns support owned reusable compositions. ADD-05 owns native-backend authoring, ADD-07 propagation and ADD-09 the published blueprint. No claim covers arbitrary combinations of add-on parts. | [RES] [EXT] [PLAT] [LAYOUT] |
| <a id="cap-add-05">ADD-05</a> | Develop an add-on around a shared Godot API and selectable native backends. | Platform Paths implements a shared native API with operating-system backend selection. It is not a universal backend interface. | [PATHS] [PATHS-BUILD] |
| <a id="cap-add-08">ADD-08</a> | Express separate runnable demo and integration-test projects for an add-on. | Resource, project and test declarations compose these separate contexts. TST-06 owns independent native unit execution; RES-10 owns production/test isolation. | [RES] [DEV] [LAYOUT] [TESTS] |
| <a id="cap-add-09">ADD-09</a> | Use published layout and ownership guidance as an add-on blueprint. | The layout guide describes separate demo and integration contexts, project-owned `main/` and `tests/` groups, reusable add-on ownership and implementation-owned native tests. The SQLite and Platform Paths examples are concrete compositions. DX-05 owns naming. | [LAYOUT] [TESTS] |
| <a id="cap-add-10">ADD-10</a> | Publish and reuse an owned add-on outside its original workspace through declared dependencies. | Composition is external-consumer-capable; no add-on archive format exists. | [ROOT] [LAYOUT] |

## Import and processing tools

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-imp-01">IMP-01</a> | Convert standard supported assets with the selected Godot editor and import settings. | Format support follows the actual engine; no promise of every upstream importer or tool. | [RES] [CAT] |
| <a id="cap-imp-02">IMP-02</a> | Keep connected and grouped resource conversions together with their declared dependencies. | Related files can share a unit; minimal groups are not discovered automatically. | [RES] [CAT] |
| <a id="cap-imp-03">IMP-03</a> | Use project-provided import plugins with their resource dependencies. | Explicit plugin membership and purposes apply; arbitrary plugin IO is a boundary. | [RES] [CAT] |
| <a id="cap-imp-04">IMP-04</a> | Use importers and extension types registered by an extension the editor loads. | Requires appropriate extension editor libraries and a declared closure. | [EXT] [CAT] |
| <a id="cap-imp-06">IMP-06</a> | Control plugin and extension participation independently for processing, editor and execution. | A phase policy decides each participation. | [RES] [EXT] |

## Interactive editor and authored metadata

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-edt-01">EDT-01</a> | Open the selected editor with built resources, plugins and required extension editor libraries. | Editor tool identity and extension editor library availability are explicit dependencies. | [DEV] [EXT] |
| <a id="cap-edt-02">EDT-02</a> | Persist edits to existing authored scenes, scripts, assets and authored project settings for subsequent builds. | Writes to linked authored files and authored project settings are supported. Generated or attribute-owned settings keep their declared owner. | [DEV] |
| <a id="cap-edt-03">EDT-03</a> | Create, rename and delete resources in the editor and use them in subsequent builds. | Fully linked directories support creation, rename and delete in the checkout. New files outside them need explicit placement and BUILD declarations. | [DEV] [LAYOUT] |
| <a id="cap-edt-04">EDT-04</a> | Distinguish editable owned inputs from generated or external read-only inputs. | The editor view uses links for editable inputs and copies for the rest. | [DEV] |
| <a id="cap-edt-05">EDT-05</a> | Generate, inspect and check missing UID and import sidecars beside their source files. | Missing-sidecar writeback exists; it does not overwrite stale authored sidecars. | [DEV] [RES] |
| <a id="cap-edt-06">EDT-06</a> | Keep authored identities and import settings in authored sidecars. | Moving a resource needs explicit reference and import-path maintenance. | [RES] [CAT] |

## Execution

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-run-01">RUN-01</a> | Start the application's normal main scene from declared sources. | Desktop source execution uses the registered editor. | [DEV] |
| <a id="cap-run-02">RUN-02</a> | Start a selected scene or executable script without changing the application's normal entrypoint. | Explicit scene and script entrypoints and arguments are supported. | [DEV] |
| <a id="cap-run-03">RUN-03</a> | Start exported PCK content for smoke tests or local use. | The desktop runner and the packaged application are distinct execution paths. | [DEV] [PLAT] |
| <a id="cap-run-04">RUN-04</a> | Choose windowed or headless execution and supply arguments, environment and runtime data. | Rendering and external-state requirements stay the caller's responsibility. | [DEV] [CAT] |
| <a id="cap-run-05">RUN-05</a> | Run against an isolated writable environment without modifying authored sources. | The normal runner stages declared inputs; interactive editor writes are separate. | [DEV] [CAT] |
| <a id="cap-run-06">RUN-06</a> | Install and launch mobile applications through a common `bazel run` workflow. | `bazel run` installs an Android or iOS application on a device, emulator or Simulator and launches it, starting an emulator or Simulator when needed (`rules_godot/tools/platforms/launch`). | [PLAT] |

## Script checks

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-chk-01">CHK-01</a> | Check selected GDScripts with required classes, autoloads and extension types available. | Every operation validates each unit it contains: its scripts and scenes load under the project with what its `deps` reach, and no project code runs. | [DEV] [CAT] |
| <a id="cap-chk-02">CHK-02</a> | Check owned add-on scripts with a deliberate warning and error policy while excluding unrelated vendor scripts. | The validation follows the project's warning settings; a test project includes the owned add-on's directory in Godot's `directory_rules`, which exempt the other add-ons. | [DEV] |
| <a id="cap-chk-03">CHK-03</a> | Select the units to check and obtain per-script diagnostics. | A build of an operation, or of its `_validation` output group, selects the units; each unit's validation is a cached action whose failure lists Godot's diagnostics per file. | [DEV] |

## Testing

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-tst-01">TST-01</a> | Run GdUnit suites with their production dependencies, helpers and fixtures. | Candidates and dependency availability are separate; the actual framework recognizes suites. | [DEV] [CAT] |
| <a id="cap-tst-02">TST-02</a> | Filter and shard suites and forward framework options. | Filtering and sharding are suite-oriented, not cached per assertion. | [DEV] |
| <a id="cap-tst-03">TST-03</a> | Publish test failures, logs and JUnit and framework reports to CI. | Failure and report policy is part of the execution contract. | [DEV] |
| <a id="cap-tst-04">TST-04</a> | Write script-based smoke and integration tests without requiring GdUnit. | A test can start a script or scene and report failure through the runtime contract. | [DEV] |
| <a id="cap-tst-05">TST-05</a> | Test exported desktop application behavior with declared build artifacts. | Exported-PCK examples and declared executable-artifact testing exist. | [EXAMPLES] [DEV] |
| <a id="cap-tst-06">TST-06</a> | Run independent native implementation unit tests without a Godot project. | Ordinary native test rules compose with the ruleset; project integration is not required. | [PATHS] [TESTS] |
| <a id="cap-tst-08">TST-08</a> | Reuse deterministic test results only when their dependencies remain valid, and account for live native and external state. | Bazel policies distinguish deterministic and live-state execution. FAST-04 owns avoiding unrelated reruns. | [DEV] [TESTS] [CAT] |

## Resource packs and DLC

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-pck-01">PCK-01</a> | Export the main application resources as a standalone PCK. | Pack content and applications are separate products. | [RES] |
| <a id="cap-pck-02">PCK-02</a> | Choose complete declared content or reachable content with explicit dynamic dependencies. | Opaque and dynamic dependencies have bounded support and explicit declaration requirements. | [RES] [CAT] |
| <a id="cap-pck-03">PCK-03</a> | Build a DLC pack that refers to resources supplied by a prerequisite pack. | Required content identity and load-order declarations exist; delivery is separate. | [RES] |
| <a id="cap-pck-04">PCK-04</a> | Exclude optional DLC from the main pack while permitting deliberate optional loads. | Optional content and entrypoints are explicit. | [RES] |
| <a id="cap-pck-05">PCK-05</a> | Deliver additional packs for explicit runtime loading. | The desktop runner copies packs; application code controls mounting and activation. | [DEV] [RES] |
| <a id="cap-pck-06">PCK-06</a> | Diagnose missing or conflicting pack dependencies and shared resource identities. | Identity checks have authored-sidecar and same-project constraints. | [RES] [CAT] |
| <a id="cap-pck-07">PCK-07</a> | Change export variant, feature tags, script representation and export options. | The exposed options do not cover every upstream preset capability. | [RES] [PLAT] |
| <a id="cap-pck-08">PCK-08</a> | Deliver the extension libraries of every included pack without duplicating consumer wiring. | `godot_app` delivers the extension libraries, platform libraries and Info.plist fragments of the add-ons of its start pack and of its `loadable_packs`. The application does not contain the loadable PCKs; PCK-05 owns delivering them. | [PLAT] [RES] |
| <a id="cap-pck-09">PCK-09</a> | Use the same public content and application roles under a selected target platform configuration. | Per-operating-system declarations exist. | [PLAT] [CAT] |

## Application products

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-app-11">APP-11</a> | Produce a runnable application for a selected operating system with its resources, extension libraries and platform libraries. | Baseline products are Linux application trees, macOS bundles, Android APKs and iOS apps, with their runtime and SDK prerequisites. APP-01 to APP-05 record the format and target observations; arbitrary ABIs and other variants are not implied. | [PLAT] [ENG] |
| <a id="cap-app-01">APP-01</a> | Produce a runnable Linux application with resources and extension libraries. | Directory or archive product. | [PLAT] |
| <a id="cap-app-02">APP-02</a> | Produce a macOS application bundle and archive. | Unsigned assembly and optional signing are separate workflows. | [PLAT] |
| <a id="cap-app-03">APP-03</a> | Produce an Android APK with native and Java, resource and manifest dependencies. | SDK, NDK, Java and engine and provider constraints apply. | [PLAT] |
| <a id="cap-app-04">APP-04</a> | Produce an Android App Bundle. | The AAB is unsigned; sign it outside Bazel before upload. | [PLAT] |
| <a id="cap-app-05">APP-05</a> | Produce an iOS device or simulator application with native linkage. | SDK, the runtime of the platform slice, provisioning and rules_apple provider constraints apply. | [PLAT] [ENG] |
| <a id="cap-app-12">APP-12</a> | Produce a web application with Godot's web export's files and page, and run it in a browser of this host. | Web export platforms with and without threads, without extensions, from Godot's prebuilt web templates, and Godot's progressive web app; the page and files match Godot's export of the same project. `bazel run` serves it on 127.0.0.1 and reports its log and exit code; `--headless` needs a Chromium browser of the host. | [PLAT] |
| <a id="cap-app-06">APP-06</a> | Configure application identity, versions, icons, splash, localization, privacy and permissions. | Metadata applies per operating system; not every setting exists on every operating system. | [PLAT] |
| <a id="cap-app-07">APP-07</a> | Select debug and release variants and compatible engine and extension CPUs. | Execution platform, target platform and device or simulator are different axes. | [PLAT] [EXT] |
| <a id="cap-app-08">APP-08</a> | Obtain matching engine, extension and application debug symbols. | Symbol content depends on the supplied or compiled debug information and the build flags. | [PLAT] [ENG] |
| <a id="cap-app-09">APP-09</a> | Sign applicable application products with deliberate locality and credential handling. | macOS signing, Android APK signing and delegated iOS signing exist. | [PLAT] |
| <a id="cap-app-10">APP-10</a> | Package app-only platform libraries, platform resources and transitive platform libraries. | rules_android and rules_apple own linking, resource and manifest/plist merging. | [PLAT] [EXT] |

## Incremental feedback and caching

These outcomes apply to the work and results a change affects.

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-fast-01">FAST-01</a> | Repeat an unchanged build without rerunning compatible processing and native work. | Bazel action caching applies; live execution results are not implied. | [ARCH] [CAT] |
| <a id="cap-fast-02">FAST-02</a> | Change one native source or header and rebuild only the required native objects and dependents. | The native compile and header graph exists within supported engine and extension builds. | [ENG] [ARCH] |
| <a id="cap-fast-03">FAST-03</a> | Change an independent asset and keep unrelated asset conversion and native compilation. | Import unit boundaries support this; independence must be declared soundly. | [RES] [CAT] |
| <a id="cap-fast-04">FAST-04</a> | Keep valid check and test results after unrelated edits. | Bazel's result cache keeps them. | [DEV] [CAT] |
| <a id="cap-fast-05">FAST-05</a> | Share compatible imports between operations. | Some project consumers share imports. FAST-08 owns invalidation and FAST-09 reuse across delivery and build contexts. | [CAT] |
| <a id="cap-fast-06">FAST-06</a> | Prepare a small suite without whole-project preparation, keeping its real context dependencies. | Independent test compositions exist. RES-07 owns resource-selection correctness, RES-06 configuration reuse. | [DEV] [CAT] |
| <a id="cap-fast-07">FAST-07</a> | Change export-only options or signing policy without repeating unaffected imports and compilation. | Phase and output separation exists; plugin effects and actual input equality are conditions. | [RES] [PLAT] [CAT] |
| <a id="cap-fast-08">FAST-08</a> | Invalidate affected work for importer, plugin, configuration, native-type and tool changes. | Invalidation is conservative. | [CAT] |
| <a id="cap-fast-09">FAST-09</a> | Reuse compatible outputs between main and DLC packs, variants and local and CI builds. | Action and native reuse exist. FAST-05 owns shared import work. | [RES] [ARCH] [CAT] |
| <a id="cap-fast-10">FAST-10</a> | Understand why a change causes work to rerun or remain reusable. | Graph and action inspection exist. DX-03 owns resource inclusion, not action invalidation explanations. | [RES] [ARCH] [CAT] |

## Reproducibility and usability

| ID | Outcome | Support and limits | Sources |
| --- | --- | --- | --- |
| <a id="cap-dx-01">DX-01</a> | Pin engines, add-ons and tools for reproducible local and CI setup. | Module and repository pins exist; source configure, SDKs and signing have explicit external boundaries. | [ROOT] [VERS] [ENG] |
| <a id="cap-dx-02">DX-02</a> | Use ordinary Bazel dependency, visibility, configuration and test workflows. | Platform tools and rules compose with the core workflows; no second scheduler exists. | [API] [ARCH] |
| <a id="cap-dx-03">DX-03</a> | Inspect resource ownership and references and why a file is included in a pack. | Graph and selection reports explain resource inclusion with bounded static-format coverage. FAST-10 owns why work reruns. | [RES] [CAT] |
| <a id="cap-dx-04">DX-04</a> | Receive actionable errors for configuration, resource identity, dependency or platform mismatch. | Checks cover the stated cases; unknown combinations are not silently treated as supported. | [RES] [PLAT] [EXT] |
| <a id="cap-dx-05">DX-05</a> | Find equivalent workflows through consistent explicit local names. | The example layout guide defines consistent explicit role names across the example add-ons and Lichtpost, keeping meaningful platform, signing and symbol qualifiers. | [LAYOUT] [CAT] [API] |

## Capability relationships

Each outcome has a leading entry; related entries cover only their distinct scope.

| Concern | Leading entry | Related scope |
|---|---|---|
| Generic add-on authoring | [ADD-11](#cap-add-11) | ADD-05 native backends; ADD-07 dependency propagation; ADD-10 cross-workspace reuse |
| Runnable application | [APP-11](#cap-app-11) | APP-01 to APP-05 target and format observations; APP-06 to APP-10 metadata, variants, symbols, signing and app-only platform libraries |
| Layout and ownership blueprint | [ADD-09](#cap-add-09) | DX-05 naming; ADD-08 separate demo and integration contexts; TST-06 independent native testing; RES-10 production/test isolation |
| Configuration reuse and intentional differences | [RES-06](#cap-res-06) | RES-07 required resource selection; FAST-06 preparation cost for small scopes |
| Compatible import work reused across operations | [FAST-05](#cap-fast-05) | FAST-08 sound invalidation; FAST-09 reuse across pack, variant and local/CI contexts |
| Deterministic versus live-state result validity | [TST-08](#cap-tst-08) | FAST-04 avoiding unrelated check and test reruns |
| Resource ownership and inclusion explanations | [DX-03](#cap-dx-03) | RES-09 identity and dependency conflicts; FAST-10 work rerunning and reuse |
| Additional-pack extension library delivery | [PCK-08](#cap-pck-08) | ADD-07 general add-on propagation |

## Operating-system facets

The cells show where a workflow is supported. Conditional I cells keep the documented SDK,
engine and artifact constraints; no row claims every CPU.

### Engine and tool execution platform

The editor and runtime tools run on Linux and macOS hosts:

| Workflow and capability IDs | Boundary |
|---|---|
| Interactive editor and authored writeback: EDT-01/02 | The editor workflow runs on a desktop host [DEV] |
| Source script and scene run: RUN-01/02/04 | Mobile target selection is not source execution on that device [DEV] |
| GDScript checking: CHK-01/02/03 | Correct extension editor libraries and real context dependencies required [DEV] [EXT] |
| GdUnit source suites: TST-01/02/03 | Suite filtering and cache granularity and rendering requirements apply [DEV] |
| Engine configure and native builds: ENG-03/04/05 | The target SDK must be available on the configuring host; Apple targets need Apple tooling [ENG] |

### Operating system of the application

| Product and capability IDs | Linux | macOS | Android | iOS | Conditions |
|---|---|---|---|---|---|
| Resource PCK export: PCK-01/07 | I | I | I | I | Compatible execution platform and editor; configured platform role is PCK-09 [RES] |
| Runnable application: APP-11; APP-01 to APP-05 | tree, archive | app, archive | APK, AAB | device and simulator app | Required runtime, ABI and platform tools and providers [PLAT] |
| Extension library delivery and linking: EXT-03 to EXT-05 | I | I | I | I | Shared libraries on desktop, ABI delivery on Android, static or framework integration on iOS [EXT] |
| Target runtime from prebuilt artifacts: ENG-02 | I | I | I | I | Platform slices follow the selected archive, not every CPU or simulator variant [PLAT] [ENG] |
| Target runtime built from supported sources: ENG-04 | I | I | I | I | Supported configure and build scope and SDK constraints [ENG] |
| Native symbol products: APP-08 | I | I | I | I | Only supplied or compiled debug data is retained [PLAT] [ENG] |
| Application signing: APP-09 | — | I | APK | I | Apple signing needs an identity and provisioning [PLAT] |
| Android plugin and lifecycle integration: ADD-06 | — | — | I | — | Registration and context plumbing [PATHS] |
| Sentry consumer case: ADD-04 | I | I | I | I | The editor runs on Linux and macOS [SENTRY] |
| Managed install and launch: RUN-06 | — | — | I | I | Through `bazel run` on devices, emulators and Simulators [PLAT] |
| Additional-pack extension library aggregation: PCK-08 | I | I | I | I | `loadable_packs` delivers the native code of further packs' add-ons; their PCKs are delivered separately (PCK-05) [PLAT] |

### Engine, content and validity qualifiers

| Facet | Supported | Capability references |
|---|---|---|
| Prebuilt editor, prebuilt runtime, source-built editor, source-built runtime | The separately documented workflows | ENG-01 to ENG-06 |
| Source patches, modules, generators and native object reuse | Within the source-build translator scope; arbitrary build-system commands and SDK provisioning are not covered [ENG] | ENG-05, FAST-02 |
| Same sources under different effective configurations | Separate configurations | RES-06 to RES-08, FAST-05 |
| Generated versus authored inputs | Generic input consumption and editor boundaries | RES-02, EDT-02 to EDT-06 |
| Ordinary unit conversion versus grouped or custom import | Declared supported units | IMP-02 |
| Main pack, prerequisite pack, optional DLC | Content selection, loading declarations and extension library aggregation | PCK-01 to PCK-08 |
| Debug and release, strip and symbols | Within the selected engine and native support; symbols are not invented for an artifact lacking debug data | APP-07/08 |
| Source run versus exported-content run versus application | Separately supported; not equivalent evidence | RUN-01/03, APP-01 to APP-05, TST-05 |
| Deterministic result versus live-state execution | Bazel policies distinguish them | TST-08 owns validity; FAST-04 unrelated-rerun avoidance |
| Individual suite versus individual test-case result reuse | Suite and target filtering and caching | TST-02, FAST-04 |

## Sources

| Source | Role |
|---|---|
| [ROOT] [API] | Module setup and public surface |
| [RES] [DEV] | Resource, configuration, import and pack behavior; source, check, test and editor behavior |
| [PLAT] [ENG] [EXT] [VERS] | Applications, engine origin, build and version, extension and platform conditions |
| [EXAMPLES] [PATHS] [LAYOUT] [TESTS] | Examples, the Android and native backend pattern, ownership conventions |
| [SENTRY] | The Sentry add-on module |
| [ARCH] [CAT] | Cache and dependency boundaries; source and experiment research |
| [ADAPTER] | Test adapter composition, relevant to RES-06 |
| [PATHS-BUILD] | Shared native API composition and operating-system backend selection in ADD-05 |

## Maintaining capability references

A row names an outcome the ruleset supports, with the limits that apply. Link each row to the
guide that owns the details and keep the limits short; the guide holds the explanation.
Assess a row against the outcome as worded, not against a generic prerequisite: a building
block is not partial delivery of an end-to-end workflow. Update the row when support
changes, and add or delete rows with it. Keep an ID when a row is renamed. Related rows cite
their leading entry instead of repeating its support.

[ROOT]: ../../../README.md
[API]: ../../BUILD.bazel
[RES]: ../public/resources.md
[DEV]: ../public/development.md
[PLAT]: ../public/platforms.md
[ENG]: ../public/engine.md
[EXT]: ../public/gdextension.md
[VERS]: ../public/versions.md
[EXAMPLES]: ../../../examples/README.md
[PATHS]: ../../../addons/platform_paths/README.md
[LAYOUT]: ../public/project-layout.md
[TESTS]: ../../../e2e/rules_godot/AGENTS.md
[ARCH]: architecture.md
[CAT]: godot-pipeline/README.md
[SENTRY]: ../../../addons/sentry/README.md
[ADAPTER]: ../../godot/testing/adapter.bzl
[PATHS-BUILD]: ../../../examples/addons/platform_paths/BUILD.bazel
