# Evidence, Experiments and Independent Review

**Date:** 2026-11-01. Sources below were inspected for the catalogue. F means pinned
upstream source, R the current ruleset at baseline 506d045. Links identify the owning
implementation; named functions and line ranges explain which mechanisms were checked.
Bazel live reference pages are identified separately from version-pinned source/probes.
This is research evidence, not completed feature acceptance.

## Pinned upstream source ledger

### S01

Repository [MODULE.bazel](../../../MODULE.bazel), [.bazelversion](../../../.bazelversion),
[examples/MODULE.bazel](../../../examples/MODULE.bazel), [engine profiles](../../../godot/private/engine/profiles.bzl)
and [strict source patching](../../../godot/private/patches.bzl). Pins:
Godot 4.7.2, Bazel 9.3.0, rules_android 0.8.0, rules_apple 5.3.1.
The Godot tag resolves to ed1daf0bf001b61586d9930840f2f1394092c079 (git ls-remote);
E01 independently reports the same official binary revision. Source-built engine fixture
patches/modules remain configurable inputs. No unrecorded engine patch is assumed.

### S02

[ProjectSettings](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/core/config/project_settings.cpp#L392):
feature overrides 392–434; _load_resource_pack 585–626; _setup/config/binary/override search
652–886; global class cache refresh/get/save 1433–1481; scene group cache load/save/path
1548–1582. Startup configuration is distinct from additional-pack class/UID refresh.
Custom project_settings_override and disable_project_settings_override depend on build support.

### S03

[Main entry](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/main/main.cpp#L4319):
explicit script/check-only dispatch 4319–4388 and SceneTree autoload startup 4496–4567;
editor flag controls override handling in setup. [GDScript reload](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/modules/gdscript/gdscript.cpp#L803)
parses/analyzes/compiles and can run static initialization. Runtime compilation need not be
a persistent output file.

### S04

[EditorFileSystem](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/file_system/editor_file_system.cpp#L260):
first scan/classes/extensions ordering 260–366; filesystem_cache10 and reimport tests
553–747; UID sidecar generation 1320–1404; scene-group updates 2302–2377 (not command-line
mode); group import 2617–2777; _reimport_file options/defaults/generator/outputs 2813–3068;
ignored/nested project membership 3488–3509.

### S05

[ResourceUID](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/core/io/resource_uid.cpp#L113):
generic randomness/path-seeded generation and collision loop 113–155; registry/cache IO
272–390, including merge semantics. Path seed uses project name, lowercased path and source
MD5. Registry state participates; this is not a universal content-only identifier.

### S06

[ResourceFormatImporter](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/core/io/resource_importer.cpp#L43):
remap/feature selection 43–152 and import base-path construction 541–547.
[Editor paths](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/file_system/editor_paths.cpp#L132) cover self-contained markers/roots;
[editor settings](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/settings/editor_settings.cpp#L1342) versioned settings loading.
[Blender importer](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/modules/gltf/editor/editor_scene_importer_blend.cpp#L54)
reads executable settings/executes external tools.
[Texture importer](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/import/resource_importer_texture.cpp#L231)
uses compression settings/variants and editor products (also 1010–1075).
[Scene importer](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/import/3d/resource_importer_scene.cpp#L3396)
handles post-import callback scripts.
[EditorImportPlugin reference](https://docs.godotengine.org/en/4.7/classes/class_editorimportplugin.html)
describes dependency/generated-file/platform-variant/group contracts.
These examples establish classes of extension dependencies, not an audit of every importer.

### S07

[ShaderRD](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/servers/rendering/renderer_rd/shader_rd.cpp#L150):
source/defines/API/hash inputs 150–213 and cache IO 603–699. Renderer cache differs from
resource import cache. This does not establish identical behavior for all renderer backends.

### S08

[Editor export engine](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/export/editor_export_platform.cpp#L1319):
selection/filters/encryption/plugins/customization 1319–1518; import variants/remaps/resource
conversion 1526–1800; project.binary/filtered class/UID/extension metadata 1801–1928;
optional shared-object collection 1930; export_pack 2464; patch export 2474.
[Preset storage](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/export/editor_export.cpp#L270) loads preset/credential files
(270–443); [preset resolution](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/export/editor_export_preset.cpp#L72)
applies project settings/features. [PC exporter](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/export/editor_export_platform_pc.cpp#L94)
uses templates and collects/copies native shared objects for full application export.
[Android exporter](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/platform/android/export/export_plugin.cpp#L2863)
illustrates conditional keystore/environment/application export inputs; today's ruleset
delegates APK/AAB construction to Bazel instead of this full application exporter.

### S09

[GDExtension exporter](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/export/gdextension_export_plugin.h#L46):
descriptors/AAR marker, feature libraries/shared objects, Apple registration/static hooks and
dependent libraries (46–168).
[Library loader](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/core/extension/gdextension_library_loader.cpp#L40):
feature dependency choice 40–71, optional prefix/directory autodetection 99–155,
physical operating-system library loading 176–208, entry/init/version/reload checks 224–385.
[Manager](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/core/extension/gdextension_manager.cpp#L44):
explicit lifecycle 44–151 and extension-list/platform startup 323–410.
Neither extension library bytes in a PCK nor mounting a new extension list alone causes
operating-system load/registration.

### S10

[GDScript export plugin](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/modules/gdscript/register_types.cpp#L83)
emits remapped .gdc tokenizer buffers, optionally ZSTD-compressed (83–120).
Use “token buffer”, not VM/native bytecode.

### S12

[Shader baker export plugin](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/editor/export/shader_baker_export_plugin.cpp#L56):
RendererRD/feature gate, driver/settings/resources, customization cache, emitted shader files
and container compiler (56–270, 373–458).
[Encrypted file access](https://github.com/godotengine/godot/blob/ed1daf0bf001b61586d9930840f2f1394092c079/core/io/file_access_encrypted.cpp#L44) uses random IV without an
explicit IV. Export engine encryption seed handling 377–429 and encryption environment-key
override 1139–1145 are conditional inputs. Source-backed capabilities do not imply exposure
by the current wrapper preset/environment.

### S13

[Pinned GdUnit scanner](https://github.com/godot-gdunit-labs/gdUnit4/blob/0127a55f4543dfc24746f6e5c7ba6f94105d51f2/addons/gdUnit4/src/core/GdUnitTestSuiteScanner.gd#L32):
global class metadata/scanning 32–133 and suite inheritance 234–247.
Candidate resource roots, dependency availability and recognized suites are distinct.

## Repository implementation ledger

### R01

[Project/resources](../../../godot/private/project.bzl): resource paths/deps/import inputs/
import unit metadata 253–329; per-import-unit action declaration 750–822; full project
imports/init/provider 839–1061; pack selection/export/shell input registration 1199–1412.
[Providers](../../../godot/providers.bzl) describe current contracts.
Whole-project memberships here are implementation facts, not desired minimum dependencies.

### R02

[Per-purpose configuration](../../../godot/private/project_config.py#L179), especially 227–250:
drops import autoload/editor-plugin section, main scene, resource-reference-valued settings
and inactive feature overrides, then reconstructs per-purpose plugin lists.
[Godot staging](../../../tools/godot_staging.py): staging/extensions 194–258; child environment
272–294. [Godot project actions](../../../tools/godot_actions.py): scan/conversion/output
capture 31–106; importer/feature probes 109–176. [Godot exports](../../../tools/godot_export.py):
generated presets 231–279; export lock/workspace 332–357; pack staging/rescan/export/report 393–433.
Per-import-unit output retention is .godot/imported changes + own sidecars; initialization captures
changed staged-project files. Custom output paths/alternative project-data layout need review.

### R03

[Editor and sidecar rules](../../../godot/private/editor.bzl),
[editor tool](../../../tools/godot_editor.py) and
[sidecar extraction/write/check](../../../tools/godot_metadata_sync.py).
Editor uses checkout links/copies and inherited environment; generated/source files have
different writeback ownership. Missing-sidecar writer does not overwrite existing files.

### R04

[Run rules and launcher](../../../godot/private/run.bzl) 21–148 and
[runner](../../../tools/godot_run.py) 245–365:
source full project imports/init/runfiles, main-pack-only extension library staging, extra PCK
delivery, explicit env plus test variables, report publishing.
[Test adapter](../../../godot/private/adapter.bzl),
[GdUnit adapter](../../../addons/gdunit/private/gdunit_test.bzl) and
[GdUnit test adapter script](../../../addons/gdunit/private/run.gd) show case selection/framework/report policy.

### R05

[Extension construction](../../../godot/extension/defs.bzl),
[desktop backend](../../../godot/platforms/private/desktop.bzl),
[Android](../../../godot/platforms/private/android.bzl),
[iOS](../../../godot/platforms/private/ios.bzl),
[macOS signing](../../../godot/platforms/private/macos_signing.bzl),
[shell file writers](../../../godot/platforms/private/shell.bzl),
[symbol rules](../../../godot/private/symbols.bzl),
[native symbol tool](../../../tools/platforms/native_symbols.py) and
[signing tool](../../../tools/platforms/sign_macos.py).
Editor and runtime extension providers, transitive native code/resources/manifests/plists,
ABI/Swift/framework aspects, strip/dSYM/UUID preservation and signing locality are distinct
edges.
macOS certificate signing has no-cache/no-sandbox/no-remote; adhoc still no-remote.

### R06

[Graph declaration](../../../godot/private/graph.bzl),
[graph inspection rule](../../../godot/private/analysis.bzl),
[scanner/selector](../../../tools/resource_graph.py):
analyzed/opaque/leaf classes 1–75, runtime/import input validation and unknown dynamic refs,
selection 1091 onward. Static scanning does not dynamically declare new Bazel inputs.
[Pack format inspection](../../../tools/pck.py) validates the current PCK structure.

### R07

[Engine components](../../../godot/engine/private/components.bzl),
[engine source repositories](../../../godot/engine/repositories.bzl),
[engine generators](../../../godot/engine/private/generator.bzl) and
[patch handling](../../../godot/private/patches.bzl).
Archive/checksum, module trees, ordered patches, host configure tools/imported env,
generator source/stamp and native compilation/link inputs feed actual executable identity.

### R08

[Shell assets](../../../godot/private/shell_assets.bzl),
[probe export script](../../../tools/action/shell.gd),
[action plugin](../../../tools/action/plugin.gd),
[engine profiles](../../../godot/private/engine/profiles.bzl) and
[export shell mode](../../../tools/godot_export.py#L120).
Probe reports actual defaults/settings/feature tags; engine profiles supply remaining versioned
tables.
The shell-assets action does not parse the already generated main PCK as its input.

## Bazel mechanism sources

### B01

[Bazel 9.3 aspects](https://bazel.build/versions/9.3.0/extending/aspects):
actions/providers attach to configured dependency graph applications.
A resource-reference graph and a configured aspect/action graph are different mechanisms.

### B02

[Bazel configurations](https://bazel.build/extending/config) and
[action APIs](https://bazel.build/rules/lib/builtins/actions.html):
label settings/transitions, configuration growth, declared actions/tree-directory expansion.
These live references describe Bazel mechanisms, not pinned Godot facts or proof that an
automatic Godot import-sharing design is correct.

### B03

[Bazel test environment](https://bazel.build/reference/test-encyclopedia) and
[remote caching](https://bazel.build/remote/caching):
declared dependencies/runfiles/temp/report environment and cache validity.
Artifact equality does not account for untracked device/network/keychain/live
operating-system state.

## Bounded experiments

### E01

**New cold-import observation, 2026-11-01.** Two empty, separately isolated projects used
the existing official executable reporting 4.7.2.stable.official.ed1daf0bf. Each ran
`--headless --path <absolute-probe-project> --editor --import`; the placeholder is replaced
with that fresh project directory. Both returned 0. Environment used the current wrapper's
child_environment, which isolates HOME/TMPDIR/XDG roots and fixes locale/TZ.

Each project had identical probe.gd (`class_name CatalogProbe`, then `extends RefCounted`)
and an identical 8×8 red-rectangle SVG. Configuration was config_version=5, rendering method
gl_compatibility and application/config/name of CatalogAlpha or CatalogBeta. No authored
.uid/.import, addons or preset were supplied. The varying physical root is not claimed
independently controlled; S05 establishes which logical inputs participate in UID generation.

Observed generated files:

- .godot/.gdignore
- .godot/editor/filesystem_cache10 and project_metadata.cfg
- .godot/global_script_class_cache.cfg and uid_cache.bin
- .godot/imported/icon.svg-218a8f2b3041327d8a5756f3a245f83b.ctex and its .md5
- icon.svg.import and probe.gd.uid

Observed script UIDs were uid://c6xegu6cd1byq (Alpha) and uid://cbklui350ya1c (Beta).
Class cache and converted .ctex/.md5 bytes matched; project config, source sidecars,
filesystem cache and UID cache differed. Source files were identical. This is a narrow
observation, not proof all project-name changes leave converted bytes unchanged or all
UIDs are deterministic. No group/extension library/shader/export/mobile behavior was exercised.

Local receipts: /private/tmp/godot-pipeline-probes/result.json and each case's import.log.
The recipe/results are recorded here so conclusions do not depend on temporary files surviving.

### E02

**Historical probe notes, not reproducible evidence.** These earlier synthetic probes were
reread rather than rerun. Their complete setup and commands are not preserved here;
the temporary receipts below are provenance only. No catalogue conclusion relies on them
as independent experimental proof. The mechanism discussion is explicitly an inference
from [B01](#b01) and [B02](#b02).

At
/private/tmp/godot-context-aspect-probe, two operations sharing config_a resources and one
using config_b produced three configured aspect applications. This used generated write
actions; no real Godot conversions/contribution/native-config behavior was tested.

The separate explicit binding probe used actual tiny shell actions:
initial 2 imports + 2 consumers; unrelated extra edit/shared-only consumer 0 processing actions;
extra edit/both consumers 1 extra import + second consumer; shared edit 1 shared import +
both consumers; unchanged 0. Logs/JSON are binding-{initial,extra-one,extra-both,shared-both,noop}.
This reported selected-artifact reuse in the synthetic case, not necessity of a public
binding API or verified behavior for real Godot imports.

The earlier application alias probe in /private/tmp/godot-configured-app-probe passed
provider/aspect forwarding and failed on selecting its deliberate SDK-poison branch.
It does not prove real Android/Apple SDK isolation.

## Open questions and coverage limits

| ID | Boundary / unresolved question | Consequence |
|---|---|---|
| Q01 | Arbitrary importer/exporter/editor/native/static/test code can read files, directories, env, external tools, time/network/device state and write extra outputs | Define declared closure/output contracts, isolate, remain conservative or document unsupported/noncacheable behavior; no universal closed plugin list |
| Q02 | Current broad removal of resource-valued settings from the import configuration is policy, not proof custom importer independence | Reassess contract before constructing an automatic import-context key |
| Q03 | Group imports, custom auxiliary outputs and alternative project-data locations | Preserve real group import units; current import unit capture hardcodes .godot/imported and own sidecars, so upstream alternatives are not automatically retained |
| Q04 | Automatic sharing needs global/sibling contribution resolution and bounded native configuration propagation | Bazel aspect/transition mechanisms alone are insufficient; no public godot_imports API selected here |
| Q05 | Cold/warm UID registry, global class/group/extension state and resource cache composition | Do not share a full initialization tree across arbitrary selected subsets; test real collision/pack order cases for implementation |
| Q06 | PCK encryption, shader baking, patch export and custom presets are conditional upstream facilities | Source catalogued; not all are exposed by current generated preset/isolated env; no new support claim |
| Q07 | Actual shader bake effect under headless configuration, encrypted output and external importer execution | Not experimentally exercised here; specific capability claims require focused checks |
| Q08 | Android/iOS signing, native linkage/runtime and SDK isolation | Source reviewed, no new application/mobile acceptance run; delegate SDK internals to pinned rules_android/rules_apple rather than claim exhaustive compiler audit |
| Q09 | Other renderers, C#/.NET pipeline, unsupported operating systems and every builtin importer implementation | Outside this catalogue's operation/workflow baseline; represented by engine/module/tool/extension classes, not audited individually |
| Q10 | Current full-project source/export inputs, extra-pack extension library lookup and plugin capture restrictions | Known implementation boundaries; this catalogue neither fixes them nor treats them as mandatory design choices |

These are documented limits of this research or current implementation, not silent missing
input classes and not completed implementation tasks. Decision-critical questions keep the
import API/model design open.

## Independent review

Completed 2026-11-01 by catalog_independent_review, separate from the research authors
catalog_import_editor, catalog_export_native and catalog_bazel_mapping. The parent consolidated
the catalogue and ran E01; the reviewer independently inspected pinned engine/current wrapper
source and E01 receipt/hash comparisons rather than accepting author summaries alone.

Scope: all five catalogue files; 50 artifact classes, 21 operations, 25 explicit dependency
edges and their evidence/limits. Relative file and Markdown-heading links were also checked.
No CRITICAL/HIGH/MEDIUM findings remain, and the final narrow refinements were resolved:

- Scene-group cache generation is conditional and excluded from command-line mode.
- Extension library prefix autodetection has a directory-membership dependency.
- Custom project-settings override paths/build policy are explicit.
- Alternative project-data locations are an upstream capability; current import unit retention
  hardcodes .godot/imported and does not automatically support every such layout.
- PCK export consumes project.files/imports and rescans; no direct initialized-tree input
  is asserted.

Verdict: coverage is complete at the documented artifact-class/operation boundary for the
selected workflows. It is not a proof of arbitrary plugin closure, every native compiler/
importer implementation or untested conditional capability. Q01–Q10 remain visible boundaries
and design questions, not hidden assertions of dependency absence. Automatic import sharing
and a public godot_imports API remain undecided. Full feature/application/mobile acceptance was
not performed by this research review.
