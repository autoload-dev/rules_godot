"""
The tag evaluation of the godot_engines module extension.

engine_selection.bzl settles one configuration per engine name. The planner takes the
extension's modules and returns the repositories to declare; the extension instantiates
them. Errors go through `_fail`, so a
Starlark unit test with mocked modules collects them; the planner returns None after an
error.

Sections: Binaries, Binary slots, Source recipes, Runtime profiles, Declarations.
"""

load("//godot/engine/private:archives.bzl", "template_target")
load("//godot/engine/private:catalogue.bzl", "EDITOR_PLATFORMS", "RELEASES", "TEMPLATE_CPUS")
load("//godot/engine/private:engine_selection.bzl", "selected_engines")
load("//godot/engine/private:hub.bzl", "component")
load(
    "//godot/engine/private:source_build_rows.bzl",
    "ROWS",
    "pinning",
    "plan_rows",
    "recipe_declarations",
    "slot_name",
)
load("//godot/private:supply_chain.bzl", "LIBRARY_PACKAGES")
load("//godot/private:versions.bzl", "godot_version_error")

visibility(["//godot/..."])

# The repository of every engine's toolchains, which rules_godot's module registers.
TOOLCHAINS_REPOSITORY = "godot_engines_toolchains"

def _declaration(rule, **attrs):
    return struct(rule = rule, attrs = attrs)

# ==== Binaries ================================================================

def _release_urls(tag, slug):
    """Godot's CDN URL, then the GitHub release URL, of Godot_v<tag>_<slug>."""
    version, flavor = tag.split("-", 1)
    return [
        "https://downloads.godotengine.org/?version=%s&flavor=%s&slug=%s" % (version, flavor, slug),
        "https://github.com/godotengine/godot-builds/releases/download/%s/Godot_v%s_%s" % (tag, tag, slug),
    ]

def _pins(engine, binaries, release):
    """What an engine's binaries come from: its binaries tag, or None, and the catalogue's release, or None."""
    return struct(name = engine.name, binaries = binaries, release = release)

def _release_packages(release):
    """
    The godot_bundled_packages declaration of the COPYRIGHT.txt the catalogue pins for a release.

    The file's digest names the repository, so every engine of the release shares it.

    Args:
        release: The catalogue's release, or None.

    Returns:
        The declaration, or None for a release without a pinned COPYRIGHT.txt.
    """
    copyright = (release or {}).get("copyright")
    if not copyright:
        return None
    return _declaration(
        "godot_bundled_packages",
        name = "godot_release_packages_" + copyright["sha256"][:12],
        urls = copyright["urls"],
        sha256 = copyright["sha256"],
    )

def _packages_label(declaration):
    """The label of the libraries of a godot_bundled_packages declaration."""
    return "@" + declaration.attrs["name"] + LIBRARY_PACKAGES

def _catalogue_bundled_packages(pins):
    """
    The label of the libraries of an engine's catalogued binaries, or None.

    Godot's official binaries come without its sources, so their repositories name the
    libraries of the COPYRIGHT.txt the catalogue pins. Pinned binaries are a fork's and take
    none.
    """
    packages = _release_packages(pins.release)
    return _packages_label(packages) if packages else None

def _pinned(pins, attribute):
    """A binaries tag's value, None without the tag."""
    return getattr(pins.binaries, attribute) if pins.binaries else None

def _editor(pins, editor_platform, _fail):
    """Return the archive of one editor platform: pinned on the binaries tag or catalogued; None after an error."""
    if editor_platform not in EDITOR_PLATFORMS:
        return _fail("godot_engines.binaries of %r: unknown editor platform %r; expected one of %s" % (pins.name, editor_platform, sorted(EDITOR_PLATFORMS)))
    layout = EDITOR_PLATFORMS[editor_platform]
    release = pins.release
    if not _pinned(pins, "editor_urls"):
        return struct(
            urls = _release_urls(release["tag"], layout.suffix + ".zip"),
            integrity = release[editor_platform],
            binary = layout.binary.format(tag = release["tag"]),
            layout = layout,
            bundled_packages = _catalogue_bundled_packages(pins),
        )
    binaries = pins.binaries
    if editor_platform not in binaries.editor_integrity:
        return _fail("godot_engines.binaries of %r: editor_integrity lacks %r" % (pins.name, editor_platform))
    binary = binaries.editor_binaries.get(editor_platform, layout.binary.format(tag = release["tag"]) if release else "")
    if not binary:
        return _fail("godot_engines.binaries of %r: editor_binaries lacks %r" % (pins.name, editor_platform))
    return struct(
        urls = binaries.editor_urls[editor_platform],
        integrity = binaries.editor_integrity[editor_platform],
        binary = binary,
        layout = layout,
        bundled_packages = None,
    )

def _editor_platforms(pins):
    """The editor platforms of an engine's binaries: those its binaries tag pins, or the catalogue's."""
    if _pinned(pins, "editor_urls"):
        return sorted(pins.binaries.editor_urls)
    return pins.release["editor_platforms"] if pins.release else []

def _editors(pins, _fail):
    """Return the editor archives of an engine by editor platform, or None after an error."""
    editors = {}
    for editor_platform in _editor_platforms(pins):
        editor = _editor(pins, editor_platform, _fail)
        if editor == None:
            return None
        editors[editor_platform] = editor
    return editors

def _pinned_templates(pins, _fail):
    """Return the export-template archive a binaries tag pins with templates_urls, or None after an error."""
    binaries = pins.binaries
    if not binaries.templates_integrity:
        return _fail("godot_engines.binaries of %r: templates_integrity is required with templates_urls" % pins.name)
    return struct(
        urls = binaries.templates_urls,
        integrity = binaries.templates_integrity,
        macos_cpus = binaries.templates_macos_cpus or ["universal"],
        linux_cpus = binaries.templates_linux_cpus or TEMPLATE_CPUS["linux"],
        bundled_packages = None,
    )

def _templates(pins, _fail):
    """
    Return the export-template archive of an engine and its layout.

    Returns:
        The templates, False without any, or None after an error.
    """
    if _pinned(pins, "templates_urls"):
        return _pinned_templates(pins, _fail)
    layouts = [attribute for attribute in ["templates_macos_cpus", "templates_linux_cpus"] if _pinned(pins, attribute)]
    if layouts:
        return _fail("godot_engines.binaries of %r: %s describes templates_urls; set both" % (pins.name, layouts[0]))
    release = pins.release
    if not release:
        return False
    return struct(
        urls = _release_urls(release["tag"], "export_templates.tpz"),
        integrity = release["templates"],
        macos_cpus = release["macos_cpus"],
        linux_cpus = release.get("linux_cpus", TEMPLATE_CPUS["linux"]),
        bundled_packages = _catalogue_bundled_packages(pins),
    )

# The Android shell AARs of an engine's binaries: the variant each serves and the prefix of
# its binaries attributes, catalogue key and repository name. The shells of official
# releases are template_release builds with every ABI's engine library, so the catalogue
# has no debug shell today and a debug shell is an explicit pin.
_SHELL_PINS = [("release", "android_shell"), ("debug", "android_debug_shell")]

def _shell_error(pins):
    """The error of a shell AAR pinned without its integrity, or None."""
    for _, pin in _SHELL_PINS:
        if _pinned(pins, pin + "_urls") and not _pinned(pins, pin + "_integrity"):
            return "godot_engines.binaries of %r: %s_integrity is required with %s_urls" % (pins.name, pin, pin)
    return None

def _android_shells(pins):
    """
    Return the shell AARs of an engine by variant, in _SHELL_PINS order.

    Each is pinned on the binaries tag with `<pin>_urls` and `<pin>_integrity` or
    catalogued under `<pin>`; a struct of its pin, urls and integrity.
    """
    shells = {}
    release = pins.release or {}
    for variant, pin in _SHELL_PINS:
        urls = _pinned(pins, pin + "_urls")
        if urls:
            shells[variant] = struct(
                pin = pin,
                urls = urls,
                integrity = _pinned(pins, pin + "_integrity"),
                bundled_packages = None,
            )
        elif pin in release:
            shells[variant] = struct(
                pin = pin,
                bundled_packages = _catalogue_bundled_packages(pins),
                **release[pin]
            )
    return shells

def _binaries_plan(engine, binaries, release, *, _fail = fail):
    """
    Return the prebuilt editors, export templates and Android shells of an engine.

    Each part comes from the engine's binaries tag where it pins one, and otherwise from the
    catalogue's release.

    Args:
        engine: A godot_engines.engine tag.
        binaries: The engine's godot_engines.binaries tag, or None.
        release: The catalogue's release of the engine's version, or None where its
            binaries may not serve, such as with a build policy of the engine's own.
        _fail: Replaces fail in Starlark unit tests.

    Returns:
        A struct of editors by editor platform, templates (False without any), the Android
        shells by variant, iOS simulator CPUs and Android CPUs; None after an error.
    """
    pins = _pins(engine, binaries, release)
    editors = _editors(pins, _fail)
    if editors == None:
        return None
    templates = _templates(pins, _fail)
    if templates == None:
        return None
    error = _shell_error(pins)
    if error:
        return _fail(error)
    simulator_cpus = binaries.ios_simulator_cpus if binaries else []
    return struct(
        editors = editors,
        templates = templates,
        android_shells = _android_shells(pins),
        ios_simulator_cpus = simulator_cpus or (release["ios_simulator_cpus"] if release else []),
        android_cpus = (release or {}).get("android_cpus", TEMPLATE_CPUS["android"]),
    )

# ==== Binary slots ============================================================

def _editor_slots(engine, editors):
    return [
        component(
            role = "editor",
            name = "editor_%s_%s" % (editor.layout.platform, cpu),
            payload = "@%s_editor_%s//:editor" % (engine.name, editor_platform),
            platform = editor.layout.platform,
            cpu = cpu,
            version = engine.version,
        )
        for editor_platform, editor in editors.items()
        for cpu in editor.layout.cpus
    ]

def _runtime_slot(engine, platform, cpu, variant, payload, environment = "", digest = ""):
    """A runtime slot, named runtime_<platform>_<cpu>[_<environment>]_<variant>."""
    return component(
        role = "runtime",
        name = "_".join(["runtime", platform, cpu] + ([environment] if environment else []) + [variant]),
        payload = payload,
        platform = platform,
        cpu = cpu,
        version = engine.version,
        variant = variant,
        environment = environment,
        digest = digest,
    )

def _templates_repository(engine, platform):
    """The name of the repository of a Godot platform's export templates."""
    return "%s_templates_%s" % (engine.name, platform)

def _template_payload(engine, platform, target):
    """The label of a target in the export-template repository of a platform."""
    return "@%s//:%s" % (_templates_repository(engine, platform), target)

def _macos_target(macos_cpus, cpu, variant):
    """The macOS runtime target that serves a CPU, or None when the templates lack it."""
    if macos_cpus == ["universal"]:
        return template_target("macos", "universal", variant)
    return template_target("macos", cpu, variant) if cpu in macos_cpus else None

def _desktop_runtime_slots(engine, templates):
    slots = []
    for variant in ["release", "debug"]:
        targets = [("linux", cpu, template_target("linux", cpu, variant)) for cpu in templates.linux_cpus] + [
            ("macos", cpu, _macos_target(templates.macos_cpus, cpu, variant))
            for cpu in ["arm64", "x86_64"]
        ] + [("web", "wasm32", template_target("web", "wasm32", variant))]
        slots.extend([
            _runtime_slot(engine, platform, cpu, variant, _template_payload(engine, platform, target))
            for platform, cpu, target in targets
            if target
        ])
    return slots

def _ios_runtime_slots(engine, templates, simulator_cpus):
    """The device slot and one simulator slot per CPU of each variant; one XCFramework serves them all."""
    return [
        _runtime_slot(
            engine,
            "ios",
            cpu,
            variant,
            _template_payload(engine, "ios", template_target("ios", "", variant)),
            environment = environment,
            digest = templates.integrity,
        )
        for variant in ["release", "debug"]
        for cpu, environment in [("arm64", "device")] + [(cpu, "simulator") for cpu in simulator_cpus]
    ]

def _android_runtime_slots(engine, plan):
    return [
        _runtime_slot(engine, "android", cpu, variant, "//android:" + variant, digest = shell.integrity)
        for variant, shell in plan.android_shells.items()
        for cpu in plan.android_cpus
    ]

def _binary_slots(engine, plan):
    """
    Return the hub slots of an engine's binaries.

    Args:
        engine: The godot_engines.engine tag.
        plan: The result of _binaries_plan.

    Returns:
        A list of hub component descriptions.
    """
    slots = _editor_slots(engine, plan.editors)
    if plan.templates:
        slots += _desktop_runtime_slots(engine, plan.templates)
        slots += _ios_runtime_slots(engine, plan.templates, plan.ios_simulator_cpus)
    return slots + _android_runtime_slots(engine, plan)

# ==== Source recipes ==========================================================

# The build policy of an engine without a build tag: the modules of Godot's official
# builds.
_OFFICIAL_POLICY = {
    "enabled_modules": [],
    "default_modules": True,
    "custom_modules": {},
    "patches": [],
    "patch_strip": 1,
    "renderers": [],
    "build_options": {},
}

# The rendering methods of an official policy's recipes where they are not Godot's drivers.
# Apple's run every method on Metal and OpenGL; Vulkan would need the MoltenVK SDK on the
# configuring Mac. Declaring them lets applications check their project's method against
# them.
_OFFICIAL_RENDERERS = {
    "ios": ["gl_compatibility", "mobile", "forward_plus"],
    "macos": ["gl_compatibility", "mobile", "forward_plus"],
}

# The suffix of the slots and Android runtimes that serve the builds whose runtime needs
# tuning, a build profile or engine optimization, where a prebuilt runtime serves the others.
_TUNED = "_tuned"

# The visibility of the tuned slots' targets: the registrations of the hub and of the
# extension's toolchains repository, not an entrypoint. Their payloads are configured from
# source on the first analysis, which only a host that Godot's configuration accepts can do.
_TUNED_VISIBILITY = ["//:registration"]

def _policy(engine, build):
    """
    The build policy of an engine: its build tag's, or the official policy.

    It holds the godot_engine_build attributes of the engine's recipes, its patches among
    them.
    """
    policy = dict(_OFFICIAL_POLICY)
    if build:
        policy = {attribute: getattr(build, attribute) for attribute in _OFFICIAL_POLICY}
    return policy | {"build_name": engine.name}

def _editor_policy(policy, editor):
    """The policy of an engine's editor recipes: the editor tag's modules and options replace the build's."""
    if not editor:
        return policy
    result = dict(policy)
    if editor.enabled_modules or editor.default_modules:
        result["enabled_modules"] = editor.enabled_modules
        result["default_modules"] = editor.default_modules
    if editor.build_options:
        result["build_options"] = editor.build_options
    return result

# The binaries tag's pins that make the binaries a fork's, whose sources the catalogue lacks.
_FORK_PINS = ["editor_urls", "templates_urls"]

def _source(engine, source, binaries, release):
    """
    Return the godot_engine_source attributes of an engine's sources, None without.

    They are its source tag's, or the catalogue's unless its binaries tag pins a fork's
    editors or templates.
    """
    if source:
        return dict(
            urls = source.urls,
            sha256 = source.sha256,
            strip_prefix = source.strip_prefix,
            version = source.version or engine.version,
        )
    if binaries and any([getattr(binaries, pin) for pin in _FORK_PINS]):
        return None
    return (release or {}).get("source")

def _tuned_slots(rows_plan, covered):
    """
    Return the source-built slots, their Android runtimes and the covered slots' names.

    A slot that a prebuilt runtime covers takes the source-built runtime under the slot's
    name with _TUNED, for builds whose runtime needs tuning, which a prebuilt runtime
    cannot apply. Its name sorts after the prebuilt one's, so it is registered after it.
    """
    android = {}
    for variant, runtime in rows_plan.android.items():
        if covered.get("android_" + variant):
            android[variant + _TUNED] = runtime | {"visibility": _TUNED_VISIBILITY}
        else:
            android[variant] = runtime
    slots = [
        _tuned_slot(slot) if slot["name"] in covered else slot
        for slot in rows_plan.slots
    ]
    tuned = [slot["name"] for slot in rows_plan.slots if slot["name"] in covered]
    return slots, android, tuned

def _tuned_slot(slot):
    """Return a covered slot renamed with _TUNED and visible only to the hub's registration."""
    payload = slot["payload"] + _TUNED if slot["platform"] == "android" else slot["payload"]
    return slot | {
        "name": slot["name"] + _TUNED,
        "payload": payload,
        "visibility": _TUNED_VISIBILITY,
    }

def _recipe_policies(declarations, build, editor_policy):
    """Give the editor recipes their policy and an official policy's recipes their renderers."""
    for declaration in declarations:
        attrs = declaration.attrs
        if declaration.rule != "godot_engine_build":
            continue
        if attrs["build_target"] == "editor":
            attrs.update(editor_policy)
        if not build and attrs["platform"] in _OFFICIAL_RENDERERS:
            attrs["renderers"] = _OFFICIAL_RENDERERS[attrs["platform"]]

def _source_repositories(source):
    """
    Return the names of a source archive's repository, its engine tree and its libraries.

    The archive's digest names them, so engines of one source share all three: the tree is
    the archive's, and each recipe applies its engine's patches to copies of its own.

    Args:
        source: The godot_engine_source attributes of an engine's sources.

    Returns:
        A struct of the godot_engine_source, godot_engine_tree and godot_bundled_packages
        repository names.
    """
    digest = source["sha256"][:12]
    return struct(archive = "godot_source_" + digest, tree = "godot_tree_" + digest)

def _source_packages(source, tree):
    """
    Return the godot_bundled_packages declaration of a source archive's libraries.

    The sources of a catalogued release take the repository of the COPYRIGHT.txt the
    catalogue pins for it, which is the archive's own; other sources that of their tree.

    Args:
        source: The godot_engine_source attributes of an engine's sources.
        tree: The label of the `:tree.json` of the archive's engine tree.

    Returns:
        A godot_bundled_packages declaration, which engines of one source share.
    """
    for release in RELEASES.values():
        if release["source"]["sha256"] == source["sha256"] and "copyright" in release:
            return _release_packages(release)
    return _declaration(
        "godot_bundled_packages",
        name = "godot_tree_packages_" + source["sha256"][:12],
        tree = tree,
    )

def _source_recipes(parts, source, covered, profiles = {}):
    """
    Return the source declarations, slots and Android runtimes of an engine's source recipes.

    The engine builds from its sources every slot its binaries lack, and, for applications
    whose runtime needs tuning, the runtimes they cover. An editor its binaries cover is not
    built.

    Args:
        parts: The engine's tags by tag class, as selected_engines returns them.
        source: The engine's godot_engine_source attributes.
        covered: The names of the binary slots, and android_<variant> of each Android
            shell its binaries pin, as keys.
        profiles: The engine's registered runtime profiles: each label string's build
            options, as runtime_profiles returns them.

    Returns:
        A struct of `declarations`, the source archive, engine tree and recipe repositories,
        of which engines of one source share the first two, `slots`,
        the source-built hub slots, `android`, their Android runtimes by name, `tuned`,
        the binary slots a build whose runtime needs tuning leaves to them, and `pinning`,
        the hub attributes of its lock file.
    """
    engine = parts["engine"]
    build = parts.get("build")
    rows = [row for row in ROWS if not (row.build_target == "editor" and slot_name(row) in covered)]
    rows_plan = plan_rows(engine.name, rows, version = source["version"])
    repositories = _source_repositories(source)
    tree = "@%s//:tree.json" % repositories.tree
    packages = _source_packages(source, tree)

    # Every recipe's engine carries the libraries of the sources' COPYRIGHT.txt.
    policy = _policy(engine, build)
    policy["bundled_packages"] = _packages_label(packages)
    lock_file = engine.lock_file
    declarations = recipe_declarations(
        engine.name,
        tree,
        rows_plan,
        policy,
        lock_file,
        runtime_profiles = profiles,
    )
    _recipe_policies(declarations, build, _editor_policy(policy, parts.get("editor")))
    source_slots, android, tuned = _tuned_slots(rows_plan, covered)
    return struct(
        declarations = [
            _declaration("godot_engine_source", name = repositories.archive, **source),
            _declaration(
                "godot_engine_tree",
                name = repositories.tree,
                source = "@%s//:source.json" % repositories.archive,
            ),
            packages,
        ] + declarations,
        slots = source_slots,
        android = android,
        tuned = tuned,
        pinning = pinning(rows_plan, lock_file, profiles),
    )

# ==== Runtime profiles ========================================================

def _graph_options(text):
    """
    The build options of a build profile, as a JSON object with sorted keys; empty without.

    Only its build options shape a source recipe's graph: Godot's configuration reads its
    disabled_build_options, and its classes reach the class generator as an input.
    """
    data = json.decode(text)
    options = data.get("disabled_build_options", {}) if type(data) == "dict" else {}
    return json.encode({key: options[key] for key in sorted(options)}) if options else ""

def runtime_profiles(modules, read):
    """
    Return the registered runtime profiles with build options, by engine name.

    A profile that disables classes alone needs no runtime variant: applications apply its
    classes to any source-built runtime. Recipes take a profile's build options, not its
    file, so editing its classes configures no recipe again.

    Args:
        modules: module_ctx.modules.
        read: Returns the content of a profile's file by its label.

    Returns:
        A dict of each engine name to a dict of its runtime profiles' label strings, sorted,
        to their build options as JSON.
    """
    profiles = {}
    for mod in modules:
        for tag in mod.tags.runtime_profile:
            options = _graph_options(read(tag.profile))
            if options:
                profiles.setdefault(tag.engine, {})[str(tag.profile)] = options
    return {
        engine: {label: options[label] for label in sorted(options)}
        for engine, options in profiles.items()
    }

# ==== Declarations ============================================================

def _bundled_packages_of(part):
    """The bundled_packages attribute of a binary's repository, where the catalogue pins its COPYRIGHT.txt."""
    return {"bundled_packages": part.bundled_packages} if part.bundled_packages else {}

def _copyright_declarations(release, parts):
    """
    Return the repository of the libraries the catalogue's COPYRIGHT.txt lists, where binary parts name it.

    Args:
        release: The catalogue's release of the engine's version, or None.
        parts: The editors, templates and shells of the engine's binaries plan.

    Returns:
        The godot_bundled_packages declarations, none or one.
    """
    if not [part for part in parts if part.bundled_packages]:
        return []
    return [_release_packages(release)]

# The file name of a downloaded export-template archive. The platform repositories
# extract the file itself, so they name it rather than the archive repository's //file
# target.
_ARCHIVE_FILE = "export_templates.tpz"

def _templates_declarations(engine, templates):
    """
    Return the export-template repositories of an engine's binaries.

    One repository downloads the archive, and one per Godot platform extracts that
    platform's templates from it: a build extracts only the templates of the platforms it
    uses, and downloads the archive once however many it uses.

    Args:
        engine: The godot_engines.engine tag.
        templates: The templates of the engine's binaries plan, or False.

    Returns:
        The http_file declaration of the archive, then the godot_export_templates_archive
        declarations; none without templates.
    """
    if not templates:
        return []
    archive = _templates_repository(engine, "archive")
    return [_declaration(
        "http_file",
        name = archive,
        urls = templates.urls,
        integrity = templates.integrity,
        downloaded_file_path = _ARCHIVE_FILE,
    )] + [
        _declaration(
            "godot_export_templates_archive",
            name = _templates_repository(engine, platform),
            archive = "@%s//file:%s" % (archive, _ARCHIVE_FILE),
            integrity = templates.integrity,
            version = engine.version,
            platform = platform,
            cpus = cpus,
            **_bundled_packages_of(templates)
        )
        for platform, cpus in [("linux", templates.linux_cpus), ("macos", templates.macos_cpus), ("ios", []), ("web", [])]
    ]

def _editor_declarations(engine, editors):
    return [
        _declaration(
            "godot_editor_archive",
            name = "%s_editor_%s" % (engine.name, editor_platform),
            urls = editor.urls,
            integrity = editor.integrity,
            binary = editor.binary,
            version = engine.version,
            **_bundled_packages_of(editor)
        )
        for editor_platform, editor in editors.items()
    ]

def _shell_declarations(engine, shells):
    """
    Return the repositories of an engine's shell AARs and the hub's Android runtimes.

    Args:
        engine: The godot_engines.engine tag.
        shells: The shell AARs of the engine's binaries plan, by variant.

    Returns:
        A tuple of the http_file declarations and, by variant, the Android runtime of the
        hub: a dict whose `shell` is the label of the AAR.
    """
    declarations = []
    android_runtimes = {}
    for variant, shell in shells.items():
        name = "%s_%s" % (engine.name, shell.pin)
        declarations.append(_declaration(
            "http_file",
            name = name,
            urls = shell.urls,
            integrity = shell.integrity,
            downloaded_file_path = "shell.aar",
        ))
        android_runtimes[variant] = {"shell": "@%s//file" % name}
    return declarations, android_runtimes

def _binary_declarations(engine, release, plan):
    """
    Return the repositories of an engine's binaries and what its hub takes of them.

    Args:
        engine: The godot_engines.engine tag.
        release: The catalogue's release of the engine's version, or None.
        plan: The result of _binaries_plan.

    Returns:
        A struct of the declarations, the hub's Android runtimes by variant and the hub's
        attributes for them: the libraries of catalogued shells.
    """
    shells, android_runtimes = _shell_declarations(engine, plan.android_shells)
    templates = [plan.templates] if plan.templates else []
    parts = plan.editors.values() + templates + plan.android_shells.values()
    declarations = _copyright_declarations(release, parts)
    declarations += _editor_declarations(engine, plan.editors)
    declarations += _templates_declarations(engine, plan.templates) + shells

    # The hub's Android runtimes wrap the shells, so they carry the shells' libraries.
    bundled = [shell.bundled_packages for shell in plan.android_shells.values() if shell.bundled_packages]
    return struct(
        declarations = declarations,
        android_runtimes = android_runtimes,
        hub = {"bundled_packages": bundled[0]} if bundled else {},
    )

def _acquisition_error(engine, source, plan):
    """The error of an engine that has no editor, or a lock file but no sources; None otherwise."""
    if not source and not plan.editors:
        return (
            "Godot %s has no catalogue entry for the engine %r; declare its sources with " +
            "godot_engines.source or its editors with godot_engines.binaries"
        ) % (engine.version, engine.name)
    if engine.lock_file and not source:
        return "godot_engines.engine %r: lock_file pins source recipes, but the engine has no sources" % engine.name
    return None

def _engine_profiles(engine, default, profiles):
    """The runtime profiles of an engine: those that name it, and, for the default engine, those that name none."""
    named = profiles.get(engine.name, {})
    unnamed = profiles.get("", {}) if default else {}
    combined = named | unnamed
    return {label: combined[label] for label in sorted(combined)}

def _engine_declarations(selection, profiles, _fail):
    """
    Return one engine's repositories and what the toolchains repository registers of it.

    Returns None after an error.
    """
    parts = selection.parts
    engine = parts["engine"]
    error = godot_version_error(engine.version)
    if error:
        return _fail(error)
    release = RELEASES.get(engine.version)

    # A build policy of the engine's own makes the catalogue's binaries another engine.
    catalogued = None if "build" in parts else release
    plan = _binaries_plan(engine, parts.get("binaries"), catalogued, _fail = _fail)
    if plan == None:
        return None
    source = _source(engine, parts.get("source"), parts.get("binaries"), release)
    error = _acquisition_error(engine, source, plan)
    if error:
        return _fail(error)
    binaries = _binary_declarations(engine, release, plan)
    declarations = binaries.declarations
    android_runtimes = binaries.android_runtimes
    slots = _binary_slots(engine, plan)
    hub = dict(
        name = engine.name,
        display_name = engine.name,
        engine = engine.name,
        default_engine = selection.default,
        toolchains_repository = TOOLCHAINS_REPOSITORY,
        version = engine.version,
        **binaries.hub
    )
    if source:
        covered = {slot["name"]: True for slot in slots} | {"android_" + variant: True for variant in plan.android_shells}
        built = _source_recipes(parts, source, covered, _engine_profiles(engine, selection.default, profiles))
        declarations += built.declarations
        slots = [
            slot | {"untuned_only": True} if slot["name"] in built.tuned else slot
            for slot in slots
        ] + built.slots
        android_runtimes = built.android | android_runtimes
        hub.update(built.pinning)
    hub.update(components = json.encode(slots), android_runtimes = json.encode(android_runtimes))
    return struct(
        declarations = declarations + [_declaration("engine_hub", **hub)],
        toolchains = {"name": engine.name, "default_engine": selection.default, "slots": slots},
    )

def _profile_tag_error(tag, names, has_default):
    """The error of one runtime profile that reaches no registered engine, or None."""
    if tag.engine and tag.engine not in names:
        return "godot_engines.runtime_profile(profile = %r) names the engine %r, which no module registers" % (str(tag.profile), tag.engine)
    if not (tag.engine or has_default):
        return "godot_engines.runtime_profile(profile = %r) names no engine, and no engine is the default" % str(tag.profile)
    return None

def _profile_error(modules, selections):
    """The error of the first runtime profile that reaches no registered engine, or None."""
    names = {selection.name: True for selection in selections}
    has_default = any([selection.default for selection in selections])
    errors = [
        _profile_tag_error(tag, names, has_default)
        for mod in modules
        for tag in mod.tags.runtime_profile
    ]
    errors = [error for error in errors if error]
    return errors[0] if errors else None

# The repositories engines of one source archive share.
_SHARED_RULES = ["godot_bundled_packages", "godot_engine_source", "godot_engine_tree"]

def _same_archive(first, other):
    """
    Whether two declarations of a shared repository describe the same archive.

    Mirror URLs are no identity: the first declaration takes the other's as well.
    """
    if first.rule != other.rule:
        return False
    if first.rule == "godot_engine_source":
        if {key: value for key, value in first.attrs.items() if key != "urls"} != {key: value for key, value in other.attrs.items() if key != "urls"}:
            return False
        first.attrs["urls"] = first.attrs["urls"] + [url for url in other.attrs["urls"] if url not in first.attrs["urls"]]
        return True
    return first == other

def _shared_error(declaration):
    """The error of a shared repository that engines declare differently."""
    if declaration.rule == "godot_bundled_packages":
        return "Godot engines declare the libraries' repository %s differently" % declaration.attrs["name"]
    return (
        "Godot engines declare the source archive of %s with different " +
        "strip_prefix or version; declare it alike in every engine"
    ) % declaration.attrs["name"]

def _shared_once(declarations, _fail):
    """
    Declare each shared repository once, for every engine of its archive; None after an error.

    Engines that describe one archive's digest otherwise, such as by another strip prefix
    or version, fail.
    """
    seen = {}
    result = []
    for declaration in declarations:
        name = declaration.attrs["name"]
        if declaration.rule in _SHARED_RULES and name in seen:
            if not _same_archive(seen[name], declaration):
                return _fail(_shared_error(declaration))
            continue
        seen[name] = declaration
        result.append(declaration)
    return result

def _collision_error(declarations):
    """The error of two declarations of the same repository name, the first by name; None without."""
    owners = {}
    collisions = {}
    engine = ""
    for declaration in reversed(declarations):
        # Each engine's declarations end with its hub, which names the engine.
        if declaration.rule == "engine_hub":
            engine = declaration.attrs["name"]
        owner = "" if declaration.rule == "engine_toolchains" else engine
        name = declaration.attrs["name"]
        if name in owners:
            collisions[name] = sorted([owner, owners[name]])
        owners[name] = owner
    if not collisions:
        return None
    name = sorted(collisions)[0]
    first, second = collisions[name]
    if not first:
        return "The Godot engine %r and godot_engines both declare the repository %r; rename the engine" % (second, name)
    return "The Godot engines %r and %r both declare the repository %r; rename one" % (first, second, name)

def plan_engines(modules, *, tag_attributes, read = None, _fail = fail):
    """
    Return the repositories the godot_engines extension declares.

    Args:
        modules: module_ctx.modules.
        tag_attributes: The attribute names of each tag class, keyed by tag class.
        read: Returns the content of a runtime profile's file by its label.
        _fail: Replaces fail in Starlark unit tests.

    Returns:
        A list of structs with `rule`, the name of a repository rule or macro, and `attrs`,
        its keyword arguments; None after an error.
    """
    selections = selected_engines(modules, tag_attributes = tag_attributes, _fail = _fail)
    if selections == None:
        return None
    error = _profile_error(modules, selections)
    if error:
        return _fail(error)
    profiles = runtime_profiles(modules, read)
    declarations = []
    engines = []
    for selection in selections:
        engine = _engine_declarations(selection, profiles, _fail)
        if engine == None:
            return None
        declarations.extend(engine.declarations)
        engines.append(engine.toolchains)

    # The toolchains of every engine, which rules_godot's module registers, so a module
    # that registers an engine needs no registration of its own.
    declarations.append(_declaration("engine_toolchains", name = TOOLCHAINS_REPOSITORY, engines = json.encode(engines)))
    declarations = _shared_once(declarations, _fail)
    if declarations == None:
        return None
    error = _collision_error(declarations)
    if error:
        return _fail(error)
    return declarations
