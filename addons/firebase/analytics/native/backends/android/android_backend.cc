// Android: a bridge to the FirebaseAnalyticsAndroid plugin singleton.
#include "firebase/analytics/native/backend.h"
#include <godot_cpp/classes/engine.hpp>

using namespace godot;

namespace firebase_analytics {
namespace {
// The plugin singleton, looked up once it exists.
Object *plugin() {
  static Object *singleton = nullptr;
  if (singleton) return singleton;
  Engine *engine = Engine::get_singleton();
  if (!engine || !engine->has_singleton("FirebaseAnalyticsAndroid")) return nullptr;
  singleton = engine->get_singleton("FirebaseAnalyticsAndroid");
  return singleton;
}
} // namespace

bool backend_is_supported() { return plugin() != nullptr; }

void backend_log_event(const String &name, const Dictionary &parameters) {
  if (Object *singleton = plugin()) singleton->call("log_event", name, parameters);
}

void backend_set_user_id(const String &user_id) {
  if (Object *singleton = plugin()) singleton->call("set_user_id", user_id);
}

void backend_set_user_property(const String &name, const String &value) {
  if (Object *singleton = plugin()) singleton->call("set_user_property", name, value);
}

void backend_set_collection_enabled(bool enabled) {
  if (Object *singleton = plugin()) singleton->call("set_collection_enabled", enabled);
}
} // namespace firebase_analytics
