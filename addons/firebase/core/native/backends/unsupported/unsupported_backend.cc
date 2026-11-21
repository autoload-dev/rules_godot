// The editor and desktop platforms: no Firebase.
#include "firebase/core/native/backend.h"

namespace firebase_core {
bool backend_is_supported() { return false; }
bool backend_initialize() { return false; }
bool backend_is_initialized() { return false; }
} // namespace firebase_core
