# GDExtensions

Compile a C/C++ extension with `rules_cc`, then list it in the `deps` of the resources
whose scripts use it. An extension is an [add-on](resources.md#add-ons) of only that
extension: every operation and application containing those resources contains it.
Bazel compiles each translation unit independently; game-content edits do not
recompile the extension.

```starlark
load("@autoload_rules_godot//godot:defs.bzl", "godot_pack", "godot_project", "godot_resources")
load("@autoload_rules_godot//godot/extension:defs.bzl", "godot_cc_extension")

godot_cc_extension(
    name = "game_extension",
    srcs = ["register_types.cc", "movement.cc"],
    entry_symbol = "game_library_init",
)

godot_resources(
    name = "main",
    srcs = ["main.gd", "main.tscn"],
    deps = [":game_extension"],
)

godot_project(
    name = "game",
    project_file = "project.godot",
)

godot_pack(
    name = "pack",
    project = ":game",
    deps = [":main"],
)
```

An extension that no content uses but every operation loads, such as a crash reporter,
goes in the `deps` of the `godot_project` instead. An extension that belongs to an add-on
with scripts, an editor plugin or configuration is in that `godot_addon`'s `deps`; the
add-on treats every extension there alike, wherever its descriptor lies.

The rule generates a descriptor at `res://addons/<name>/<name>.gdextension`, where Godot
add-ons keep theirs, and places the libraries in `bin/<feature tags>/` beside it;
`resource_path` names another place, such as a vendor's own layout. Nothing in a project
needs to name that path: Godot loads every descriptor of the project. Its feature tags follow the configuration Bazel builds the library
in: operating system, CPU, `simulator` on the iOS Simulator, and the variant, for example
`android.arm64.release`. A matching C++ toolchain is still required. Generated
descriptors require Godot 4.7.2 or newer.

The extension library exports only `entry_symbol`, as godot-cpp's own build
does, so extensions loaded into one process each run their own copy of godot-cpp and of
their other static dependencies. On iOS this holds for the default
[framework](#ios-frameworks); a [statically linked](#ios-static-linking) extension shares
the executable's. Other functions of the library are not visible to code
that looks them up by name.

## C++ bindings

Add the optional upstream bindings to `MODULE.bazel`:

```starlark
godot_cpp_bindings = use_repo_rule(
    "@autoload_rules_godot//godot/extension:repositories.bzl",
    "godot_cpp_bindings",
)

godot_cpp_bindings(
    name = "godot_cpp",
    enabled_classes = ["Node"],
)
```

Then add `deps = ["@godot_cpp//:godot_cpp"]` to your extension. The repository
pins **godot-cpp 10.0.0**, with the Godot 4.7 API, to commit
`507ed9d840c01a3c5b2a39af8bb4000bfac30bf5` and a SHA-256 digest. Its versioning
is independent of the engine's versioning.

`enabled_classes` uses upstream's build profile to keep selected classes,
required runtime classes and ancestors. Methods referencing omitted classes
are removed. Include classes reached through returned pointers, or omit the
attribute to build the complete API. This reduces generation and compilation.

Repository evaluation only downloads, reads metadata, applies optional
`patches` and writes BUILD files. A Python action generates the interface and
bindings; each generated and handwritten C++ file compiles through `rules_cc`.
API JSON, interface JSON, profile, generator, precision and word size are
explicit inputs. The defaults are 64-bit/single precision; match these to the
engine. Set `debug_features = False` for release-only bindings.

For a patched API, supply a checksum-pinned archive with matching `api_path`
and generator/interface files, or apply repository patches. Changes to the
upstream generator's output contract need validation before use.

Source-built descriptors derive the operating system, CPU, iOS device/Simulator
environment and Godot variant from the build configuration; the extension editor library
has debug features, see [extension editor and runtime libraries](#extension-editor-and-runtime-libraries).
`features = [...]` selects rules_cc toolchain features. Imported `godot_extension.libraries` retains explicit tagged
alternatives, including variant-independent vendor imports.

An application fails analysis when an extension it delivers has libraries for its
operating system, but none that the requested CPU, Android ABI or iOS platform slice loads in the
selected variant. This includes an extension disabled only for the export, which the
application still loads at runtime. An extension without any library for the
operating system, such as a desktop-only one in a mobile app, is left out, and one disabled
for `runtime` is not delivered.

A pack contains the extension's descriptor but never its libraries; `godot_run` and
applications deliver or link those from the project. A PCK used elsewhere needs its extension
libraries delivered separately, see [export membership](resources.md#export-membership).

## Upgrade the engine without rebuilding the extension

Keep `godot_cpp_bindings` pinned when changing the editor or runtime version.
The default API file is `gdextension/extension_api-4-7.json`; it is independent
of the engine toolchain. A compatible editor upgrade rebuilds imports and the
PCK, while the existing binding generation, objects and extension libraries remain
cached. A runtime-only upgrade can also reuse imports and the PCK, rebuilding
only the affected application package. Changing API JSON, generator, precision,
C++ sources or C++ toolchain
can legitimately rebuild the extension.

[Godot's compatibility contract](https://docs.godotengine.org/en/stable/tutorials/scripting/cpp/about_godot_cpp.html#version-compatibility)
allows an extension targeting an older API to run on newer minor releases.
Choose the oldest API providing the features you need. Engine and extension
must use the same floating-point precision; a source-built engine changing the API
may require its own API JSON. This is a compatibility condition to validate,
not a reason to regenerate bindings on every engine upgrade.

Keep `compatibility_minimum = "4.7.2"` unless newer functionality requires a
higher minimum. This descriptor value accepts stable versions, independently
of an editor pin such as `4.8.0-beta1`. See [version selection](versions.md).

## Libraries per configuration

An extension has one `library` per configuration. A prebuilt extension varies it with
`select()` over platform constraints and the variant settings `@autoload_rules_godot//godot:debug`,
`:release` and `:editor`:

```starlark
load("@autoload_rules_godot//godot/extension:defs.bzl", "godot_extension")

config_setting(
    name = "android_arm64",
    constraint_values = ["@platforms//os:android", "@platforms//cpu:aarch64"],
)

config_setting(
    name = "android_arm32",
    constraint_values = ["@platforms//os:android", "@platforms//cpu:armv7"],
)

godot_extension(
    name = "prebuilt",
    entry_symbol = "game_library_init",
    library = select({
        ":android_arm64": "lib/arm64-v8a/libgame.so",
        ":android_arm32": "lib/armeabi-v7a/libgame.so",
        "@platforms//os:macos": ":game_macos",  # a cc_import(shared_library = ...)
    }),
)
```

Each configuration writes a descriptor fragment with the one library it built, under the
feature tags of that configuration; a pack merges the fragments of its platform slices.
A configuration without a matching `select()` branch is Bazel's analysis error, and a
branch of `None` leaves the extension without a library there, where scripts that use its
classes fail their [content validation](development.md#content-validation).

The library's providers decide how Godot loads it:

| Library | Link kind | Operating systems |
| --- | --- | --- |
| `cc_import(shared_library = ...)`, `cc_binary(linkshared = True)`, a target with one `.so`, `.dylib` or `.dll` | dynamic | Linux, macOS, Android |
| `cc_library`, `cc_import(static_library = ...)`, `apple_static_xcframework_import` | static | iOS |
| `apple_dynamic_xcframework_import`, `apple_dynamic_framework_import`, see [dynamic frameworks](#dynamic-frameworks) | framework | macOS, iOS |

A link kind the operating system cannot load fails analysis, as does a shared library
whose name its loader does not take: Linux and Android load `.so` files, macOS `.dylib` and
`.so` files. The shared libraries a
library needs at run time are its runtime dependencies: the shared libraries in its
`CcInfo`, such as a `cc_import`'s `deps`, the shared libraries in the runfiles of a
`cc_binary` or `cc_shared_library`, and the other frameworks of an Apple import. The
extension places them beside the library and lists them in the descriptor's
`[dependencies]`, so a library that finds its dependencies through `$ORIGIN` or
`@loader_path` loads them. `godot_cc_extension` links its shared library with such a run
path. Two runtime files of the same name fail analysis.

`data` holds the files of a vendor's `[dependencies]` that the library's providers do not
already bring, such as a crash handler executable:

| Operating system | `data` takes |
| --- | --- |
| Linux, macOS | any file, placed beside the library |
| Android | `lib*.so` files, packaged in `lib/<abi>/`; anything else fails analysis |
| iOS | nothing: an application delivers no files beside the library, so a file fails analysis. A file goes to a [platform library](#platform-libraries), a framework the library loads to [`platform_deps`](#dynamic-frameworks) |

```starlark
godot_extension(
    name = "crash_reporter",
    entry_symbol = "crash_reporter_init",
    library = ":crash_reporter_library",
    data = select({
        ":linux_x86_64": ["bin/linux/crashpad_handler"],
        "//conditions:default": [],
    }),
)
```

### The tool configuration

Editor actions, such as imports, initialization and exports, run the editor on the
execution platform, and `godot_editor` runs it on the host. They load the extension's
library in the tool configuration: the same declaration built for their platform, where
`@autoload_rules_godot//godot:tool` and `:editor` match and the feature tags end in `editor`.
Projects, packs and applications receive the target configuration's fragment. Source runs
run in the [editor variant](platforms.md#the-editor-variant), whatever variant the build
selects: `godot_run` and `godot_test` with `deps`, autoload_gdunit's `gdunit_test` and a
`godot_app` of the editor variant load the library of that variant for their target
platform, the `:editor` branch of a `select()`. A `godot_run` or `godot_test` of a
`pack` runs the pack with the editor in the pack's variant; for a `release` pack it lists
each desktop library under `<operating system>.<cpu>.editor_runtime` too, the feature tag
of an editor running a project, so the editor loads it. `bazel run` for a target platform
the host cannot run loads the host's tool configuration instead.

A `select()` over platform keys that has a branch for every execution platform's
operating system needs no `@autoload_rules_godot//godot:tool` branch: the tool configuration takes
the branch of the platform it builds for. A `select()` without a branch for the editor's
platform needs one: `None` for an extension the editor does not load, or a library built for
the editor's platform. `//godot:tool` refines `//godot:editor`, so both may appear in one
`select()`. The same holds for a library target whose `target_compatible_with` excludes the
editor's platform: without a tool branch, the extension becomes incompatible there too.

A `//godot:tool` branch beside a `config_setting` that also matches the execution
platform, such as one of `@platforms//os:linux` and `@platforms//cpu:x86_64` on a Linux
executor, is an ambiguous match: neither key refines the other, and Bazel fails analysis.
Beside a bare constraint key such as `@platforms//os:macos`, the tool branch wins. Prefer
platform keys alone where the library exists for every execution platform.

Every execution platform that runs Godot actions needs that tool library, remote executors
included: with `--config=buildbuddy`, actions run on BuildBuddy's linux/x86_64 executors, so a
prebuilt extension needs a Linux library for that configuration. A `no_match_error`
explains the analysis failure without one. An extension without a Linux library keeps Godot actions on this
host: build without a remote execution platform.

```starlark
godot_extension(
    name = "crash_reporter",
    entry_symbol = "crash_reporter_init",
    # No tool branch: macOS hosts and Linux executors take their own branch.
    library = select(
        {
            "@platforms//os:android": "bin/android/libcrash_reporter.arm64.so",
            "@platforms//os:macos": "bin/macos/libcrash_reporter.dylib",
            # A config_setting of @platforms//os:linux and @platforms//cpu:x86_64.
            ":linux_x86_64": "bin/linux/libcrash_reporter.x86_64.so",
        },
        no_match_error = "crash_reporter has libraries for Android, macOS and linux/x86_64 only",
    ),
)
```

An extension that wraps a platform SDK usually has nothing to do in the editor: the SDK acts
in a running game. Select a backend that reports the feature as unsupported for the tool
configuration, in `godot_cc_extension`'s `deps`:

```starlark
godot_cc_extension(
    name = "store",
    srcs = ["store.cc"],
    entry_symbol = "store_init",
    deps = ["@godot_cpp//:godot_cpp"] + select({
        "@autoload_rules_godot//godot:tool": [":store_unsupported"],
        "//conditions:default": [":store_platform"],
    }),
)
```

The editor then still knows the extension's classes for scripts, checks and completion,
while source runs and applications load the library with the SDK, and editor builds never
fetch or compile the SDK. The [AppAuth add-on](../../examples/addons/app_auth/BUILD.bazel)
shows this.

## iOS frameworks

With an iOS target toolchain, `godot_cc_extension` links the same shared library as on
other platforms and wraps it in a dynamic framework named after the target,
`<name>.framework`, with an `Info.plist` whose `MinimumOSVersion` is the deployment target
of the link. Its binary holds the library of every CPU of the application's export
platform, such as both CPUs of an iOS Simulator platform. The iOS application embeds and
signs it in its `Frameworks` directory, as it does a vendor's
[dynamic framework](#dynamic-frameworks), and Godot loads it when it loads the extension. Each framework links its own godot-cpp, so extensions from different
Bazel modules, each with their own `godot_cpp_bindings`, never share godot-cpp symbols, and
every extension keeps its own main loop callbacks.

`ios_bundle_id` sets the framework's `CFBundleIdentifier`; by default it derives from the
target's label, such as `rules-godot.extension.addons.sentry.sentry`. Two extensions of one
application need different target names, since the frameworks share one directory.

## iOS static linking

With `ios_linkage = "static"`, `godot_cc_extension` selects a static archive on iOS
instead. Include the extension
in the project's `deps`, or those of resources it contains. The iOS application
links its archive and transitive C++ dependencies from the pack's project.
The [SQLite extension](../../examples/addons/sqlite/BUILD.bazel) and its
[project BUILD file](../../examples/addons/sqlite/demo/BUILD.bazel) show the
extension, project, pack and application together; follow the
[iOS setup and build commands](platforms.md#ios) to build it.

The target propagates an always-link archive and retains/exports its entry
symbol despite dead stripping. The descriptor must retain a nonempty `.a`
resource path: Godot recognizes that suffix and resolves the entry in the main
executable. A `.a` alias bridges rules_cc's `.lo` always-link naming without
changing its rules_cc linking metadata.

The statically linked `godot_cc_extension` archives of an iOS application share one
godot-cpp copy, which godot-cpp supports for classes and object bindings. They must
therefore link the same godot-cpp: two `godot_cpp_bindings` repositories, such as one of
the application's module and one of an add-on module, with different `enabled_classes`
fail with duplicate symbols, and different `precision` or `debug_features` mix
incompatible objects. Main loop callbacks
(`register_startup_callback`, `register_frame_callback`, `register_shutdown_callback`)
are the exception: only the last extension that registers them keeps its callbacks.
When several extensions need them, register them in one extension that calls the
others, or keep the default [framework](#ios-frameworks), which carries its own godot-cpp.

A prebuilt extension shipped as a static XCFramework comes in through
`apple_static_xcframework_import` as the iOS branch of `library`; rules_apple selects the
XCFramework slice of each platform slice, which the application links:

```starlark
load("@rules_apple//apple:apple.bzl", "apple_static_xcframework_import")
load("@autoload_rules_godot//godot/extension:defs.bzl", "godot_extension")

apple_static_xcframework_import(
    name = "vendor_ios",
    xcframework_imports = glob(["addons/vendor/bin/ios/libvendor.ios.release.xcframework/**"]),
)

godot_extension(
    name = "vendor",
    entry_symbol = "vendor_gdextension_init",
    library = select({
        # The editor, on a macOS host.
        "@autoload_rules_godot//godot:tool": "addons/vendor/bin/macos/libvendor.dylib",
        "@platforms//os:ios": ":vendor_ios",
    }),
)
```

The pack follows the [start-pack rule for extension libraries](resources.md#export-membership),
so the linked archive stays out of the PCK.

## Dynamic frameworks

An extension whose library is a dynamic framework, as Sentry for Godot ships its iOS
extension, comes in through `apple_dynamic_xcframework_import` or
`apple_dynamic_framework_import` with `bundle_only = True`. Godot loads the framework when it
loads the extension, so nothing links it: an iOS application embeds and signs it in its
`Frameworks` directory, a macOS application places it at its resource path with the
extension's other files, and the descriptor names the `.framework` for Godot to load. A
framework the extension's framework loads, such as Sentry's `Sentry.xcframework`, which
Sentry's descriptor lists under `[dependencies]`, is a separate `bundle_only` import in
`platform_deps`, rules_apple's way to embed without linking; the iOS application embeds it
beside the extension's:

```starlark
load("@rules_apple//apple:apple.bzl", "apple_dynamic_xcframework_import")
load("@autoload_rules_godot//godot/extension:defs.bzl", "godot_extension")

# Godot loads the framework, so nothing links it. Linking would also fail: rules_cc rejects
# a library to link whose name has dots, such as libsentry.ios.release.
apple_dynamic_xcframework_import(
    name = "sentry_ios",
    bundle_only = True,
    xcframework_imports = glob(["addons/sentry/bin/ios/libsentry.ios.release.xcframework/**"]),
)

apple_dynamic_xcframework_import(
    name = "sentry_objc",
    bundle_only = True,
    xcframework_imports = glob(["addons/sentry/bin/ios/Sentry.xcframework/**"]),
)

godot_extension(
    name = "sentry",
    entry_symbol = "sentry_gdextension_init",
    library = select({
        "@autoload_rules_godot//godot:tool": ":sentry_macos",  # a cc_import(shared_library = ...)
        "@platforms//os:ios": ":sentry_ios",
    }),
    platform_deps = select({
        "@platforms//os:ios": [":sentry_objc"],
        "//conditions:default": [],
    }),
)
```

Without `bundle_only`, rules_apple hands the framework binary to rules_cc as a library to
link, and rules_cc rejects a binary whose name contains a dot, such as
`libsentry.ios.release`, with "does not have any of the allowed extensions". An import with
`bundle_only` may bundle only the extension's own framework, so each framework it loads
is an import of its own.

When the release is downloaded with `http_archive`, its `build_file` holds these imports
and filegroups of the add-on's scripts; the `godot_addon` with the extension in its `deps`
lives in the consumer's package and places the scripts from the release, as a
[release in a repository of its own](resources.md#add-ons) does.

## Platform libraries

An extension whose native code needs Android or Apple libraries at runtime,
such as an AAR or a Swift package, lists them in `platform_deps` on either
`godot_extension` or `godot_cc_extension`. Use a `select()` on the operating system with an
empty default for mobile-only libraries. `godot_cc_extension.deps` remains for C++
compilation/link dependencies. Applications shipping a pack that contains the extension link
and package them, as described for
[add-on platform libraries](platforms.md#add-on-platform-libraries).

Info.plist keys the native code needs, such as an SDK's configuration keys, go in the
extension's `infoplists`, merged as an [add-on's](platforms.md#add-on-platform-libraries)
are.

Resources owned by these libraries follow the same `platform_deps` edge: use
`android_library.resource_files` on Android or `objc_library.data` on iOS,
including a source-less `objc_library` for resources without code. Neither extension
accepts raw resource files in `platform_deps`. Applications need not repeat
extension-owned libraries or resources in their own composition fields.

On iOS, a library that `godot_cc_extension` links statically through its C++ `deps` brings its
Apple resources as well: iOS applications bundle them as they bundle those of
`platform_deps`. A Swift package target's resource bundle with its privacy manifest therefore
arrives with the package in `deps`; listing the package in `platform_deps` as well would link
it twice.

## Extensions in exports

An extension an operation contains runs in a pack's export, in editor views and at
runtime; imports and initializations load only the extensions of the
[importers](resources.md#importers) that convert their files. The export loads the library
the extension has for the platform that runs it, so export plugins the extension registers
natively run there; see [export plugins](resources.md#export-plugins). An extension without
such a library, as in `library = select({"//godot:tool": None, ...})`, does not load in the
export: Godot would drop the values of its classes from the scenes and resources it
converts, so a pack whose export meets one of them fails, naming the class. A product
without an extension is a pack or application whose `deps` do not contain it.

## Minimum operating-system versions

An extension library builds in the configuration of the application that packages it, so
it takes the application's minimum version as its deployment target: `macos_minimum_os_version`
and `ios_minimum_os_version` of `godot_app`. A library that needs a newer system, because it
calls an API that arrived there, declares it:

```starlark
godot_cc_extension(
    name = "extension",
    srcs = ["extension.cpp"],
    entry_symbol = "my_extension_init",
    minimum_os_versions = {"macos": "13.0", "ios": "16.0"},
)
```

An application whose minimum is lower fails with the extension's requirement, as it fails
when its minimum falls below the deployment target its source-built runtime was compiled
for. Extension editor libraries build for the execution platform and need no declaration.

## Debug symbols

Applications provide their extensions' libraries as
[debug symbols](platforms.md#debug-symbols) and package them stripped as Bazel's
`--strip` asks. That section names the compilation flags that give them file
and line numbers.

## Verify your integration

Use `godot_test` or autoload_gdunit's `gdunit_test` to exercise the
extension from GDScript in your project's test packages. A source-run smoke test
should load the extension and instantiate its registered classes; a test of
the exported pack also checks the staged extension libraries. See
[execution and tests](development.md#execution-and-tests).

Library metadata tests, exported-project execution and mobile package inspection
cover different things; loading the extension on Android or iOS needs a
runtime test of that application.
