#pragma once

#include "firebase/firestore/native/firestore_task.h"
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

// The GDScript-facing API of Cloud Firestore: static methods, identical on every platform.
// Each operation returns a FirestoreTask; where Firebase is unsupported it fails.
class FirebaseFirestore : public godot::Object {
  GDCLASS(FirebaseFirestore, godot::Object)

protected:
  static void _bind_methods();

public:
  static bool is_supported();
  // Talks to the Firestore emulator instead of the cloud; call before any other operation.
  static void use_emulator(const godot::String &host, int64_t port);
  // Result: the document's data, or null when it does not exist.
  static godot::Ref<FirestoreTask> get_document(const godot::String &path);
  // Replaces the document, or with `merge` updates only the given fields. Result: null.
  static godot::Ref<FirestoreTask> set_document(const godot::String &path,
                                                const godot::Dictionary &data, bool merge);
  static godot::Ref<FirestoreTask> delete_document(const godot::String &path);
  // `filters`: [field, operator, value] arrays, operators ==, !=, <, <=, >, >=,
  // array-contains, array-contains-any, in and not-in. Result: an array of dictionaries with
  // the keys id, path and data.
  static godot::Ref<FirestoreTask> query(const godot::String &collection_path,
                                         const godot::Array &filters, const godot::String &order_by,
                                         bool descending, int64_t limit);
};
