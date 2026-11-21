#include "firebase/firestore/native/firestore.h"

#include "firebase/firestore/native/backend.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

using namespace godot;

namespace {
const char *const OPERATORS[] = {"==", "!=",          "<",                  ">",  ">=",
                                 "<=", "array-contains", "array-contains-any", "in", "not-in"};

// Firestore paths alternate collection and document IDs: collections have an odd number of
// segments, documents an even one. The SDKs abort on malformed paths instead of failing.
bool is_path(const String &path, bool document) {
  const PackedStringArray segments = path.split("/");
  for (const String &segment : segments) {
    if (segment.is_empty()) return false;
  }
  return segments.size() % 2 == (document ? 0 : 1);
}

bool is_operator(const String &name) {
  for (const char *op : OPERATORS) {
    if (name == op) return true;
  }
  return false;
}

String filters_error(const Array &filters) {
  for (int64_t i = 0; i < filters.size(); ++i) {
    const Variant &filter = filters[i];
    if (filter.get_type() != Variant::ARRAY || Array(filter).size() != 3) {
      return vformat("Filter %d is not a [field, operator, value] array.", i);
    }
    const Array triple = filter;
    if (triple[0].get_type() != Variant::STRING || String(triple[0]).is_empty()) {
      return vformat("Filter %d has no field name.", i);
    }
    if (triple[1].get_type() != Variant::STRING || !is_operator(triple[1])) {
      return vformat("Filter %d has an unknown operator: %s.", i, triple[1]);
    }
  }
  return String();
}

// A new task that `operation` starts with the backend, or one already failed for lack of
// support or with `error`.
template <typename Operation>
Ref<FirestoreTask> start(const String &error, Operation operation) {
  Ref<FirestoreTask> task;
  task.instantiate();
  if (!firebase_firestore::backend_is_supported()) {
    task->fail("Firebase is unavailable on this platform.");
  } else if (!error.is_empty()) {
    task->fail(error);
  } else {
    operation(task);
  }
  return task;
}

String document_error(const String &path) {
  return is_path(path, true) ? String() : "Not a document path: \"" + path + "\".";
}
} // namespace

void FirebaseFirestore::_bind_methods() {
  ClassDB::bind_static_method("FirebaseFirestore", D_METHOD("is_supported"),
                              &FirebaseFirestore::is_supported);
  ClassDB::bind_static_method("FirebaseFirestore", D_METHOD("use_emulator", "host", "port"),
                              &FirebaseFirestore::use_emulator, DEFVAL(8080));
  ClassDB::bind_static_method("FirebaseFirestore", D_METHOD("get_document", "path"),
                              &FirebaseFirestore::get_document);
  ClassDB::bind_static_method("FirebaseFirestore",
                              D_METHOD("set_document", "path", "data", "merge"),
                              &FirebaseFirestore::set_document, DEFVAL(false));
  ClassDB::bind_static_method("FirebaseFirestore", D_METHOD("delete_document", "path"),
                              &FirebaseFirestore::delete_document);
  ClassDB::bind_static_method(
      "FirebaseFirestore",
      D_METHOD("query", "collection_path", "filters", "order_by", "descending", "limit"),
      &FirebaseFirestore::query, DEFVAL(Array()), DEFVAL(String()), DEFVAL(false), DEFVAL(0));
}

bool FirebaseFirestore::is_supported() { return firebase_firestore::backend_is_supported(); }

void FirebaseFirestore::use_emulator(const String &host, int64_t port) {
  firebase_firestore::backend_use_emulator(host, port);
}

Ref<FirestoreTask> FirebaseFirestore::get_document(const String &path) {
  return start(document_error(path), [&](const Ref<FirestoreTask> &task) {
    firebase_firestore::backend_get_document(path, task);
  });
}

Ref<FirestoreTask> FirebaseFirestore::set_document(const String &path, const Dictionary &data,
                                                   bool merge) {
  return start(document_error(path), [&](const Ref<FirestoreTask> &task) {
    firebase_firestore::backend_set_document(path, data, merge, task);
  });
}

Ref<FirestoreTask> FirebaseFirestore::delete_document(const String &path) {
  return start(document_error(path), [&](const Ref<FirestoreTask> &task) {
    firebase_firestore::backend_delete_document(path, task);
  });
}

Ref<FirestoreTask> FirebaseFirestore::query(const String &collection_path, const Array &filters,
                                            const String &order_by, bool descending,
                                            int64_t limit) {
  String error;
  if (!is_path(collection_path, false)) {
    error = "Not a collection path: \"" + collection_path + "\".";
  } else if (limit < 0) {
    error = "The limit must not be negative.";
  } else {
    error = filters_error(filters);
  }
  return start(error, [&](const Ref<FirestoreTask> &task) {
    firebase_firestore::backend_query({collection_path, filters, order_by, descending, limit}, task);
  });
}
