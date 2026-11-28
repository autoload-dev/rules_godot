"""
The shell assets of a pack: what Godot decides for its export and the images it renders.

The shell action exports the pack's project once more with a probe plugin and
throws that export away. Godot reports its facts, the export options with their
defaults, the project settings with the export's feature overrides and the
values of the version options, and renders the application's icons and splash
images as its exporter for the operating system does. Application rules write their
shell files from these facts.
"""

load(":export_options.bzl", "string_option")

visibility("//godot/...")

_PROJECT_ICON = "setting:application/config/icon"
_LANCZOS = 4

def _option(name):
    return "option:" + name

def _file(file):
    return "file:" + file.path

def asset_catalog(ctx, path, fields = {}):
    """
    Declare and write the Contents.json of an Xcode asset catalog directory.

    Args:
        ctx: Rule context.
        path: The catalog directory, relative to the rule's package.
        fields: Further fields of the Contents.json, such as images.

    Returns:
        The Contents.json File.
    """
    contents = ctx.actions.declare_file(path + "/Contents.json")
    ctx.actions.write(contents, json.encode_indent(
        fields | {"info": {"author": "xcode", "version": 1}},
        indent = "  ",
    ) + "\n")
    return contents

def _android(ctx, profile):
    res = ctx.actions.declare_directory(ctx.label.name + ".android_res")
    splash = ctx.actions.declare_directory(ctx.label.name + ".android_splash")
    main = [_option("launcher_icons/main_192x192"), _PROJECT_ICON]
    foreground = [_option("launcher_icons/adaptive_foreground_432x432")] + main
    layers = [
        ("icon_foreground", foreground),
        ("icon_background", [_option("launcher_icons/adaptive_background_432x432")]),
        ("icon_monochrome", [_option("launcher_icons/adaptive_monochrome_432x432")]),
    ]
    images = []
    for directory, size, layer_size in profile["android"]["icon_densities"]:
        for name, sources, pixels in [("icon", main, size)] + [
            (name, sources, layer_size)
            for name, sources in layers
        ]:
            path = "%s/%s.webp" % (directory, name)
            images.append({
                "name": path,
                "output": res.path + "/" + path,
                "sources": sources,
                "size": pixels,
                "interpolation": _LANCZOS,
            })

    # Godot saves the splash images as they load; a vector drawable stays one.
    images.append({
        "name": "drawable/splash_icon.webp",
        "output": splash.path + "/drawable/splash_icon.webp",
        "sources": [_option("splash_screen/icon")] + foreground,
        "copy": {
            "extension": ".xml",
            "output": splash.path + "/drawable/splash_icon_vector.xml",
        },
    })
    images.append({
        "name": "drawable/splash_branding_image.webp",
        "output": splash.path + "/drawable/splash_branding_image.webp",
        "sources": [_option("splash_screen/branding_image")],
    })
    spec = {
        "directories": [res.path, splash.path],
        "images": images,
        "adaptive_icon": {
            "output": res.path + "/mipmap-anydpi-v26/icon.xml",
            "foreground": "mipmap/icon_foreground.webp",
            "monochrome": "mipmap/icon_monochrome.webp",
        },
    }
    return struct(spec = spec, outputs = [res, splash], icons = [res], splash = [splash])

def _ios_icon_slot(ios, appearance, icon):
    option, name, size, scale, points = icon
    suffix = "_" + appearance if appearance else ""
    icon_options = [option + suffix, ios["base_icon"] + suffix]
    return struct(
        appearance = appearance,
        options = icon_options,
        sources = [_option(icon_option) for icon_option in icon_options],
        file_name = name + suffix + ".png",
        size = size,
        scale = scale,
        points = points,
        opaque = option == ios["opaque_icon"],
    )

def _ios_icon_slots(ios, options):
    """The icons of the app icon set, each with its appearance and the options it renders from."""
    slots = [
        _ios_icon_slot(ios, appearance, icon)
        for appearance in ["", "dark", "tinted"]
        for icon in ios["icons"]
    ]

    # Dark and tinted icons exist only where the pack sets them.
    return [
        slot
        for slot in slots
        if not slot.appearance or any([string_option(options, option) for option in slot.options])
    ]

def _ios_icon_entry(slot, filename):
    """The icon's entry in the Contents.json of the app icon set."""
    entry = {"idiom": "universal", "platform": "ios", "size": slot.points}
    if slot.appearance:
        entry["appearances"] = [{"appearance": "luminosity", "value": slot.appearance}]
    if slot.scale != "1x":
        entry["scale"] = slot.scale
    entry["filename"] = filename
    return entry

def _ios_icons(ctx, prefix, slots, assets):
    icon_set = prefix + "Assets.xcassets/AppIcon.appiconset/"
    images = []
    outputs = []
    for slot in slots:
        output = ctx.actions.declare_file(icon_set + slot.file_name)
        outputs.append(output)
        images.append({
            "name": output.basename,
            "output": output.path,
            # Only icons of the default appearance fall back to the project icon, then to
            # Godot's default application icon.
            "sources": slot.sources + ([] if slot.appearance else [
                _PROJECT_ICON,
                _file(assets.icon),
            ]),
            "size": slot.size,
            "interpolation": _option("application/icon_interpolation"),
            "opaque": slot.opaque,
            "required": True,
        })
    entries = [_ios_icon_entry(slot, output.basename) for slot, output in zip(slots, outputs)]
    files = [
        asset_catalog(ctx, prefix + "Assets.xcassets"),
        asset_catalog(ctx, icon_set.removesuffix("/"), {"images": entries}),
    ] + outputs
    return struct(images = images, outputs = outputs, files = files)

def _ios_splash(ctx, prefix, assets):
    """
    The launch screen's image.

    It is Godot's boot splash unless the project or the storyboard options set one.
    """
    image_set = prefix + "Launch.xcassets/SplashImage.imageset"
    images = []
    outputs = []
    for scale, other in [("2x", "3x"), ("3x", "2x")]:
        output = ctx.actions.declare_file("%s/splash@%s.png" % (image_set, scale))
        outputs.append(output)
        images.append({
            "name": output.basename,
            "output": output.path,
            "sources": [
                [
                    _option("storyboard/custom_image@" + scale),
                    _option("storyboard/custom_image@" + other),
                ],
                "setting:application/boot_splash/image",
                _file(assets.splash),
            ],
            "required": True,
        })
    files = [
        asset_catalog(ctx, prefix + "Launch.xcassets"),
        asset_catalog(ctx, image_set, {"images": [
            {"filename": image.basename, "idiom": "universal", "scale": scale}
            for image, scale in zip(outputs, ["2x", "3x"])
        ]}),
    ] + outputs
    return struct(images = images, outputs = outputs, files = files)

def _ios(ctx, profile, options, assets):
    prefix = ctx.label.name + ".ios/"
    icons = _ios_icons(ctx, prefix, _ios_icon_slots(profile["ios"], options), assets)
    splash = _ios_splash(ctx, prefix, assets)
    return struct(
        spec = {"images": icons.images + splash.images},
        outputs = icons.outputs + splash.outputs,
        icons = icons.files,
        splash = splash.files,
    )

def _macos(ctx, profile, assets):
    icons = ctx.actions.declare_directory(ctx.label.name + ".macos")
    sources = [
        _option("application/icon"),
        "setting:application/config/macos_native_icon",
        _PROJECT_ICON,
        # Without any other icon, the export uses Godot's default application icon.
        _file(assets.icon),
    ]

    # Godot assembles the rendered sizes into one .icns file, or copies the
    # .icns file the options name.
    spec = {
        "directories": [icons.path],
        "icns": icons.path + "/icon.icns",
        "images": [
            {
                "name": "icon_%d" % size,
                "sources": sources,
                "size": size,
                "interpolation": _option("application/icon_interpolation"),
            }
            for size in profile["macos"]["icon_sizes"]
        ],
    }
    return struct(spec = spec, outputs = [icons], icons = [icons], splash = [])

# Image.resize's default, which Godot's web export resizes the touch icon with.
_BILINEAR = 1

# The icons of the web manifest of a progressive web app, square, in pixels.
_PWA_ICON_SIZES = [144, 180, 512]

def _web(ctx, assets):
    """The images of Godot's web export: the page's icons and its boot splash, as loaded."""
    images = ctx.actions.declare_directory(ctx.label.name + ".web")

    # Without a project icon the web export takes the editor theme's default.
    icon = [_PROJECT_ICON, "editor_icon:DefaultProjectIcon"]
    spec = {
        "directories": [images.path],
        "images": [
            {"name": "icon.png", "output": images.path + "/icon.png", "sources": icon},
            {
                "name": "apple-touch-icon.png",
                "output": images.path + "/apple-touch-icon.png",
                "sources": icon,
                "size": 180,
                "interpolation": _BILINEAR,
            },
        ] + [
            {
                # The progressive web app's icons, which the packager takes only for one.
                "name": "pwa_%d.png" % size,
                "output": "%s/pwa_%d.png" % (images.path, size),
                "sources": [_option("progressive_web_app/icon_%dx%d" % (size, size))] + icon,
                "size": size,
                "interpolation": _BILINEAR,
                # Godot resizes the editor theme's icon in place, so each default icon
                # starts from the one before it: from the touch icon where the page has
                # one, then from each earlier manifest icon that has no icon of its own.
                "shared_resizes": [[180, "!html/export_icon"]] + [
                    [earlier, "progressive_web_app/icon_%dx%d" % (earlier, earlier)]
                    for earlier in _PWA_ICON_SIZES[:index]
                ],
            }
            for index, size in enumerate(_PWA_ICON_SIZES)
        ] + [
            {
                "name": "splash.png",
                "output": images.path + "/splash.png",
                "sources": ["setting:application/boot_splash/image", _file(assets.splash)],
            },
        ],
    }
    return struct(spec = spec, outputs = [images], icons = [images], splash = [images])

def pack_shell_assets(ctx, preset_platform, profile, options, assets):
    """
    Declare the shell assets of a pack's export for its operating system.

    Args:
        ctx: godot_pack rule context.
        preset_platform: Godot's export preset platform name of the pack's operating system.
        profile: The engine profile of the editor that exports the pack.
        options: The pack's export options as Godot literals.
        assets: struct of Godot's default application icon and boot splash Files.

    Returns:
        A struct of facts, the
        File of Godot's facts; spec, the shell action's description; outputs,
        the images the action writes; icons and splash, the Files for
        GodotPackInfo.
    """
    if preset_platform == "Android":
        images, section = _android(ctx, profile), profile["android"]
    elif preset_platform == "iOS":
        images, section = _ios(ctx, profile, options, assets), profile["ios"]
    elif preset_platform == "macOS":
        images, section = _macos(ctx, profile, assets), profile["macos"]
    elif preset_platform == "Web":
        images, section = _web(ctx, assets), {"version_options": []}
    else:
        images = struct(spec = {"images": [], "directories": []}, outputs = [], icons = [], splash = [])
        section = {"version_options": []}
    return struct(
        facts = ctx.actions.declare_file(ctx.label.name + ".facts.json"),
        spec = images.spec | {"versions": section["version_options"]},
        outputs = images.outputs,
        icons = images.icons,
        splash = images.splash,
    )
