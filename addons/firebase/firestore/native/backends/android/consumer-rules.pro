-keepattributes RuntimeVisibleAnnotations,RuntimeInvisibleAnnotations
-keep class dev.autoload.firebase.firestore.FirebaseFirestorePlugin { public <init>(org.godotengine.godot.Godot); }
-keepclassmembers class dev.autoload.firebase.firestore.FirebaseFirestorePlugin {
    @org.godotengine.godot.plugin.UsedByGodot <methods>;
}
