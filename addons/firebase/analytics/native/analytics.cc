#include "firebase/analytics/native/analytics.h"

#include "firebase/analytics/native/backend.h"
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

namespace {
// The parameters every backend logs: string keys, and booleans, integers, floats and strings
// as values. Other values become their Godot string form; null values are left out, since
// Firebase has no null parameter. Converted here, Android and iOS log the same event.
Dictionary event_parameters(const Dictionary &parameters) {
  Dictionary result;
  const Array keys = parameters.keys();
  for (int64_t i = 0; i < keys.size(); ++i) {
    const Variant value = parameters[keys[i]];
    switch (value.get_type()) {
    case Variant::NIL: continue;
    case Variant::BOOL:
    case Variant::INT:
    case Variant::FLOAT:
    case Variant::STRING: result[String(keys[i])] = value; break;
    default: result[String(keys[i])] = value.stringify(); break;
    }
  }
  return result;
}
} // namespace

void FirebaseAnalytics::_bind_methods() {
  ClassDB::bind_static_method("FirebaseAnalytics",
                              D_METHOD("log_event", "name", "parameters"),
                              &FirebaseAnalytics::log_event, DEFVAL(Dictionary()));
  ClassDB::bind_static_method("FirebaseAnalytics", D_METHOD("set_user_id", "user_id"),
                              &FirebaseAnalytics::set_user_id);
  ClassDB::bind_static_method("FirebaseAnalytics",
                              D_METHOD("set_user_property", "name", "value"),
                              &FirebaseAnalytics::set_user_property);
  ClassDB::bind_static_method("FirebaseAnalytics", D_METHOD("set_collection_enabled", "enabled"),
                              &FirebaseAnalytics::set_collection_enabled);
  ClassDB::bind_static_method("FirebaseAnalytics", D_METHOD("is_supported"),
                              &FirebaseAnalytics::is_supported);
}

void FirebaseAnalytics::log_event(const String &name, const Dictionary &parameters) {
  firebase_analytics::backend_log_event(name, event_parameters(parameters));
}
void FirebaseAnalytics::set_user_id(const String &user_id) {
  firebase_analytics::backend_set_user_id(user_id);
}
void FirebaseAnalytics::set_user_property(const String &name, const String &value) {
  firebase_analytics::backend_set_user_property(name, value);
}
void FirebaseAnalytics::set_collection_enabled(bool enabled) {
  firebase_analytics::backend_set_collection_enabled(enabled);
}
bool FirebaseAnalytics::is_supported() { return firebase_analytics::backend_is_supported(); }
