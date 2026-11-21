#pragma once

#include <godot_cpp/classes/object.hpp>

// The GDScript-facing API of Firebase Core: static methods, identical on every platform.
class FirebaseCore : public godot::Object {
  GDCLASS(FirebaseCore, godot::Object)

protected:
  static void _bind_methods();

public:
  // Initializes the default Firebase app; true once it exists. Repeated calls are cheap.
  static bool initialize();
  static bool is_initialized();
  // False in the editor and on desktop platforms, where Firebase does nothing.
  static bool is_supported();
};
