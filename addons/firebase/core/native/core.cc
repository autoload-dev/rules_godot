#include "firebase/core/native/core.h"

#include "firebase/core/native/backend.h"
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void FirebaseCore::_bind_methods() {
  ClassDB::bind_static_method("FirebaseCore", D_METHOD("initialize"), &FirebaseCore::initialize);
  ClassDB::bind_static_method("FirebaseCore", D_METHOD("is_initialized"),
                              &FirebaseCore::is_initialized);
  ClassDB::bind_static_method("FirebaseCore", D_METHOD("is_supported"),
                              &FirebaseCore::is_supported);
}

bool FirebaseCore::initialize() { return firebase_core::backend_initialize(); }
bool FirebaseCore::is_initialized() { return firebase_core::backend_is_initialized(); }
bool FirebaseCore::is_supported() { return firebase_core::backend_is_supported(); }
