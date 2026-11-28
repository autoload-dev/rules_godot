# Application platforms

Export common content once in its content configuration, then package it with a matching
runtime through `godot_app`. Select the export platform with `--platforms`. Packaging does not run a nested editor, Gradle or Xcode build. The
editor toolchain follows the execution platform; runtimes and extension runtime libraries
follow the target platform.

| Operating system | Packaging integration | Output |
| --- | --- | --- |
| Linux | Declared runtime executable and PCK | Runnable directory and deterministic `.tar.gz` |
| macOS | Runtime executable, PCK and bundle metadata | Selected unsigned or signed `.app` and deterministic `.zip` |
| Android | `rules_android`, the Android shell library and native libraries | Signed APK or unsigned App Bundle |
| iOS | `rules_apple`, the static engine library, extension libraries and platform libraries | Simulator or device IPA |

Each application also provides its [debug symbols](#debug-symbols).

The Starlark snippets below are templates for your own project: supply the
resource, engine and dependency targets they reference. Commands with
`//path/to:target` are placeholders; replace the package and target. Commands
for the repository's examples name their working directory explicitly.

See the [Godot configuration guide](configuration.md) for Project Settings, Preset Settings,
Export Options, their precedence and the values that belong to Bazel instead.

## Export platforms

`godot_export_platform` combines an operating system, a CPU set and the iOS
environment. For example, in a consumer BUILD file:

```starlark
load("@autoload_rules_godot//godot/platforms:defs.bzl", "godot_export_platform")

godot_export_platform(
    name = "android_local",
    operating_system = "android",
    cpus = ["@platforms//cpu:aarch64"],
)

godot_export_platform(
    name = "android_store",
    operating_system = "android",
    cpus = [
        "@platforms//cpu:armv7",
        "@platforms//cpu:aarch64",
        "@platforms//cpu:x86_32",
        "@platforms//cpu:x86_64",
    ],
)

godot_export_platform(
    name = "simulator",
    operating_system = "ios",
    environment = "simulator",
    cpus = ["@platforms//cpu:aarch64"],
)
```

Select one with `--platforms=//path/to:android_local`. CPUs are `@platforms//cpu`
constraint values: `armv7`, `aarch64`, `x86_32`, `x86_64`, `riscv64` and `wasm32`, which
rules_godot maps to Godot's CPU feature tags and to Android ABIs. Desktops take one CPU, an
iOS device `aarch64`, the iOS Simulator `aarch64` or `x86_64`, and the [web](#web) `wasm32`. A CPU builds when a runtime component
is registered for it; otherwise analysis fails, naming the target platform that no runtime
component matches. An engine registers every valid CPU: the official export templates'
CPUs come prebuilt, and a catalogued engine builds the others from source.
Do not request extra platform slices for a known local device. Engine and library selectors
must supply every requested platform slice. Device and Simulator are separate iOS environments.
`bazel test` with a desktop export platform runs its tests on an execution platform of the
same operating system and CPU.

Without `--platforms`, an application builds for the host: a Linux or macOS host
builds the desktop application for its own CPU. `target_compatible_with` restricts
supported consumer contexts using Bazel constraints. Wildcard builds such as
`bazel build //...` skip applications that do not support the selected target platform;
requesting such an application by its label fails.

The export platform owns the operating system, CPU and iOS environment; a Bazel
`platform` passed through `parents` cannot change them. Put custom constraints, flags and
execution properties that every platform slice needs on that parent, or on the export platform's
own `constraint_values` and `exec_properties`.

A child platform of an export platform keeps its operating system, CPUs and platform slices:

```starlark
platform(
    name = "android_ci",
    parents = ["@autoload_rules_godot//godot/platforms:android_arm64"],
    constraint_values = [":ci"],
)
```

The child platform's own constraints, flags and execution properties apply only to the
application's packaging and, on desktop, its runtime. Content export, the pack's
extension runtime libraries and the mobile builds of each platform slice use the export
platform or its platform slices; a desktop export platform is its own single platform slice.
A child platform that sets another operating system, CPU or iOS environment fails analysis.

C++ optimization (`--compilation_mode`), symbol policy, Godot variant and Android format
stay independent; `--compilation_mode` also chooses the [pack form](resources.md#pack-forms).

## Application metadata

Godot's exporter decides each application's manifest, Info.plist, icons, splash screen,
privacy manifest and localized strings from the pack's `export_options` and the project's
settings:

```starlark
godot_pack(
    name = "android_pack",
    project = ":game",
    deps = [":main"],
    export_options = {
        "package/name": '"My Game"',
        "permissions/vibrate": "true",
        "screen/immersive_mode": "false",
    },
)
```

The [Godot configuration guide](configuration.md#shell-files-and-shell-assets) lists the
settings and options that shape the shell files and shell assets, and those that Bazel
owns instead.

## Variant

`--@autoload_rules_godot//godot:variant=debug` builds the debug variant: packs export as
Godot's debug export does, with its `debug` and `template_debug` feature tags,
extensions deliver their debug-tagged libraries, and each platform slice packages the
registered debug runtime. The prebuilt Android shell libraries are release builds, so an
Android debug app takes a debug runtime that its engine builds from source, or a
[pinned debug shell library](engine.md#use-other-sources-or-binaries).

As Godot's pack loader, an engine loads packs of its own major.minor version
and older ones. Bazel validation actions check that an Android engine AAR ships its declared engine
library for each requested CPU, that the static libraries of an iOS runtime contain objects of the requested
CPU and iOS environment, and that authored export options match the selected editor's registration. They run
in parallel with the build and fail it; `--run_validations=false` skips them.
rules_godot checks its own inputs and outputs, not how rules_android or rules_apple
assemble packages.

## Run an application

`bazel run` on a `godot_app` builds the application for the selected export platform,
starts it and streams its log on the terminal until it exits. Ctrl-C ends the
application, and the command exits with the application's exit code.

```sh
bazel run //path/to:app
bazel run //path/to:app -- --headless -- --verbose
```

Arguments after the first `--` are options of the launcher. Arguments after a second
`--` are Godot's command line, as the `godot` command takes it: engine options such as
`--verbose`, then, after a further `--`, the arguments `OS.get_cmdline_user_args()`
returns. The launcher options change nothing in the build, so changing them rebuilds
nothing.

| Option | Effect |
| --- | --- |
| `--headless` | No window: Godot's `--headless` |
| `--fresh` | Start without the application's earlier data: an empty home directory, which holds `user://` |
| `--detach` | Return once the application started, without its log |
| `--env NAME=VALUE` | Environment variable of the application; repeat for more |

A Linux or macOS application runs on this host. A macOS application runs as built,
so select ad hoc signing as [Linux and macOS](#linux-and-macos) shows.

### The editor variant

With the editor variant, `--@autoload_rules_godot//godot:variant=editor`, `bazel run` runs an
application's project from its sources with Godot's editor binary, without exporting it:
no pack, runtime or shell is built, so a change to a script or scene runs without an export.

```sh
bazel run --@autoload_rules_godot//godot:variant=editor //path/to:app -- --headless -- --verbose
```

A `.bazelrc` line such as `build:editor --@autoload_rules_godot//godot:variant=editor` shortens it to
`--config=editor`.

The variant chooses the binary and the target platform where it runs: this host by
default, or a Linux or macOS export platform, on which a test can run it on a remote
executor. On Android and iOS an application of the editor variant is incompatible: a
wildcard build skips it, and an explicit request fails.

The project, its resources, add-ons, settings and the custom features of the build come
from the application's start pack, as an export of it gets them; its extensions build for
the target platform. The run happens in a writable copy of the project, as `godot_run`
runs one. `--headless`, `--detach`, `--env` and Godot's arguments apply; Godot options that
would replace the project, such as `--path` or `--main-pack`, fail.

The start pack must be a `godot_pack`, whose project the run uses; the application's
`loadable_packs` are not part of the run. The game has the feature tags `editor`,
`editor_runtime` and `debug` with those of the target platform and of the build, not
`template` or `template_debug`. `@autoload_rules_godot//godot:editor` lets a `select()` tell the
editor variant apart.

### Devices, emulators and Simulators

An Android or iOS application installs on a device, emulator or Simulator before it
starts. The launcher takes the one `--device` names, else the only one running, else it
starts one: an Android AVD or the newest iOS Simulator that suits the application, which
it creates when none exists. Emulators and Simulators keep running afterwards. Several
running devices need a choice; `--list-devices` lists them.

```sh
bazel run --config=android //path/to:app -- --device=medium_phone -- --verbose
bazel run --platforms=@autoload_rules_godot//godot/platforms:ios_sim_arm64 //path/to:app -- --device="iPhone 17 Pro"
bazel run --config=android //path/to:app -- --list-devices
```

| Option | Effect |
| --- | --- |
| `--device=<id or name>` | Android serial or AVD name, iOS UDID or name; without it, `ANDROID_SERIAL` or `BAZEL_APPLE_DEVICE_UDID` |
| `--list-devices` | List the running devices and those the launcher can start, then exit |
| `--no-start-device` | Fail instead of starting an emulator or Simulator |
| `--headless` | Start an emulator without its window, show no Simulator window |
| `--fresh` | Uninstall the application and its data before installing |
| `--on-conflict=uninstall` or `fail` | When the installed copy blocks the install: uninstall it with its data (default), or fail |
| `--install-only`, `--no-install` | Install without launching, or launch what is installed |
| `--emulator-arg=<argument>` | Android: argument of the emulator that starts an AVD, such as `-no-snapshot` |
| `--grant-permissions` | Android: grant the manifest's runtime permissions on install |
| `--logcat=<filterspecs>` or `all` | Android: logcat filters for the application's process, or the device's whole log |
| `--simulator-type=<name>`, `--os=<version>` | iOS: device type and iOS version of a Simulator to start or create |

An installed copy blocks the install when it is signed with another key, and on Android
also when it has a newer version code that a downgrade cannot replace or when the device
lacks the storage for both. A debuggable Android application downgrades and keeps its
data. Other failures name their cause, such as a CPU the APK has no libraries for.

On Android the launcher uses the host's SDK tools, from `ANDROID_SDK_ROOT`,
`ANDROID_HOME` or `PATH`. It starts the AVD `medium_phone`, or the only AVD whose CPU
the APK has libraries for. Without one, it creates `medium_phone` with `avdmanager` from
an installed system image of the host's CPU, preferring the application's target API
level; it downloads nothing and accepts no license, and without a system image it names
the `sdkmanager` command that installs one. An App Bundle installs as the universal APK
bundletool derives from it, signed with the debug key, which needs `java`. The log is the
logcat of the application's process. `bazel mobile-install` does not apply: the Android
target of a `godot_app` is not an `android_binary`.

Godot's command line reaches an Android application built without `-c opt` only: those
builds are debuggable and carry a small Godot plugin that hands the launcher's arguments
to the engine. The launcher writes them into the application's private files with
`run-as`, which other applications cannot write, and the plugin takes them for one
launch. Godot appends them to the command line the export options write to
`assets/_cl_`, such as `command_line/extra_args`, so an option given in both takes the
launcher's value. Release builds leave the plugin out, and the launcher rejects Godot
arguments for them.

An iOS application built for the Simulator runs on a Simulator, and one built for a
device on a device that is paired with this Mac, unlocked, in Developer Mode and named by
the provisioning profile. The log is the application's output with its `os_log`
messages, which hold Godot's log. rules_apple's `--ios_simulator_device` and
`--ios_simulator_version` do not choose the Simulator, `--device` does, and its `IOS_`
environment variables do not reach the application, `--env` does.

## Linux and macOS

The [registered engines](engine.md#register-an-engine) supply the runtime of each
operating system; the large export-templates archive is fetched only when an app needs it,
and only the templates of the app's operating system are extracted from it.
Declare one pack and app:

```starlark
load("@autoload_rules_godot//godot:app.bzl", "godot_app")
load("@autoload_rules_godot//godot:defs.bzl", "godot_pack")

godot_pack(name = "pack", project = ":game", deps = [":main"])

godot_app(
    name = "app",
    pack = ":pack",
    application_id = "com.example.mygame",
    target_compatible_with = select({
        "@platforms//os:macos": [],
        "@platforms//os:linux": [],
        "//conditions:default": ["@platforms//:incompatible"],
    }),
)
```

The app bundles or links the extension libraries of the pack; the PCK holds only
their descriptors, see [export membership](resources.md#export-membership).

Build a desktop application for one platform:

```sh
bazel build //path/to:app --platforms=@autoload_rules_godot//godot/platforms:linux_x86_64
bazel build //path/to:app --platforms=@autoload_rules_godot//godot/platforms:macos_arm64
```

Desktop export platforms build one CPU; a universal imported macOS runtime is thinned to
the requested CPU. `target_compatible_with` expresses the consumer's limits; it does not
select a different operating system or hide missing SDK setup.

`macos_minimum_os_version` is the macOS application's minimum system version, by default
11.0, Godot's floor: the bundle's `LSMinimumSystemVersion` names it, and the native code
the pack compiles for macOS, such as extension libraries, takes it as its deployment
target. A source-built engine compiles for Godot's floor regardless, and the build fails
when the application's minimum falls below that floor or below what one of its
[extensions requires](gdextension.md#minimum-operating-system-versions).

[Run](#run-an-application) the Linux application with `bazel run //path/to:app` on a matching host. For macOS,
sign the assembled bundle before launching it: repackaging a signed runtime can
invalidate its signature. Default desktop outputs include the bundle and archive;
`--output_groups=bundle` or `--output_groups=archive` selects one.

Extensions and their library dependencies come from the add-ons of the pack: those its
resources use and those its project names.
Libraries need correct install names and dependency declarations. Icons, privacy data,
localization and metadata use the [Godot configuration guide](configuration.md), including
macOS `application/liquid_glass_icon` for Icon Composer assets with Xcode 26.

The app is unsigned by default. Select ad hoc signing for local execution:

```sh
bazel build //path/to:app --@autoload_rules_godot//godot:macos_signing=adhoc
bazel run //path/to:app --@autoload_rules_godot//godot:macos_signing=adhoc
bazel build //path/to:app --@autoload_rules_godot//godot:macos_signing=unsigned
```

For certificate signing, set the app's `macos_signing_identity` to a suitable local
keychain identity and optionally set `macos_entitlements` to a declared plist file
(including a generated file). Invoke the same app with
`--@autoload_rules_godot//godot:macos_signing=certificate`. An empty identity or `-` fails in
certificate mode. Ad hoc signing uses `-` and ignores a configured certificate identity.
Entitlements apply to the app signature; nested libraries are signed without them.

Signing copies the unsigned bundle, signs nested native code, verifies the result and
archives that copy. The selected `GodotDesktopAppInfo` bundle/archive, output groups,
launcher and runfiles all refer to that signed bundle. Basenames remain app-derived.
The unsigned bundle is independently obtainable by selecting `unsigned`; no signing
inputs enter its actions. Builds for other operating systems do not analyze macOS signing
inputs.

Certificate signing requires a macOS host and accessible local keychain. It runs
without action caching or sandboxing; signing failures never return unsigned output.
Notarization and store submission remain separate release steps. The app's
`debug_symbols` group requests symbols from the selected result and therefore still
analyzes its signer. Use the common `//path/to:app.debug_symbols` companion target to bypass
signer analysis, including in certificate mode without an identity.

## Android

Use the [repository's root module](../../../MODULE.bazel), which builds the examples, as a
setup template: it declares the SDK/NDK toolchains, the registered engines and the
Maven lock file. Its
[SQLite project BUILD file](../../../examples/addons/sqlite/BUILD.bazel)
declares one app for every operating system, packaged as APK or
[App Bundle](#app-bundles-for-store-upload);
[`.bazelrc`](../../../.bazelrc) supplies build configurations.
For your own module, adapt `local_path_override` to your rules_godot source
and use your project's targets in the BUILD declarations.

The template pins SDK platform **35**, build tools **35.0.0**, NDK
**29.0.14206865**, Java **21** and native API **24** for Godot 4.7.2.
In this checkout, with [Bazelisk](https://github.com/bazelbuild/bazelisk) and the
[Aspect CLI](https://docs.aspect.build/cli) installed, `aspect work android:setup` installs
those components, and `aspect exec` supplies the Android environment (Java 21 comes from
Bazel unless `JAVA_HOME` is set). From the repository root:

```sh
aspect work android:setup
aspect exec -- bazel build //examples/addons/sqlite:app --config=android
```

The setup reuses an existing SDK and installs only missing pinned components.
The SDK stays outside the checkout and is shared by worktrees.

For a separate consuming module, provide equivalent toolchain setup or select
your installed SDK, NDK and JDK explicitly:

```sh
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
export JAVA_HOME=/path/to/jdk-21
```

Replace the `/path/to/...` placeholders with your SDK and JDK installations.
Use an NDK revision matching your module's pin even for a prebuilt engine:
`rules_android` resolves a C++ toolchain while assembling JNI libraries.
Choose its native API level for the engine and deployment targets you support.

Declare the application beside an explicit `godot_pack(project = ":game", deps = [":main"])`:

```starlark
load("@autoload_rules_godot//godot:app.bzl", "godot_app")

godot_app(
    name = "app",
    pack = ":pack",
    application_id = "com.example.mygame",
    target_compatible_with = ["@platforms//os:android"],
)
```

Its pack follows the [start-pack rule for extension libraries](resources.md#export-membership).
Select `--platforms=@autoload_rules_godot//godot/platforms:android_arm64` with the SDK and NDK
toolchains configured as in the examples, whose NDK toolchains come from
[`godot_android_toolchains`](#remote-execution-of-android-builds).

rules_godot adds the Android shell
library's Kotlin/AndroidX dependencies to the shared `maven` repository, which `rules_jvm_external`
pins in `maven_install.json`. Refresh that lock explicitly with
`RULES_JVM_EXTERNAL_REPIN=1 bazel run @maven//:pin` when changing dependencies.

Also pin `rules_android`'s own tool repository, `rules_android_maven`, as the template
does with `rules_android_maven_install.json`. `rules_android` declares it without a lock
file. Unpinned, every new Bazel output base downloads all of its artifacts at once,
including large test-only ones, which can exceed Maven Central's rate limit. Pinned, Bazel
fetches only the tools a build uses and keeps them in its shared repository cache. Refresh
this lock with `REPIN=1 bazel run @rules_android_maven//:pin` after upgrading
`rules_android`.

The application runs Godot's template activity `com.godot.game.GodotApp` of the pack's
Godot minor, unchanged, and launchers start it through the `com.godot.game.GodotAppLauncher`
alias, as in Godot's Gradle export. Immersive mode, edge to edge, the safe area and Picture in
Picture therefore behave as in that export, and Android libraries can refer to the activity by
Godot's name. The activity mounts `res://main.pck`; Godot options control its command line,
manifest, themes, icons and splash. The rules provision the template activity's AndroidX
dependencies through the **shared Maven installation**; applications do not repeat their
labels. Consumers
contribute their Maven artifacts and allowlist to the module extension, retaining root
version/lock precedence, as in [MODULE.bazel](../../../MODULE.bazel). Do not create
an unrelated private Maven graph. Refresh the shared lock when dependencies change.

Set the SDK versions, signing and platform libraries with the
[Bazel-owned inputs](configuration.md#values-that-belong-to-bazel) and everything else with
[Godot options](configuration.md#export-options-support).

### Remote execution of Android builds

`godot_android_toolchains` lets an Android build run its actions on remote Linux executors
such as BuildBuddy's; rules_android and rules_android_ndk alone would give those executors this
host's SDK and NDK tools. It is experimental: its tag and generated repository may change.

```starlark
# MODULE.bazel
godot_android_toolchains = use_extension(
    "@autoload_rules_godot//godot:extensions.bzl",
    "godot_android_toolchains",
)
godot_android_toolchains.configure(ndk_api_level = 24)
use_repo(godot_android_toolchains, "android_toolchains")
```

```
# .bazelrc
build:android --extra_toolchains=@android_toolchains//:all
```

Local actions keep using the SDK of `ANDROID_HOME` and the NDK of `ANDROID_NDK_HOME`; Linux
executors receive the Linux SDK and NDK that the
[API documentation](https://registry.bazel.build/modules/autoload_rules_godot) of `godot_android_toolchains` pins. Choose an
`--@androidsdk//:api_level` it pins: for another level, an action on a Linux executor fails
analysis.

A test runs on an execution platform that matches its target platform: on this host, or on
a Linux executor with `--config=buildbuddy-linux`. A test that inspects an application with
`aapt` or `aapt2` takes `@android_toolchains//:aapt` or `:aapt2`, which give the tool of the
platform it runs on; `@androidsdk//:aapt_binary` is always this host's.

```starlark
py_test(
    name = "manifest_test",
    srcs = ["manifest_test.py"],
    args = ["--aapt=$(rootpath @android_toolchains//:aapt)", "$(rootpath :app)"],
    data = [":app", "@android_toolchains//:aapt"],
)
```

Godot actions load the project's extensions on their execution platform too; see
[the tool configuration](gdextension.md#the-tool-configuration) for the libraries remote
executors need.

### App Bundles for store upload

Select the same app with `--@autoload_rules_godot//godot:android_format=aab`; the default is `apk`.
The delivered AAB is unsigned and contains no alternate delivery APK. Sign the AAB outside Bazel before upload.
Changing only format reuses content export and native compilation.

From `examples/`, with the Android SDK configured:

```sh
bazel build //examples/addons/sqlite:app --config=android
bazel build //examples/addons/sqlite:app --config=android --config=aab
bazel build //examples/addons/sqlite:app --config=multi_abi --config=aab
```

The `multi_abi` export platform requests arm64 and x86_64. Both platform slices receive a
matching runtime and extension runtime libraries. For local development, use the single-CPU
export platform matching the device.

### Use a source-built engine

A source-built engine is an engine with a [`build` tag](engine.md#build-an-engine-from-source);
the app selects it with its `engine` attribute, or a build with
`--@autoload_rules_godot//godot:engine`. The runtime's AAR manifest names
the engine's [version stamp](engine.md#version-stamp) as
`org.godotengine.library.version`. Engine source, Android shell library and extension ABI must
agree; the engine builds the shell library and engine from the same source. Replace `//path/to` with your
package and `my_engine` with your engine's name:

```sh
bazel build //path/to:app --config=android --config=aab --@autoload_rules_godot//godot:engine=my_engine
```

### Use a prerelease engine

Register the prerelease as an [engine of its own](engine.md#name-an-engine), such as `beta`;
its Android shell AAR is a release asset rather than a Maven artifact, which its
[`binaries` tag](engine.md#use-other-sources-or-binaries) pins. Select it for a build with
`--@autoload_rules_godot//godot:engine=beta`, which selects the matching editor for
imports and export as well as the runtime. The beta AAR uses Java APIs from Android SDK
platform 36; install it alongside the stable platform and select it with
`--@androidsdk//:api_level=36`.

## iOS

Use macOS with Xcode selected and an installed iOS SDK. The
[repository's root module](../../../MODULE.bazel), which builds the examples, the
[SQLite project BUILD file](../../../examples/addons/sqlite/BUILD.bazel) and the root's
[`.bazelrc`](../../../.bazelrc) provide the complete engine, editor,
export platform and application setup. From the repository root:

```sh
bazel build //examples/addons/sqlite:app --config=official
```

`official` selects x86_64 Simulator, the CPU of the official templates' Simulator
libraries; see [register an engine](engine.md#register-an-engine). Select the
export platform for the runtime you supply; it configures compiler CPU flags
and the iOS environment together. A device build needs `ios_arm64`, a matching runtime,
provisioning and signing configuration through `rules_apple`.

The [registered engines](engine.md#register-an-engine) supply the official
templates' XCFrameworks for device and simulator slots, with the MoltenVK, AccessKit and
camera frameworks the archive carries:

```starlark
load("@autoload_rules_godot//godot:app.bzl", "godot_app")

godot_app(
    name = "app",
    pack = ":ios_pack",
    application_id = "com.example.mygame",
    target_compatible_with = ["@platforms//os:ios"],
)
```

A Simulator build, or any build without `-c opt`, produces the application as an
`.app` directory; an optimized device build produces the `.ipa` archive you
distribute. Both appear as `bazel-bin/path/to/app.ios/app.app` or `app.ipa`.
A directory saves rewriting the whole archive, engine included, after every
change, so rebuilds after a script edit stay short.

Godot supplies the SwiftUI entry point and scene lifecycle. Deployment floor, device
families, provisioning, entitlements and platform libraries are
[Bazel-owned inputs](configuration.md#values-that-belong-to-bazel); icons, privacy metadata,
localized strings, launch-screen settings and additional plist content use
[Godot options](configuration.md#export-options-support).
Extensions use [embedded dynamic frameworks](gdextension.md#ios-frameworks), which
`godot_cc_extension` builds by default and vendors ship
([prebuilt frameworks](gdextension.md#dynamic-frameworks)), or
[static linking and exported symbols](gdextension.md#ios-static-linking).

### Source-built engines

A catalogued engine builds the ARM64 Simulator runtimes the official templates
lack from the release's sources; [register an engine](engine.md#register-an-engine) has the
details and limits.
To use other modules, patches or options, give an engine a
[`build` tag](engine.md#build-an-engine-from-source), or register a
`godot_runtime_component` of a prebuilt arm64 Simulator engine library, such as one of
[godot-ios-builds](https://github.com/godot-mobile-plugins/godot-ios-builds),
[ahead of the engine's](engine.md#replace-slots).

A source-built iOS engine library compiles for one
[deployment target](engine.md#build-an-engine-from-source), whatever
`ios_minimum_os_version` the applications linking it declare.
Then select the export platform:

```sh
bazel build //path/to:app --platforms=@autoload_rules_godot//godot/platforms:ios_sim_arm64
```

### Use a prerelease engine

Register the prerelease as an [engine of its own](engine.md#name-an-engine), such as `beta`,
and select it with an application's `engine` attribute or a build's
`--@autoload_rules_godot//godot:engine`. For an ARM64 device build with its prebuilt
templates, declare the app with your provisioning profile,
which must match the bundle ID and a signing identity available to `rules_apple`:

```starlark
load("@autoload_rules_godot//godot:app.bzl", "godot_app")

godot_app(
    name = "ios_device_app",
    application_id = "com.example.mygame",
    pack = ":ios_pack",  # Your declared iOS godot_pack target.
    ios_provisioning_profile = "//signing:development.mobileprovision",
    target_compatible_with = ["@platforms//os:ios"],
)
```

Replace `//path/to` with the package where you put it:

```sh
bazel build //path/to:ios_device_app --platforms=@autoload_rules_godot//godot/platforms:ios_arm64 --@autoload_rules_godot//godot:engine=beta
```

Statically linked iOS extension libraries follow the
[start-pack rule for extension libraries](resources.md#export-membership): their code is in
the executable, while their descriptors remain in the PCK. A prebuilt static XCFramework follows the
[GDExtension setup](gdextension.md#ios-static-linking).

## Web

A `godot_app` builds for the web export platform into what Godot's own web export produces:
the same files under the same names and the same page, for the same project and export
options. The result deploys unchanged to a static host or to itch.io.

```sh
bazel build //path/to:app --platforms=@autoload_rules_godot//godot/platforms:web_wasm32
```

rules_godot calls the operating system `web`; Bazel's constraint is
`@platforms//os:emscripten`. `@autoload_rules_godot//godot/platforms:is_web` is the predicate
for `select()`, and a consumer's own export platform declares `operating_system = "web"` with
`cpus = ["@platforms//cpu:wasm32"]`. A web pack has the feature tags `web`, `wasm32`,
`nothreads` and `web_noextensions`. The registered engines supply the web runtime from
Godot's prebuilt web templates, with and without threads, in the release and debug variants; the templates are fetched only when an application builds for
the web. The runtime names its Godot version and the Emscripten version its templates were
built with, and the engine version check covers it.

The application's outputs are a directory and its ZIP, as Godot's export names the files;
`--output_groups=bundle` or `--output_groups=archive` selects one:

```
app/
  index.html
  index.js
  index.wasm
  index.pck
  index.audio.worklet.js
  index.audio.position.worklet.js
  index.png                   # boot splash
  index.icon.png
  index.apple-touch-icon.png
app.zip
```

`GodotWebAppInfo` describes it for a rule that deploys or starts it: `bundle`, `archive`,
`entry_point` (`index.html`) and `cross_origin_isolation` (`none` without threads).

The page follows the pack's `export_options`, under the names of Godot's export dialog:

| Option | Effect or owner |
| --- | --- |
| `html/*` | The page, as Godot writes it. `html/custom_html_shell` names a file of the pack. |
| `vram_texture_compression/*` | Which texture families the pack keeps. |
| `variant/thread_support` | The export platform's `threads`; an authored value fails. |
| `variant/extensions_support` | Derived from the pack's extensions; an authored value fails. |
| `custom_template/*` | The registered engine; an authored value fails. |
| `progressive_web_app/*` | The [progressive web app](#progressive-web-apps), as Godot writes it. |

The web runs the Compatibility renderer: a project that selects Forward+ or Mobile for the
web gets a note when its application is packaged. Godot exports no C# project for the web,
and its application fails analysis. An application whose add-ons bring extensions follows
[missing extension libraries](gdextension.md#missing-extension-libraries): it fails and
names them, or builds without them.

### Threads

Threads are a property of the export platform: they change the engine's feature tags, the
ABI of extensions and what the host must serve. `web_wasm32_threads` runs Godot's threaded
templates, and a consumer's own export platform sets `threads = True`; without threads stays
the default, as in Godot since 4.3.

```sh
bazel build //path/to:app --platforms=@autoload_rules_godot//godot/platforms:web_wasm32_threads
```

```starlark
godot_export_platform(
    name = "web_threads",
    operating_system = "web",
    cpus = ["@platforms//cpu:wasm32"],
    threads = True,
)

select({
    "@autoload_rules_godot//godot/platforms:is_web_threads": [...],
    "@autoload_rules_godot//godot/platforms:is_web_nothreads": [...],
    "//conditions:default": [...],
})
```

A pack for a threaded platform has the feature tag `threads` instead of `nothreads`. A
threaded application starts only in a cross-origin isolated page: the host sends
`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`, or
the progressive web app's service worker supplies them where the host sets none, such as
GitHub Pages. Without either, the page shows Godot's notice naming cross-origin isolation.
`GodotWebAppInfo.cross_origin_isolation` tells a deploy rule which: `none` without threads,
`headers` with threads, `service_worker` with threads and a progressive web app that ensures
the headers. Packaging a threaded application prints what its host needs. `bazel run` sends
the headers itself. Safari does not support `Cross-Origin-Embedder-Policy: credentialless`,
which some hosts, such as itch.io, rely on; serve `require-corp` or use the progressive web app
there.

### Progressive web apps

A web application is a progressive web app as Godot exports one, on either web export
platform, from the pack's export options:

```starlark
godot_pack(
    name = "pack",
    project = ":game",
    deps = [":main"],
    export_options = {
        "progressive_web_app/enabled": "true",
        "progressive_web_app/ensure_cross_origin_isolation_headers": "true",
        "progressive_web_app/offline_page": '"res://web/offline.html"',
        "progressive_web_app/display": "1",
        "progressive_web_app/orientation": "0",
        "progressive_web_app/icon_144x144": '"res://web/icon_144.png"',
        "progressive_web_app/icon_180x180": '"res://web/icon_180.png"',
        "progressive_web_app/icon_512x512": '"res://web/icon_512.png"',
        "progressive_web_app/background_color": "Color(0.14, 0.14, 0.14, 1)",
    },
)
```

The directory gains Godot's files: `index.manifest.json`, `index.service.worker.js`,
`index.offline.html` and the manifest's icons `index.144x144.png`, `index.180x180.png` and
`index.512x512.png`. The offline page and the icons that the options name are files of the
pack. One deliberate difference from Godot: Godot versions the service worker's cache with
the export's time, so two exports of one project differ; rules_godot takes a digest of the
files the worker caches, which changes exactly when they do.

### Run a web application

`bazel run` serves the application's directory on `127.0.0.1`, opens its page in a browser
of this host, shows the application's log on the terminal and exits with its exit code. The
launcher inserts a script into the page it serves, never into the built files, which reports
the log and the exit; Godot's arguments after the second `--` reach the engine as on the
other platforms.

```sh
bazel run //path/to:app --platforms=@autoload_rules_godot//godot/platforms:web_wasm32
bazel run //path/to:app --platforms=... -- --device=firefox -- --verbose
bazel run //path/to:app --platforms=... -- --headless -- -- --level=3
```

| Option | Effect on the web |
| --- | --- |
| `--device=<name or path>` | The browser: the system's default without it, and with `--headless` the first Chromium browser found on this host |
| `--list-devices` | List the browsers the launcher can start, then exit |
| `--headless` | A Chromium browser of this host without a window, with software rendering, and Godot's `--headless` |
| `--port=<number>` | The server's port; 8060 by default, the next free one when it is taken |
| `--fresh`, `--detach`, `--env` | Fail: a browser gives the application no environment, and its storage is the browser's |

For a threaded application the server sends the isolation headers.

The launcher uses the browsers of this host and downloads none. `--headless` needs a
Chromium browser: Google Chrome, Chromium, Microsoft Edge or `chrome-headless-shell`. Without
one the launcher fails and says what it looked for; `--device=<path>` names another. A
browser the launcher starts gets a fresh profile under `/tmp`, which it deletes afterwards.

An application that quits within its first frames never reports its exit: Godot's audio
driver is still starting, and the page waits. The log arrives in full. Run it with
`--headless`, which turns audio off, or quit after the first frames. A project without a
main scene exits with 0 on the web, where Godot reports an error on the desktop.

## Version and build number

A release pipeline sets the version and build number on the command line,
without editing BUILD files. For the Android example, from `examples/`:

```sh
bazel build //examples/addons/sqlite:app --config=android --@autoload_rules_godot//godot:app_version=2.3.4 --@autoload_rules_godot//godot:build_number=57
```

| Consumer | `app_version` | `build_number` |
| --- | --- | --- |
| `godot_pack` | `application/config/version` of the exported project | not used |
| `godot_app` (Android) | `versionName` | `versionCode` |
| `godot_app` (iOS) | `CFBundleShortVersionString` | `CFBundleVersion` |
| `godot_app` (macOS) | `CFBundleShortVersionString` | `CFBundleVersion` |

Export options take precedence: Android `version/name` and `version/code`,
Apple `application/short_version` and `application/version`, and a pack's
`settings`. Next come the build settings, then Godot's values: the project's
`application/config/version`, else `1.0.0`, and `versionCode` 1. iOS accepts
only one to three period-separated integers for both values, as App Store
Connect does. A changed build number repackages the applications and reuses
imports, packs and native results; a changed version also reruns the pack
exports.

## Release builds in one invocation

A `--config` selects one configuration for a whole build. To build a mobile or release
application beside the desktop targets in the same `bazel build` or `bazel test`, declare it
with `godot_configured_app` from `@autoload_rules_godot//godot:app.bzl`. It builds a
`godot_app` and its debug symbols under an export platform and build settings of its own;
`ANDROID_RELEASE` and `APPLE_RELEASE` hold the native settings of a release whose debug
symbols ship apart, as the `--config` examples above set them:

```starlark
load("@autoload_rules_godot//godot:app.bzl", "ANDROID_RELEASE", "godot_configured_app")

godot_configured_app(
    name = "android_release",
    app = ":app",
    debug_symbols = ":app.debug_symbols",
    platform = "@autoload_rules_godot//godot/platforms:android_arm64",
    android_format = "aab",
    tags = ["manual"],
    **ANDROID_RELEASE
)
```

`android_release` is the App Bundle and `android_release.debug_symbols` its debug symbols.
The macro is public API that may still change: pin the rules_godot release you build on.

## Debug symbols

Every application provides the debug symbols of its native code for a release
pipeline to upload to Play Console, App Store Connect or a crash reporter such
as Sentry. Replace `//path/to:target` with your application label. The common
`.debug_symbols` companion target works on every operating system and analyzes the unsigned
symbol producer independently of the selected app signer:

```sh
bazel build //path/to:target.debug_symbols                                  # All operating systems
bazel build //path/to:target.debug_symbols --apple_generate_dsym             # iOS
bazel build //path/to:target --output_groups=debug_symbols                   # Linux
bazel build //path/to:target --output_groups=debug_symbols --apple_generate_dsym  # macOS
```

| Application | Debug symbols | Contents |
| --- | --- | --- |
| `godot_app` (Android) | `<name>.debug_symbols`, `<name>_debug_symbols.zip` | `<abi>/<name>.so` of the extension libraries and of a source-built engine's `libgodot_android.so`, laid out as the Android Gradle plugin's `native-debug-symbols.zip` |
| `godot_app` (iOS) | `<name>.debug_symbols`, rules_apple's `<name>.app.dSYM` | The executable, which links the engine library, static extension libraries and the application's code; empty without `--apple_generate_dsym` |
| `godot_app` (macOS) | `<name>.debug_symbols` or `debug_symbols` output group, `<name>_debug_symbols.zip` | A `.dSYM` of the runtime and of each extension library, at its path in the bundle |
| `godot_app` (Linux) | `<name>.debug_symbols` or `debug_symbols` output group, `<name>_debug_symbols.zip` | The runtime and extension libraries as built, at their paths in the bundle |

Desktop apps also expose the `debug_symbols` output group shown above. A group
request still analyzes the selected app, including its signer. Use the common
companion target when certificate-mode symbols must remain available without a signing
identity or entitlements. Mobile apps retain the output groups of rules_android and rules_apple;
`debug_symbols` is not a universal group. Symbols still require the selected Android or
Apple SDK and engine inputs.

Applications package that native code stripped as Bazel's `--strip` asks:
with `sometimes`, the default, in `fastbuild` only; with `always` or `never` in
every compilation mode. Stripping uses the target platform's C/C++ toolchain
and keeps the build ID or UUID that crash reporters match symbols by.
Extension libraries and source-built engines link without `--strip`, so the debug
symbols keep what they were compiled with; Bazel's warning that `--strip` removes
the debug information of `--copt=-g` applies only to the packaged copy. On iOS, rules_apple strips the executable
instead, with `-c opt --objc_enable_binary_stripping`, and the application's native code
builds without `--strip`.

Debug symbols carry what the build compiled in: `-c`, the toolchain's features
and `--copt`, `--per_file_copt` or `copts` decide, for a source-built engine,
extensions and application code alike. File and line numbers on Android, iOS and Linux need
DWARF: `-c dbg`, or `--copt=-g` with `-c opt`. Without DWARF, the symbol table
still names functions. On macOS, they need `--apple_generate_dsym`, which
compiles with DWARF in every compilation mode: native code rules_cc links, such
as `godot_cc_extension` libraries and [source-built engines](engine.md#debug-symbols),
then has the `.dSYM` its linker writes, with file and line numbers. Other
files, such as prebuilt runtimes and prebuilt libraries, get a `.dSYM` made
from the file alone, which names functions only. Prebuilt engines contribute
no debug symbols; build a [source-built engine with debug symbols](engine.md#debug-symbols)
for symbolicated engine frames. Play Console takes the Android ZIP as an upload of its own,
since App Bundles do not embed it.

| Purpose | Flags | Packages |
| --- | --- | --- |
| Develop and debug | `--@autoload_rules_godot//godot:variant=debug -c dbg` | Keep DWARF |
| Iterate quickly | none (`fastbuild`) | Stripped |
| Store release with crash reports | `-c opt --copt=-g --strip=always`; macOS `-c opt --apple_generate_dsym --strip=always`; iOS `-c opt --apple_generate_dsym --objc_enable_binary_stripping` | Stripped, DWARF in the debug symbols |

On Android, add `--copt=-fdebug-compilation-dir=.` so the NDK does not record
the sandbox directory in debug information and make compilation bytes differ.
The `android-release` and `ios-release` configurations in the examples'
linked `.bazelrc` provide these flags. From `examples/`:

```sh
bazel build //examples/addons/sqlite:app //examples/addons/sqlite:app.debug_symbols --config=android-release --config=aab
```

For iOS:

```sh
bazel build //examples/addons/sqlite:app //examples/addons/sqlite:app.debug_symbols --config=ios-release
```

Match the packaged library and its symbols by build ID on Android or UUID on
Apple platforms. Symbols contain DWARF when file and line information is
required; a crash reporter also needs the matching symbol upload.

## Add-on platform libraries

A platform library hangs on the code that uses it. Three targets take `platform_deps`, and
each states a different fact:

| The library is used by | `platform_deps` of | Example |
| --- | --- | --- |
| an add-on's scripts, through `Engine.get_singleton()` | the `godot_addon` | a billing add-on's GDScript calls its Android plugin |
| an extension's native code, with no link between them | the `godot_extension` or `godot_cc_extension` | C++ that fetches a Kotlin plugin through `Engine::get_singleton()->get_singleton()` |
| the application alone | the `godot_app` | a push SDK no add-on uses, see [app-only platform libraries](#app-only-platform-libraries) |

A library the extension's code links, such as a Swift backend or an Objective-C SDK, is
none of these: it belongs in the C++ `deps` of the library, and applications link and
bundle it from there; on iOS they embed a dynamic framework among them once, however many
extensions link it. A dynamic framework the extension library loads, which a vendor's
descriptor lists under `[dependencies]`, is a `bundle_only` import in the extension's
`platform_deps`: applications embed it without linking it, see
[dynamic frameworks](gdextension.md#dynamic-frameworks).

An [add-on](resources.md#add-ons) declares the Android and Apple libraries its scripts
need in `platform_deps`, with the usual Android and Apple rules:

```starlark
godot_addon(
    name = "billing",
    srcs = glob(["addon/**"]),
    strip_prefix = "addon",
    infoplists = ["billing.plist"],
    platform_deps = select({
        "@platforms//os:android": ["//third_party:billing_plugin_aar", "@maven//:com_android_billingclient_billing"],
        "@platforms//os:ios": [":billing_swift"],
        "//conditions:default": [],
    }),
)
```

Applications whose packs contain the add-on, because resources of the pack use it or
the pack's project names it, link and package these libraries without listing them:
`godot_app` (Android) adds their code, resources, native libraries and
manifest entries, `godot_app` (iOS) links their code, linker flags and
SDK frameworks and bundles their resources. A `godot_extension` takes the
libraries its native code needs the same way.

- **Android permissions:** the `uses-permission` entries of library manifests merge
  into the application's manifest as in a Gradle build, through rules_android's
  manifest merger, with their `tools:` markers as Android's
  [merge rules](https://developer.android.com/build/manage-manifests#merge_rule_markers)
  define them. The application's manifest ranks first, then the libraries in the order
  Godot's Gradle template declares them: the template activity's androidx libraries,
  the Godot library, the libraries the add-ons and the application name; then their
  dependencies breadth-first. A library's `tools:node="remove"` drops the permission
  from the libraries ranked below it only, as Google's `play-services-ads-api` drops the
  `RECEIVE_BOOT_COMPLETED` of its dependency WorkManager while a named library that
  declares it keeps it. The permissions the pack's `permissions/*` export options enable
  belong to the application's manifest, so no library removes them; false or default
  options remove nothing. The attributes of one permission merge across the manifests
  that declare it: a value the application or a higher-ranked library sets wins, and
  one only a lower-ranked library sets applies too, so a library's
  `android:maxSdkVersion` also limits the application's own declaration. Where two
  manifests set different values, Gradle fails the build and rules_android takes the
  higher-ranked value with a warning; `tools:replace` in the higher-ranked manifest
  settles it in both.
- **Android manifest entries:** an `android_library` passes its activities, meta-data
  and permissions on only with `exports_manifest = 1`; an `aar_import` always does. One
  manifest serves every ABI of an application: a library selected per CPU contributes
  the manifest entries of the first platform slice's selection only.
- **Godot's classes:** an `android_library` that extends `GodotPlugin` compiles against
  the [plugin API target](engine.md#android-shell-libraries), the shell library of the
  application's engine.
- **Android manifest placeholders:** a library manifest may leave a value to the
  application as `${key}`, as AppAuth's redirect activity does with
  `${appAuthRedirectScheme}`. The application sets it in
  `godot_app.android_manifest_values`, the counterpart of Gradle's
  `manifestPlaceholders`; the [API documentation](https://registry.bazel.build/modules/autoload_rules_godot) of `godot_app` says
  what an unset placeholder and a reserved key do.
- **Activity themes:** the application element carries no theme, as in Godot's own
  Android export, so a library activity without a theme of its own gets the platform
  default. An SDK activity that extends `AppCompatActivity` then fails to start with
  "You need to use a Theme.AppCompat theme". Give such an activity a theme in the
  add-on's manifest; the merge adds it to the SDK's entry. The
  [AppAuth add-on](../../../addons/app_auth/app_auth/native/backends/android/AndroidManifest.xml)
  does this for AppAuth's redirect activity with the SDK's own AppCompat theme.
- **Info.plist entries:** rules_apple has no library-level Info.plist, so an
  add-on's fragments go in its `infoplists`, and those an extension's native code needs
  in the extension's `infoplists`, which also serve an extension used without an add-on.
  Two fragments with different values for a key fail; the application's own
  `ios_infoplists` win.
- **Loadable packs:** an application that may load a pack later, such as DLC, lists it
  in `godot_app.loadable_packs`, and delivers the libraries of its add-ons too.

For example, this complete Android BUILD template declares a vendor plugin
and an optional local Java library beside the add-on's script:

```starlark
load("@rules_android//rules:rules.bzl", "aar_import", "android_library")
load("@autoload_rules_godot//godot:defs.bzl", "godot_addon")

aar_import(
    name = "vendor_plugin",
    aar = "vendor/plugin.aar",
)

android_library(
    name = "android_bridge",
    srcs = ["android/Bridge.java"],
    manifest = "android/AndroidManifest.xml",
    exports_manifest = 1,
)

godot_addon(
    name = "vendor",
    srcs = ["addon.gd", "addon.gd.uid"],
    platform_deps = select({
        "@platforms//os:android": [":android_bridge", ":vendor_plugin"],
        "//conditions:default": [],
    }),
)
```

Supply your actual plugin AAR, Java bridge and library manifest at these paths;
the AAR must register its Godot plugin in the manifest when it needs one.
The resources whose scripts use the add-on list this package's `:vendor` in their `deps`.
The application itself does not list these platform libraries again.

For Apple code, a separate add-on BUILD template can use Swift, Objective-C,
SDK frameworks, resources and an Info.plist fragment together:

```starlark
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@autoload_rules_godot//godot:defs.bzl", "godot_addon")
load("@rules_swift//swift:swift_library.bzl", "swift_library")

swift_library(
    name = "swift_bridge",
    srcs = ["apple/Bridge.swift"],
    module_name = "VendorBridge",
)

objc_library(
    name = "controller",
    srcs = ["apple/controller.m"],
    data = ["apple/notice.txt"],
    sdk_frameworks = ["GameController"],
)

godot_addon(
    name = "vendor",
    srcs = ["addon.gd", "addon.gd.uid"],
    infoplists = ["apple/addon.plist"],
    platform_deps = select({
        "@platforms//os:ios": [":controller", ":swift_bridge"],
        "//conditions:default": [],
    }),
)
```

These are consumer templates with placeholder vendor inputs, not repository
targets. Declare `rules_android`, `rules_cc` and `rules_swift` directly in the
consuming module, as the [repository's root module](../../../MODULE.bazel) does for the
examples.
The `select` keeps each library out of applications for other operating systems; an
add-on supporting both mobile operating systems combines both branches, as in the first
example. Imports, which run on the execution platform, also need a portable script or
editor implementation.

## App-only platform libraries

Use `godot_app.platform_deps` for platform libraries needed by just one app and
`platform_resources` for its Android primary resources or iOS bundle resources.
Both fields default to empty configurable label lists. Select Android/iOS inputs
with `select()` and leave desktop branches empty: desktop packaging rejects nonempty
selected contributions. Inactive `select()` branches are not analyzed. With existing
`:pack`, `:android_services` and `:ios_services` targets, select their
platform libraries and platform resources at the app boundary:

```starlark
godot_app(
    name = "app",
    pack = ":pack",
    platform_deps = select({
        "@platforms//os:android": [":android_services"],
        "@platforms//os:ios": [":ios_services"],
        "//conditions:default": [],
    }),
    platform_resources = select({
        "@platforms//os:android": ["android/res/values/styles.xml"],
        "@platforms//os:ios": ["ios/notice.txt"],
        "//conditions:default": [],
    }),
)
```

Library resources remain on the platform libraries that own them, including those reached
through an extension's `platform_deps`. Android primary app resources override dependency
resources using rules_android's merger; conflicting siblings fail with its source
messages. iOS uses rules_apple's resource deduplication and reports conflicting bundle
destinations. Godot `res://` content belongs to the pack.


## Replace shell files

An application's own file replaces the shell file or shell asset Godot's exporter would
write for the same slot. It reaches rules_android or rules_apple unchanged, and rules_godot
leaves its default out; everything the application does not replace stays Godot's. Godot
projects set such values through a Gradle template or by editing the Xcode project, which a
Bazel build does not have.

| In Godot's export | Here | Replaces |
|---|---|---|
| `gradle_build/custom_theme_attributes`, `res://android/build/res/values/themes.xml` | A style named `GodotAppSplashTheme` or `GodotAppMainTheme` in `platform_resources` under `res/values/` | The shell's style of that name, as a whole |
| Launcher icon images of the Gradle template | `res/mipmap-<density>/icon.png` and the other resources of `platform_resources` | The shell's resource of the same type, name and configuration qualifiers; `mipmap-xxxhdpi` is the same configuration as Godot's `mipmap-xxxhdpi-v4` |
| `res://android/build/AndroidManifest.xml` | `godot_app.android_manifest` | The main manifest; Godot's manifest merges below it |
| `application/additional_plist_content`, edits of the Xcode project's `Info.plist` | `godot_app.ios_infoplists` | Each top-level key they set, in the shell's `Info.plist` and in add-ons' fragments |
| `icons/*`, an Icon Composer icon added to the Xcode project | `godot_app.ios_app_icons` | All app icons |
| `storyboard/*` | `godot_app.ios_launch_storyboard` | The launch screen |
| `privacy/*` | `PrivacyInfo.xcprivacy` in `platform_resources` | The privacy manifest |

### Android shell files

The manifest given as `android_manifest` is the main manifest of rules_android's manifest
merge, and the manifest Godot's export writes merges below it like a library's. Its
attribute values win over the shell's, and `tools:node` and `tools:remove` act on the
shell's elements that the merger matches by name, such as Godot's activity
`com.godot.game.GodotApp` and its `meta-data`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission android:name="android.permission.VIBRATE" tools:node="remove" />
    <application>
        <activity android:name="com.godot.game.GodotApp"
            android:screenOrientation="portrait" />
    </application>
</manifest>
```

rules_godot adds the shell's permissions to this manifest, except those it declares itself or
removes as above, because rules_android drops the permissions of library manifests. It also
adds the shell's `<manifest>` attributes and SDK versions it leaves out. The version code and
name and the SDK versions keep their owners: a manifest that sets them fails, naming the
export option, build setting or `godot_app` attribute to set instead.

A start theme of its own replaces the splash screen's theme:

```starlark
godot_app(
    name = "app",
    pack = ":pack",
    application_id = "org.example.game",
    android_manifest = "android/AndroidManifest.xml",
    platform_resources = select({
        "@platforms//os:android": [
            "android/res/values/themes.xml",
            "android/res/drawable/start.xml",
        ],
        "//conditions:default": [],
    }),
)
```

```xml
<resources>
    <style name="GodotAppSplashTheme" parent="Theme.SplashScreen">
        <item name="android:windowBackground">@drawable/start</item>
        <item name="windowSplashScreenAnimatedIcon">@mipmap/icon</item>
        <item name="postSplashScreenTheme">@style/GodotAppMainTheme</item>
    </style>
</resources>
```

The style replaces the shell's whole style, not single items: keep the items of the
shell's style that the application needs, such as `postSplashScreenTheme`. A style in a
qualified directory, such as `res/values-night/`, adds a configuration beside the shell's
style and replaces nothing.

### iOS shell files

rules_apple merges `Info.plist` fragments without precedence and fails on a key two of them
set differently. A key of `ios_infoplists` therefore takes the key's place: the shell's
`Info.plist` and the add-ons' fragments leave it out. Keys rules_godot or rules_apple own,
such as `CFBundleIdentifier`, `MinimumOSVersion`, the version keys and the icon and
launch-storyboard keys, fail, naming the attribute or setting to use instead.

App icons, the launch screen and the privacy manifest are replaced as a whole. An Icon
Composer `.icon` bundle goes to rules_apple's `app_icons` unchanged; it needs Xcode 26 and
must not sit inside an `.xcassets` catalog:

```starlark
godot_app(
    name = "app",
    pack = ":pack",
    application_id = "org.example.game",
    ios_app_icons = glob(["ios/AppIcon.icon/**"]),
    ios_infoplists = ["ios/Overrides.plist"],
    ios_launch_storyboard = "ios/LaunchScreen.storyboard",
    platform_resources = select({
        "@platforms//os:ios": ["ios/PrivacyInfo.xcprivacy"],
        "//conditions:default": [],
    }),
)
```

The files of one `.appiconset` in an `.xcassets` catalog work as well; rules_apple rejects a
mix of both kinds.

## Inspect the result

Build the SQLite APK and Simulator IPA from the repository root:

```sh
bazel build //examples/addons/sqlite:app --config=android
bazel cquery //examples/addons/sqlite:app --config=android --output=files
bazel build //examples/addons/sqlite:app --config=official
bazel cquery //examples/addons/sqlite:app --config=official --output=files
```

Inspect the APK/IPA paths reported by Bazel with `unzip -l`; use your SDK's
`apksigner verify --verbose` on the signed APK. Output directories are configuration-specific.

The APK contains `assets/main.pck` and the SQLite extension library under
`lib/arm64-v8a/`; the IPA contains the application's `.pck` beside its executable
in `Payload/*.app/`. On iOS the extension is statically linked, so a separate
SQLite dylib is not expected. The example's own
exported-pack test loads SQLite from the production PCK through the public
`godot_test` rule. Package inspection alone does not run a mobile app or
establish store acceptance.

Inspect each output before switching build configurations: Bazel updates the
`bazel-bin` symlink to the most recent configuration's output directory.

Custom Bazel rules should consume the documented providers instead of choosing an arbitrary
file from `DefaultInfo.files`. APK defaults retain rules_android's build outputs alongside the signed
APK. `ApkInfo` identifies the APK for distribution; `AndroidBundleInfo` identifies an AAB
without exposing an intermediate APK. iOS consumers use `AppleBundleInfo` for the archive
and rules_apple's bundle metadata.

Desktop consumers use
[GodotDesktopAppInfo](https://registry.bazel.build/modules/autoload_rules_godot): `archive`,
`bundle`, `operating_system` and bundle-relative `executable_path` describe the selected result,
including optional macOS signing. For file subsets, use the desktop `archive`, `bundle` or
`debug_symbols` output group. The common `.debug_symbols` companion target preserves independent
symbol access on every operating system. The [API documentation](https://registry.bazel.build/modules/autoload_rules_godot) of `godot_app`
documents each interface's availability and prerequisites.

An attribute that takes file labels rather than an output group can use a group through a
`filegroup` in your own package. It selects files of the app and adds no build work:

```starlark
filegroup(
    name = "app_archive",
    srcs = [":app"],
    output_group = "archive",
)
```

## Bill of materials and licenses

rules_godot, the engines it downloads or builds, and godot-cpp declare their identity and
license as [package metadata](https://github.com/bazel-contrib/supply-chain), which SBOM and
license tools read from an application's build graph. With
[`@supply_chain_tools`](https://github.com/bazel-contrib/supply-chain/tree/main/tools), write a
software bill of materials of an application as SPDX:

```starlark
load("@package_metadata//rules:package_metadata.bzl", "package_metadata")
load("@supply_chain_tools//sbom:sbom.bzl", "sbom")
load("@supply_chain_tools//sbom:spdx.bzl", "spdx")

package(default_package_metadata = [":package_metadata"])

package_metadata(
    name = "package_metadata",
    purl = "pkg:generic/my_game@1.0.0",
    visibility = ["//visibility:public"],
)

sbom(
    name = "app_sbom",
    target = ":app",
)

spdx(
    name = "app_spdx",
    sbom = ":app_sbom",
)
```

The SBOM reads the graph from analysis and builds none of the application's outputs. Your
`package_metadata` must be visible to rules_godot, since the targets its macros declare in
your package carry it too. The SBOM names `pkg:bazel/autoload_rules_godot` (MPL-2.0), and
`pkg:generic/godot@<version>` and `pkg:generic/godot-cpp@<version>` (MIT), whose `checksum`
names the archive they come from where rules_godot knows its digest. Each license names its
text, such as the ruleset's `LICENSE`, so that a license report can include it.

Godot bundles libraries under other licenses, such as zlib, FreeType and HarfBuzz, and lists
them in the `COPYRIGHT.txt` of its sources. The SBOM names each library it lists as a package
of its own, `pkg:generic/godot/<name>` with the name of its `Comment` field, with its license
as an SPDX expression and its part of `COPYRIGHT.txt` as the license text. Godot 4.7.2 lists
102 libraries. Godot's short names become SPDX identifiers: `Expat` is `MIT`, `HarfBuzz`
`MIT-Modern-Variant`, `Unicode` `Unicode-DFS-2016`, `X11` `HPND-sell-variant`, and a license
on no SPDX list, such as glslang's, is a `LicenseRef`. The packages have no version, since
`COPYRIGHT.txt` names none.

The list covers every library of `COPYRIGHT.txt`, also those a given build does not link,
such as the Vulkan loader in a build without Vulkan, or the editor's own fonts in an
exported application: it can name more than the application ships. A source-built engine
reads `COPYRIGHT.txt` from its source archive, a fork's included. Its patches and custom
modules do not change the list, so declare the package metadata of a library they add
yourself. The prebuilt binaries of a catalogued version read the file of the release's
commit, which rules_godot pins beside the archives. Binaries you pin with
`godot_engines.binaries` name Godot alone, since rules_godot does not know the sources they
were built from.
