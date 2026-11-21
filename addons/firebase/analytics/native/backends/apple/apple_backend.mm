// iOS: FirebaseAnalytics.framework of //ios.
#include "firebase/analytics/native/backend.h"
#import <FirebaseAnalytics/FirebaseAnalytics.h>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace firebase_analytics {
namespace {
NSString *ns(const String &text) { return [NSString stringWithUTF8String:text.utf8().get_data()]; }

NSDictionary<NSString *, id> *ns(const Dictionary &parameters) {
  NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
  const Array keys = parameters.keys();
  for (int64_t i = 0; i < keys.size(); ++i) {
    const Variant value = parameters[keys[i]];
    id converted = nil;
    switch (value.get_type()) {
    case Variant::INT: converted = @((int64_t)value); break;
    case Variant::FLOAT: converted = @((double)value); break;
    default: converted = ns((String)value); break;
    }
    result[ns((String)keys[i])] = converted;
  }
  return result;
}
} // namespace

bool backend_is_supported() { return true; }

void backend_log_event(const String &name, const Dictionary &parameters) {
  [FIRAnalytics logEventWithName:ns(name) parameters:ns(parameters)];
}

void backend_set_user_id(const String &user_id) {
  [FIRAnalytics setUserID:user_id.is_empty() ? nil : ns(user_id)];
}

void backend_set_user_property(const String &name, const String &value) {
  [FIRAnalytics setUserPropertyString:value.is_empty() ? nil : ns(value) forName:ns(name)];
}

void backend_set_collection_enabled(bool enabled) {
  [FIRAnalytics setAnalyticsCollectionEnabled:enabled];
}
} // namespace firebase_analytics
