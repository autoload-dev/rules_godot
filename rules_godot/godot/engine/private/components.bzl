"""
Engine components: one editor or runtime slot with its provenance and toolchain registration.

Sections: Component provenance, Editor component, Runtime component, resolved_runtime,
Component macros.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//godot/engine/private:generator.bzl", "GodotEngineVersionInfo")
load("//godot/engine/private:optimization.bzl", "ENGINE_SETTINGS_ATTRS", "engine_settings", "require_tunable_runtime")
load("//godot/engine/private:prebuilt.bzl", "PrebuiltArtifactInfo")
load("//godot/engine/private:registration.bzl", "component_toolchains")
load("//godot/engine/private:resolution.bzl", "RUNTIME_TOOLCHAIN_TYPE", "engine_toolchain")
load("//godot/platforms/private:android_runtime_bridge.bzl", "ANDROID_PAYLOAD_ASPECTS")
load("//godot/platforms/private:ios_runtime_bridge.bzl", "IOS_PAYLOAD_ASPECTS")
load("//godot/private:providers.bzl", "GodotComponentInfo", "GodotRuntimeInfo")
load("//godot/private:versions.bzl", "require_supported_godot_version", "require_supported_source_version")
load("//godot/private/config:settings.bzl", "CPU_TABLE")

visibility(["//godot/..."])

# ==== Component provenance ====================================================

def _fields(value):
    return {name: getattr(value, name) for name in dir(value) if name not in ["to_json", "to_proto"]}

def _forwarded(target, role, label, engine):
    """
    Return the toolchain value of a payload that is itself a component, or None.

    The forwarded payload belongs to the forwarding component's engine, which its
    provenance names.
    """
    if platform_common.ToolchainInfo not in target:
        return None
    godot = getattr(target[platform_common.ToolchainInfo], "godot", None)
    if not godot or getattr(godot, "role", None) == None:
        fail("%s payload %s provides a foreign ToolchainInfo" % (label, target.label))
    if godot.role != role:
        fail("%s payload %s is a %s component, not a %s component" % (label, target.label, godot.role, role))
    provenance = GodotComponentInfo(**(_fields(godot.provenance) | {"engine": engine}))
    return struct(**(_fields(godot) | {"provenance": provenance}))

def _require_slot(ctx, payload, facts):
    """
    Fail when a payload's own slot facts contradict the component's declared slot.

    Args:
        ctx: Rule context of the component.
        payload: Label of the payload, for the diagnostic.
        facts: dict of attribute name to the payload's value; empty values are unknown.
    """
    for name, value in facts.items():
        declared = getattr(ctx.attr, name, "")
        if name == "cpu":
            # A universal macOS template fills every macOS CPU slot.
            value = "" if value == "universal" else value
        if value and declared and value != declared:
            fail("%s: payload %s is for %s %r, but the component declares %r" % (
                ctx.label,
                payload,
                name,
                value,
                declared,
            ))

def _require_forwarded_slot(ctx, target, godot):
    facts = {"platform": godot.provenance.platform, "cpu": godot.provenance.cpu}
    if godot.role == "runtime":
        facts["environment"] = godot.provenance.environment
        facts["variant"] = godot.provenance.variant
    _require_slot(ctx, target.label, facts)

def _require_version(version, kind):
    if kind == "source":
        require_supported_source_version(version)
    else:
        require_supported_godot_version(version)

def _artifact(target):
    """The archive digest of a prebuilt payload, or empty when the payload names none."""
    return target[PrebuiltArtifactInfo].digest if PrebuiltArtifactInfo in target else ""

def _producer(target):
    """Source-recipe metadata of a payload, or None for prebuilt and opaque payloads."""
    return target[GodotEngineVersionInfo] if GodotEngineVersionInfo in target else None

def _payload_facts(ctx, target, runtime = None):
    """
    The version, kind and origin of a payload that is no component.

    The version comes from the payload's GodotRuntimeInfo, else from its source recipe,
    else from the component. An unsupported version fails.
    """
    producer = _producer(target)
    source_runtime = runtime and runtime.facts_source == "source"
    kind = "source" if producer or source_runtime else "prebuilt"
    if runtime:
        version = runtime.version
    else:
        version = producer.canonical_version if producer else ctx.attr.version
    _require_version(version, kind)
    return struct(
        version = version,
        kind = kind,
        origin = runtime.origin if runtime else str(target.label),
        producer = producer,
        artifact_digest = _artifact(target),
    )

def _provenance(ctx, role, payload):
    producer = payload.producer
    return GodotComponentInfo(
        component = str(ctx.label),
        engine = ctx.attr.engine,
        role = role,
        platform = ctx.attr.platform,
        cpu = ctx.attr.cpu,
        environment = getattr(ctx.attr, "environment", ""),
        variant = getattr(ctx.attr, "variant", ""),
        version = payload.version,
        kind = payload.kind,
        # The declared origin describes the component; the payload's is the fallback.
        origin = ctx.attr.origin or payload.origin,
        # A producer or prebuilt payload names its own digest; an opaque payload, such as
        # an XCFramework or AAR import, takes the declared one.
        digest = producer.digest if producer else (payload.artifact_digest or getattr(ctx.attr, "digest", "")),
        customizations = producer.customizations if producer else {},
        renderers = producer.renderers if producer else None,
    )

# ==== Editor component ========================================================

def _editor_payload(ctx, target):
    """The toolchain value of an editor payload that is no component."""
    info = target[DefaultInfo]
    if not info.files_to_run or not info.files_to_run.executable:
        fail("%s editor %s must be an executable target" % (ctx.label, target.label))
    payload = _payload_facts(ctx, target)
    return struct(
        role = "editor",
        editor = info.files_to_run,
        files = depset(transitive = [info.files, info.default_runfiles.files]),
        version = payload.version,
        provenance = _provenance(ctx, "editor", payload),
    )

def _editor_component_impl(ctx):
    target = ctx.attr.editor
    godot = _forwarded(target, "editor", ctx.label, ctx.attr.engine)
    if godot:
        _require_forwarded_slot(ctx, target, godot)
    else:
        godot = _editor_payload(ctx, target)
    return [
        platform_common.ToolchainInfo(godot = godot),
        godot.provenance,
        DefaultInfo(files = godot.files),
    ]

_editor_component = rule(
    implementation = _editor_component_impl,
    attrs = {
        "editor": attr.label(mandatory = True, allow_files = True, cfg = "exec"),
        "platform": attr.string(mandatory = True),
        "cpu": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "origin": attr.string(),
        "engine": attr.string(),
    },
)

# ==== Runtime component =======================================================

def _declared_runtime(ctx, target):
    """GodotRuntimeInfo for a plain desktop template file without producer metadata."""
    files = target[DefaultInfo].files
    payload = files.to_list()
    if len(payload) != 1:
        fail("%s desktop runtime %s must be one template file or carry GodotRuntimeInfo" % (ctx.label, target.label))
    return GodotRuntimeInfo(
        executable = payload[0],
        files = files,
        platform = ctx.attr.platform,
        cpu = ctx.attr.cpu,
        environment = "",
        facts_source = "declared",
        origin = str(target.label),
        version = ctx.attr.version,
        bundle_files = {},
        variant = ctx.attr.variant,
        debug_symbols = None,
        minimum_os = "",
    )

# The provider each runtime bridge forwards to rules_android or rules_apple, and what
# supplies it.
_MOBILE_PAYLOAD_PROVIDERS = {
    "android": (JavaInfo, "JavaInfo", "a godot_android_runtime"),
    "ios": (CcInfo, "CcInfo", "an XCFramework import or a source recipe's :engine_library"),
}

def _require_mobile_payload(ctx, target):
    contract = _MOBILE_PAYLOAD_PROVIDERS.get(ctx.attr.platform)
    if contract and contract[0] not in target:
        fail("%s: the %s runtime payload %s has no %s; use %s" % (
            ctx.label,
            ctx.attr.platform,
            target.label,
            contract[1],
            contract[2],
        ))

def _payload_runtime(ctx, target):
    """
    The GodotRuntimeInfo of a runtime payload, or None for a mobile payload without one.

    A payload's own GodotRuntimeInfo must fill the declared slot. A plain desktop template
    file gets one from the declared slot.
    """
    if GodotRuntimeInfo in target:
        runtime = target[GodotRuntimeInfo]
        _require_slot(ctx, target.label, {
            "platform": runtime.platform,
            "cpu": runtime.cpu,
            "environment": runtime.environment,
            "variant": runtime.variant,
        })
        return runtime
    if ctx.attr.platform in ["linux", "macos"]:
        return _declared_runtime(ctx, target)
    return None

def _runtime_payload(ctx, target):
    """The toolchain value of a runtime payload that is no component."""
    _require_mobile_payload(ctx, target)
    runtime = _payload_runtime(ctx, target)
    payload = _payload_facts(ctx, target, runtime)
    return struct(
        role = "runtime",
        payload = target,
        runtime = runtime,
        files = target[DefaultInfo].files,
        version = payload.version,
        provenance = _provenance(ctx, "runtime", payload),
    )

def _runtime_component_impl(ctx):
    target = ctx.attr.runtime
    godot = _forwarded(target, "runtime", ctx.label, ctx.attr.engine)
    if godot:
        _require_forwarded_slot(ctx, target, godot)
    else:
        godot = _runtime_payload(ctx, target)
    return [
        platform_common.ToolchainInfo(godot = godot),
        godot.provenance,
        DefaultInfo(files = godot.files),
    ]

_RUNTIME_ATTRS = {
    "engine": attr.string(),
    "platform": attr.string(mandatory = True),
    "cpu": attr.string(mandatory = True),
    "environment": attr.string(),
    "variant": attr.string(mandatory = True),
    "version": attr.string(mandatory = True),
    "origin": attr.string(),
    "digest": attr.string(),
}

_runtime_component = rule(
    implementation = _runtime_component_impl,
    attrs = _RUNTIME_ATTRS | {"runtime": attr.label(mandatory = True, allow_files = True)},
)

# Android payloads replay rules_android's aspects before they enter ToolchainInfo.
_android_runtime_component = rule(
    implementation = _runtime_component_impl,
    attrs = _RUNTIME_ATTRS | {
        "runtime": attr.label(mandatory = True, allow_files = True, aspects = ANDROID_PAYLOAD_ASPECTS),
    },
)

# iOS payloads replay rules_apple's propagation aspects before they enter ToolchainInfo.
_ios_runtime_component = rule(
    implementation = _runtime_component_impl,
    attrs = _RUNTIME_ATTRS | {
        "runtime": attr.label(mandatory = True, allow_files = True, aspects = IOS_PAYLOAD_ASPECTS),
    },
)

# ==== resolved_runtime ========================================================

def _resolved_runtime_impl(ctx):
    godot = engine_toolchain(ctx, "runtime")
    require_tunable_runtime(ctx.label, ctx.attr, godot.provenance)
    if not godot.runtime:
        fail("%s: the selected runtime component %s has no GodotRuntimeInfo for desktop packaging" % (
            ctx.label,
            godot.provenance.component,
        ))
    return [godot.runtime, godot.provenance, DefaultInfo(files = godot.runtime.files)]

resolved_runtime = rule(
    doc = "Forward the GodotRuntimeInfo of the runtime component resolved in this configuration.",
    implementation = _resolved_runtime_impl,
    toolchains = [config_common.toolchain_type(RUNTIME_TOOLCHAIN_TYPE, mandatory = False)],
    attrs = ENGINE_SETTINGS_ATTRS,
    cfg = engine_settings,
)

# ==== Component macros ========================================================

def _provenance_engine(engine, default_engine):
    """The engine a component's provenance names: none for the default engine, as packs record it."""
    return "" if default_engine else engine

def _editor_macro_impl(name, visibility, editor, platform, cpu, version, origin, engine, default_engine, tags):
    _editor_component(
        name = name,
        editor = editor,
        platform = platform,
        cpu = cpu,
        version = version,
        origin = origin,
        engine = _provenance_engine(engine, default_engine),
        visibility = visibility,
        tags = tags,
    )
    component_toolchains(
        name = name + ".toolchain",
        component = ":" + name,
        role = "editor",
        platform = platform,
        cpu = cpu,
        engine = engine,
        default_engine = default_engine,
        visibility = visibility,
        tags = tags,
    )

def runtime_slot_error(name, platform, environment, _fail = fail):
    """
    Check the iOS environment of a godot_runtime_component's slot.

    Args:
        name: Name of the godot_runtime_component.
        platform: Its platform attribute.
        environment: Its environment attribute, empty when unset.
        _fail: Called with the error; the function then returns.
    """
    if platform == "ios" and environment not in ["device", "simulator"]:
        _fail("%s: iOS runtimes require environment = device or simulator" % name)
        return
    if platform != "ios" and environment:
        _fail("%s: environment is only valid for iOS runtimes" % name)
        return

def _runtime_macro_impl(name, visibility, runtime, platform, cpu, variant, version, environment, origin, digest, engine, default_engine, untuned_only, tags):
    runtime_slot_error(name, platform, environment)
    component = {
        "android": _android_runtime_component,
        "ios": _ios_runtime_component,
    }.get(platform, _runtime_component)
    component(
        name = name,
        runtime = runtime,
        platform = platform,
        cpu = cpu,
        environment = environment,
        variant = variant,
        version = version,
        origin = origin,
        digest = digest,
        engine = _provenance_engine(engine, default_engine),
        visibility = visibility,
        tags = tags,
    )
    component_toolchains(
        name = name + ".toolchain",
        component = ":" + name,
        role = "runtime",
        platform = platform,
        cpu = cpu,
        environment = environment,
        variant = variant,
        engine = engine,
        default_engine = default_engine,
        untuned_only = untuned_only,
        visibility = visibility,
        tags = tags,
    )

_COMMON = {
    "cpu": attr.string(
        doc = "CPU of the slot as Godot's CPU tag: arm32, arm64, x86_32, x86_64, rv64 or wasm32.",
        mandatory = True,
        configurable = False,
        values = sorted(CPU_TABLE),
    ),
    "version": attr.string(
        doc = "Canonical Godot version of the payload; producer metadata takes precedence where present.",
        mandatory = True,
        configurable = False,
    ),
    "origin": attr.string(
        doc = "Optional human-readable origin recorded in provenance; never part of selection.",
        configurable = False,
    ),
    "engine": attr.string(
        doc = """
        Name of the engine the slot belongs to; the component fills it only in builds whose
        --@autoload_rules_godot//godot:engine names that engine. Empty, the default, joins the
        default engine, which builds use when the flag is empty.
        """,
        configurable = False,
    ),
    "default_engine": attr.bool(
        doc = """
        Whether the named engine is also the default engine, so the component also fills
        its slot in builds that name no engine, as the default engine of godot_engines
        does.
        """,
        configurable = False,
    ),
    "tags": attr.string_list(
        doc = "Conventional Bazel tags for both generated targets, such as manual for a payload only some builds need.",
        configurable = False,
    ),
}

godot_editor_component = macro(
    doc = """
    Declare one execution-platform editor slot and its toolchain registration.

    Creates the provenance-carrying toolchain implementation `<name>` and Bazel's
    built-in `toolchain()` `<name>.toolchain`, constrained to the operating system and CPU
    of the execution platform and to the engine selected by `--@autoload_rules_godot//godot:engine`.
    A registration set is a package of components: register it with its `:all` pattern;
    the first registered candidate of the selected engine for a slot wins. The
    editor may be an executable target, such as a prebuilt editor archive's `:editor` or
    a source recipe's `:godot`, or another editor component, whose payload and provenance
    are forwarded.

    Example:
    ```starlark
    godot_editor_component(
        name = "editor_macos_arm64",
        editor = "@godot_editor_macos//:editor",
        platform = "macos",
        cpu = "arm64",
        version = "4.7.2",
    )
    ```
    """,
    implementation = _editor_macro_impl,
    attrs = _COMMON | {
        "editor": attr.label(
            doc = "Executable editor for the execution platform, or another editor component.",
            mandatory = True,
        ),
        "platform": attr.string(
            doc = "Operating system of the slot's editor platform: linux or macos.",
            mandatory = True,
            configurable = False,
            values = ["linux", "macos"],
        ),
    },
)

godot_runtime_component = macro(
    doc = """
    Declare one target-platform runtime slot and its toolchain registration.

    Creates the provenance-carrying toolchain implementation `<name>` and Bazel's
    built-in `toolchain()` `<name>.toolchain`, constrained to the target platform's operating
    system, CPU and iOS environment, with `target_settings` on
    `--@autoload_rules_godot//godot:variant` for the template variant, on
    `--@autoload_rules_godot//godot:engine` for the engine and, with
    `without_build_profile`, on the application having no build profile. The runtime may be a
    desktop template file, a target with GodotRuntimeInfo, an iOS XCFramework import or
    `:engine_library`, an Android runtime, a `select()` between prepared same-slot
    payloads, or another runtime component, whose payload and provenance are forwarded.
    Every selected branch must fill the declared slot; slot facts are not configurable.

    Example:
    ```starlark
    godot_runtime_component(
        name = "runtime_ios_arm64_simulator_debug",
        runtime = "@godot_ios_arm64_simulator_debug//:engine_library",
        platform = "ios",
        cpu = "arm64",
        environment = "simulator",
        variant = "debug",
        version = "4.7.2",
    )
    ```
    """,
    implementation = _runtime_macro_impl,
    attrs = _COMMON | {
        "runtime": attr.label(
            doc = "Runtime payload for the declared slot, a select() over prepared payloads, or another runtime component.",
            mandatory = True,
        ),
        "platform": attr.string(
            doc = "Operating system of the slot's target platform: linux, macos, android, ios or web.",
            mandatory = True,
            configurable = False,
            values = ["linux", "macos", "android", "ios", "web"],
        ),
        "variant": attr.string(
            doc = "Godot template variant the payload implements: debug or release.",
            mandatory = True,
            configurable = False,
            values = ["debug", "release"],
        ),
        "environment": attr.string(
            doc = "iOS environment, device or simulator; required for iOS and empty otherwise.",
            configurable = False,
            values = ["", "device", "simulator"],
        ),
        "digest": attr.string(
            doc = """
            Optional digest of the artifact behind an opaque payload, such as the archive of
            an XCFramework import or an Android shell AAR, recorded in provenance. Source
            recipes and prebuilt template files supply their own, which take precedence.
            """,
            configurable = False,
        ),
        "untuned_only": attr.bool(
            doc = """
            Serve only builds whose runtime needs no tuning, as a prebuilt runtime does,
            which can neither leave classes out nor compile otherwise: the application has
            no `build_profile`, and the runtime compiles outside `-c opt` or with the default
            engine optimization. A source-built component of the same slot registered after
            it then serves the other builds.
            """,
            configurable = False,
        ),
    },
)
