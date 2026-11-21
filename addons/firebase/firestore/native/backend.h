#pragma once

#include "firebase/firestore/native/firestore_task.h"
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

// The platform's side of FirebaseFirestore; each backend defines these once. Paths and
// filters are validated before they reach a backend, and values hold only null, booleans,
// integers, floats, strings, byte arrays, arrays and dictionaries with string keys. Every operation completes its task exactly once. Tasks
// pass by value: Objective-C blocks capture C++ references by reference.
namespace firebase_firestore {
bool backend_is_supported();
void backend_use_emulator(const godot::String &host, int64_t port);
void backend_get_document(const godot::String &path, godot::Ref<FirestoreTask> task);
void backend_set_document(const godot::String &path, const godot::Dictionary &data, bool merge,
                          godot::Ref<FirestoreTask> task);
void backend_delete_document(const godot::String &path, godot::Ref<FirestoreTask> task);
// A validated query: `filters` holds [field, operator, value] arrays; an empty `order_by`
// keeps Firestore's order and a `limit` of 0 returns every match.
struct QuerySpec {
  godot::String collection_path;
  godot::Array filters;
  godot::String order_by;
  bool descending = false;
  int64_t limit = 0;
};
void backend_query(const QuerySpec &query, godot::Ref<FirestoreTask> task);
// Drops what the backend holds on to before the extension unloads.
void backend_shutdown();
} // namespace firebase_firestore
