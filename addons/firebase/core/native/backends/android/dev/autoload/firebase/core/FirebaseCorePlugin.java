package dev.autoload.firebase.core;

import android.app.Activity;
import com.google.firebase.FirebaseApp;
import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

/**
 * Initializes the default Firebase app from the string resources firebase_config generates
 * from google-services.json. FirebaseInitProvider usually did so before the game starts; the
 * FirebaseCore class of the extension is the API, this singleton an implementation detail.
 */
public final class FirebaseCorePlugin extends GodotPlugin {
    public FirebaseCorePlugin(Godot godot) {
        super(godot);
    }

    @Override
    public String getPluginName() {
        return "FirebaseCoreAndroid";
    }

    @UsedByGodot
    public boolean initialize() {
        Activity activity = getActivity();
        if (activity == null) {
            return false;
        }
        if (!FirebaseApp.getApps(activity).isEmpty()) {
            return true;
        }
        return FirebaseApp.initializeApp(activity) != null;
    }

    @UsedByGodot
    public boolean is_initialized() {
        Activity activity = getActivity();
        return activity != null && !FirebaseApp.getApps(activity).isEmpty();
    }
}
