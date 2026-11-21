"""Stable resource paths without leaking Bazel output directory names."""

visibility(["//godot/engine/private", "//godot/extension", "//godot/platforms/private", "//godot/private/tests"])

def runfile_key(ctx, file):
    """
    Return a file's path below a runfiles directory, as launchers look it up.

    Args:
        ctx: Analysis context.
        file: A file in the runfiles.

    Returns:
        The path relative to the runfiles directory.
    """
    path = file.short_path
    return path[3:] if path.startswith("../") else ctx.workspace_name + "/" + path

def _relative_posix(path):
    """Whether a path is relative POSIX: not empty or absolute, no backslash, colon or control character."""
    if not path or path.startswith("/"):
        return False
    if "\\" in path or ":" in path:
        return False
    return not any([c < " " for c in path.elems()])

def validate_resource_path(path):
    """
    Validate a POSIX resource path.

    Args:
        path: Resource path without a res:// prefix.

    Returns:
        The validated path.
    """
    if not _relative_posix(path):
        fail("Expected a relative Godot resource path, got %r" % path)
    if any([part in ["", ".", ".."] for part in path.split("/")]):
        fail("Resource paths cannot contain empty, '.' or '..' components: %r" % path)
    folded = path.lower()
    reserved = ["project.godot", "export_presets.cfg", ".godot"]
    if folded in reserved or folded.startswith(".godot/"):
        fail("Reserved Godot resource path: %r" % path)
    return path

def _repository_relative(file):
    """A file's path below the root of its repository: its short path without ../<repository>/."""
    path = file.short_path
    return path.split("/", 2)[2] if path.startswith("../") else path

def resource_path(file, target, strip_prefix, prefix = ""):
    """
    Return the resource path of a file from the package of the target that brings it.

    Args:
        file: Source or generated File among the target's files.
        target: Label of the target listed in srcs that brings the file; its package is the
            directory the file's path is relative to, in any repository.
        strip_prefix: Additional package-relative directory prefix to remove.
        prefix: Resource path of a directory, ending in a slash, that the remaining
            path is placed under; empty for the project root.

    Returns:
        The file's stable resource path.
    """
    path = _repository_relative(file)
    package = target.package + "/" if target.package else ""
    if file.owner.workspace_name != target.workspace_name or not path.startswith(package):
        fail((
            "%s is outside %r of %s; list the files through a target in their own " +
            "package, or give each its path in resource_paths"
        ) % (file.short_path, package, target))
    source = package
    if strip_prefix:
        strip_prefix = strip_prefix.rstrip("/")
        validate_resource_path(strip_prefix)
        source += strip_prefix + "/"
    if not path.startswith(source):
        fail("%s is outside strip_prefix %r of %s; give it its path in resource_paths" % (
            file.short_path,
            source,
            target,
        ))
    return validate_resource_path(prefix + path[len(source):])

def placed_resource_paths(ctx, srcs, resource_paths, prefix):
    """
    Place the files of srcs-like targets and of single-file targets at explicit paths.

    Args:
        ctx: Rule analysis context with strip_prefix, the package-relative directory
            prefix to remove from srcs paths.
        srcs: The listed targets, such as ctx.attr.srcs; each file's path is relative
            to its target's package.
        resource_paths: A label-keyed dictionary of single-file targets to explicit
            resource paths, which prefix does not change.
        prefix: Resource path of the directory the srcs files are placed under.

    Returns:
        A dictionary of resource paths to Files.
    """
    placed = {}
    owner = str(ctx.label)
    for target in srcs:
        for file in target[DefaultInfo].files.to_list():
            path = resource_path(file, target.label, ctx.attr.strip_prefix, prefix)
            merge_resource_paths(placed, {path: file}, owner = owner)
    for target, path in resource_paths.items():
        merge_resource_paths(placed, {path: _single_file(target)}, owner = owner)
    return placed

def _single_file(target):
    """The one file of a resource_paths target."""
    files = target[DefaultInfo].files.to_list()
    if len(files) != 1:
        fail("resource_paths requires a single file per label: %s" % target.label)
    return files[0]

def directory_prefix(path):
    """
    Return a directory's resource path as a prefix.

    Args:
        path: Resource path of a directory, with or without res:// and a trailing slash.

    Returns:
        The validated path with a trailing slash; empty for the project root.
    """
    if path.startswith("res://"):
        path = path[len("res://"):]
    path = path.rstrip("/")
    return validate_resource_path(path) + "/" if path else ""

def _origin(resource_paths, owners, path):
    return (owners or {}).get(path, str(resource_paths[path].owner))

def _validate_addition(path, file):
    """Fail for an invalid resource path or a tree artifact, which has no single resource path."""
    validate_resource_path(path)
    if file.is_directory:
        fail((
            "Godot resource res://%s from %s is a tree artifact; " +
            "declare individual generated files with known resource paths"
        ) % (path, file.owner))

def merge_resource_paths(
        destination,
        additions,
        owners = None,
        additions_owners = None,
        owner = None):
    """
    Merge resource paths, rejecting conflicting files for one path with origin labels.

    Namespace-wide checks belong to validate_namespace, run once per final composition.

    Args:
        destination: Mutable resource-path-to-File dictionary.
        additions: New resource-path-to-File entries.
        owners: Optional mutable resource-path-to-owner dictionary.
        additions_owners: Optional origins for additions.
        owner: Fallback origin for newly declared paths.
    """
    for path, file in additions.items():
        _validate_addition(path, file)
        origin = (additions_owners or {}).get(path, owner or str(file.owner))
        if path in destination and destination[path] != file:
            fail((
                "Conflicting Godot resource paths " +
                "res://%s (%s, %s) and res://%s (%s, %s)"
            ) % (
                path,
                destination[path].short_path,
                _origin(destination, owners, path),
                path,
                file.short_path,
                origin,
            ))
        destination[path] = file
        if owners != None and path not in owners:
            owners[path] = origin

# The files Godot writes beside a file, its import settings and its UID, which it never
# treats as resources of their own, in any case; tools/godot_files.py holds the same rule.
_SIDECAR_SUFFIXES = (".import", ".uid")

def sidecar_source(path):
    """
    The resource path whose sidecar path is, or None for any other path.

    Args:
        path: A resource path.

    Returns:
        The source's resource path, or None.
    """
    if not path.lower().endswith(_SIDECAR_SUFFIXES):
        return None
    source = path.rpartition(".")[0]
    if not source.rpartition("/")[2] or source.lower().endswith(_SIDECAR_SUFFIXES):
        return None
    return source

_DIRECTORY_MARKERS = [".gdignore", "project.godot"]

def godot_ignore_markers(paths):
    """
    The `.gdignore` and `project.godot` files among paths that make Godot skip their directory.

    Args:
        paths: Resource paths, a list or the keys of a dict.

    Returns:
        A list of the marker paths; the project's root directory has none.
    """
    return [path for path in paths if "/" in path and path.rpartition("/")[2] in _DIRECTORY_MARKERS]

def godot_ignored(paths):
    """
    The paths Godot ignores among paths, as tools/godot_files.py documents Godot's rule.

    A path is Godot-ignored when it or one of its directories is hidden, its name
    beginning with a dot, or when it lies below a directory whose `.gdignore` or
    `project.godot` is among paths.

    Args:
        paths: Resource paths, a list or the keys of a dict.

    Returns:
        A dict of the Godot-ignored paths to True.
    """
    directories = tuple([marker.rpartition("/")[0] + "/" for marker in godot_ignore_markers(paths)])
    return {
        path: True
        for path in paths
        if path.startswith(".") or "/." in path or (directories and path.startswith(directories))
    }

def _portable_paths(resource_paths, owners):
    """Fail for two paths that differ only by case; return the paths by their folded case."""
    portable_paths = {}
    for path in resource_paths:
        folded = path.lower()
        other = portable_paths.get(folded, path)
        if other != path:
            fail((
                "Portable Godot resource path collision: " +
                "res://%s (%s) and res://%s (%s) differ only by case"
            ) % (
                other,
                _origin(resource_paths, owners, other),
                path,
                _origin(resource_paths, owners, path),
            ))
        portable_paths[folded] = path
    return portable_paths

def _fail_file_directory(origin, parent, ancestor, child):
    """Fail for a file at parent that a child's ancestor directory, in any case, also names."""
    first = origin(parent)
    second = origin(child)
    if parent != ancestor:
        fail((
            "Portable Godot file/directory path collision: " +
            "res://%s (%s) and res://%s (%s)"
        ) % (parent, first, child, second))
    fail((
        "Conflicting Godot file/directory paths " +
        "res://%s (%s) and res://%s (%s)"
    ) % (parent, first, child, second))

def validate_namespace(resource_paths, owners = None):
    """
    Reject paths that collide on case-insensitive or file/directory filesystems.

    Args:
        resource_paths: Dictionary of resource paths to Files of one complete composition.
        owners: Optional resource-path-to-owner dictionary for messages.
    """
    portable_paths = _portable_paths(resource_paths, owners)

    # A file cannot also be a directory, and one directory has one spelling.
    # Checking every ancestor handles intervening sibling names (a, a-b, a/b)
    # in linear total path depth.
    portable_directories = {}
    for child in resource_paths:
        parts = child.split("/")
        for index in range(1, len(parts)):
            ancestor = "/".join(parts[:index])
            folded = ancestor.lower()
            parent = portable_paths.get(folded)
            if parent != None:
                _fail_file_directory(lambda path: _origin(resource_paths, owners, path), parent, ancestor, child)
            spelling = portable_directories.get(folded)
            if spelling != None and spelling != ancestor:
                fail((
                    "Portable Godot directory path collision: res://%s and res://%s " +
                    "use different directory capitalization (from %s)"
                ) % (spelling, ancestor, child))
            portable_directories[folded] = ancestor

def collect_resource_paths(ctx):
    """
    Collect sources and generated or external files placed at explicit resource paths.

    Args:
        ctx: Rule analysis context with srcs, resource_paths, strip_prefix and
            optionally prefix.

    Returns:
        A dictionary of resource paths to Files.
    """
    return placed_resource_paths(
        ctx,
        ctx.attr.srcs,
        ctx.attr.resource_paths,
        directory_prefix(getattr(ctx.attr, "prefix", "")),
    )

def declared_path(resource_paths, path, kind):
    """
    Return a declared resource path, accepting an optional res:// prefix.

    Args:
        resource_paths: Dictionary of resource paths to Files of the project.
        path: The path as written by the user.
        kind: What the path names, for the failure message.

    Returns:
        The validated resource path.
    """
    resolved = resolve_project_path(resource_paths, path)
    if not resolved or resolved.kind != "file":
        fail("%s res://%s is not a declared project member%s" % (
            kind,
            directory_prefix(path).rstrip("/"),
            "; it names a directory" if resolved else "",
        ))
    return resolved.path

def resolve_project_path(resource_paths, path):
    """
    Resolve a path from configuration as the resource graph does: a file or a directory.

    Godot records no file or directory hint for a setting or an export option, and a
    directory name can have a suffix (an Icon Composer `.icon` bundle), so only the
    declared files decide.

    Args:
        resource_paths: Dictionary of resource paths to Files of the project.
        path: The path as written in configuration, with or without res://.

    Returns:
        A struct with `kind` ("file" or "directory"), `path` (the resource path) and
        `files` (resource paths to Files: the file, or every file below the directory),
        or None when the project declares neither.
    """
    prefix = directory_prefix(path)
    path = validate_resource_path(prefix.rstrip("/"))
    if path in resource_paths:
        return struct(kind = "file", path = path, files = {path: resource_paths[path]})
    files = {
        member: file
        for member, file in resource_paths.items()
        if member.startswith(prefix)
    }
    if not files:
        return None
    return struct(kind = "directory", path = path, files = files)

def exec_paths(resource_paths):
    """
    Return resource paths to the execution paths of their Files.

    Args:
        resource_paths: Dictionary of resource paths to Files.

    Returns:
        A dictionary for action manifests.
    """
    return {path: file.path for path, file in resource_paths.items()}

def mapped_path(file):
    """
    Return a File's path as path mapping stages it: an output's without its configuration.

    The manifests of actions that support path mapping name files this way, so that they
    are the same in every target configuration; tools/mapped_paths.py resolves them.

    Args:
        file: A File.

    Returns:
        The source path, or bazel-out/cfg/ and the rest of the output path.
    """
    if file.is_source:
        return file.path
    return "bazel-out/cfg/" + file.path.split("/", 2)[2]

def mapped_paths(resource_paths):
    """
    Return resource paths to the mapped paths of their Files, as mapped_path names them.

    Args:
        resource_paths: Dictionary of resource paths to Files.

    Returns:
        A dictionary for the manifests of actions that support path mapping.
    """
    return {path: mapped_path(file) for path, file in resource_paths.items()}

_LOADER_FIELDS = {
    "editor": "editor_resource_paths",
    "host_editor": "host_editor_resource_paths",
    "runtime": "runtime_resource_paths",
}

def with_extensions_for(resource_paths, extensions, loader):
    """
    Return resource paths with each extension's files replaced by those one loader can load.

    The process that stages these resource paths loads the extension libraries built for where
    it runs: the runtime or an editor running the project loads the extension
    runtime libraries, editor actions the extension editor libraries, and an editor on the
    host the extension host editor libraries.

    Args:
        resource_paths: Resource paths to Files that hold the extensions' files of any loader.
        extensions: GodotExtensionInfo of the extensions to replace.
        loader: The process that loads them: "runtime", "editor" or "host_editor".

    Returns:
        A new dict of resource paths to Files.
    """
    if loader not in _LOADER_FIELDS:
        fail("Unknown extension loader %r; expected one of %s" % (
            loader,
            ", ".join(sorted(_LOADER_FIELDS)),
        ))
    staged = dict(resource_paths)
    for extension in extensions:
        for field in _LOADER_FIELDS.values():
            for path in getattr(extension, field):
                staged.pop(path, None)
    for extension in extensions:
        staged.update(getattr(extension, _LOADER_FIELDS[loader]))
    return staged
