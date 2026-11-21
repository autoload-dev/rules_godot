# Sentry

[Sentry for Godot](https://github.com/getsentry/sentry-godot) for Godot applications built
with Bazel: crash and error reporting on Android, iOS, Linux and macOS.

| Add-on | Label | Platforms |
| --- | --- | --- |
| Sentry | `@autoload_sentry//sentry` | Android, iOS, Linux, macOS; the editor on Linux and macOS |

## Setup

Depend on the module, let it add the Sentry Android SDK to the application's Maven graph, and
add the add-on to a project's resources:

```starlark
bazel_dep(name = "autoload_sentry", version = "0.1.0")

maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(
    name = "maven",
    known_contributing_modules = ["autoload_rules_godot", "autoload_sentry", "protobuf"],
    lock_file = "//:maven_install.json",
    ...
)
```

```starlark
godot_resources(
    name = "main",
    srcs = ["main.gd"],
    deps = ["@autoload_sentry//sentry"],
)
```

Configure Sentry with the `sentry/*` settings in `project.godot`, at least `options/dsn`.
GDScript then calls the class `SentrySDK`:

```gdscript
SentrySDK.capture_message("Hello from Godot")
```

## Design

- The add-on is Sentry for Godot's prebuilt release (`third_party/sentry_godot.BUILD.bazel`),
  not a build from source. A `godot_extension` replaces the release's descriptor: release
  builds take the release libraries, debug builds, source runs and the editor the debug
  libraries, as Sentry's own descriptor maps them.
- What Sentry's editor export plugin adds to a Gradle or Xcode build is declared instead: on
  Android the Godot plugin and `io.sentry:sentry-android` in `platform_deps`, on iOS the
  `SentryObjC` framework, embedded beside the extension's framework without linking.
- On Linux, Sentry writes native crash reports with its Crashpad handler, which the
  extension declares as `data`: runs and the editor find it at its path in the release,
  applications beside their executable. Sentry's Linux library needs the system's
  `libcurl.so.4`.
- The release's repository holds only filegroups and imports; the `godot_addon` in this
  module places its user-feedback UI.
- Windows and the web are not wired, since rules_godot builds no applications for them.

The example application in `examples/` consumes the module as applications do. Its headless
test initializes Sentry and captures a message.
