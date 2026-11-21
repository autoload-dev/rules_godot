// Android: a bridge to the FirebaseFirestoreAndroid plugin singleton. Java starts each
// operation under a request ID and emits `completed(id, outcome)` on Godot's thread; the
// outcome holds either "error" or "result".
#include "firebase/firestore/native/backend.h"
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

using namespace godot;

namespace firebase_firestore {
namespace {
const char *const SINGLETON = "FirebaseFirestoreAndroid";

HashMap<int64_t, Ref<FirestoreTask>> &pending() {
  static HashMap<int64_t, Ref<FirestoreTask>> tasks;
  return tasks;
}

void on_completed(int64_t id, const Dictionary &outcome) {
  HashMap<int64_t, Ref<FirestoreTask>>::Iterator entry = pending().find(id);
  if (entry == pending().end()) return;
  const Ref<FirestoreTask> task = entry->value;
  pending().remove(entry);
  if (outcome.has("error")) {
    task->fail(outcome["error"]);
  } else {
    task->succeed(outcome.get("result", Variant()));
  }
}

// The plugin singleton, connected to on_completed once it is found.
Object *plugin() {
  static Object *singleton = nullptr;
  if (singleton) return singleton;
  Engine *engine = Engine::get_singleton();
  if (!engine || !engine->has_singleton(SINGLETON)) return nullptr;
  singleton = engine->get_singleton(SINGLETON);
  singleton->connect("completed", callable_mp_static(&on_completed));
  return singleton;
}

// Shared by every instantiation of `start`, so request IDs are unique across operations.
int64_t next_id = 0;

// Registers the task under a new request ID and starts `method` with it.
template <typename... Args>
void start(const Ref<FirestoreTask> &task, const char *method, const Args &...args) {
  const int64_t id = ++next_id;
  pending()[id] = task;
  plugin()->call(method, id, args...);
}
} // namespace

bool backend_is_supported() { return plugin() != nullptr; }

void backend_use_emulator(const String &host, int64_t port) {
  if (Object *singleton = plugin()) singleton->call("use_emulator", host, port);
}

void backend_get_document(const String &path, Ref<FirestoreTask> task) {
  start(task, "get_document", path);
}

void backend_set_document(const String &path, const Dictionary &data, bool merge,
                          Ref<FirestoreTask> task) {
  start(task, "set_document", path, data, merge);
}

void backend_delete_document(const String &path, Ref<FirestoreTask> task) {
  start(task, "delete_document", path);
}

void backend_query(const QuerySpec &query, Ref<FirestoreTask> task) {
  // One dictionary: the JNI bridge rejects the filters as an array argument.
  Dictionary spec;
  spec["filters"] = query.filters;
  spec["order_by"] = query.order_by;
  spec["descending"] = query.descending;
  spec["limit"] = query.limit;
  start(task, "query", query.collection_path, spec);
}
} // namespace firebase_firestore
