#include "firebase/firestore/native/backend.h"
#include "firebase/firestore/native/firestore.h"
#include "firebase/firestore/native/firestore_task.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize(ModuleInitializationLevel level) {
  if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
  ClassDB::register_class<FirestoreTask>();
  ClassDB::register_class<FirebaseFirestore>();
}
static void uninitialize(ModuleInitializationLevel level) {
  if (level == MODULE_INITIALIZATION_LEVEL_SCENE) firebase_firestore::backend_shutdown();
}

extern "C" GDExtensionBool GDE_EXPORT firebase_firestore_init(
    GDExtensionInterfaceGetProcAddress get_proc_address, GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization) {
  GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
  init.register_initializer(initialize);
  init.register_terminator(uninitialize);
  init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
  return init.init();
}
