# Fixtures of godot/platforms/private/tests/engine_probe

Each section names a fixture and what it reproduces for the tests of this package.

## probe_project_with_native_extensions

One project with a godot-cpp extension (`BazelNode`, entry `example_library_init`) and a C
ABI extension (`libhello.so`), packaged as Android applications and an iOS
application and unsigned device link for whichever engine the test's configuration
selects: the prebuilt 4.8 beta, the source-built beta with the `bazel_probe` module and
engine patch of `godot/engine/private/tests/fixtures/source_build`, or the source-built 4.7
engines.

Its `main/main.gd` is the fixture of mobile runtime acceptance in the verification policy
(the repository's `docs/internal/verification.md`, verification kinds):
on a device or Simulator it checks the engine version, `BazelNode` and, when started with
`--expect-source`, `BazelProbe` and the patched engine name. No test runs it.
