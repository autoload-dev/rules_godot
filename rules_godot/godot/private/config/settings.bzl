"""
Export platform state and validation; not independent consumer flags.

Sections: CPU table and errors, Constraints and tags, Platform slices,
Dispatch conditions, Configured context.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

visibility(["//godot/..."])

OPERATING_SYSTEM = str(Label("//godot/private/config:operating_system"))

ENVIRONMENT = str(Label("//godot/private/config:environment"))

CPUS = str(Label("//godot/private/config:cpus"))

EXPORT_PLATFORM = str(Label("//godot/private/config:export_platform"))

PLATFORM_SLICES = str(Label("//godot/private/config:platform_slices"))

APPLICATION_CONTEXT = str(Label("//godot/private/config:application_context"))

# The build's --macos_minimum_os, JSON-encoded, that a macOS application's edge to its pack
# replaced with its own minimum; empty where no application did. The project context
# restores it, so a host test and a macOS application share the imports' configuration
# without dropping a minimum the build sets.
MACOS_MINIMUM_OS_OUTSIDE_APPLICATION = str(Label("//godot/private/config:macos_minimum_os_outside_application"))

# rules_android merges the uses-permission entries of library manifests only with this
# option. An Android application sets it on its edge; the application's edge to its pack
# resets it, so packs, their imports and native code stay in one configuration.
MERGE_ANDROID_MANIFEST_PERMISSIONS = "//command_line_option:merge_android_manifest_permissions"

TOOL = str(Label("//godot/private/config:tool"))

VARIANT = str(Label("//godot:variant"))

# ==== CPU table and errors ====================================================

# The CPUs Godot can express, keyed by Godot's CPU feature tag, the CPU name rules_godot
# uses internally. `constraint` is the canonical @platforms//cpu value and `aliases` the
# other labels that name it; `android_abi` is the Android ABI and `apple_cpus` the Apple split
# CPU per iOS environment, absent where the operating system has no such CPU. Godot's
# exporters, rules_android's aar_import and rules_android_ndk use the same correspondence.
CPU_TABLE = {
    "arm32": struct(
        constraint = Label("@platforms//cpu:armv7"),
        android_abi = "armeabi-v7a",
        apple_cpus = {},
    ),
    "arm64": struct(
        constraint = Label("@platforms//cpu:aarch64"),
        aliases = [Label("@platforms//cpu:arm64")],
        android_abi = "arm64-v8a",
        apple_cpus = {"device": "arm64", "simulator": "sim_arm64"},
    ),
    "x86_32": struct(
        constraint = Label("@platforms//cpu:x86_32"),
        android_abi = "x86",
        apple_cpus = {},
    ),
    "x86_64": struct(
        constraint = Label("@platforms//cpu:x86_64"),
        android_abi = "x86_64",
        apple_cpus = {"simulator": "x86_64"},
    ),
    "rv64": struct(
        constraint = Label("@platforms//cpu:riscv64"),
        android_abi = "riscv64",
        apple_cpus = {},
    ),
    # The web's CPU, through Emscripten's WebAssembly.
    "wasm32": struct(
        constraint = Label("@platforms//cpu:wasm32"),
        android_abi = "",
        apple_cpus = {},
    ),
}

_CPU_TAGS = {
    str(label): tag
    for tag, row in CPU_TABLE.items()
    for label in [row.constraint] + getattr(row, "aliases", [])
}

def cpu_tag(label):
    """
    Return the Godot CPU tag of a @platforms//cpu label, or None outside the CPU table.

    Args:
        label: A Label of a CPU constraint value.

    Returns:
        The CPU table key, or None.
    """
    return _CPU_TAGS.get(str(label))

def _cpus_error(cpus):
    """The error of a CPU list that is empty, repeats a CPU or names one outside the CPU table."""
    if not cpus or len({cpu: True for cpu in cpus}) != len(cpus):
        return "CPUs must be nonempty and duplicate-free"
    unknown = [cpu for cpu in cpus if cpu not in CPU_TABLE]
    if unknown:
        return "Unsupported CPU %s; expected one of %s" % (", ".join(unknown), ", ".join(CPU_TABLE))
    return ""

def _parents_error(parents):
    return "parents accepts at most one parent platform" if len(parents) > 1 else ""

def _ios_error(cpus, environment):
    """The error of an iOS environment that is unknown or has no CPU of cpus."""
    if environment not in [None, "device", "simulator"]:
        return "iOS environment must be device or simulator"
    environment = environment or "device"
    foreign = [cpu for cpu in cpus if environment not in CPU_TABLE[cpu].apple_cpus]
    if not foreign:
        return ""
    return "iOS %s has no CPU %s; it takes %s" % (
        environment,
        ", ".join([str(CPU_TABLE[cpu].constraint) for cpu in foreign]),
        ", ".join([str(row.constraint) for row in CPU_TABLE.values() if environment in row.apple_cpus]),
    )

def _web_error(operating_system, cpus):
    """The error of a web export platform without exactly wasm32, or another one with it."""
    web = operating_system == "web"
    if cpus == ["wasm32"] if web else "wasm32" not in cpus:
        return ""
    return "Web export platforms take exactly the CPU @platforms//cpu:wasm32, and only they do"

def _operating_system_error(operating_system, cpus, environment):
    """The error of an environment or a CPU count the operating system does not take."""
    if operating_system == "ios":
        return _ios_error(cpus, environment)
    if environment != None:
        return "environment is only valid for iOS"
    if operating_system in ["linux", "macos"] and len(cpus) != 1:
        return "Desktop export platforms require one CPU"
    return _web_error(operating_system, cpus)

# rules_godot's operating systems and their @platforms//os constraint. Godot's web
# platform is Emscripten's: @platforms has no web.
_OPERATING_SYSTEMS = {
    "linux": "linux",
    "macos": "macos",
    "android": "android",
    "ios": "ios",
    "web": "emscripten",
}

def export_platform_error(operating_system, cpus, environment, parents = []):
    """
    Return a declaration error, or empty for a valid export platform.

    Only facts of the operating system are errors here. Whether a runtime exists for a
    CPU is decided by toolchain resolution.

    Args:
        operating_system: Operating system name.
        cpus: CPU table keys.
        environment: iOS environment, or None for the default.
        parents: Common parent platform labels.

    Returns:
        Error text, or an empty string for a valid export platform.
    """
    if operating_system not in _OPERATING_SYSTEMS:
        return "Unsupported operating system for an export platform: %s" % operating_system
    return (
        _cpus_error(cpus) or
        _parents_error(parents) or
        _operating_system_error(operating_system, cpus, environment)
    )

# ==== Constraints and tags ====================================================

OPERATING_SYSTEM_CONSTRAINTS = {
    operating_system: Label("@platforms//os:" + constraint)
    for operating_system, constraint in _OPERATING_SYSTEMS.items()
}

CPU_CONSTRAINTS = {cpu: row.constraint for cpu, row in CPU_TABLE.items()}

# The web's threads: a property of the export platform, since they change the ABI of
# extensions, the engine's feature tags and what the host must serve.
THREADS_CONSTRAINT = Label("//godot/platforms:threads")

_NOTHREADS_CONSTRAINT = Label("//godot/platforms:nothreads")

def _thread_constraints(operating_system, threads):
    """A web export platform's threads constraint, explicit so a parent cannot set it."""
    if operating_system != "web":
        return []
    return [THREADS_CONSTRAINT if threads else _NOTHREADS_CONSTRAINT]

ENVIRONMENT_CONSTRAINTS = {
    environment: Label("@apple_support//constraints:" + environment)
    for environment in ["device", "simulator"]
}

# Feature tags whose value a platform slice's configuration establishes: the operating
# system, CPU, variant and iOS environment. Custom features cannot claim them,
# so that they cannot change which configured extension library Godot loads.
_RESERVED_FEATURE_TAGS = (
    OPERATING_SYSTEM_CONSTRAINTS.keys() +
    CPU_TABLE.keys() +
    ["debug", "release", "template_debug", "template_release"] +
    ENVIRONMENT_CONSTRAINTS.keys()
)

# Every feature tag Godot or the configuration sets: the reserved ones and Godot's own,
# some of which depend on run time or export options (texture formats, movie, threads).
# Custom features cannot claim them, and checks count them as present, since analysis
# cannot know them: https://docs.godotengine.org/en/stable/tutorials/export/feature_tags.html
ENGINE_FEATURE_TAGS = _RESERVED_FEATURE_TAGS + [
    "32",
    "64",
    "astc",
    "bptc",
    "bsd",
    "double",
    "editor",
    "editor_hint",
    "editor_runtime",
    "etc",
    "etc2",
    "linuxbsd",
    "mobile",
    "movie",
    "nothreads",
    "pc",
    "s3tc",
    "single",
    "template",
    "threads",
    "web",
    "web_extensions",
    "web_noextensions",
    "windows",
]

def entry_features(custom_features):
    """
    Return the feature tags a program entry can have, as override_applies takes them.

    Args:
        custom_features: The program entry's custom features, which are exact.

    Returns:
        The tags Godot or the configuration sets, and the custom features.
    """
    return ENGINE_FEATURE_TAGS + custom_features

def ios_cpu(environment, cpu):
    """
    Return Bazel's Apple split CPU for one iOS platform slice.

    Args:
        environment: iOS environment, device or simulator.
        cpu: CPU table key.

    Returns:
        The CPU without the ios_ prefix, as --ios_multi_cpus spells it.
    """
    return CPU_TABLE[cpu].apple_cpus[environment]

# ==== Platform slices =========================================================

_APPLE = Label("@apple_support//constraints:apple")

# rules_android's Starlark setting behind --android_platforms.
ANDROID_PLATFORMS_SETTING = str(Label("@rules_android//flags:android_platforms"))

# The apple_support platform setting of each Apple split CPU.
_APPLE_FLAGS = {
    "arm64": str(Label("@apple_support//platforms:ios_arm64_platform")),
    "sim_arm64": str(Label("@apple_support//platforms:ios_sim_arm64_platform")),
    "x86_64": str(Label("@apple_support//platforms:ios_x86_64_platform")),
}

def _cpu_tags(cpus, package_relative_label, _fail):
    """The CPU table keys of the declared CPUs; None after failing for one outside the table."""
    tags = []
    for cpu in cpus:
        tag = cpu_tag(package_relative_label(cpu))
        if not tag:
            _fail("Unsupported CPU %s; godot_export_platform takes %s" % (
                package_relative_label(cpu),
                ", ".join([str(row.constraint) for row in CPU_TABLE.values()]),
            ))
            return None
        tags.append(tag)
    return tags

def _names_owned_constraint(constraint_values, package_relative_label):
    """Whether constraint_values name an operating system, CPU or iOS environment constraint."""
    owned = [str(x) for x in OPERATING_SYSTEM_CONSTRAINTS.values() + CPU_CONSTRAINTS.values() + ENVIRONMENT_CONSTRAINTS.values()]
    return any([str(package_relative_label(c)) in owned for c in constraint_values])

def platform_slice_name(export_platform, cpu):
    """
    Return the target name of an export platform's platform slice for a CPU.

    Args:
        export_platform: The export platform's target name, such as ios_sim_x86_64.
        cpu: The CPU table key, such as x86_64.

    Returns:
        The platform slice's target name in the export platform's package.
    """
    return export_platform + ".platform_slice_" + cpu

def _platform_slices(declared, package_relative_label):
    """
    The export platform's facts and the labels of its platform slices.

    Generated platform slice names are deterministic private targets, not public
    entrypoints; callers select only `name`. A desktop export platform has one CPU and no
    split flags, so it is its own platform slice; a separate platform slice would build
    its native code twice.

    Args:
        declared: struct of the export platform's name, operating_system, sorted cpus and
            declared environment.
        package_relative_label: native.package_relative_label of the declaring package.

    Returns:
        A struct of operating_system, cpus (sorted CPU table keys), environment (device or
        simulator on iOS, otherwise empty), desktop, export_platform and platform_slices,
        label strings.
    """
    export_platform = str(package_relative_label(":" + declared.name))

    # The web, like a desktop, has one CPU and no split.
    desktop = declared.operating_system in ["linux", "macos", "web"]
    ios = declared.operating_system == "ios"
    return struct(
        operating_system = declared.operating_system,
        cpus = declared.cpus,
        environment = (declared.environment or "device") if ios else "",
        desktop = desktop,
        export_platform = export_platform,
        platform_slices = [export_platform] if desktop else [
            str(package_relative_label(":" + platform_slice_name(declared.name, cpu)))
            for cpu in declared.cpus
        ],
    )

def _platform_flags(platform):
    """The flags every platform of the export platform sets: its export platform state."""
    return [
        "--%s=%s" % (OPERATING_SYSTEM, platform.operating_system),
        "--%s=%s" % (ENVIRONMENT, platform.environment),
        "--%s=%s" % (CPUS, ",".join(platform.cpus)),
        "--%s=%s" % (EXPORT_PLATFORM, platform.export_platform),
        "--%s=%s" % (PLATFORM_SLICES, ",".join(platform.platform_slices)),
    ]

def _base_constraints(platform, constraint_values):
    """The constraints every platform of the export platform has, its CPU's aside."""
    constraints = list(constraint_values) + [OPERATING_SYSTEM_CONSTRAINTS[platform.operating_system]]
    if platform.operating_system in ["macos", "ios"]:
        constraints.append(_APPLE)
    if platform.environment:
        constraints.append(ENVIRONMENT_CONSTRAINTS[platform.environment])
    return constraints

def _split_flags(platform):
    """
    The flags of the public export platform that split mobile targets into platform slices.

    rules_android's MODULE flag_alias redirects Bazel's built-in --android_platforms to its
    Starlark setting. It is set explicitly; clearing it would erase the request, and its
    nonempty value takes precedence over any stale built-in list. platform_slice_options in
    native.bzl sets the same options per platform slice in transitions.
    """
    if platform.operating_system == "android":
        return ["--%s=%s" % (ANDROID_PLATFORMS_SETTING, ",".join(platform.platform_slices))]
    if platform.operating_system != "ios":
        return []
    environment = platform.environment
    return ["--ios_multi_cpus=" + ",".join([ios_cpu(environment, cpu) for cpu in platform.cpus])] + [
        "--%s=%s" % (_APPLE_FLAGS[ios_cpu(environment, cpu)], platform_slice)
        for cpu, platform_slice in zip(platform.cpus, platform.platform_slices)
    ]

def export_platform_declarations(
        name,
        operating_system,
        cpus,
        *,
        package_relative_label,
        environment = None,
        parents = [],
        constraint_values = [],
        exec_properties = {},
        visibility = None,
        threads = False,
        _fail = fail):
    """
    Return the platforms of one export platform, as native.platform keyword arguments.

    The mobile platform slices come first, the public export platform last.

    Args:
        name: Public export platform target name.
        operating_system: Operating system: linux, macos, android, ios or web.
        cpus: @platforms//cpu labels from the CPU table.
        package_relative_label: native.package_relative_label of the declaring package.
        environment: iOS environment, or None for the default.
        parents: At most one parent platform label.
        constraint_values: Additional constraints of every platform.
        exec_properties: Execution properties of every platform.
        threads: Whether a web export platform runs threads.
        visibility: Visibility of the public export platform.
        _fail: Called with the declaration error; the function then returns no platforms.

    Returns:
        List of native.platform keyword argument dictionaries.
    """
    tags = _cpu_tags(cpus, package_relative_label, _fail)
    if tags == None:
        return []
    error = export_platform_error(operating_system, tags, environment, parents)
    if error:
        _fail(error)
        return []
    if threads and operating_system != "web":
        _fail("threads applies to web export platforms only")
        return []
    if _names_owned_constraint(constraint_values, package_relative_label):
        _fail("Operating system, CPU and iOS environment constraints are owned by godot_export_platform")
        return []
    platform = _platform_slices(
        struct(name = name, operating_system = operating_system, cpus = sorted(tags), environment = environment),
        package_relative_label,
    )
    flags = _platform_flags(platform)
    base_constraints = _base_constraints(platform, constraint_values) + _thread_constraints(operating_system, threads)
    declarations = [
        {
            "name": package_relative_label(platform_slice).name,
            "constraint_values": base_constraints + [CPU_CONSTRAINTS[cpu]],
            "exec_properties": exec_properties,
            "flags": flags,
            "parents": parents,
            "visibility": ["//visibility:private"],
        }
        for cpu, platform_slice in zip(platform.cpus, [] if platform.desktop else platform.platform_slices)
    ]
    declarations.append({
        "name": name,
        "constraint_values": base_constraints + [CPU_CONSTRAINTS[platform.cpus[0]]],
        "exec_properties": exec_properties,
        "flags": flags + _split_flags(platform),
        "parents": parents,
        "visibility": visibility,
    })
    return declarations

# ==== Dispatch conditions =====================================================

# The flag values of a desktop target platform without an export platform.
_UNEXPORTED = {
    ":operating_system": "",
    ":environment": "",
    ":cpus": "",
    ":export_platform": "",
    ":platform_slices": "",
}

def _exported_conditions(operating_system, operating_system_constraint):
    """The dispatch conditions of an operating system's export platforms: one per environment and CPU it takes."""
    result = {}
    for environment in ["device", "simulator"] if operating_system == "ios" else [None]:
        prefix = "ios_" + environment if environment else operating_system
        constraints = [operating_system_constraint] + ([ENVIRONMENT_CONSTRAINTS[environment]] if environment else [])
        for cpu in CPU_TABLE:
            if not export_platform_error(operating_system, [cpu], environment):
                result[prefix + "_" + cpu] = struct(
                    operating_system = operating_system,
                    constraint_values = constraints + [CPU_CONSTRAINTS[cpu]],
                    flag_values = {
                        ":operating_system": operating_system,
                        ":environment": environment or "",
                    },
                )
    return result

def _unexported_conditions(operating_system, operating_system_constraint):
    """The dispatch conditions of a desktop target platform without an export platform, one per CPU."""
    if operating_system not in ["linux", "macos"]:
        return {}
    return {
        "unexported_%s_%s" % (operating_system, cpu): struct(
            operating_system = operating_system,
            constraint_values = [operating_system_constraint, cpu_constraint],
            flag_values = _UNEXPORTED,
        )
        for cpu, cpu_constraint in CPU_CONSTRAINTS.items()
    }

def _dispatch_conditions():
    result = {}
    for operating_system, constraint in OPERATING_SYSTEM_CONSTRAINTS.items():
        result |= _exported_conditions(operating_system, constraint)
        result |= _unexported_conditions(operating_system, constraint)
    return result

# Finite dispatch conditions, one per operating system, iOS environment and effective
# platform slice CPU, keyed by their config_setting name in this package. They reject
# effective operating system/CPU/environment contradictions before an application backend
# enters analysis; configured_context validates the declared CPU set.
DISPATCH_CONDITIONS = _dispatch_conditions()

# ==== Configured context ======================================================

# The constraint values target_platform() reads, as private rule attributes.
PLATFORM_ATTRS = {
    "_operating_system_" + name: attr.label(default = label)
    for name, label in OPERATING_SYSTEM_CONSTRAINTS.items()
} | {
    "_cpu_" + name: attr.label(default = label)
    for name, label in CPU_CONSTRAINTS.items()
} | {
    "_environment_" + name: attr.label(default = label)
    for name, label in ENVIRONMENT_CONSTRAINTS.items()
} | {"_threads": attr.label(default = THREADS_CONSTRAINT)}

def target_platform(ctx):
    """
    Return the operating system, CPU and iOS environment of the target platform.

    Args:
        ctx: Rule context with PLATFORM_ATTRS.

    Returns:
        A struct of operating_system and cpu (CPU table key), each empty where the
        platform has none rules_godot knows, environment (device or simulator on
        iOS, otherwise empty) and threads (whether a web platform runs threads).
    """

    def first(kind, names):
        found = [
            name
            for name in names
            if ctx.target_platform_has_constraint(getattr(ctx.attr, "_%s_%s" % (kind, name))[platform_common.ConstraintValueInfo])
        ]
        return found[0] if found else ""

    operating_system = first("operating_system", OPERATING_SYSTEM_CONSTRAINTS)
    return struct(
        operating_system = operating_system,
        cpu = first("cpu", CPU_CONSTRAINTS),
        environment = first("environment", ENVIRONMENT_CONSTRAINTS) if operating_system == "ios" else "",
        threads = operating_system == "web" and ctx.target_platform_has_constraint(
            ctx.attr._threads[platform_common.ConstraintValueInfo],
        ),
    )

def context_attrs():
    """
    Return attributes for export platform state and constraint lookups.

    Returns:
        Rule attribute dictionary for configured_context.
    """
    return PLATFORM_ATTRS | {
        "_operating_system": attr.label(default = Label("//godot/private/config:operating_system")),
        "_environment": attr.label(default = Label("//godot/private/config:environment")),
        "_cpus": attr.label(default = Label("//godot/private/config:cpus")),
        "_export_platform": attr.label(default = Label("//godot/private/config:export_platform")),
        "_platform_slices": attr.label(default = Label("//godot/private/config:platform_slices")),
        "_application_context": attr.label(default = Label("//godot/private/config:application_context")),
    }

def _declared_state(ctx):
    """The export platform state the flags declare: its operating system and environment, CPUs and platform slices."""
    return struct(
        system = (
            ctx.attr._operating_system[BuildSettingInfo].value,
            ctx.attr._environment[BuildSettingInfo].value,
        ),
        cpus = ctx.attr._cpus[BuildSettingInfo].value,
        platform_slices = ctx.attr._platform_slices[BuildSettingInfo].value,
    )

def _split_list(value):
    return value.split(",") if value else []

def _consistent_slices(cpus, platform_slices, cpu):
    """Whether CPUs are sorted, with one platform slice each, among them the current CPU."""
    if cpus != sorted(cpus) or cpu not in cpus:
        return False
    return len(platform_slices) == len(cpus)

def _exported_slices(ctx, platform):
    """The CPUs and platform slices of the declared export platform, validated against the target platform."""
    declared = _declared_state(ctx)
    effective = (platform.operating_system, platform.environment)
    if declared.system != effective:
        fail("Export platform for %s conflicts with effective target platform %s at %s" % (
            " ".join([part for part in declared.system if part]),
            " ".join([part for part in effective if part]),
            ctx.label,
        ))
    cpus = _split_list(declared.cpus)
    platform_slices = _split_list(declared.platform_slices)
    error = export_platform_error(
        platform.operating_system,
        cpus,
        platform.environment if platform.operating_system == "ios" else None,
    )
    if error or not _consistent_slices(cpus, platform_slices, platform.cpu):
        fail("Invalid export platform context at %s: %s" % (ctx.label, error or "inconsistent CPU/platform slice metadata"))
    return struct(cpus = cpus, platform_slices = platform_slices)

def _unexported_slices(ctx, platform):
    """The CPU of a desktop target platform without an export platform, which may declare none."""
    declared = _declared_state(ctx)
    if declared.system != ("", "") or (declared.cpus + declared.platform_slices):
        fail("A target platform without an export platform cannot carry export platform metadata at %s" % ctx.label)
    if platform.operating_system in ["android", "ios"]:
        fail("Select an export platform for the mobile operating system %s" % platform.operating_system)
    return struct(cpus = [platform.cpu] if platform.cpu else [], platform_slices = [])

def configured_context(ctx):
    """
    Resolve the export platform and validate it against the current platform slice.

    Args:
        ctx: Rule context with context_attrs.

    Returns:
        Validated operating system, platform slice, export platform and application context struct.
    """
    platform = target_platform(ctx)
    operating_system = platform.operating_system
    cpu = platform.cpu
    environment = platform.environment
    export_platform = ctx.attr._export_platform[BuildSettingInfo].value
    slices = _exported_slices(ctx, platform) if export_platform else _unexported_slices(ctx, platform)
    cpus = slices.cpus
    platform_slices = slices.platform_slices
    if operating_system and not cpu:
        fail("Unsupported CPU for operating system %s at %s" % (operating_system, ctx.label))
    return struct(
        threads = platform.threads,
        operating_system = operating_system,
        preset_platform = {"linux": "Linux", "macos": "macOS", "android": "Android", "ios": "iOS", "web": "Web"}.get(operating_system, ""),
        cpus = cpus,
        cpu = cpu,
        environment = environment,
        export_platform = export_platform,
        platform_slices = platform_slices,
        application_context = json.decode(ctx.attr._application_context[BuildSettingInfo].value),
    )
