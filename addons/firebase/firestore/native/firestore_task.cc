#include "firebase/firestore/native/firestore_task.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void FirestoreTask::_bind_methods() {
  ClassDB::bind_method(D_METHOD("is_done"), &FirestoreTask::is_done);
  ClassDB::bind_method(D_METHOD("get_error"), &FirestoreTask::get_error);
  ClassDB::bind_method(D_METHOD("get_result"), &FirestoreTask::get_result);
  ADD_PROPERTY(PropertyInfo(Variant::BOOL, "done"), "", "is_done");
  ADD_PROPERTY(PropertyInfo(Variant::STRING, "error"), "", "get_error");
  ADD_PROPERTY(PropertyInfo(Variant::NIL, "result", PROPERTY_HINT_NONE, "",
                            PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_NIL_IS_VARIANT),
               "", "get_result");
  ADD_SIGNAL(MethodInfo("completed"));
}

void FirestoreTask::finish(const Variant &value, const String &message) {
  if (done) return;
  done = true;
  result = value;
  error = message;
  call_deferred("emit_signal", "completed");
}

void FirestoreTask::succeed(const Variant &value) { finish(value, String()); }

void FirestoreTask::fail(const String &message) {
  finish(Variant(), message.is_empty() ? String("Firestore operation failed.") : message);
}
