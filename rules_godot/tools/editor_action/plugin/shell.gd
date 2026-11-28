@tool
extends "export.gd"

# The shell probe's export plugin. During an export of the staged project, it
# records what Godot decides for it: the feature tags, the export options with
# their defaults, the project settings with the export's feature overrides, the
# values of the version options and the translations of the project's name.
# export.gd writes these facts into the record. The plugin also renders the
# application's images the action lists, as Godot's exporters do. It skips
# every file, because the export is thrown away.


func _export_begin(features: PackedStringArray, is_debug: bool, path: String, flags: int) -> void:
	super(features, is_debug, path, flags)
	var preset: EditorExportPreset = get_export_preset()
	# A preset lists its advanced options only in the editor's advanced mode.
	# It leaves out the options an export plugin overrides; a new preset lists them.
	EditorInterface.get_editor_settings().set_setting("_export_preset_advanced_mode", true)
	var clean: EditorExportPreset = get_export_platform().create_preset()
	var options: Dictionary = {}
	var option_types: Dictionary = {}
	var actual_types: Dictionary = {}
	for option_name: String in _option_names(preset, clean):
		options[option_name] = _plain(preset.get(option_name))
		option_types[option_name] = type_string(typeof(clean.get(option_name)))
		actual_types[option_name] = type_string(typeof(preset.get(option_name)))
	var settings: Dictionary = _settings(preset)
	var images: Dictionary = _render_images(preset)
	facts = {
		"features": Array(features),
		"editor_version": Engine.get_version_info()["string"],
		"options": options,
		"option_types": option_types,
		"actual_option_types": actual_types,
		"preset_settings": {"custom_features": preset.get_custom_features(), "script_export_mode": preset.get_script_export_mode()},
		"settings": settings,
		"versions": _versions(preset),
		"name_translations": _name_translations(preset),
		"rendered": images["rendered"],
		"copied": images["copied"],
	}


func _export_file(_path: String, _type: String, _features: PackedStringArray) -> void:
	skip()


# The export options the probe records: those the preset or a new preset lists,
# and those the action names if the export platform has them.
func _option_names(preset: EditorExportPreset, clean: EditorExportPreset) -> Dictionary:
	var names: Dictionary = {}
	for listed: EditorExportPreset in [preset, clean]:
		for property: Dictionary in listed.get_property_list():
			var property_name: String = property["name"]
			if clean.has(property_name):
				names[property_name] = true
	var option_names: Array = action.get("option_names", [])
	var authored_options: Array = action.get("authored_options", [])
	for option_name: String in option_names + authored_options:
		if clean.has(option_name):
			names[option_name] = true
	return names


# The stored project settings with the export's feature overrides.
func _settings(preset: EditorExportPreset) -> Dictionary:
	var settings: Dictionary = {}
	for property: Dictionary in ProjectSettings.get_property_list():
		var setting: String = property["name"]
		var usage: int = property["usage"]
		if usage & PROPERTY_USAGE_STORAGE and "/" in setting:
			settings[setting] = _plain(preset.get_project_setting(setting))
	return settings


# Render the images the action lists into their outputs. The result names the
# rendered entries and maps each entry that rules_godot copies to its source.
func _render_images(preset: EditorExportPreset) -> Dictionary:
	var rendered: Array[String] = []
	var copied: Dictionary = {}
	var loaded: Dictionary = {}
	var saved: Dictionary = {}
	var images: Array = action["images"]
	for entry: Dictionary in images:
		var source: String = _first_source(preset, entry, loaded)
		if source.is_empty():
			continue
		var entry_name: String = entry["name"]
		if _copies(entry, source):
			# Godot uses a file of this type as it is; rules_godot copies it.
			copied[entry_name] = source
			continue
		var image: Image = loaded[source]
		if _render(preset, entry, source, image, saved):
			rendered.append(entry_name)
	return {"rendered": rendered, "copied": copied}


# Return the first source of the entry that Godot can use, or "" if none works.
# `loaded` caches the image of each path tried. It holds null for a path that is copied
# or does not load.
func _first_source(preset: EditorExportPreset, entry: Dictionary, loaded: Dictionary) -> String:
	var candidates: Array = entry["sources"]
	for candidate: Variant in candidates:
		var source: String = _resolve(preset, candidate)
		if source.is_empty():
			continue
		if not loaded.has(source):
			loaded[source] = null if _copies(entry, source) else _load(source)
		if _copies(entry, source) or loaded[source] != null:
			return source
	return ""


func _copies(entry: Dictionary, path: String) -> bool:
	if not entry.has("copy"):
		return false
	var extension: String = entry["copy"]["extension"]
	return path.ends_with(extension)


# The path a source names. option:NAME and setting:NAME read it from an export
# option or a project setting, and file:PATH names an image file. editor_icon:NAME
# stays as it is: an icon of the editor's theme. A pair [source, condition] applies
# only if the condition resolves to a path too.
func _resolve(preset: EditorExportPreset, source: Variant) -> String:
	if source is Array:
		var pair: Array = source
		return _resolve(preset, pair[0]) if not _resolve(preset, pair[1]).is_empty() else ""
	var text: String = source
	var kind: String = text.get_slice(":", 0)
	var source_name: String = text.substr(kind.length() + 1)
	if kind == "option":
		return str(preset.get(source_name)).strip_edges()
	if kind == "setting":
		return str(preset.get_project_setting(source_name)).strip_edges()
	if kind == "editor_icon":
		return text
	return source_name


# As EditorExportPlatform loads icons and splash images: the imported texture,
# else the image file, or an icon of the editor's theme, as the web export's default.
func _load(path: String) -> Image:
	if path.begins_with("editor_icon:"):
		var theme: Theme = EditorInterface.get_editor_theme()
		return theme.get_icon(path.trim_prefix("editor_icon:"), "EditorIcons").get_image()
	var imported: Image = _imported(path)
	if imported != null:
		return imported
	if not FileAccess.file_exists(path):
		return null
	var image: Image = Image.load_from_file(path)
	return image if image != null and not image.is_empty() else null


# The decompressed image of the texture imported from path, or null if there is none.
func _imported(path: String) -> Image:
	if not ResourceLoader.exists(path):
		return null
	var texture: Texture2D = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	if texture == null:
		return null
	var imported: Image = texture.get_image()
	if imported == null or imported.is_empty():
		return null
	if imported.is_compressed():
		var _decompressed: Error = imported.decompress()
	return imported


# Save the entry's rendering of the source's image to its output. A rendering
# that is saved already is copied instead; saved maps each rendering to its file.
func _render(preset: EditorExportPreset, entry: Dictionary, source: String, image: Image, saved: Dictionary) -> bool:
	var output: String = entry["output"]
	var key: String = JSON.stringify([source, entry.get("size", 0), entry.get("interpolation"), entry.get("opaque", false), entry.get("shared_resizes"), output.get_extension()])
	if saved.has(key):
		var _made: Error = DirAccess.make_dir_recursive_absolute(output.get_base_dir())
		var copied_from: String = saved[key]
		return DirAccess.copy_absolute(copied_from, output) == OK
	var copy: Image = image.duplicate()
	if source.begins_with("editor_icon:"):
		_resize_as_shared(preset, entry, copy)
	if not _save(preset, entry, copy):
		return false
	saved[key] = output
	return true


# Resize an icon of the editor's theme as the exports before it resized the one image they
# share: entry["shared_resizes"] names the sizes, those after guard only where it is set.
func _resize_as_shared(preset: EditorExportPreset, entry: Dictionary, image: Image) -> void:
	if not entry.has("shared_resizes"):
		return
	var shared: Dictionary = entry["shared_resizes"]
	var sizes: Array = []
	var guard: String = shared["guard"]
	if preset.get(guard):
		sizes.append_array(shared["guarded"])
	sizes.append_array(shared["sizes"])
	for size: int in sizes:
		image.resize(size, size, Image.INTERPOLATE_BILINEAR)


func _save(preset: EditorExportPreset, entry: Dictionary, image: Image) -> bool:
	var size: int = entry.get("size", 0)
	if size:
		var interpolation: Variant = entry["interpolation"]
		if interpolation is String:
			var option: String = interpolation
			interpolation = preset.get(option.trim_prefix("option:"))
		var mode: int = interpolation
		image.resize(size, size, mode as Image.Interpolation)
	if entry.get("opaque", false) and image.detect_alpha() != Image.ALPHA_NONE:
		# Godot fills an icon that must be opaque with the boot splash color.
		var opaque: Image = Image.create_empty(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8)
		var background: Color = preset.get_project_setting("application/boot_splash/bg_color")
		opaque.fill(background)
		image.convert(Image.FORMAT_RGBA8)
		opaque.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
		image = opaque
	var path: String = entry["output"]
	var _made: Error = DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error: Error = image.save_webp(path) if path.ends_with(".webp") else image.save_png(path)
	if error != OK:
		push_error("Could not save %s: %s" % [path, error_string(error)])
	return error == OK


func _versions(preset: EditorExportPreset) -> Dictionary:
	var versions: Dictionary = {}
	var version_names: Array = action["versions"]
	for version_name: String in version_names:
		versions[version_name] = preset.get_version(version_name, false)
	return versions


# The project's name in each locale of its translations, as Godot's Apple
# exporters name the application.
func _name_translations(preset: EditorExportPreset) -> Dictionary:
	var project_name: String = str(preset.get_project_setting("application/config/name"))
	var names: Variant = preset.get_project_setting("application/config/name_localized")
	var domain: TranslationDomain = TranslationServer.get_or_add_domain("rules_godot.project_name")
	var locales: Array[String] = _add_translations(domain)
	var translated: Dictionary = {}
	var localized: Dictionary = names if names is Dictionary else {}
	if not localized.is_empty():
		for locale: String in locales:
			translated[locale] = localized.get(locale, null)
		return translated
	for locale: String in locales:
		domain.set_locale_override(locale)
		var value: String = str(domain.translate(project_name))
		translated[locale] = null
		if value != project_name:
			translated[locale] = value
	return translated


# Add the project's translations to the domain and return their locales.
func _add_translations(domain: TranslationDomain) -> Array[String]:
	var locales: Array[String] = []
	var translations: PackedStringArray = ProjectSettings.get_setting("internationalization/locale/translations", PackedStringArray())
	for path: String in translations:
		if not ResourceLoader.exists(path):
			continue
		var translation: Translation = load(path) as Translation
		if translation == null:
			continue
		domain.add_translation(translation)
		if not locales.has(translation.get_locale()):
			locales.append(translation.get_locale())
	return locales


func _plain(value: Variant) -> Variant:
	match typeof(value):
		TYPE_COLOR:
			var color: Color = value
			return [color.r, color.g, color.b, color.a]
		TYPE_VECTOR2:
			var vector: Vector2 = value
			return [vector.x, vector.y]
		TYPE_VECTOR2I:
			var cells: Vector2i = value
			return [cells.x, cells.y]
		TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_ARRAY:
			var items: Array = value
			return items.map(_plain)
		TYPE_DICTIONARY:
			var dictionary: Dictionary = value
			var plain: Dictionary = {}
			for key: Variant in dictionary:
				plain[str(key)] = _plain(dictionary[key])
			return plain
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME:
			return value if typeof(value) != TYPE_STRING_NAME else str(value)
	return null
