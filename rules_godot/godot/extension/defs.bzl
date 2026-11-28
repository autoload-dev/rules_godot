"""Extensions, the extension libraries they load, and the C++ shorthand over both."""

load("//godot/extension/private:cc_extension.bzl", _godot_cc_extension = "godot_cc_extension")
load("//godot/extension/private:extension.bzl", _godot_extension = "godot_extension")
load("//godot/extension/private:extension_library.bzl", _godot_extension_library = "godot_extension_library")

godot_extension = _godot_extension
godot_extension_library = _godot_extension_library
godot_cc_extension = _godot_cc_extension
