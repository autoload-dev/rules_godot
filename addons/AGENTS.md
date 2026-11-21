# Add-ons

Each directory here is a Bazel module of its own, `addons/<module>` named
`autoload_<module>`, which applications consume like any other module; the
[README](README.md) lists them. A module has its own `MODULE.bazel`, README, version and
release tags `<module>-v<version>`.

Create modules and add-ons with the generator, never by copying another module:

```sh
mise run addon:new <module>                   # a module with one add-on, <module>
mise run addon:new <module> --addon <addon>   # one more add-on in a module
mise run addons:generate                      # then: README table and .bcr templates
```

It writes [tools/addons/template](../tools/addons/template), which builds in every lane from
the start. Improve the template, not one module, when a pattern should hold for all of them.
A new add-on gets its own module, unless it must be versioned with others, such as products
that share one SDK.

# Module layout

The conventions check enforces it (RG015, `docs/public/conventions.md`):

- `MODULE.bazel`, `README.md` (its first paragraph is the README table's description),
  `REPO.bazel`, `BUILD.bazel`, `.gitignore`, `.gitattributes`, `.bazelversion`.
- `.bazelrc` imports [module.bazelrc](module.bazelrc) and `examples/.bazelrc` imports
  [examples.bazelrc](examples.bazelrc); each adds only its BuildBuddy tag. Settings for all
  modules go in those two files.
- `addon.pkl` names the lanes that verify the module and the hosts of its host lane, such
  as `lanes = List("host")` and `hosts = List("macos")`. hk.pkl reads it; nothing outside the
  module lists the module.
- `presubmit.yml`: the Bazel Central Registry's checks of a release.
  `mise run addons:generate` copies it to `.bcr/addons/<module>/` beside the generated
  templates. Never edit `.bcr/addons/`, `.bcr/config.yml` or the README table by hand.
- `examples/`: an independent root module with the module's example applications in
  `projects/<name>/`, each with the targets `app`, `edit` and `pack`. It consumes the module
  like an external application (`local_path_override` to `..`) and the rules of this
  repository (`local_path_override` to `../../..`), so an add-on always builds against the
  rules it is changed with.
- Each add-on `<module>/<addon>/` is a `godot_addon` whose `godot_cc_extension` selects one
  backend per platform below `native/`, which holds the platform-independent API:
  `native/backends/android` (C++ over JNI to a Godot Android plugin in Java, carried in
  `platform_deps`), `native/backends/apple` (Objective-C++ against the Apple SDK) and
  `native/backends/unsupported` for the editor and desktop platforms. Editor builds never
  fetch an SDK.
- Header libraries set `include_prefix = "<module>"` and `strip_include_prefix = "/"`, so
  includes read `<module>/<addon>/native/...`.
- Every extension target has a name unique across all add-ons and applications: on iOS the
  target name becomes the framework or library name, and those share one directory. The
  generator names it `<module>_<addon>`, or `<module>_extension` for an add-on named like
  its module.
- Android dependencies come from Maven: a module's `maven.install` merges into the
  examples' `@maven`, which lists the module in `known_contributing_modules`. After changing
  artifacts, repin from the module's `examples/` with `REPIN=1 bazel run @maven//:pin`.
- Never commit or print secrets, signing material or real service configurations; local
  provisioning profiles stay in the gitignored `<module>/examples/signing/`.

# Lanes

The same tasks verify every module, from its `examples/` (`tools/addons/lanes.py`):

```sh
mise run addon:host <module>      # module tests and example targets but apps, editor and desktop
mise run addon:android <module>   # each example project's app for Android
mise run addon:ios <module>       # each example project's app for the iOS Simulator
```

`host` runs `bazel test` over `@autoload_<module>//...` and all of `examples/`, so tests in
the module or its examples need no registration. Tests that need more than the module's own
dependencies, such as Python, live in `examples/tests/`, where the examples' module declares
what they use; the release archive leaves them out with the examples. CI selects a module's
lanes for changes in its directory or the shared `addons/*.bazelrc`; `mise run
addon:template <lane>` checks the template the same way.

For iOS device runs, add `--define=ios_signing=local` with a profile in
`examples/signing/`, install with `xcrun devicectl` and check the log for crashes.
