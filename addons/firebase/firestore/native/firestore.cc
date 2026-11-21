#include "firebase/firestore/native/firestore.h"

#include "firebase/firestore/native/backend.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

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

// The operators whose value is a list of values.
const char *const LIST_OPERATORS[] = {"array-contains-any", "in", "not-in"};

template <size_t N> bool contains(const char *const (&names)[N], const String &name) {
  for (const char *candidate : names) {
    if (name == candidate) return true;
  }
  return false;
}

// Arrays and packed arrays but byte arrays, which are blobs.
bool is_list(const Variant &value) {
  const Variant::Type type = value.get_type();
  return type == Variant::ARRAY || (type > Variant::PACKED_BYTE_ARRAY && type < Variant::VARIANT_MAX);
}

String filter_error(int64_t index, const Array &triple) {
  if (triple[0].get_type() != Variant::STRING || String(triple[0]).is_empty()) {
    return vformat("Filter %d has no field name.", index);
  }
  if (triple[1].get_type() != Variant::STRING || !contains(OPERATORS, triple[1])) {
    return vformat("Filter %d has an unknown operator: %s.", index, triple[1]);
  }
  if (contains(LIST_OPERATORS, triple[1]) && !is_list(triple[2])) {
    return vformat("Filter %d needs a list of values for %s.", index, triple[1]);
  }
  return String();
}

Variant firestore_value(const Variant &value);

Array firestore_list(const Array &values) {
  Array result;
  for (int64_t i = 0; i < values.size(); ++i) result.push_back(firestore_value(values[i]));
  return result;
}

Dictionary firestore_map(const Dictionary &fields) {
  Dictionary result;
  const Array keys = fields.keys();
  for (int64_t i = 0; i < keys.size(); ++i) {
    result[String(keys[i])] = firestore_value(fields[keys[i]]);
  }
  return result;
}

// Values both backends take as they are.
bool is_stored_as_is(Variant::Type type) {
  switch (type) {
  case Variant::NIL:
  case Variant::BOOL:
  case Variant::INT:
  case Variant::FLOAT:
  case Variant::STRING:
  case Variant::PACKED_BYTE_ARRAY: return true;
  default: return false;
  }
}

// A Godot value as both backends store it: null, booleans, integers, floats, strings and byte
// arrays as they are, dictionaries as maps with string keys, other arrays as lists, and every
// other value in its Godot string form.
Variant firestore_value(const Variant &value) {
  if (is_stored_as_is(value.get_type())) return value;
  if (value.get_type() == Variant::DICTIONARY) return firestore_map(value);
  if (is_list(value)) return firestore_list(UtilityFunctions::type_convert(value, Variant::ARRAY));
  return value.stringify();
}

// The filters with their values as the backends take them.
Array firestore_filters(const Array &filters) {
  Array result;
  for (int64_t i = 0; i < filters.size(); ++i) {
    const Array triple = filters[i];
    Array filter;
    filter.push_back(triple[0]);
    filter.push_back(triple[1]);
    filter.push_back(firestore_value(triple[2]));
    result.push_back(filter);
  }
  return result;
}

String filters_error(const Array &filters) {
  for (int64_t i = 0; i < filters.size(); ++i) {
    const Variant &filter = filters[i];
    if (filter.get_type() != Variant::ARRAY || Array(filter).size() != 3) {
      return vformat("Filter %d is not a [field, operator, value] array.", i);
    }
    const String error = filter_error(i, filter);
    if (!error.is_empty()) return error;
  }
  return String();
}

// A new task that `operation` starts with the backend, or one already failed with `error`
// or for lack of support. Malformed arguments fail on every platform.
template <typename Operation>
Ref<FirestoreTask> start(const String &error, Operation operation) {
  Ref<FirestoreTask> task;
  task.instantiate();
  if (!error.is_empty()) {
    task->fail(error);
  } else if (!firebase_firestore::backend_is_supported()) {
    task->fail("Firebase is unavailable on this platform.");
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
    firebase_firestore::backend_set_document(path, firestore_map(data), merge, task);
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
    firebase_firestore::backend_query(
        {collection_path, firestore_filters(filters), order_by, descending, limit}, task);
  });
}
