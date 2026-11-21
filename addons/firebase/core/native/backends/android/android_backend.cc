// Android: a bridge to the FirebaseCoreAndroid plugin singleton.
#include "firebase/core/native/backend.h"
#include <godot_cpp/classes/engine.hpp>

using namespace godot;

namespace firebase_core {
namespace {
Object *plugin() {
  Engine *engine = Engine::get_singleton();
  if (!engine || !engine->has_singleton("FirebaseCoreAndroid")) return nullptr;
  return engine->get_singleton("FirebaseCoreAndroid");
}

bool call_bool(const char *method) {
  Object *singleton = plugin();
  // Java singleton methods are dispatched dynamically; a failed call yields a nil Variant.
  return singleton && singleton->call(method).booleanize();
}
} // namespace

bool backend_is_supported() { return plugin() != nullptr; }
bool backend_initialize() { return call_bool("initialize"); }
bool backend_is_initialized() { return call_bool("is_initialized"); }
} // namespace firebase_core
