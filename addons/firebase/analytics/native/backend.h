#pragma once

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

// The platform's side of FirebaseAnalytics; each backend defines these once.
namespace firebase_analytics {
bool backend_is_supported();
// Parameter keys are strings and values strings, integers, floats or booleans, which
// FirebaseAnalytics::log_event ensures; booleans become 0 or 1.
void backend_log_event(const godot::String &name, const godot::Dictionary &parameters);
void backend_set_user_id(const godot::String &user_id);
void backend_set_user_property(const godot::String &name, const godot::String &value);
void backend_set_collection_enabled(bool enabled);
} // namespace firebase_analytics
