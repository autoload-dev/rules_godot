"""
Checksum-pinned acquisition of prebuilt editor and export-template archives.

Sections: Editor archive, Template extraction, Templates archive, Repository rules.
"""

load("//godot/private:repository_templates.bzl", "fill_template", "starlark_list")
load("//godot/private:supply_chain.bzl", "BUNDLED_PACKAGES", "source_purl", "write_package_metadata")
load("//godot/private:versions.bzl", "require_supported_godot_version")
load("//godot/private/config:settings.bzl", "CPU_TABLE")

visibility(["//godot/..."])

_VERSION_ATTR = attr.string(
    doc = "Canonical Godot version of the archive's payloads; checked for ruleset support, not read from the archive.",
    mandatory = True,
)

_BUNDLED_PACKAGES_ATTR = attr.label(
    doc = "The `:bundled_packages` of the godot_bundled_packages repository of the version's COPYRIGHT.txt, which the payloads carry beside Godot; none without.",
)

# ==== Editor archive ==========================================================

_EDITOR_ARCHIVE_ATTRS = {
    "urls": attr.string_list(
        doc = "Ordered mirror URLs of the same ZIP archive.",
        mandatory = True,
    ),
    "integrity": attr.string(
        doc = "Subresource Integrity digest of the archive, including the hash algorithm, such as sha512-...; required.",
        mandatory = True,
    ),
    "version": _VERSION_ATTR,
    "bundled_packages": _BUNDLED_PACKAGES_ATTR,
    "binary": attr.string(
        doc = "Path of the editor executable inside the archive.",
        mandatory = True,
    ),
}

def _download(ctx, _fail):
    if not ctx.attr.integrity:
        _fail("integrity is required: every Godot download must be checksum-pinned")
        return False
    ctx.download_and_extract(url = ctx.attr.urls, integrity = ctx.attr.integrity, type = "zip")
    return True

def editor_archive_impl(ctx, *, _fail = fail):
    """
    Download one editor archive and generate its BUILD file.

    Args:
        ctx: Repository rule context.
        _fail: Replaces fail in Starlark unit tests.

    Returns:
        The repository's metadata: reproducible.
    """
    if not require_supported_godot_version(ctx.attr.version, _fail = _fail):
        return None
    if not _download(ctx, _fail):
        return None
    if not ctx.path(ctx.attr.binary).exists:
        _fail("Godot editor archive does not contain " + ctx.attr.binary)
        return None
    ctx.template("BUILD.bazel", ctx.attr._build_template, substitutions = {
        "{PREBUILT_BZL}": repr(str(ctx.attr._prebuilt_bzl)),
        "{BINARY}": repr(ctx.attr.binary),
        "{BUNDLED_PACKAGES}": repr(BUNDLED_PACKAGES),
        "{DIGEST}": repr(ctx.attr.integrity),
    })
    write_package_metadata(
        ctx,
        source_purl("godot", ctx.attr.version, integrity = ctx.attr.integrity),
        bundled_packages = ctx.attr.bundled_packages,
    )

    # The integrity-pinned archive determines the contents, so Bazel's repo contents
    # cache, local or remote, may reuse them.
    return ctx.repo_metadata(reproducible = True)

_EDITOR_ARCHIVE_RULE_ATTRS = _EDITOR_ARCHIVE_ATTRS | {
    "_prebuilt_bzl": attr.label(default = Label("//godot/engine/private:prebuilt.bzl")),
    "_build_template": attr.label(default = Label("//godot/engine/private:editor_archive.BUILD.tpl")),
}

# ==== Template extraction =====================================================

# The directory that the archive members a repository keeps are renamed into, so that
# strip_prefix extracts them alone: Bazel skips the entries outside the prefix.
_KEPT = "kept"

def _extract_members(ctx, members):
    """Extract the archive entries named `members` that the archive has; at least one must be present."""
    ctx.extract(
        ctx.path(ctx.attr.archive),
        type = "zip",
        rename_files = {member: _KEPT + "/" + member for member in members},
        strip_prefix = _KEPT,
        # The archive's repository verifies it against the integrity this repository's
        # definition also carries, so watching the archive would only rehash it.
        watch_archive = "no",
    )

def _extract_nested(ctx, nested, _fail):
    """Expand a nested ZIP, a struct of its member and output, and delete it; False if it is missing."""
    if not ctx.path(nested.member).exists:
        _fail("Godot template archive does not contain " + nested.member)
        return False
    ctx.extract(nested.member, output = nested.output)
    ctx.delete(nested.member)
    return True

def template_target(platform, cpu, variant):
    """
    Return the name of the runtime target a templates repository declares for a binary.

    Args:
        platform: The Godot platform: linux, macos or ios.
        cpu: The binary's suffix: a Godot CPU tag, `universal` for a macOS universal
            binary, or empty for iOS, whose XCFramework serves every CPU.
        variant: release or debug.

    Returns:
        `<platform>_<cpu>_<variant>`, or `<platform>_<variant>` for a universal or iOS
        binary.
    """
    return "_".join([platform] + ([cpu] if cpu not in ["", "universal"] else []) + [variant])

# Godot's layout of an export-template archive: its members, and the nested ZIPs with the
# directories this repository expands them to.
def _linux_binary(variant, cpu):
    return "templates/linux_%s.%s" % (variant, cpu)

_MACOS_ZIP = struct(member = "templates/macos.zip", output = "macos")

_IOS_ZIP = struct(member = "templates/ios.zip", output = "ios")

def _macos_binary(variant, cpu):
    return "%s/macos_template.app/Contents/MacOS/godot_macos_%s.%s" % (_MACOS_ZIP.output, variant, cpu)

def _ios_xcframework(name):
    return "%s/%s.xcframework" % (_IOS_ZIP.output, name)

def _ios_engine(variant):
    return _ios_xcframework("libgodot.ios." + variant)

# ==== Templates archive =======================================================

def _ios_libraries(ctx):
    """
    Return the imports of the dependent XCFrameworks an expanded ios.zip carries.

    Args:
        ctx: Repository rule context.

    Returns:
        A tuple of the filled import declarations and, per variant, the labels of the
        imports the engine of that variant depends on.
    """
    candidates = [
        ("MoltenVK", ctx.attr._ios_moltenvk_template, "ios_moltenvk", ["debug", "release"], {}),
        ("AccessKit", ctx.attr._ios_accesskit_template, "ios_accesskit", ["debug", "release"], {}),
    ] + [
        ("libgodot_camera.ios." + variant, ctx.attr._ios_camera_template, "ios_camera_" + variant, [variant], {
            "{VARIANT}": variant,
        })
        for variant in ["debug", "release"]
    ]
    libraries = []
    dependencies = {"debug": [], "release": []}
    for name, template, target, variants, substitutions in candidates:
        xcframework = _ios_xcframework(name)
        if not ctx.path(xcframework + "/Info.plist").exists:
            continue
        libraries.append(fill_template(ctx, template, substitutions | {"{XCFRAMEWORK}": xcframework}))
        for variant in variants:
            dependencies[variant].append(":" + target)
    return libraries, dependencies

def _ios(ctx, _fail):
    """Return the iOS XCFramework import declarations of an archive's ios.zip, or None after an error."""
    if not _extract_nested(ctx, _IOS_ZIP, _fail):
        return None
    for variant in ["debug", "release"]:
        path = _ios_engine(variant) + "/Info.plist"
        if not ctx.path(path).exists:
            _fail("Godot templates ios.zip is missing %s; expected Godot's ios.zip layout" % path)
            return None
    libraries, dependencies = _ios_libraries(ctx)
    engines = [
        fill_template(ctx, ctx.attr._ios_engine_template, {
            "{NAME}": repr(template_target("ios", "", variant)),
            "{XCFRAMEWORK}": _ios_engine(variant),
            "{BUNDLED_PACKAGES}": repr(BUNDLED_PACKAGES),
            "{DEPS}": starlark_list(sorted(dependencies[variant]), indent = "    "),
        })
        for variant in ["debug", "release"]
    ]
    return [fill_template(ctx, ctx.attr._ios_template, {
        "{SIMULATOR}": repr(str(ctx.attr._simulator_constraint)),
        # Each library is set off by blank lines; without any, nothing.
        "{LIBRARIES}": "".join(["\n" + library + "\n" for library in libraries]),
        "{ENGINES}": "\n\n".join(engines),
    })]

def _binary_runtimes(ctx, _fail):
    """Return the runtime declarations of the platform's binary per CPU in cpus, or None after an error."""
    platform = _PLATFORMS[ctx.attr.platform]
    runtimes = []
    for cpu in ctx.attr.cpus:
        release = platform.binary("release", cpu)
        if not ctx.path(release).exists:
            _fail("Godot template archive does not contain %s; %s" % (release, platform.missing_binary))
            return None
        runtimes.extend(_runtimes(ctx, ctx.attr.platform, cpu, platform.binary))
    return runtimes

# The files of the expanded macos.zip, which every macOS runtime needs: the template's
# application bundle around its binary.
_MACOS_FILES = """filegroup(
    name = "macos_files",
    srcs = glob(["%s/**"]),
)""" % _MACOS_ZIP.output

def _macos_runtimes(ctx, _fail):
    """Return the declarations of an archive's macos.zip: its files and runtimes; None after an error."""
    if not _extract_nested(ctx, _MACOS_ZIP, _fail):
        return None
    runtimes = _binary_runtimes(ctx, _fail)
    return None if runtimes == None else [_MACOS_FILES] + runtimes

def _runtime_loads(ctx):
    return "load(%r, \"prebuilt_runtime\")" % str(ctx.attr._prebuilt_bzl)

def _apple_loads(ctx):
    return "load(%r, \"apple_static_xcframework_import\")" % str(ctx.attr._apple_bzl)

def _linux_cpus_error(cpus):
    if cpus and all([cpu in CPU_TABLE for cpu in cpus]):
        return None
    return "cpus of Linux templates must be Godot CPU tags: " + ", ".join(CPU_TABLE)

def _macos_cpus_error(cpus):
    if sorted(cpus) in [["universal"], ["arm64"], ["x86_64"], ["arm64", "x86_64"]]:
        return None
    return 'cpus of macOS templates must be ["universal"] or a subset of ["arm64", "x86_64"]'

# The web templates a runtime of each variant describes, by kind: the prefix of Godot's
# template name. The web application takes the one its export platform needs.
_WEB_TEMPLATES = {
    "nothreads": "web_nothreads_",
    "threads": "web_",
}

_VARIANTS = ["release", "debug"]

def _web_template(kind, variant):
    """The archive member of a web template and the directory this repository expands it to."""
    name = _WEB_TEMPLATES[kind] + variant
    return struct(member = "templates/%s.zip" % name, output = name)

# Where godot.js names the Emscripten version the template was built with.
_EMSCRIPTEN_VERSION_MARKER = "godot_js_emscripten_get_version(){const emscriptenVersionPtr=GodotRuntime.allocString(\""

def _emscripten_version(ctx, directory, _fail):
    """The Emscripten version a web template's godot.js names, or None after an error."""
    script = ctx.read(directory + "/godot.js")
    start = script.find(_EMSCRIPTEN_VERSION_MARKER)
    if start < 0:
        _fail("Godot web template %s names no Emscripten version in godot.js, where %s was expected" % (
            directory,
            _EMSCRIPTEN_VERSION_MARKER,
        ))
        return None
    start += len(_EMSCRIPTEN_VERSION_MARKER)
    end = script.find("\"", start)
    if end < 0:
        _fail("Godot web template %s ends godot.js inside its Emscripten version" % directory)
        return None
    return script[start:end]

def _web_runtimes(ctx, _fail):
    """Return the runtime declarations of an archive's web templates, or None after an error."""
    runtimes = []
    for variant in _VARIANTS:
        templates = {kind: _web_template(kind, variant) for kind in _WEB_TEMPLATES}
        for template in templates.values():
            if not _extract_nested(ctx, template, _fail):
                return None
        emscripten = _emscripten_version(ctx, templates["nothreads"].output, _fail)
        if emscripten == None:
            return None
        runtimes.append(fill_template(ctx, ctx.attr._web_runtime_template, {
            "{NAME}": repr(template_target("web", "wasm32", variant)),
            "{BINARY}": repr(templates["nothreads"].output + "/godot.wasm"),
            "{FILES}": ", ".join([repr(template.output + "/**") for template in templates.values()]),
            "{TEMPLATES}": repr({template.output + "/godot.wasm": kind for kind, template in templates.items()}),
            "{EMSCRIPTEN_VERSION}": repr(emscripten),
            "{BUNDLED_PACKAGES}": repr(BUNDLED_PACKAGES),
            "{VARIANT}": repr(variant),
            "{VERSION}": repr(ctx.attr.version),
            "{DIGEST}": repr(ctx.attr.integrity),
        }))
    return runtimes

def _web_cpus_error(cpus):
    return None if cpus in [[], ["wasm32"]] else 'cpus of web templates must be empty or ["wasm32"]'

def _ios_cpus_error(cpus):
    return "cpus must be empty for iOS templates" if cpus else None

# Per Godot platform: the error of cpus that do not describe its templates, or None; the
# archive entries its targets are made of; the load statements of its BUILD file; its
# target declarations, or None after an error; and for desktop platforms, the path of a
# template binary by variant and CPU, the advice when an archive lacks one and the
# `data` its runtimes carry.
_PLATFORMS = {
    "linux": struct(
        cpus_error = _linux_cpus_error,
        members = lambda cpus: [_linux_binary(variant, cpu) for cpu in cpus for variant in ["release", "debug"]],
        loads = _runtime_loads,
        targets = _binary_runtimes,
        binary = _linux_binary,
        missing_binary = "its Linux CPUs differ from the catalogue's",
        runtime_data = "",
    ),
    "macos": struct(
        cpus_error = _macos_cpus_error,
        members = lambda _cpus: [_MACOS_ZIP.member],
        loads = _runtime_loads,
        targets = _macos_runtimes,
        binary = _macos_binary,
        missing_binary = "set cpus to match the archive layout",
        runtime_data = '\n    data = [":macos_files"],',
    ),
    "web": struct(
        cpus_error = _web_cpus_error,
        members = lambda _cpus: [_web_template(kind, variant).member for kind in _WEB_TEMPLATES for variant in _VARIANTS],
        loads = _runtime_loads,
        targets = _web_runtimes,
    ),
    "ios": struct(
        cpus_error = _ios_cpus_error,
        members = lambda _cpus: [_IOS_ZIP.member],
        loads = _apple_loads,
        targets = _ios,
    ),
}

def _runtimes(ctx, platform, cpu, binary):
    """Return the release and, when present, debug runtime declarations of the binary `binary(variant, cpu)` names."""
    rules = []
    for variant in ["release", "debug"]:
        if variant == "debug" and not ctx.path(binary(variant, cpu)).exists:
            continue
        rules.append(fill_template(ctx, ctx.attr._runtime_template, {
            "{NAME}": repr(template_target(platform, cpu, variant)),
            "{CPU}": repr(cpu),
            "{BINARY}": repr(binary(variant, cpu)),
            "{BUNDLED_PACKAGES}": repr(BUNDLED_PACKAGES),
            "{DATA}": _PLATFORMS[platform].runtime_data,
            "{PLATFORM}": repr(platform),
            "{VARIANT}": repr(variant),
            "{VERSION}": repr(ctx.attr.version),
            "{DIGEST}": repr(ctx.attr.integrity),
        }))
    return rules

# Godot's version file, which every export-template archive Godot installs carries.
# Extracting it with a platform's members keeps strip_prefix satisfied when the archive
# lacks them, so the repository can name the missing member.
_VERSION_FILE = "templates/version.txt"

def templates_archive_impl(ctx, *, _fail = fail):
    """
    Extract the templates of one platform from an export-template archive and generate their targets.

    Only the platform's members leave the archive.

    Args:
        ctx: Repository rule context.
        _fail: Replaces fail in Starlark unit tests.

    Returns:
        The repository's metadata: reproducible.
    """
    if not require_supported_godot_version(ctx.attr.version, _fail = _fail):
        return None
    platform = _PLATFORMS[ctx.attr.platform]
    error = platform.cpus_error(ctx.attr.cpus)
    if error:
        _fail(error)
        return None
    _extract_members(ctx, [_VERSION_FILE] + platform.members(ctx.attr.cpus))
    targets = platform.targets(ctx, _fail)
    if targets == None:
        return None
    ctx.template("BUILD.bazel", ctx.attr._build_template, substitutions = {
        "{LOADS}": platform.loads(ctx),
        # Each declaration is set off by blank lines.
        "{TARGETS}": "".join(["\n" + target + "\n" for target in targets]),
    })
    write_package_metadata(
        ctx,
        source_purl("godot", ctx.attr.version, integrity = ctx.attr.integrity),
        bundled_packages = ctx.attr.bundled_packages,
    )

    # The integrity-pinned archive determines the contents, so Bazel's repo contents
    # cache, local or remote, may reuse them.
    return ctx.repo_metadata(reproducible = True)

_TEMPLATES_ARCHIVE_ATTRS = {
    "archive": attr.label(
        doc = "The export-template archive, a TPZ or ZIP file, such as another repository's download.",
        mandatory = True,
    ),
    "integrity": attr.string(
        doc = "Subresource Integrity digest of the archive, which the runtimes record as their provenance; whoever provides the archive verifies it.",
        mandatory = True,
    ),
    "version": _VERSION_ATTR,
    "bundled_packages": _BUNDLED_PACKAGES_ATTR,
    "platform": attr.string(
        doc = "Godot platform whose templates the repository extracts: linux, macos, ios or web.",
        mandatory = True,
        values = ["linux", "macos", "ios", "web"],
    ),
    "cpus": attr.string_list(
        doc = """
        Template binary suffixes of the platform in the archive. Linux: Godot's CPU tags,
        such as arm64 or x86_64; a missing binary fails. macOS: ["universal"] or a subset of
        ["arm64", "x86_64"]. iOS: empty.
        """,
    ),
}

_TEMPLATES_ARCHIVE_RULE_ATTRS = _TEMPLATES_ARCHIVE_ATTRS | {
    "_prebuilt_bzl": attr.label(default = Label("//godot/engine/private:prebuilt.bzl")),
    "_build_template": attr.label(default = Label("//godot/engine/private:export_templates.BUILD.tpl")),
    "_runtime_template": attr.label(default = Label("//godot/engine/private:prebuilt_runtime.BUILD.tpl")),
    "_web_runtime_template": attr.label(default = Label("//godot/engine/private:web_runtime.BUILD.tpl")),
    "_apple_bzl": attr.label(default = Label("@rules_apple//apple:apple.bzl")),
    "_simulator_constraint": attr.label(default = Label("@apple_support//constraints:simulator")),
    "_ios_template": attr.label(default = Label("//godot/engine/private:ios_templates.BUILD.tpl")),
    "_ios_engine_template": attr.label(default = Label("//godot/engine/private:ios_engine.BUILD.tpl")),
    "_ios_moltenvk_template": attr.label(default = Label("//godot/engine/private:ios_moltenvk.BUILD.tpl")),
    "_ios_accesskit_template": attr.label(default = Label("//godot/engine/private:ios_accesskit.BUILD.tpl")),
    "_ios_camera_template": attr.label(default = Label("//godot/engine/private:ios_camera.BUILD.tpl")),
}

# ==== Repository rules ========================================================

# The repository rules godot_engines declares for the prebuilt binaries of an engine.

godot_editor_archive = repository_rule(
    doc = """
    Acquire one checksum-pinned prebuilt editor archive.

    The repository exposes `:editor`, the executable with the complete distribution as
    runfiles, for a godot_editor_component; it registers nothing. The editor must match
    the operating system and CPU of the execution platform of the slot it fills. The
    declared version is checked for ruleset support; it is not read from the archive.
    """,
    implementation = editor_archive_impl,
    attrs = _EDITOR_ARCHIVE_RULE_ATTRS,
)

godot_export_templates_archive = repository_rule(
    doc = """
    Extract the export templates of one Godot platform from an export-template archive.

    Only that platform's templates leave the archive, so a build extracts the templates
    of the platforms it uses, while the repositories of all platforms share one download
    of the archive. A Linux or macOS repository exposes one runtime target per
    CPU and template variant, such as `:linux_x86_64_release` or `:macos_debug`, each
    carrying GodotRuntimeInfo, for godot_runtime_component payloads; an archive without a
    debug template omits the debug target, and cpus describes the macOS layout. An iOS
    repository exposes `:ios_debug` and `:ios_release`, XCFramework imports with the
    dependent frameworks the archive carries; they serve device and simulator slots
    alike. A platform whose templates the archive lacks fails. Extracting, and
    downloading the archive, happen only when a payload is requested.
    """,
    implementation = templates_archive_impl,
    attrs = _TEMPLATES_ARCHIVE_RULE_ATTRS,
)
