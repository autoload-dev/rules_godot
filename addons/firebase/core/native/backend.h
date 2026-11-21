#pragma once

// The platform's side of FirebaseCore; each backend defines these once.
namespace firebase_core {
bool backend_is_supported();
// Initializes the default app from the application's configuration; true once it exists.
bool backend_initialize();
bool backend_is_initialized();
} // namespace firebase_core
