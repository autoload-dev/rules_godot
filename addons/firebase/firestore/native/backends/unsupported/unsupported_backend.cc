// The editor and desktop platforms: no Firebase. FirebaseFirestore fails every task before
// it reaches a backend, so only the support check and the emulator setting remain.
#include "firebase/firestore/native/backend.h"

using namespace godot;

namespace firebase_firestore {
bool backend_is_supported() { return false; }
void backend_use_emulator(const String &, int64_t) {}
void backend_get_document(const String &, Ref<FirestoreTask>) {}
void backend_set_document(const String &, const Dictionary &, bool, Ref<FirestoreTask>) {}
void backend_delete_document(const String &, Ref<FirestoreTask>) {}
void backend_query(const QuerySpec &, Ref<FirestoreTask>) {}
void backend_shutdown() {}
} // namespace firebase_firestore
