package dev.autoload.firebase.firestore;

import com.google.android.gms.tasks.Task;
import com.google.firebase.Timestamp;
import com.google.firebase.firestore.Blob;
import com.google.firebase.firestore.DocumentReference;
import com.google.firebase.firestore.DocumentSnapshot;
import com.google.firebase.firestore.Filter;
import com.google.firebase.firestore.FirebaseFirestore;
import com.google.firebase.firestore.GeoPoint;
import com.google.firebase.firestore.Query;
import com.google.firebase.firestore.QuerySnapshot;
import com.google.firebase.firestore.SetOptions;
import java.lang.reflect.Array;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.BiFunction;
import java.util.function.Function;
import org.godotengine.godot.Dictionary;
import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

/**
 * Cloud Firestore behind the FirebaseFirestore class of the extension. Every operation runs
 * under the extension's request ID and ends with one {@code completed(id, outcome)} signal on
 * Godot's thread; the outcome holds either "error" or "result".
 */
public final class FirebaseFirestorePlugin extends GodotPlugin {
    private static final SignalInfo COMPLETED =
            new SignalInfo("completed", Integer.class, Dictionary.class);

    public FirebaseFirestorePlugin(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "FirebaseFirestoreAndroid";
    }

    @Override
    public Set<SignalInfo> getPluginSignals() {
        return Collections.singleton(COMPLETED);
    }

    @UsedByGodot
    public void use_emulator(String host, int port) {
        try {
            FirebaseFirestore.getInstance().useEmulator(host, port);
        } catch (RuntimeException e) {
            // Firestore was used already, or there is no default app; nothing to report to.
        }
    }

    @UsedByGodot
    public void get_document(int id, String path) {
        run(id, db -> db.document(path).get(), snapshot -> snapshot.exists()
                ? toGodot(snapshot.getData())
                : null);
    }

    @UsedByGodot
    public void set_document(int id, String path, Dictionary data, boolean merge) {
        Map<String, Object> fields = toFirestoreMap(data);
        run(id, db -> merge
                ? db.document(path).set(fields, SetOptions.merge())
                : db.document(path).set(fields), ignored -> null);
    }

    @UsedByGodot
    public void delete_document(int id, String path) {
        run(id, db -> db.document(path).delete(), ignored -> null);
    }

    /**
     * Runs a query whose filters, order_by, descending and limit come in {@code spec}: Godot's
     * JNI bridge rejects arrays of mixed values as arguments, but converts dictionaries
     * recursively.
     */
    @UsedByGodot
    public void query(int id, String collectionPath, Dictionary spec) {
        run(id, db -> {
            Query query = db.collection(collectionPath);
            for (Object filter : (Object[]) spec.get("filters")) {
                query = query.where(toFilter((Object[]) filter));
            }
            String orderBy = (String) spec.get("order_by");
            if (!orderBy.isEmpty()) {
                query = query.orderBy(orderBy, Boolean.TRUE.equals(spec.get("descending"))
                        ? Query.Direction.DESCENDING
                        : Query.Direction.ASCENDING);
            }
            long limit = ((Number) spec.get("limit")).longValue();
            return limit > 0 ? query.limit(limit).get() : query.get();
        }, FirebaseFirestorePlugin::documents);
    }

    /** Starts {@code operation} and reports its outcome, or the exception it threw. */
    private <T> void run(int id, Function<FirebaseFirestore, Task<T>> operation,
            Function<T, Object> result) {
        try {
            operation.apply(FirebaseFirestore.getInstance()).addOnCompleteListener(task -> {
                if (task.isSuccessful()) {
                    complete(id, "result", result.apply(task.getResult()));
                } else {
                    complete(id, "error", message(task.getException()));
                }
            });
        } catch (RuntimeException e) {
            complete(id, "error", message(e));
        }
    }

    private void complete(int id, String key, Object value) {
        Dictionary outcome = new Dictionary();
        outcome.put(key, value);
        runOnRenderThread(() -> emitSignal(COMPLETED.getName(), id, outcome));
    }

    /** The exception's message; FirestoreTask substitutes a generic one for "". */
    private static String message(Exception e) {
        return e == null || e.getMessage() == null ? "" : e.getMessage();
    }

    private static Object[] documents(QuerySnapshot snapshot) {
        List<DocumentSnapshot> documents = snapshot.getDocuments();
        Object[] result = new Object[documents.size()];
        for (int i = 0; i < result.length; i++) {
            DocumentSnapshot document = documents.get(i);
            Dictionary entry = new Dictionary();
            entry.put("id", document.getId());
            entry.put("path", document.getReference().getPath());
            entry.put("data", toGodot(document.getData()));
            result[i] = entry;
        }
        return result;
    }

    /** Firestore's filter for each operator that FirebaseFirestore accepts. */
    private static final Map<String, BiFunction<String, Object, Filter>> FILTERS =
            new HashMap<>();

    static {
        FILTERS.put("==", Filter::equalTo);
        FILTERS.put("!=", Filter::notEqualTo);
        FILTERS.put("<", Filter::lessThan);
        FILTERS.put("<=", Filter::lessThanOrEqualTo);
        FILTERS.put(">", Filter::greaterThan);
        FILTERS.put(">=", Filter::greaterThanOrEqualTo);
        FILTERS.put("array-contains", Filter::arrayContains);
        FILTERS.put("array-contains-any",
                (field, value) -> Filter.arrayContainsAny(field, (List<?>) value));
        FILTERS.put("in", (field, value) -> Filter.inArray(field, (List<?>) value));
        FILTERS.put("not-in", (field, value) -> Filter.notInArray(field, (List<?>) value));
    }

    /** FirebaseFirestore validated the filter, so its operator is one of FILTERS'. */
    private static Filter toFilter(Object[] filter) {
        return FILTERS.get((String) filter[1]).apply((String) filter[0], toFirestore(filter[2]));
    }

    /** Firestore values as Godot takes them: maps become dictionaries, lists arrays. */
    private static Object toGodot(Object value) {
        if (value instanceof Map) {
            return toGodotDictionary((Map<?, ?>) value);
        }
        if (value instanceof List) {
            return toGodotArray((List<?>) value);
        }
        return toGodotScalar(value);
    }

    private static Dictionary toGodotDictionary(Map<?, ?> map) {
        Dictionary dictionary = new Dictionary();
        for (Map.Entry<?, ?> entry : map.entrySet()) {
            dictionary.put(String.valueOf(entry.getKey()), toGodot(entry.getValue()));
        }
        return dictionary;
    }

    private static Object[] toGodotArray(List<?> list) {
        Object[] array = new Object[list.size()];
        for (int i = 0; i < array.length; i++) {
            array[i] = toGodot(list.get(i));
        }
        return array;
    }

    /**
     * Timestamps become seconds since the epoch, references paths, geo points dictionaries
     * with latitude and longitude, and blobs byte arrays.
     */
    private static Object toGodotScalar(Object value) {
        if (value instanceof Timestamp) {
            Timestamp timestamp = (Timestamp) value;
            return timestamp.getSeconds() + timestamp.getNanoseconds() / 1e9;
        }
        if (value instanceof DocumentReference) {
            return ((DocumentReference) value).getPath();
        }
        if (value instanceof GeoPoint) {
            return toGodotGeoPoint((GeoPoint) value);
        }
        if (value instanceof Blob) {
            return ((Blob) value).toBytes();
        }
        return value;
    }

    private static Dictionary toGodotGeoPoint(GeoPoint point) {
        Dictionary dictionary = new Dictionary();
        dictionary.put("latitude", point.getLatitude());
        dictionary.put("longitude", point.getLongitude());
        return dictionary;
    }

    private static Map<String, Object> toFirestoreMap(Map<?, ?> map) {
        Map<String, Object> result = new HashMap<>();
        for (Map.Entry<?, ?> entry : map.entrySet()) {
            result.put(String.valueOf(entry.getKey()), toFirestore(entry.getValue()));
        }
        return result;
    }

    /** Godot values as Firestore takes them: arrays become lists, byte arrays blobs. */
    private static Object toFirestore(Object value) {
        if (value instanceof Map) {
            return toFirestoreMap((Map<?, ?>) value);
        }
        if (value instanceof byte[]) {
            return Blob.fromBytes((byte[]) value);
        }
        if (value != null && value.getClass().isArray()) {
            int length = Array.getLength(value);
            List<Object> list = new ArrayList<>(length);
            for (int i = 0; i < length; i++) {
                list.add(toFirestore(Array.get(value, i)));
            }
            return list;
        }
        return value;
    }
}
