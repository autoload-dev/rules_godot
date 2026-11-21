// iOS: FirebaseFirestore.framework of //ios. Completion blocks run on the
// main queue, which is Godot's main thread on iOS.
#include "firebase/firestore/native/backend.h"
#import <FirebaseCore/FirebaseCore.h>
#import <FirebaseFirestore/FirebaseFirestore.h>
#include <godot_cpp/variant/packed_byte_array.hpp>

using namespace godot;

namespace firebase_firestore {
namespace {
NSString *ns(const String &text) { return [NSString stringWithUTF8String:text.utf8().get_data()]; }

String to_string(NSString *text) { return String::utf8(text.UTF8String); }

id to_firestore(const Variant &value);

NSArray *to_firestore_array(const Array &array) {
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:array.size()];
  for (int64_t i = 0; i < array.size(); ++i) [result addObject:to_firestore(array[i])];
  return result;
}

NSDictionary<NSString *, id> *to_firestore_map(const Dictionary &dictionary) {
  NSMutableDictionary<NSString *, id> *result = [NSMutableDictionary dictionary];
  const Array keys = dictionary.keys();
  for (int64_t i = 0; i < keys.size(); ++i) {
    result[ns(String(keys[i]))] = to_firestore(dictionary[keys[i]]);
  }
  return result;
}

NSData *to_firestore_blob(const PackedByteArray &bytes) {
  return [NSData dataWithBytes:bytes.ptr() length:bytes.size()];
}

// Scalars as Firestore takes them; FirebaseFirestore left only null, booleans, integers,
// floats and strings.
id to_firestore_scalar(const Variant &value) {
  switch (value.get_type()) {
  case Variant::NIL: return [NSNull null];
  case Variant::BOOL: return @((bool)value);
  case Variant::INT: return @((int64_t)value);
  case Variant::FLOAT: return @((double)value);
  default: return ns(value.stringify());
  }
}

// Godot values as Firestore takes them, as on Android: packed byte arrays become blobs,
// other arrays lists.
id to_firestore(const Variant &value) {
  switch (value.get_type()) {
  case Variant::DICTIONARY: return to_firestore_map(value);
  case Variant::PACKED_BYTE_ARRAY: return to_firestore_blob(value);
  case Variant::ARRAY: return to_firestore_array(value);
  default: return to_firestore_scalar(value);
  }
}

Variant to_godot(id value);

Variant to_godot_number(NSNumber *number) {
  if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return (bool)number.boolValue;
  if (CFNumberIsFloatType((__bridge CFNumberRef)number)) return (double)number.doubleValue;
  return (int64_t)number.longLongValue;
}

Dictionary to_godot_dictionary(NSDictionary *dictionary) {
  Dictionary result;
  for (id key in dictionary) result[to_string([key description])] = to_godot(dictionary[key]);
  return result;
}

Array to_godot_array(NSArray *array) {
  Array result;
  for (id item in array) result.push_back(to_godot(item));
  return result;
}

Dictionary to_godot_geo_point(FIRGeoPoint *point) {
  Dictionary result;
  result["latitude"] = point.latitude;
  result["longitude"] = point.longitude;
  return result;
}

PackedByteArray to_godot_bytes(NSData *data) {
  PackedByteArray bytes;
  bytes.resize(data.length);
  memcpy(bytes.ptrw(), data.bytes, data.length);
  return bytes;
}

// Firestore's own value types: timestamps become seconds since the epoch, references paths,
// geo points dictionaries with latitude and longitude, blobs byte arrays.
Variant to_godot_firestore(id value) {
  if ([value isKindOfClass:[FIRTimestamp class]]) {
    FIRTimestamp *timestamp = value;
    return timestamp.seconds + timestamp.nanoseconds / 1e9;
  }
  if ([value isKindOfClass:[FIRDocumentReference class]]) {
    return to_string(((FIRDocumentReference *)value).path);
  }
  if ([value isKindOfClass:[FIRGeoPoint class]]) return to_godot_geo_point(value);
  if ([value isKindOfClass:[NSData class]]) return to_godot_bytes(value);
  return to_string([value description]);
}

// Firestore values as Godot takes them, the same as on Android.
Variant to_godot(id value) {
  if (value == nil || value == [NSNull null]) return Variant();
  if ([value isKindOfClass:[NSString class]]) return to_string(value);
  if ([value isKindOfClass:[NSNumber class]]) return to_godot_number(value);
  if ([value isKindOfClass:[NSDictionary class]]) return to_godot_dictionary(value);
  if ([value isKindOfClass:[NSArray class]]) return to_godot_array(value);
  return to_godot_firestore(value);
}

using Where = FIRQuery *(*)(FIRQuery *, NSString *, id);

// Firestore's filter for each operator that FirebaseFirestore accepts.
const struct {
  const char *op;
  Where where;
} WHERE[] = {
    {"==", [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f isEqualTo:v]; }},
    {"!=", [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f isNotEqualTo:v]; }},
    {"<", [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f isLessThan:v]; }},
    {"<=",
     [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f isLessThanOrEqualTo:v]; }},
    {">", [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f isGreaterThan:v]; }},
    {">=",
     [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f isGreaterThanOrEqualTo:v]; }},
    {"array-contains",
     [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f arrayContains:v]; }},
    {"array-contains-any",
     [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f arrayContainsAny:v]; }},
    {"in", [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f in:v]; }},
    {"not-in", [](FIRQuery *q, NSString *f, id v) { return [q queryWhereField:f notIn:v]; }},
};

// FirebaseFirestore validated the filter, so its operator is one of WHERE's.
FIRQuery *with_filter(FIRQuery *query, const Array &filter) {
  const String op = filter[1];
  for (const auto &entry : WHERE) {
    if (op == entry.op) return entry.where(query, ns(String(filter[0])), to_firestore(filter[2]));
  }
  return query;
}

Variant documents(FIRQuerySnapshot *snapshot) {
  Array result;
  for (FIRQueryDocumentSnapshot *document in snapshot.documents) {
    Dictionary entry;
    entry["id"] = to_string(document.documentID);
    entry["path"] = to_string(document.reference.path);
    entry["data"] = to_godot(document.data);
    result.push_back(entry);
  }
  return result;
}

Variant document_data(FIRDocumentSnapshot *snapshot) {
  return snapshot.exists ? to_godot(snapshot.data) : Variant();
}

void fail(const Ref<FirestoreTask> &task, NSString *message) {
  task->fail(message ? to_string(message) : String());
}

// Runs `operation` with the default app's Firestore, failing the task when there is no
// default app or the SDK raises an exception, as it does for invalid data.
void run(const Ref<FirestoreTask> &task, void (^operation)(FIRFirestore *)) {
  if ([FIRApp defaultApp] == nil) {
    task->fail("The default Firebase app is not configured.");
    return;
  }
  @try {
    operation([FIRFirestore firestore]);
  } @catch (NSException *exception) {
    fail(task, exception.reason);
  }
}

// A completion block for operations without a result.
void (^completion(Ref<FirestoreTask> task))(NSError *) {
  return ^(NSError *error) {
    if (error) {
      fail(task, error.localizedDescription);
    } else {
      task->succeed(Variant());
    }
  };
}

// A completion block for operations whose result `convert` turns into the task's result.
template <typename Snapshot>
void (^completion(Ref<FirestoreTask> task, Variant (*convert)(Snapshot)))(Snapshot, NSError *) {
  return ^(Snapshot snapshot, NSError *error) {
    if (error) {
      fail(task, error.localizedDescription);
    } else {
      task->succeed(convert(snapshot));
    }
  };
}
} // namespace

bool backend_is_supported() { return true; }

void backend_use_emulator(const String &host, int64_t port) {
  if ([FIRApp defaultApp] == nil) return;
  @try {
    FIRFirestore *db = [FIRFirestore firestore];
    [db useEmulatorWithHost:ns(host) port:port];
    // The emulator speaks plain HTTP/2, but useEmulatorWithHost: leaves SSL on (SDK 13.2.0:
    // an iPhone's TLS handshake with an emulator on the LAN failed without this).
    FIRFirestoreSettings *settings = db.settings;
    settings.sslEnabled = NO;
    db.settings = settings;
  } @catch (NSException *) {
    // Firestore was used already; the emulator setting no longer applies.
  }
}

void backend_get_document(const String &path, Ref<FirestoreTask> task) {
  run(task, ^(FIRFirestore *db) {
    [[db documentWithPath:ns(path)] getDocumentWithCompletion:completion(task, &document_data)];
  });
}

void backend_set_document(const String &path, const Dictionary &data, bool merge,
                          Ref<FirestoreTask> task) {
  run(task, ^(FIRFirestore *db) {
    [[db documentWithPath:ns(path)] setData:to_firestore_map(data)
                                      merge:merge
                                 completion:completion(task)];
  });
}

void backend_delete_document(const String &path, Ref<FirestoreTask> task) {
  run(task, ^(FIRFirestore *db) {
    [[db documentWithPath:ns(path)] deleteDocumentWithCompletion:completion(task)];
  });
}

void backend_query(const QuerySpec &spec, Ref<FirestoreTask> task) {
  run(task, ^(FIRFirestore *db) {
    FIRQuery *query = [db collectionWithPath:ns(spec.collection_path)];
    for (int64_t i = 0; i < spec.filters.size(); ++i) query = with_filter(query, spec.filters[i]);
    if (!spec.order_by.is_empty()) {
      query = [query queryOrderedByField:ns(spec.order_by) descending:spec.descending];
    }
    if (spec.limit > 0) query = [query queryLimitedTo:spec.limit];
    [query getDocumentsWithCompletion:completion(task, &documents)];
  });
}
// The SDK's completion blocks hold the tasks they complete; nothing else is kept.
void backend_shutdown() {}
} // namespace firebase_firestore
