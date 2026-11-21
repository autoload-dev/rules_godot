#pragma once

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/variant.hpp>

// One Firestore operation. GDScript awaits `completed`, then reads `error` and `result`;
// the signal is always deferred, so it fires after the caller started awaiting it.
class FirestoreTask : public godot::RefCounted {
  GDCLASS(FirestoreTask, godot::RefCounted)

  bool done = false;
  godot::String error;
  godot::Variant result;

  void finish(const godot::Variant &value, const godot::String &message);

protected:
  static void _bind_methods();

public:
  // Called once by a backend on the main thread.
  void succeed(const godot::Variant &value);
  void fail(const godot::String &message);

  bool is_done() const { return done; }
  // Empty when the operation succeeded.
  godot::String get_error() const { return error; }
  // A document's data (null when it does not exist), the documents of a query, or null.
  godot::Variant get_result() const { return result; }
};
