#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/dictionary.hpp>

// The GDScript-facing API of Google Analytics for Firebase: static methods, identical on
// every platform; they do nothing where Firebase is unsupported.
class FirebaseAnalytics : public godot::Object {
  GDCLASS(FirebaseAnalytics, godot::Object)

protected:
  static void _bind_methods();

public:
  static void log_event(const godot::String &name, const godot::Dictionary &parameters);
  // An empty ID clears it.
  static void set_user_id(const godot::String &user_id);
  // An empty value clears the property.
  static void set_user_property(const godot::String &name, const godot::String &value);
  static void set_collection_enabled(bool enabled);
  static bool is_supported();
};
