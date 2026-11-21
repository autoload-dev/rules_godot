"""Per-application Firebase configuration as platform resources of a godot_app."""

_KINDS = {
    # The Gradle plugin writes res/values/values.xml; a distinct name keeps the file
    # apart from an application's own values.xml in the same configuration.
    "android": "res/values/google_services.xml",
    # The Firebase SDK looks the file up by this name at the bundle root.
    "ios": "GoogleService-Info.plist",
}

def _firebase_config_file_impl(ctx):
    output = ctx.actions.declare_file("%s/%s" % (ctx.label.name, _KINDS[ctx.attr.kind]))
    args = ctx.actions.args()
    args.add(ctx.attr.kind)
    args.add("--config", ctx.file.src)
    args.add("--application-id", ctx.attr.application_id)
    args.add("--output", output)
    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = [args],
        inputs = [ctx.file.src],
        outputs = [output],
        mnemonic = "FirebaseConfig",
        progress_message = "Checking Firebase configuration %{input} for " + ctx.attr.application_id,
    )
    return [DefaultInfo(files = depset([output]))]

_firebase_config_file = rule(
    implementation = _firebase_config_file_impl,
    attrs = {
        "src": attr.label(allow_single_file = True, mandatory = True),
        "application_id": attr.string(mandatory = True),
        "kind": attr.string(values = _KINDS.keys(), mandatory = True),
        "_generator": attr.label(
            default = Label("//config:google_services"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _firebase_config_impl(name, visibility, application_id, google_services_json, google_service_info_plist, **kwargs):
    # Inherited common attributes arrive as None when unset; alias does not have all of
    # them, such as exec_group_compatible_with, and rejects even a None value.
    kwargs = {key: value for key, value in kwargs.items() if value != None}
    branches = {}
    if google_services_json:
        _firebase_config_file(
            name = name + ".android",
            src = google_services_json,
            application_id = application_id,
            kind = "android",
            **kwargs
        )
        branches[Label("@platforms//os:android")] = ":" + name + ".android"
    if google_service_info_plist:
        _firebase_config_file(
            name = name + ".ios",
            src = google_service_info_plist,
            application_id = application_id,
            kind = "ios",
            **kwargs
        )
        branches[Label("@platforms//os:ios")] = ":" + name + ".ios"
    native.filegroup(name = name + ".none", srcs = [], **kwargs)
    native.alias(
        name = name,
        actual = select(branches | {"//conditions:default": ":" + name + ".none"}),
        visibility = visibility,
        **kwargs
    )

firebase_config = macro(
    doc = """
    The Firebase configuration of one application, for its `platform_resources`.

    On Android, the string resources the `com.google.gms.google-services` Gradle plugin
    writes from `google-services.json` for the client of `application_id`. On iOS,
    `GoogleService-Info.plist` at the bundle root, checked against `application_id`.
    Elsewhere nothing; desktop branches of `platform_resources` still stay empty.
    """,
    implementation = _firebase_config_impl,
    inherit_attrs = "common",
    attrs = {
        "application_id": attr.string(
            doc = "The godot_app's application_id: Android client to pick and iOS bundle identifier to check.",
            mandatory = True,
            configurable = False,
        ),
        "google_services_json": attr.label(
            doc = "The Android configuration from the Firebase console; select() between projects, such as dev and prod.",
            allow_single_file = [".json"],
        ),
        "google_service_info_plist": attr.label(
            doc = "The iOS configuration from the Firebase console, under any file name.",
            allow_single_file = [".plist"],
        ),
    },
)
