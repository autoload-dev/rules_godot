package dev.autoload.firebase.analytics;

import android.app.Activity;
import android.os.Bundle;
import com.google.firebase.analytics.FirebaseAnalytics;
import java.util.Map;
import org.godotengine.godot.Dictionary;
import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

/** Google Analytics for Firebase behind the FirebaseAnalytics class of the extension. */
public final class FirebaseAnalyticsPlugin extends GodotPlugin {
    public FirebaseAnalyticsPlugin(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "FirebaseAnalyticsAndroid";
    }

    private FirebaseAnalytics analytics() {
        Activity activity = getActivity();
        return activity == null ? null : FirebaseAnalytics.getInstance(activity);
    }

    @UsedByGodot
    public void log_event(String name, Dictionary parameters) {
        FirebaseAnalytics analytics = analytics();
        if (analytics != null) {
            analytics.logEvent(name, bundle(parameters));
        }
    }

    @UsedByGodot
    public void set_user_id(String userId) {
        FirebaseAnalytics analytics = analytics();
        if (analytics != null) {
            analytics.setUserId(userId.isEmpty() ? null : userId);
        }
    }

    @UsedByGodot
    public void set_user_property(String name, String value) {
        FirebaseAnalytics analytics = analytics();
        if (analytics != null) {
            analytics.setUserProperty(name, value.isEmpty() ? null : value);
        }
    }

    @UsedByGodot
    public void set_collection_enabled(boolean enabled) {
        FirebaseAnalytics analytics = analytics();
        if (analytics != null) {
            analytics.setAnalyticsCollectionEnabled(enabled);
        }
    }

    /** Strings, integers, floats and booleans, as on iOS; booleans become 0 or 1. */
    private static Bundle bundle(Dictionary parameters) {
        Bundle bundle = new Bundle();
        for (Map.Entry<String, Object> entry : parameters.entrySet()) {
            Object value = entry.getValue();
            if (value instanceof Boolean) {
                bundle.putLong(entry.getKey(), ((Boolean) value) ? 1 : 0);
            } else if (value instanceof Integer || value instanceof Long) {
                bundle.putLong(entry.getKey(), ((Number) value).longValue());
            } else if (value instanceof Number) {
                bundle.putDouble(entry.getKey(), ((Number) value).doubleValue());
            } else {
                bundle.putString(entry.getKey(), String.valueOf(value));
            }
        }
        return bundle;
    }
}
