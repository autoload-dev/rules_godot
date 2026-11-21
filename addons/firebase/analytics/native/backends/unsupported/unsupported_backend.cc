// The editor and desktop platforms: no Firebase; every call does nothing.
#include "firebase/analytics/native/backend.h"

using namespace godot;

namespace firebase_analytics {
bool backend_is_supported() { return false; }
void backend_log_event(const String &, const Dictionary &) {}
void backend_set_user_id(const String &) {}
void backend_set_user_property(const String &, const String &) {}
void backend_set_collection_enabled(bool) {}
} // namespace firebase_analytics
