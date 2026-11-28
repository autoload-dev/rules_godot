"""
Declare an operating system and consumer-selected CPU set as one export platform.

Example: `godot_export_platform(name = "android", operating_system = "android",
cpus = ["@platforms//cpu:armv7", "@platforms//cpu:aarch64"])`.

Select the resulting label with --platforms. C++ compiler, debug symbol, signing and
variant settings stay independent of it. See the platform guide for engine and SDK setup.
"""

load("//godot/private/config:settings.bzl", "export_platform_declarations")

def _export_platform_impl(
        name,
        visibility,
        operating_system,
        cpus,
        environment,
        parents,
        constraint_values,
        exec_properties):
    for declaration in export_platform_declarations(
        name,
        operating_system,
        cpus,
        package_relative_label = native.package_relative_label,
        environment = environment or None,
        parents = parents,
        constraint_values = constraint_values,
        exec_properties = exec_properties,
        visibility = visibility,
    ):
        native.platform(**declaration)

godot_export_platform = macro(
    doc = """
    Create an export platform and, for mobile, its private platform slices.

    A child platform, `platform(parents = [":android_arm64"])` for an export platform
    named `android_arm64`, keeps the export platform's operating system, CPUs
    and platform slices. The child's own constraints, flags and execution properties
    apply only to application packaging and a desktop runtime: content export, the
    project's extension libraries and mobile platform slices build for this export
    platform or its platform slices, and a desktop export platform is its own platform
    slice. Put properties those actions need on `parents`, `constraint_values` or
    `exec_properties` here. A child that sets another operating system, CPU or iOS
    environment fails analysis. The visibility applies to the export platform; its
    platform slices remain private.

    Example:
    ```starlark
    godot_export_platform(
        name = "android",
        operating_system = "android",
        cpus = ["@platforms//cpu:armv7", "@platforms//cpu:aarch64"],
    )
    ```
    """,
    implementation = _export_platform_impl,
    attrs = {
        "operating_system": attr.string(
            doc = """
            Operating system: linux, macos, android, ios or web. rules_godot calls the
            browser's operating system web; its constraint is @platforms//os:emscripten.
            """,
            mandatory = True,
            values = ["linux", "macos", "android", "ios", "web"],
            configurable = False,
        ),
        "cpus": attr.label_list(
            doc = """
            Nonempty unique list of `@platforms//cpu` constraint values Godot can express:
            `armv7`, `aarch64` (or its alias `arm64`), `x86_32`, `x86_64`, `riscv64` and
            `wasm32`. Desktops take one CPU, an iOS device `aarch64`, the iOS Simulator
            `aarch64` or `x86_64`, and the web exactly `wasm32`, which no other operating
            system takes. Whether a CPU builds is decided by the registered runtime components:
            an application for a CPU without one fails analysis.
            """,
            mandatory = True,
            configurable = False,
        ),
        "environment": attr.string(
            doc = "iOS device (default) or simulator; omit for other operating systems.",
            values = ["", "device", "simulator"],
            configurable = False,
        ),
        "parents": attr.label_list(
            doc = """
            At most one parent platform for custom properties every platform slice shares.
            The export platform's operating system, CPU, environment and mobile CPU flags
            replace its own.
            """,
            configurable = False,
        ),
        "constraint_values": attr.label_list(
            doc = """
            Additional constraints shared by the export platform and its platform slices.
            Operating system, CPU and iOS environment constraints are owned by this macro.
            """,
            configurable = False,
        ),
        "exec_properties": attr.string_dict(
            doc = "Execution properties shared by the export platform and every platform slice.",
            configurable = False,
        ),
    },
)
